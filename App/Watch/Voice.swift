import AVFoundation
import SwiftUI
import WatchConnectivity
import WatchKit
import WatchRemoteCore

enum VoicePreview {
    static let task = "Summarize the open changes"
}

@MainActor
final class VoicePreferences: ObservableObject {
    static let shared = VoicePreferences()

    @Published var autoSend: Bool {
        didSet { UserDefaults.standard.set(autoSend, forKey: Keys.autoSend) }
    }

    @Published var readAloud: Bool {
        didSet {
            UserDefaults.standard.set(readAloud, forKey: Keys.readAloud)
            if !readAloud {
                VoiceSpeaker.shared.stop()
            }
        }
    }

    /// Optional. Off by default: a pause does not send. Action Button and I'm done do.
    @Published var pauseSends: Bool {
        didSet { UserDefaults.standard.set(pauseSends, forKey: Keys.pauseSends) }
    }

    /// Off until turned on. Tool prompts are allowed without a tap.
    @Published var autoApproveTools: Bool {
        didSet { UserDefaults.standard.set(autoApproveTools, forKey: Keys.autoApprove) }
    }

    private init() {
        let defaults = UserDefaults.standard
        autoSend = defaults.bool(forKey: Keys.autoSend)
        readAloud = defaults.bool(forKey: Keys.readAloud)
        if defaults.object(forKey: Keys.pauseSends) == nil {
            pauseSends = false
        } else {
            pauseSends = defaults.bool(forKey: Keys.pauseSends)
        }
        autoApproveTools = defaults.bool(forKey: Keys.autoApprove)
    }

    private enum Keys {
        static let autoSend = "watch.voice.autoSend"
        static let readAloud = "watch.voice.readAloud"
        static let pauseSends = "watch.voice.pauseSends"
        static let autoApprove = "watch.voice.autoApprove"
    }
}

/// Siri runs before the Watch model exists. The model takes the task when it comes up.
@MainActor
enum VoiceHandoff {
    static var handler: ((String) -> Void)?
    private static let key = "watch.voice.pendingTask"

    @discardableResult
    static func submit(_ raw: String) -> Bool {
        guard case .send(let prompt) = VoiceTaskPolicy.disposition(transcript: raw, autoSend: true) else {
            return false
        }
        if let handler {
            handler(prompt)
        } else {
            UserDefaults.standard.set(prompt, forKey: key)
        }
        return true
    }

    static func takePending() -> String? {
        let stored = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        guard let stored, !stored.isEmpty else { return nil }
        return stored
    }
}

final class VoiceSpeaker: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = VoiceSpeaker()
    private var synthesizer: AVSpeechSynthesizer?
    private var lastKey: String?
    private var current: AVSpeechUtterance?
    private var onFinish: (() -> Void)?

    func speakNow(_ text: String, dedupeKey: String? = nil, whenFinished: (() -> Void)? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            whenFinished?()
            return
        }
        if let dedupeKey {
            if dedupeKey == lastKey {
                whenFinished?()
                return
            }
            lastKey = dedupeKey
        }
        let speaker = synthesizer ?? AVSpeechSynthesizer()
        synthesizer = speaker
        speaker.delegate = self
        if speaker.isSpeaking {
            speaker.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        if let voice = AVSpeechSynthesisVoice(language: "en-US") {
            utterance.voice = voice
        }
        current = utterance
        onFinish = whenFinished
        speaker.speak(utterance)
    }

    func stop() {
        onFinish = nil
        current = nil
        synthesizer?.stopSpeaking(at: .immediate)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let finished = utterance
        DispatchQueue.main.async { [weak self] in
            guard let self, finished === self.current else { return }
            let finish = self.onFinish
            self.onFinish = nil
            self.current = nil
            finish?()
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let cancelled = utterance
        DispatchQueue.main.async { [weak self] in
            guard let self, cancelled === self.current else { return }
            self.onFinish = nil
            self.current = nil
        }
    }
}

