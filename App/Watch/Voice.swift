import AVFoundation
import SwiftUI
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

    private init() {
        autoSend = UserDefaults.standard.bool(forKey: Keys.autoSend)
        readAloud = UserDefaults.standard.bool(forKey: Keys.readAloud)
    }

    private enum Keys {
        static let autoSend = "watch.voice.autoSend"
        static let readAloud = "watch.voice.readAloud"
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
    static func present(_ onText: @escaping (String) -> Void) {
        guard let controller = WKExtension.shared().visibleInterfaceController else { return }
        controller.presentTextInputController(withSuggestions: nil, allowedInputMode: .plain) { results in
            guard let text = results?.first as? String else { return }
            DispatchQueue.main.async {
                onText(text)
            }
        }
    }
}

struct VoiceHomeSection: View {
    @EnvironmentObject private var model: WatchModel
    @ObservedObject private var preferences = VoicePreferences.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextFieldLink(prompt: Text("New task")) {
                VStack(spacing: 2) {
                    Image(systemName: "mic.fill")
                        .font(.title.weight(.bold))
                    Text("Speak")
                        .font(.footnote.weight(.semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(LojoTheme.brandGradient)
                )
            } onSubmit: { text in
                model.openVoiceConversation(text)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Voice conversation")
            .accessibilityHint("Starts dictation. Tasks, status, and approvals continue by voice.")

            Toggle(isOn: $preferences.autoSend) {
                Text("Auto-send")
                    .font(.caption2)
            }
            .accessibilityHint("Voice conversation sends a spoken task either way. Off until you turn it on.")

            Toggle(isOn: $preferences.readAloud) {
                Text("Read results aloud")
                    .font(.caption2)
            }
            .accessibilityHint("Speaks the latest finished result. Off until you turn it on.")
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .padding(.bottom, 2)
        .background {
            insetFill.ignoresSafeArea(edges: .bottom)
        }
    }

    private var insetFill: Color {
        switch scheme {
        case .light:
            return Color(red: 0.95, green: 0.95, blue: 0.96)
        case .dark:
            return .black
        @unknown default:
            return .black
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
            TextFieldLink(prompt: Text("Allow, deny, stop, or yes")) {
                Label("Voice", systemImage: "mic.fill")
                    .frame(maxWidth: .infinity)
            } onSubmit: { text in
                model.handleVoiceTurn(text, focused: session)
            }
            .buttonStyle(QuietButtonStyle(compact: true))
            .accessibilityLabel("Voice command")
            .accessibilityHint("Say allow, then yes to confirm. Deny and stop send immediately.")

            if model.pendingAllowSessionID == session.id {
                Button("Yes") {
                    model.confirmPendingAllow(session)
                }
                .buttonStyle(PrimaryButtonStyle(compact: true))
                .accessibilityLabel("Yes")
                .accessibilityHint("Confirms the spoken allow. Say yes to confirm, or tap.")
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(model.voiceLine.isEmpty ? "Say a task, or say list sessions, status, stop, or allow." : model.voiceLine)
                    .font(.footnote)
                    .foregroundStyle(LojoTheme.readablePrimary(scheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                    .accessibilityLabel("Spoken")
                    .accessibilityValue(model.voiceLine)
                TextFieldLink(prompt: Text("Reply")) {
                    Label("Speak", systemImage: "mic.fill")
                        .frame(maxWidth: .infinity)
                } onSubmit: { text in
                    model.handleVoiceTurn(text)
                }
                .buttonStyle(PrimaryButtonStyle(compact: true))
                .accessibilityLabel("Speak")
                .accessibilityHint("Continues the voice conversation.")
                if model.pendingAllowSessionID != nil {
                    Button("Yes") {
                        model.confirmSpokenAllow()
                    }
                    .buttonStyle(PrimaryButtonStyle(compact: true))
                    .accessibilityLabel("Yes")
                    .accessibilityHint("Confirms the spoken allow. Say yes to confirm, or tap.")
                }
                if let banner = model.banner, !banner.isEmpty {
                    Text(banner)
                        .font(.caption2)
                        .foregroundStyle(LojoTheme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Done") {
                    model.endVoiceConversation()
                }
                .buttonStyle(QuietButtonStyle(compact: true))
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 16)
        }
        .watchPage()
        .contentMargins(.top, 8, for: .scrollContent)
        .navigationTitle("Voice")
        .toolbarColorScheme(scheme == .dark ? .dark : .light, for: .navigationBar)
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

    func endVoiceConversation() {
        voiceModeActive = false
        pendingAllowSessionID = nil
        voiceNote = nil
        voiceNoteSessionID = nil
        VoiceSpeaker.shared.stop()
    }

    func flushHeldVoiceTask(announcingFailure: Bool = true) {
        guard forcedScreen == nil, let prompt = heldVoiceTask else { return }
        if start(prompt, announcingFailure: announcingFailure) {
            heldVoiceTask = nil
            WatchFeedback.success()
        }
    }

    func handleVoiceTurn(_ transcript: String, focused: GrokSession? = nil) {
        guard forcedScreen == nil else { return }
        let phase: VoiceDialogue = pendingAllowSessionID == nil ? .idle : .awaitingAllowYes
        let command = VoiceDialogueMatcher.interpret(transcript, phase: phase)
        heldVoiceTask = nil
        switch command {
        case .requestAllow:
            beginAllowReadback(for: focused ?? approvalSession())
        case .confirmAllow:
            confirmSpokenAllow()
        case .deny:
            guard let session = focused ?? approvalSession() ?? stoppableSession() else {
                reply("Nothing is waiting.", listenAfter: voiceModeActive)
                return
            }
            pendingAllowSessionID = nil
            voiceNote = nil
            voiceNoteSessionID = nil
            WatchFeedback.failure()
            deny(session)
            reply("Denied.", listenAfter: voiceModeActive)
        case .stop, .stopSession:
            guard let session = focused ?? stoppableSession() else {
                reply("Nothing is running.", listenAfter: voiceModeActive)
                return
            }
            pendingAllowSessionID = nil
            voiceNote = nil
            voiceNoteSessionID = nil
            WatchFeedback.click()
            stop(session)
            reply("Stopping \(session.title).", listenAfter: voiceModeActive)
        case .listSessions:
            reply(VoiceAllowScript.sessionsSpeech(snapshot.sessions), listenAfter: voiceModeActive)
        case .status:
            let running = snapshot.sessions.filter { $0.status == .running }.count
            let waiting = snapshot.sessions.filter { $0.permission != nil }.count
            reply(
                VoiceAllowScript.statusSpeech(
                    host: snapshot.hostLabel,
                    linkTitle: snapshot.link.title,
                    running: running,
                    waiting: waiting
                ),
                listenAfter: voiceModeActive
            )
        case .switchComputer(let name):
            switchSpokenComputer(name)
        case .newTask(let prompt):
            pendingAllowSessionID = nil
            voiceNote = nil
            voiceNoteSessionID = nil
            heldVoiceTask = prompt
            flushHeldVoiceTask(announcingFailure: true)
            if heldVoiceTask == nil {
                let spoken = VoiceAllowScript.shortTask(prompt)
                if let banner, !banner.isEmpty {
                    reply("\(banner) \(spoken)", listenAfter: false)
                } else {
                    reply("Sending. \(spoken)", listenAfter: false)
                }
            } else if let banner, !banner.isEmpty {
                reply(banner, listenAfter: voiceModeActive)
            } else {
                reply("Could not send that.", listenAfter: voiceModeActive)
            }
        case .cancelConfirm:
            pendingAllowSessionID = nil
            voiceNote = nil
            voiceNoteSessionID = nil
            reply("Not allowed.", listenAfter: voiceModeActive)
        case .unrecognized:
            reply("Say a task, list sessions, status, stop, or allow.", listenAfter: voiceModeActive)
        }
    }

    func confirmSpokenAllow() {
        guard let session = approvalSession(), session.id == pendingAllowSessionID else {
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
        if voiceModeActive, let arrived {
            beginAllowReadback(for: arrived, haptic: false)
            return
        }
        if let result {
            if voiceModeActive {
                voiceLine = result.text
            }
            VoiceSpeaker.shared.speakNow(result.text, dedupeKey: result.sessionID + "\n" + result.text) { [weak self] in
                guard let self, self.voiceModeActive else { return }
                self.presentNextListenIfNeeded()
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

    private func switchSpokenComputer(_ name: String?) {
        let computers = snapshot.computers
        guard !computers.isEmpty else {
            reply("No saved computers.", listenAfter: voiceModeActive)
            return
        }
        guard let name, !name.isEmpty else {
            let labels = computers.map(\.label).joined(separator: ", ")
            reply("Say switch to \(labels).", listenAfter: true)
            return
        }
        guard let label = VoiceAllowScript.matchingLabel(spoken: name, labels: computers.map(\.label)),
              let match = computers.first(where: { $0.label == label }) else {
            let labels = computers.map(\.label).joined(separator: ", ")
            reply("Say switch to \(labels).", listenAfter: true)
            return
        }
        if match.id == snapshot.activeComputerID {
            reply("Already using \(match.label).", listenAfter: voiceModeActive)
            return
        }
        selectComputer(match.id)
        if let banner, !banner.isEmpty {
            reply(banner, listenAfter: voiceModeActive)
            return
        }
        reply("Switching to \(match.label).", listenAfter: voiceModeActive)
    }

    private func approvalSession() -> GrokSession? {
        if let id = pendingAllowSessionID,
           let session = snapshot.sessions.first(where: { $0.id == id }),
           session.permission != nil {
            return session
        }
        return snapshot.sessions.first { $0.permission != nil }
    }

    private func stoppableSession() -> GrokSession? {
        if let id = pendingAllowSessionID, let session = snapshot.sessions.first(where: { $0.id == id }) {
            return session
        }
        return snapshot.sessions.first { $0.status == .needsApproval || $0.status == .running }
    }

    private func reply(_ text: String, listenAfter: Bool) {
        voiceLine = text
        VoiceSpeaker.shared.speakNow(text) { [weak self] in
            guard let self, listenAfter else { return }
            self.presentNextListenIfNeeded()
        }
    }

    private func presentNextListenIfNeeded() {
        guard forcedScreen == nil else { return }
        guard voiceModeActive || pendingAllowSessionID != nil else { return }
        VoiceInput.present { [weak self] text in
            self?.handleVoiceTurn(text)
        }
    }
}