enum VoiceInput {
    static func present(_ onText: @escaping (String?) -> Void) {
        guard let controller = WKExtension.shared().visibleInterfaceController else {
            DispatchQueue.main.async { onText(nil) }
            return
        }
        controller.presentTextInputController(withSuggestions: nil, allowedInputMode: .plain) { results in
            let text = results?.first as? String
            DispatchQueue.main.async {
                onText(text)
            }
        }
    }
}

struct VoicePreferenceToggles: View {
    @ObservedObject private var preferences = VoicePreferences.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $preferences.pauseSends) {
                Text("Pause sends")
                    .font(.caption2)
            }
            .accessibilityHint("Optional. Off uses the Action Button and I'm done. A pause does not send.")

            Toggle(isOn: $preferences.autoSend) {
                Text("Auto-send")
                    .font(.caption2)
            }
            .accessibilityHint("Applies to New task. Off until you turn it on. Speak still waits for I'm done unless Pause sends is on.")

            Toggle(isOn: $preferences.readAloud) {
                Text("Read results aloud")
                    .font(.caption2)
            }
            .accessibilityHint("Speaks the latest finished result. Off until you turn it on.")

            Toggle(isOn: $preferences.autoApproveTools) {
                Text("Auto-approve tools")
                    .font(.caption2)
            }
            .accessibilityIdentifier("settings.autoApprove")
            .accessibilityHint("Allows tool calls without a tap. Off until you turn it on.")
        }
    }
}

struct VoiceConfirmView: View {
    var transcript: String
    var isPreview: Bool
    @EnvironmentObject private var model: WatchModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Send this task?")
                    .font(.headline)
                    .foregroundStyle(LojoTheme.readablePrimary(scheme))
                    .padding(.top, 12)
                Text(transcript)
                    .font(.footnote)
                    .foregroundStyle(LojoTheme.readablePrimary(scheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Task")
                    .accessibilityValue(transcript)
                Button("Send") { send() }
                    .buttonStyle(PrimaryButtonStyle(compact: true))
                    .accessibilityHint("Sends the task to the active computer")
                Button("Cancel") { cancel() }
                    .buttonStyle(QuietButtonStyle(compact: true))
                if !isPreview, let banner = model.banner {
                    Text(banner)
                        .font(.caption2)
                        .foregroundStyle(LojoTheme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 16)
        }
        .watchPage()
        .contentMargins(.top, 8, for: .scrollContent)
        .navigationTitle("New task")
        .toolbarColorScheme(scheme == .dark ? .dark : .light, for: .navigationBar)
    }

    private func send() {
        guard !isPreview else { return }
        let text = transcript
        model.pendingDictation = nil
        if model.start(text) {
            WatchFeedback.success()
        }
    }

    private func cancel() {
        guard !isPreview else { return }
        model.pendingDictation = nil
    }
}

struct VoiceApprovalMic: View {
    var session: GrokSession
    @EnvironmentObject private var model: WatchModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 8) {
            Button {
                model.beginHandsFreeVoice()
            } label: {
                Label("Speak", systemImage: "mic.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(QuietButtonStyle(compact: true))
            .accessibilityLabel("Voice command")
            .accessibilityHint("Say allow, then yes. Deny and stop send on the first word. I'm done or the Action Button sends.")

            if model.pendingAllowSessionID == session.id {
                Button("Yes") {
                    model.confirmPendingAllow(session)
                }
                .buttonStyle(PrimaryButtonStyle(compact: true))
                .accessibilityLabel("Yes")
                .accessibilityHint("Confirms the spoken allow. Saying yes does this too.")
            }

            if model.voiceNoteSessionID == session.id, let note = model.voiceNote, !note.isEmpty {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(LojoTheme.readableSecondary(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct VoiceChatView: View {
    @EnvironmentObject private var model: WatchModel
    @Environment(\.colorScheme) private var scheme
    @ObservedObject private var preferences = VoicePreferences.shared

    private var showSpeakAgain: Bool {
        switch model.voiceStatus {
        case "Listening", "Hearing you", "Sending", "Speaking", "Waiting for the iPhone":
            return false
        default:
            return true
        }
    }

    private var history: [String] {
        if model.forcedScreen == "voice-loop" {
            return VoiceLoopHarness.lines(
                sessions: DemoCatalog.sessions(),
                hostLabel: "example-host",
                linkTitle: "Connected"
            )
        }
        if !model.voiceLog.isEmpty {
            return model.voiceLog
        }
        if model.forcedScreen == "voice-chat" {
            return VoiceConversationFixture.history
        }
        return []
    }

    var body: some View {
        SpeakBarPage {
            historyList
        } bar: {
            VoiceConversationBar(showSpeak: showSpeakAgain || model.forcedScreen != nil)
        }
        .watchPage()
        .navigationTitle(model.forcedScreen == "voice-loop" ? "Voice loop" : "Voice")
        .toolbarColorScheme(scheme == .dark ? .dark : .light, for: .navigationBar)
    }

    private var historyList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ListenTestHooks()
                if model.forcedScreen == "voice-loop" {
                    Text("Scripted check. The microphone stays off.")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(LojoTheme.accent)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !model.voiceStatus.isEmpty {
                    Text(model.voiceStatus)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(LojoTheme.accent)
                        .accessibilityIdentifier("voice.status")
                        .accessibilityLabel("Voice status")
                        .accessibilityValue(model.voiceStatus)
                }
                Text(model.voiceLine.isEmpty ? ListenEndpoint.hint(pauseSends: preferences.pauseSends) : model.voiceLine)
                    .font(.footnote)
                    .foregroundStyle(LojoTheme.readablePrimary(scheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("voice.line")
                    .accessibilityLabel("Spoken")
                    .accessibilityValue(model.voiceLine)
                ForEach(Array(history.enumerated()), id: \.offset) { item in
                    Text(item.element)
                        .font(.caption2)
                        .foregroundStyle(LojoTheme.readableSecondary(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("voice.line")
                }
                Button("Chats") {
                    model.voiceModeActive = false
                }
                .buttonStyle(QuietButtonStyle(compact: true))
                .accessibilityIdentifier("chat.back")
                .accessibilityLabel("Chats")
                Button("End chat") {
                    model.endChat()
                }
                .buttonStyle(QuietButtonStyle(compact: true))
                .accessibilityIdentifier("chat.end")
                .accessibilityLabel("End chat")
                if model.pendingAllowSessionID != nil {
                    Button("Yes") {
                        model.confirmSpokenAllow()
                    }
                    .buttonStyle(PrimaryButtonStyle(compact: true))
                    .accessibilityLabel("Yes")
                    .accessibilityHint("Confirms the spoken allow. Saying yes does this too.")
                }
                NavigationLink {
                    WatchComposeView()
                } label: {
                    Label("New task", systemImage: "plus")
                }
                .buttonStyle(QuietButtonStyle(compact: true))
                .accessibilityLabel("New task")
                if model.dictationOffered {
                    Button("Dictate") {
                        model.presentDictationSheet()
                    }
                    .buttonStyle(QuietButtonStyle(compact: true))
                    .accessibilityLabel("Dictate")
                    .accessibilityHint("Opens the keyboard. That sheet still needs Done.")
                }
                if let banner = model.banner, !banner.isEmpty {
                    Text(banner)
                        .font(.caption2)
                        .foregroundStyle(LojoTheme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("voice.banner")
                }
                if model.repairOffered {
                    Button(RelayUserNotice.repairText) {
                        model.requestPhonePairing()
                    }
                    .buttonStyle(QuietButtonStyle(compact: true))
                    .accessibilityIdentifier("voice.repair")
                }
                if !model.snapshot.sessions.isEmpty {
                    Text("Tasks")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(LojoTheme.readableSecondary(scheme))
                    ForEach(model.snapshot.sessions) { session in
                        Button {
                            model.openHistory(session)
                        } label: {
                            WatchRow(session: session)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("session.row.\(session.id)")
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("voice.history")
        .contentMargins(.top, 4, for: .scrollContent)
    }
}

extension WatchModel {
    func acceptDictation(_ transcript: String) {
        switch VoiceTaskPolicy.disposition(transcript: transcript, autoSend: VoicePreferences.shared.autoSend) {
        case .ignore:
            return
        case .confirm(let prompt):
            pendingDictation = prompt
            WatchFeedback.click()
        case .send(let prompt):
            pendingDictation = nil
            if start(prompt) {
                WatchFeedback.success()
            }
        }
    }

    /// Siri and the home microphone enter the same conversation.
    func submitSpokenTask(_ transcript: String) {
        guard forcedScreen == nil else { return }
        voiceModeActive = true
        handleVoiceTurn(transcript)
    }

    func openVoiceConversation(_ transcript: String) {
        guard forcedScreen == nil else { return }
        voiceModeActive = true
        handleVoiceTurn(transcript)
    }

    /// Stops the microphone now and sends the audio or text captured so far.
    /// The chat and the restored session stay open.
    func stopTalking() {
        guard forcedScreen == nil else { return }
        voiceModeActive = true
        VoiceSpeaker.shared.stop()
        speakingReply = false
        dictationPresented = false
        systemPausedListen = false
        ListenRuntime.shared.end()
        if uiTest {
            capture.stop()
            prepareID = nil
            expectID = nil
            let transcript = VoiceTestClips.transcript(forClip: injectedClip)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !transcript.isEmpty {
                remember("You: \(transcript)")
                if uiPhoneOff {
                    let reply = VoiceTestHost.reply(to: transcript)
                    if !reply.isEmpty {
                        remember(reply)
                    }
                }
            }
            voiceStatus = "Sent"
            return
        }
        let partial = inProgressUtterance()
        if !partial.isEmpty {
            remember(partial)
        }
        prepareID = nil
        if capture.finishEarly() {
            voiceStatus = "Sending"
            return
        }
        expectID = nil
        if !partial.isEmpty {
            handleVoiceTurn(partial)
            return
        }
        voiceStatus = "Paused"
    }

    private func inProgressUtterance() -> String {
        guard capture.isRunning || expectID != nil else { return "" }
        let line = voiceLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let hints = [
            VoiceSpeechCopy.listeningHint,
            VoiceSpeechCopy.waitingForPhone,
            ListenEndpoint.manualHint,
            ListenEndpoint.waitingManual,
        ]
        if line.isEmpty || hints.contains(line) {
            return ""
        }
        if line == VoiceSpeechCopy.missed || line == VoiceSpeechCopy.phoneAway {
            return ""
        }
        return line
    }

    func endVoiceConversation() {
        declinedVoicePermissionID = pendingAllowSessionID.flatMap { id in
            snapshot.sessions.first { $0.id == id }?.permission?.id
        } ?? snapshot.sessions.first { $0.permission != nil }?.permission?.id
        voiceModeActive = false
        resumedSessionID = nil
        pendingAllowSessionID = nil
        voiceNote = nil
        voiceNoteSessionID = nil
        prepareID = nil
        expectID = nil
        speakingReply = false
        dictationPresented = false
        dictationOffered = false
        missedTurns = 0
        voiceStatus = ""
        systemPausedListen = false
        discardPendingHostAudio()
        capture.stop()
        ListenRuntime.shared.end()
        VoiceSpeaker.shared.stop()
    }

    func continueListening() {
        if uiTest {
            beginHandsFreeVoice()
            return
        }
        guard forcedScreen == nil else { return }
        applyListenChrome()
        DispatchQueue.main.async { [weak self] in
            self?.armListener()
        }
    }

    func beginHandsFreeVoice() {
        if uiTest {
            voiceModeActive = true
            if uiPhoneOff {
                let route = VoiceListenPolicy.route(
                    phoneReachable: false,
                    attempt: uiHostReady ? 0 : VoiceListenPolicy.phoneWaitAttempts,
                    recognitionRefused: false,
                    captureFailed: false,
                    hostReady: uiHostReady
                )
                switch route {
                case .handsFree, .handsFreeHost:
                    voiceStatus = "Listening"
                    if voiceLog.isEmpty && voiceLine.isEmpty {
                        voiceLine = ListenEndpoint.hint(pauseSends: VoicePreferences.shared.pauseSends)
                        voiceLog = VoiceConversationFixture.history
                    }
                    scheduleUICap()
                case .presentDictation:
                    voiceLine = VoiceSpeechCopy.phoneAway
                    voiceStatus = "Dictation"
                    dictationOffered = true
                case .waitForPhone, .offerDictation:
                    offerDictation(VoiceSpeechCopy.phoneAway)
                @unknown default:
                    offerDictation(VoiceSpeechCopy.unavailable)
                }
                return
            }
            voiceStatus = "Listening"
            if voiceLog.isEmpty && voiceLine.isEmpty {
                voiceLine = ListenEndpoint.hint(pauseSends: VoicePreferences.shared.pauseSends)
                voiceLog = VoiceConversationFixture.history
            }
            scheduleUICap()
            return
        }
        resumedSessionID = nil
        guard forcedScreen == nil else { return }
        appIsActive = true
        declinedVoicePermissionID = nil
        dictationOffered = false
        missedTurns = 0
        voiceModeActive = true
        if let session = snapshot.sessions.first(where: { $0.permission != nil }),
           pendingAllowSessionID == nil,
           spokenPermissionIDs.contains(session.permission?.id ?? "") == false {
            beginAllowReadback(for: session, haptic: false)
            return
        }
        applyListenChrome()
        DispatchQueue.main.async { [weak self] in
            self?.armListener()
        }
    }

    func currentPhoneReachable() -> Bool {
        guard WCSession.isSupported() else { return false }
        let session = WCSession.default
        return session.activationState == .activated && session.isReachable
    }

    func setActive(_ active: Bool) {
        appIsActive = active
        if !uiTest {
            directNoteDisplay(active)
        }
        guard forcedScreen == nil, !uiTest else { return }
        if !active {
            holdThroughWristDown()
            return
        }
        let resumeListen = systemPausedListen || capture.isSuspended || capture.isRunning
        resumeAfterWristUp()
        if resumeListen || isManualListenActive {
            return
        }
        if let session = snapshot.sessions.first(where: { $0.permission != nil }) {
            considerSpokenApproval(for: session)
        }
    }

    func flushHeldVoiceTask(announcingFailure: Bool = true) {
        guard forcedScreen == nil, let prompt = heldVoiceTask else { return }
        if start(prompt, announcingFailure: announcingFailure, continueRestored: resumedSessionID != nil) {
            heldVoiceTask = nil
            WatchFeedback.success()
        }
    }

    func handleVoiceTurn(_ transcript: String, focused: GrokSession? = nil) {
        guard forcedScreen == nil else { return }
        let effect = VoiceTurnPlanner.effect(for: transcript, context: turnContext(focused: focused))
        heldVoiceTask = nil
        apply(effect)
    }

    func receiveVoice(_ raw: String) {
        guard forcedScreen == nil, let packet = VoiceWire.decode(raw) else { return }
        switch packet.kind {
        case .prepare, .audio:
            return
        case .ready:
            guard packet.utteranceID == prepareID else { return }
            prepareID = nil
            let note = packet.text == "on-device" ? "On-device speech" : "Speech on iPhone"
            remember(note)
            capture.start()
        case .failure:
            guard packet.utteranceID == prepareID || packet.utteranceID == expectID else { return }
            prepareID = nil
            expectID = nil
            capture.stop()
            let reason = packet.text.isEmpty ? VoiceSpeechCopy.unavailable : packet.text
            if reason == VoiceSpeechCopy.missed {
                noteMissedUtterance()
            } else {
                offerDictation(reason)
            }
        case .transcript:
            guard packet.utteranceID == expectID else { return }
            if !packet.isLast {
                voiceLine = packet.text
                voiceStatus = "Hearing you"
                return
            }
            expectID = nil
            if let command = VoiceTranscriptGate.commandText(packet.text, isFinal: true) {
                missedTurns = 0
                remember("Heard \(command)")
                handleVoiceTurn(command)
            } else {
                noteMissedUtterance()
            }
        }
    }

    func armListener(attempt: Int = 0) {
        guard forcedScreen == nil, appIsActive else { return }
        guard voiceModeActive || pendingAllowSessionID != nil else { return }
        guard !speakingReply, !capture.isRunning, prepareID == nil, !dictationPresented else { return }
        let phoneReachable = currentPhoneReachable()
        if phoneReachable {
            reachable = true
        }
        let route = VoiceListenPolicy.route(
            phoneReachable: phoneReachable,
            attempt: attempt,
            recognitionRefused: false,
            captureFailed: false,
            hostReady: hostIsReady
        )
        switch route {
        case .waitForPhone:
            voiceStatus = "Waiting for the iPhone"
            voiceLine = ListenEndpoint.waiting(pauseSends: VoicePreferences.shared.pauseSends)
            DispatchQueue.main.asyncAfter(deadline: .now() + VoiceListenPolicy.phoneWaitSpacing) { [weak self] in
                self?.armListener(attempt: attempt + 1)
            }
        case .presentDictation:
            fallBackToDictation(VoiceSpeechCopy.phoneAway, presentSheet: true)
        case .offerDictation:
            offerDictation(VoiceSpeechCopy.waiting)
        case .handsFree:
            beginCapture(attempt: attempt)
        case .handsFreeHost:
            beginHostCapture()
        @unknown default:
            offerDictation(VoiceSpeechCopy.unavailable)
        }
    }

    private func beginCapture(attempt: Int) {
        voiceSink = .phone
        capture.endsOnSilence = ListenEndpoint.endsOnSilence(pauseSends: VoicePreferences.shared.pauseSends)
        applyListenChrome()
        retainRuntime()
        capture.requestPermission { [weak self] granted in
            guard let self, self.voiceSink == .phone else { return }
            guard granted else {
                self.offerDictation(VoiceSpeechCopy.micDenied)
                return
            }
            let id = UUID().uuidString
            self.prepareID = id
            self.dictationOffered = false
            self.voiceStatus = "Listening"
            self.schedulePrepareTimeout(id)
            WatchVoiceLink.send(VoicePacket.prepare(id)) { [weak self] ok in
                guard let self, self.prepareID == id else { return }
                guard !ok else { return }
                self.prepareID = nil
                let next = attempt + 1
                let retry = VoiceListenPolicy.route(
                    phoneReachable: self.currentPhoneReachable(),
                    attempt: next,
                    recognitionRefused: false,
                    captureFailed: false,
                    hostReady: self.hostIsReady
                )
                switch retry {
                case .handsFree, .handsFreeHost, .waitForPhone:
                    self.armListener(attempt: next)
                case .presentDictation:
                    self.fallBackToDictation(VoiceSpeechCopy.phoneAway, presentSheet: true)
                case .offerDictation:
                    self.offerDictation(VoiceSpeechCopy.waiting)
                @unknown default:
                    self.offerDictation(VoiceSpeechCopy.unavailable)
                }
            }
        }
    }

    func noteMissedUtterance() {
        missedTurns += 1
        voiceLine = VoiceSpeechCopy.missed
        if missedTurns >= 3 {
            offerDictation(VoiceSpeechCopy.missed)
            return
        }
        relinquishListen(status: "Paused")
    }

    func offerDictation(_ reason: String) {
        guard forcedScreen == nil else { return }
        discardPendingHostAudio()
        capture.stop()
        ListenRuntime.shared.end()
        prepareID = nil
        expectID = nil
        voiceModeActive = true
        voiceLine = reason
        voiceStatus = "Paused"
        dictationOffered = true
        remember(reason)
    }

    func fallBackToDictation(_ reason: String, presentSheet: Bool = false) {
        guard forcedScreen == nil else { return }
        voiceModeActive = true
        discardPendingHostAudio()
        capture.stop()
        ListenRuntime.shared.end()
        prepareID = nil
        expectID = nil
        voiceLine = reason
        voiceStatus = presentSheet ? "Dictation" : "Paused"
        dictationOffered = true
        remember(reason)
        guard presentSheet else { return }
        presentDictationSheet()
    }

    func presentDictationSheet() {
        guard forcedScreen == nil, !dictationPresented else { return }
        dictationPresented = true
        voiceStatus = "Dictation"
        VoiceInput.present { [weak self] text in
            guard let self else { return }
            self.dictationPresented = false
            let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmed.isEmpty else {
                self.voiceStatus = "Paused"
                return
            }
            self.handleVoiceTurn(trimmed)
        }
    }

    func confirmSpokenAllow() {
        guard let id = pendingAllowSessionID,
              let session = snapshot.sessions.first(where: { $0.id == id }),
              session.permission != nil else {
            pendingAllowSessionID = nil
            reply("Nothing is waiting for approval.", listenAfter: voiceModeActive)
            return
        }
        confirmPendingAllow(session)
    }

    func confirmPendingAllow(_ session: GrokSession) {
        guard pendingAllowSessionID == session.id else { return }
        pendingAllowSessionID = nil
        voiceNote = nil
        voiceNoteSessionID = nil
        WatchFeedback.success()
        allow(session)
        reply("Allowed.", listenAfter: voiceModeActive)
    }

    func noteVoiceSnapshot(previous: PhoneSnapshot, current: PhoneSnapshot) {
        guard forcedScreen == nil else { return }
        let speakResults = VoicePreferences.shared.readAloud || voiceModeActive
        let includeNew = previous.mode == current.mode
        let result = speakResults
            ? VoiceResultPicker.latestResult(previous: previous.sessions, current: current.sessions, includeNew: includeNew)
            : nil
        let oldIDs = Set(previous.sessions.compactMap(\.permission?.id))
        let arrived = current.sessions.first { session in
            guard let permission = session.permission else { return false }
            return !oldIDs.contains(permission.id)
        }
        if let arrived, hasLiveSnapshot, appIsActive, arrived.permission?.id != declinedVoicePermissionID {
            considerSpokenApproval(for: arrived)
            return
        }
        if let result {
            capture.stop()
            prepareID = nil
            expectID = nil
            if voiceModeActive {
                voiceLine = result.text
            }
            speakingReply = true
            voiceStatus = "Speaking"
            VoiceSpeaker.shared.speakNow(result.text, dedupeKey: result.sessionID + "\n" + result.text) { [weak self] in
                guard let self else { return }
                self.speakingReply = false
                guard self.voiceModeActive else { return }
                self.relinquishListen(status: "Sent")
            }
        }
    }

    private func beginAllowReadback(for session: GrokSession?, haptic: Bool = true) {
        guard let session, let permission = session.permission else {
            reply("Nothing is waiting for approval.", listenAfter: voiceModeActive)
            return
        }
        pendingAllowSessionID = session.id
        let line = VoiceAllowScript.readback(title: permission.title, detail: permission.detail)
        voiceNote = line
        voiceNoteSessionID = session.id
        if haptic {
            WatchFeedback.notification()
        }
        reply(line, listenAfter: true)
    }

    private func turnContext(focused: GrokSession?) -> VoiceTurnContext {
        VoiceTurnContext(
            inConversation: voiceModeActive,
            hostLabel: snapshot.hostLabel,
            linkTitle: snapshot.link.title,
            sessions: snapshot.sessions,
            computers: snapshot.computers,
            activeComputerID: snapshot.activeComputerID,
            focusedSessionID: focused?.id,
            pendingAllowSessionID: pendingAllowSessionID
        )
    }

    private func apply(_ effect: VoiceTurnEffect) {
        pendingAllowSessionID = effect.pendingAllowSessionID
        if effect.phase == .awaitingAllowYes {
            voiceNote = effect.spoken
            voiceNoteSessionID = effect.pendingAllowSessionID
        } else {
            voiceNote = nil
            voiceNoteSessionID = nil
        }
        if effect.listenAgain {
            voiceModeActive = true
        }
        switch effect.action {
        case .none:
            reply(effect.spoken, listenAfter: effect.listenAgain)
        case .allow(let sessionID):
            guard let session = session(sessionID) else {
                reply("Nothing is waiting for approval.", listenAfter: effect.listenAgain)
                return
            }
            WatchFeedback.success()
            allow(session)
            reply(effect.spoken, listenAfter: effect.listenAgain)
        case .deny(let sessionID):
            guard let session = session(sessionID) else {
                reply("Nothing is waiting.", listenAfter: effect.listenAgain)
                return
            }
            WatchFeedback.failure()
            deny(session)
            reply(effect.spoken, listenAfter: effect.listenAgain)
        case .stop(let sessionID):
            guard let session = session(sessionID) else {
                reply("Nothing is running.", listenAfter: effect.listenAgain)
                return
            }
            WatchFeedback.click()
            stop(session)
            reply(effect.spoken, listenAfter: effect.listenAgain)
        case .startTask(let prompt):
            heldVoiceTask = prompt
            flushHeldVoiceTask(announcingFailure: true)
            if heldVoiceTask == nil {
                if let banner, !banner.isEmpty {
                    reply("\(banner) \(effect.spoken)", listenAfter: effect.listenAgain)
                } else {
                    reply(effect.spoken, listenAfter: effect.listenAgain)
                }
            } else if let banner, !banner.isEmpty {
                reply(banner, listenAfter: effect.listenAgain)
            } else {
                reply("Could not send that.", listenAfter: effect.listenAgain)
            }
        case .selectComputer(let id):
            selectComputer(id)
            if let banner, !banner.isEmpty {
                reply(banner, listenAfter: effect.listenAgain)
            } else {
                reply(effect.spoken, listenAfter: effect.listenAgain)
            }
        }
    }

    private func session(_ id: String) -> GrokSession? {
        snapshot.sessions.first { $0.id == id }
    }

    @discardableResult
    private func considerSpokenApproval(for session: GrokSession) -> Bool {
        guard hasLiveSnapshot, appIsActive, forcedScreen == nil else { return false }
        guard let permission = session.permission else { return false }
        if permission.id == declinedVoicePermissionID { return false }
        if spokenPermissionIDs.contains(permission.id) { return false }
        spokenPermissionIDs.insert(permission.id)
        voiceModeActive = true
        beginAllowReadback(for: session, haptic: false)
        return true
    }

    func schedulePrepareTimeout(_ id: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [weak self] in
            guard let self, self.prepareID == id else { return }
            self.prepareID = nil
            if self.hostIsReady {
                self.beginHostCapture()
                return
            }
            if self.currentPhoneReachable() {
                self.offerDictation(VoiceSpeechCopy.waiting)
            } else {
                self.fallBackToDictation(VoiceSpeechCopy.phoneAway, presentSheet: true)
            }
        }
    }

    func scheduleTranscriptTimeout(_ id: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.expectID == id else { return }
            self.expectID = nil
            self.noteMissedUtterance()
        }
    }

    func remember(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        voiceLog.append(trimmed)
        if voiceLog.count > 5 {
            voiceLog.removeFirst(voiceLog.count - 5)
        }
    }

    private func reply(_ text: String, listenAfter: Bool) {
        capture.stop()
        discardPendingHostAudio()
        prepareID = nil
        expectID = nil
        voiceLine = text
        remember(text)
        speakingReply = true
        voiceStatus = "Speaking"
        VoiceSpeaker.shared.speakNow(text) { [weak self] in
            guard let self else { return }
            self.speakingReply = false
            guard listenAfter, self.voiceModeActive || self.pendingAllowSessionID != nil else {
                self.voiceStatus = ""
                return
            }
            self.relinquishListen(status: "Sent")
        }
    }
}
