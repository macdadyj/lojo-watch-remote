import SwiftUI
import WatchConnectivity
import WatchKit
import WatchRemoteCore

@main
struct WatchRemoteWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var appDelegate
    @StateObject private var model = WatchModel()

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environmentObject(model)
        }
    }
}

/// Foreground and background transitions are not Action Button presses.
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    func handle(_ userActivity: NSUserActivity) {
        guard userActivity.activityType == ListenActionButton.activityType else { return }
        Task { @MainActor in
            ListenActionButton.press()
        }
    }
}

enum VoiceSink: Equatable {
    case phone
    case host
}

@MainActor
final class WatchModel: ObservableObject {
    @Published var snapshot = DemoCatalog.snapshot()
    @Published var forcedScreen: String?
    @Published var appearance: AppearanceChoice = .system
    @Published var selectedID: String?
    @Published var reachable = false
    @Published var banner: String?
    @Published var pathTitle = "via iPhone"
    @Published var pendingDictation: String?
    @Published var pendingAllowSessionID: String?
    @Published var voiceNote: String?
    @Published var voiceNoteSessionID: String?
    @Published var voiceModeActive = false
    @Published var voiceLine = ""
    @Published var voiceStatus = ""
    @Published var voiceLog: [String] = []
    @Published var dictationOffered = false
    /// Set only for the watchOS UI tests. The microphone and the real host stay off.
    private(set) var uiTest = false
    /// UI test launch with the iPhone app treated as unreachable.
    private(set) var uiPhoneOff = false
    /// UI test launch where a direct pairing exists. False when `-WatchRemoteHostMissing` is set.
    private(set) var uiHostReady = false
    /// UI test launch that opens a session id the demo catalog does not have.
    var uiOpenMissing = false
    /// UI test launch that shows the wrist-down control.
    private(set) var uiShowHooks = false
    /// UI test launch that fires the duration cap after Speak.
    private(set) var uiMaxListen = false
    /// Clip name from `-WatchRemoteInjectClip`. Empty on a normal launch.
    private(set) var injectedClip = ""
    @Published var repairOffered = false
    @Published var wristDown = false
    var systemPausedListen = false
    var heldVoiceTask: String?
    let capture = WatchVoiceCapture()
    /// Where the current listen sends audio. The iPhone path streams chunks. The host path keeps one utterance.
    var voiceSink: VoiceSink = .phone
    private var hostPCM = Data()
    private var pendingHostPCM: Data?
    private var pendingHostID: String?
    var prepareID: String?
    var expectID: String?
    var speakingReply = false
    var dictationPresented = false
    var missedTurns = 0
    var appIsActive = false
    var hasLiveSnapshot = false
    var declinedVoicePermissionID: String?
    var spokenPermissionIDs = Set<String>()
    private let bridge = WatchBridge()
    private let direct = DirectSession()
    private var pendingPrompt: String?
    private var pendingContinues = false
    private var pendingResumeID: String?
    var relayProbe = false
    var phoneProbe = false
    var transportProbe: Bool { relayProbe || phoneProbe }
    @Published var showTransportDiagnostics = false
    private var probeStep: TransportProbeStep = .idle
    private var phoneProbeSentAt: Date?

    var promptIsQueued: Bool { pendingPrompt != nil }

    var diagnosticsLine: String {
        WatchTransportDiagnostics.line(path: pathTitle, phase: direct.phaseLabel, lastError: direct.lastError)
    }

    func toggleTransportDiagnostics() {
        showTransportDiagnostics.toggle()
    }
    /// Set when a history row restored a chat. Later voice turns prompt that session.
    var resumedSessionID: String?

    init() {
        ListenActionButton.register { [weak self] in
            self?.toggleFromActionButton()
        }
        let arguments = ProcessInfo.processInfo.arguments
        let environment = ProcessInfo.processInfo.environment
        uiTest = Self.isUITest(arguments: arguments, environment: environment)
        if uiTest {
            VoicePreferences.shared.actionHintSeen = false
            snapshot = DemoCatalog.snapshot()
            uiPhoneOff = arguments.contains("-WatchRemotePhoneOff") || environment["WATCHREMOTE_PHONE_OFF"] == "1"
            let hostMissing = arguments.contains("-WatchRemoteHostMissing") || environment["WATCHREMOTE_HOST_MISSING"] == "1"
            uiHostReady = uiPhoneOff && !hostMissing
            uiOpenMissing = arguments.contains("-WatchRemoteMissingSession")
            uiShowHooks = arguments.contains("-WatchRemoteShowHooks")
            uiMaxListen = arguments.contains("-WatchRemoteMaxListen")
            VoicePreferences.shared.pauseSends = arguments.contains("-WatchRemotePauseSends")
            if uiPhoneOff && uiHostReady {
                pathTitle = "direct"
                snapshot.mode = .ssh
                snapshot.link = .connected
            } else if uiPhoneOff {
                pathTitle = "Pair on iPhone first"
                snapshot.mode = .ssh
                snapshot.link = .needsPairing
            } else {
                pathTitle = "Demo"
            }
            let clip = Self.argument("-WatchRemoteInjectClip", arguments: arguments) ?? environment["WATCHREMOTE_INJECT_CLIP"] ?? ""
            injectedClip = clip
            if !clip.isEmpty, WatchAudioInjection.samples(named: clip) == nil {
                banner = "Test clip missing."
            }
            return
        }
        forcedScreen = Self.argument("-WatchRemoteScreen", arguments: arguments) ?? environment["WATCHREMOTE_SCREEN"]
        let appearanceName = Self.argument("-WatchRemoteAppearance", arguments: arguments) ?? environment["WATCHREMOTE_APPEARANCE"]
        if let appearanceName, let choice = AppearanceChoice(rawValue: appearanceName) {
            appearance = choice
        }
        if forcedScreen != nil {
            snapshot = DemoCatalog.preview(named: forcedScreen ?? "") ?? DemoCatalog.snapshot()
            if forcedScreen == "session" || forcedScreen == "long" { selectedID = DemoCatalog.approvalID }
            pathTitle = Self.pathTitle(for: forcedScreen, snapshot: snapshot, reachable: false, direct: false)
            if forcedScreen == "voice-chat" || forcedScreen == "voice-loop" {
                voiceStatus = "Listening"
                voiceLine = ListenEndpoint.manualHint
                voiceLog = forcedScreen == "voice-chat" ? VoiceConversationFixture.history : []
                if forcedScreen == "voice-chat" {
                    pendingAllowSessionID = DemoCatalog.approvalID
                }
            }
        }
        direct.restore()
        relayProbe = arguments.contains("-WatchRemoteRelayProbe")
        phoneProbe = arguments.contains("-WatchRemotePhoneProbe")
        if let pairing = Self.argument("-WatchRemoteDirectPairing", arguments: arguments) {
            direct.ingest(pairing, resetCounters: true)
        }
        direct.onBanner = { [weak self] text in
            guard let self else { return }
            self.banner = text
            if text == RelayUserNotice.reconnectingText, self.probeStep == .sentFresh {
                self.probeStep = .dropped
            }
            if text == SessionResume.missingMessage {
                self.showMissingChat()
                return
            }
            guard let text, self.voiceSink == .host, self.expectID != nil else { return }
            if text == VoiceSpeechCopy.noTranscriber {
                self.offerDictation(text)
                return
            }
            self.giveUpOnHostTranscript(text)
        }
        direct.onChange = { [weak self] in
            self?.applyDirect()
        }
        direct.onRestored = { [weak self] id, lines in
            self?.showRestored(id, lines: lines)
        }
        direct.onTranscript = { [weak self] id, text in
            self?.acceptHostTranscript(id, text: text)
        }
        direct.onUp = { [weak self] in
            self?.flushPendingHostAudio()
            self?.considerRelayProbe()
        }
        direct.onStarted = { [weak self] id in
            guard let self, !id.isEmpty else { return }
            if self.resumedSessionID == nil || self.resumedSessionID == id {
                self.resumedSessionID = id
                self.voiceModeActive = true
            }
        }
        direct.onRepair = { [weak self] in
            guard let self else { return }
            self.repairOffered = true
            self.requestPhonePairing()
        }
        bridge.start { [weak self] snapshot, reachable, directText in
            guard let self, self.forcedScreen == nil else { return }
            if let directText {
                self.direct.ingest(directText)
            }
            if let snapshot {
                let previous = Set(self.snapshot.sessions.compactMap(\.permission?.id))
                let arrived = Set(snapshot.sessions.compactMap(\.permission?.id)).subtracting(previous)
                self.hasLiveSnapshot = true
                self.snapshot = snapshot
                if VoicePreferences.shared.autoApproveTools != snapshot.autoApproveTools {
                    VoicePreferences.shared.autoApproveTools = snapshot.autoApproveTools
                }
                self.noteResume(from: snapshot)
                self.autoApproveWaitingTools()
                if !arrived.isEmpty, !VoicePreferences.shared.autoApproveTools { WatchFeedback.notification() }
            }
            self.reachable = reachable
            self.route()
            self.deliverPendingPromptIfPhoneIsBack()
            self.flushHeldVoiceTask()
            if self.phoneProbe {
                self.considerPhoneProbe()
            }
        }
        VoiceHandoff.handler = { [weak self] prompt in
            self?.submitSpokenTask(prompt)
        }
        VoiceInbox.handler = { [weak self] text in
            self?.receiveVoice(text)
        }
        capture.onPacket = { [weak self] packet in
            guard let self else { return }
            switch self.voiceSink {
            case .phone:
                WatchVoiceLink.send(packet)
            case .host:
                self.appendHostAudio(packet)
            }
        }
        capture.onBegan = { [weak self] id in
            self?.expectID = id
            self?.voiceStatus = "Hearing you"
            if self?.voiceSink == .host {
                self?.hostPCM.removeAll(keepingCapacity: true)
            }
        }
        capture.onEnded = { [weak self] id in
            guard let self else { return }
            self.voiceStatus = "Sending"
            switch self.voiceSink {
            case .phone:
                self.scheduleTranscriptTimeout(id)
            case .host:
                self.sendHostUtterance(id)
            }
        }
        capture.onEmpty = { [weak self] in
            guard let self else { return }
            self.relinquishListen(status: "Paused")
        }
        capture.onFinishedEmpty = { [weak self] in
            guard let self, self.voiceModeActive else { return }
            self.expectID = nil
            self.discardPendingHostAudio()
            self.systemPausedListen = false
            self.relinquishListen(status: "Paused")
        }
        capture.onPhase = { [weak self] text in
            self?.voiceStatus = text
        }
        capture.onFailed = { [weak self] in
            guard let self else { return }
            let decision = VoiceListenPolicy.route(
                phoneReachable: self.currentPhoneReachable(),
                attempt: 0,
                recognitionRefused: false,
                captureFailed: true,
                hostReady: self.hostIsReady
            )
            switch decision {
            case .presentDictation:
                self.fallBackToDictation(VoiceSpeechCopy.micUnavailable, presentSheet: true)
            case .offerDictation, .handsFree, .handsFreeHost, .waitForPhone:
                self.offerDictation(VoiceSpeechCopy.micUnavailable)
            @unknown default:
                self.offerDictation(VoiceSpeechCopy.micUnavailable)
            }
        }
        if forcedScreen == nil, let pending = VoiceHandoff.takePending() {
            submitSpokenTask(pending)
        }
        if relayProbe {
            direct.connectIfNeeded()
        }
    }

    func consumeUITestLaunch() {
        guard uiOpenMissing else { return }
        uiOpenMissing = false
        openHistory(GrokSession(id: "missing-session", title: "Gone", summary: "Gone.", status: .idle))
    }

    func wake() {
        guard forcedScreen == nil, !uiTest else { return }
        route(waking: true)
    }

    func refresh() {
        guard forcedScreen == nil, !uiTest else { return }
        if useDirect {
            direct.refresh()
            return
        }
        _ = bridge.send(PhoneCommand(kind: .refresh))
    }

    func openHistory(_ session: GrokSession) {
        resumedSessionID = session.id
        voiceModeActive = true
        let lines = SessionResume.displayLines(
            title: session.title,
            summary: session.summary,
            transcript: session.transcript ?? []
        )
        voiceStatus = "Restoring"
        voiceLine = lines.first ?? session.title
        voiceLog = Array(lines.dropFirst())
        banner = nil
        let known = snapshot.sessions.contains { $0.id == session.id }
        if uiTest || forcedScreen != nil {
            if known {
                voiceStatus = "Restored"
            } else {
                showMissingChat()
            }
            return
        }
        guard known || snapshot.mode != .demo else {
            showMissingChat()
            return
        }
        if useDirect {
            direct.resume(session.id)
            return
        }
        if !reachable && direct.hasPairing {
            pendingResumeID = session.id
            direct.connectIfNeeded()
            banner = "Connecting directly."
            return
        }
        let queued = bridge.send(PhoneCommand(kind: .resume, sessionID: session.id))
        if queued {
            return
        }
        if direct.hasPairing {
            pendingResumeID = session.id
            direct.connectIfNeeded()
            banner = "Connecting directly."
        } else {
            banner = "Pair on iPhone first."
            voiceStatus = "Unavailable"
        }
    }

    func showRestored(_ id: String, lines: [String]) {
        let cleaned = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return }
        guard resumedSessionID == nil || resumedSessionID == id else { return }
        resumedSessionID = id
        voiceModeActive = true
        voiceStatus = "Restored"
        voiceLine = cleaned[0]
        voiceLog = Array(cleaned.dropFirst())
        banner = nil
        if let index = snapshot.sessions.firstIndex(where: { $0.id == id }) {
            snapshot.sessions[index].transcript = cleaned
        }
    }

    func noteResume(from snapshot: PhoneSnapshot) {
        guard resumedSessionID != nil || phoneProbe else { return }
        if snapshot.banner == SessionResume.missingMessage {
            showMissingChat()
            return
        }
        if phoneProbe, resumedSessionID == nil,
           let chat = snapshot.sessions.first(where: { session in
               session.transcript?.contains(where: { $0.contains("I can hear you") }) == true
           }) {
            resumedSessionID = chat.id
            voiceModeActive = true
        }
        absorbOpenTranscript(preferRestored: voiceStatus == "Restoring" || voiceStatus.isEmpty)
    }

    /// Puts the open chat's transcript on screen. A later reply must not flip the status back to Restored.
    func absorbOpenTranscript(preferRestored: Bool) {
        guard let id = resumedSessionID,
              let session = snapshot.sessions.first(where: { $0.id == id }),
              let raw = session.transcript else { return }
        let cleaned = raw.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return }
        voiceModeActive = true
        let keepStatus = !preferRestored && !voiceStatus.isEmpty && voiceStatus != "Restoring" && voiceStatus != "Restored"
        voiceLine = cleaned[0]
        voiceLog = Array(cleaned.dropFirst())
        if !keepStatus {
            voiceStatus = "Restored"
        }
    }

    func showMissingChat() {
        voiceModeActive = true
        voiceStatus = "Unavailable"
        voiceLine = SessionResume.missingMessage
        voiceLog = []
        banner = SessionResume.missingMessage
    }

    @discardableResult
    func start(_ prompt: String, announcingFailure: Bool = true, continueRestored: Bool = false) -> Bool {
        let sessionID = continueRestored ? resumedSessionID : nil
        if !continueRestored {
            resumedSessionID = nil
            pendingResumeID = nil
        }
        if forcedScreen != nil {
            return true
        }
        if relayProbe {
            guard direct.phase == .up else {
                pendingPrompt = prompt
                pendingContinues = sessionID != nil
                direct.connectIfNeeded()
                banner = "Connecting directly."
                return false
            }
            direct.start(prompt, cwd: nil, sessionID: sessionID)
            banner = nil
            return true
        }
        if useDirect {
            direct.start(prompt, cwd: nil, sessionID: sessionID)
            banner = nil
            return true
        }
        if !reachable && direct.hasPairing {
            pendingPrompt = prompt
            pendingContinues = sessionID != nil
            direct.connectIfNeeded()
            banner = "Connecting directly."
            return false
        }
        let queued = bridge.send(PhoneCommand(kind: .start, prompt: prompt, sessionID: sessionID))
        if queued {
            banner = nil
        } else if announcingFailure {
            banner = direct.hasPairing ? "Connecting directly. Try again in a moment." : "Pair on iPhone first."
            if direct.hasPairing {
                direct.connectIfNeeded()
            }
        } else if direct.hasPairing {
            direct.connectIfNeeded()
        }
        return queued
    }

    private func deliverPendingPromptIfPhoneIsBack() {
        guard reachable, let prompt = pendingPrompt else { return }
        let sessionID = pendingContinues ? resumedSessionID : nil
        guard bridge.send(PhoneCommand(kind: .start, prompt: prompt, sessionID: sessionID)) else { return }
        pendingPrompt = nil
        pendingContinues = false
        heldVoiceTask = nil
        banner = nil
        if voiceStatus == "Sending" {
            voiceStatus = "Sent"
        }
    }

    func allow(_ session: GrokSession) {
        if useDirect {
            direct.approve(session)
            return
        }
        send(PhoneCommand(kind: .approve, sessionID: session.id, permissionID: session.permission?.id))
    }

    func deny(_ session: GrokSession) {
        if useDirect {
            direct.deny(session)
            return
        }
        send(PhoneCommand(kind: .deny, sessionID: session.id, permissionID: session.permission?.id))
    }

    func stop(_ session: GrokSession) {
        if useDirect {
            direct.stop(session)
            return
        }
        send(PhoneCommand(kind: .stop, sessionID: session.id))
    }

    func setAutoApprove(_ enabled: Bool) {
        guard forcedScreen == nil, !uiTest else { return }
        _ = bridge.send(PhoneCommand(kind: .setAutoApprove, enabled: enabled))
    }

    func endChat() {
        guard let id = resumedSessionID, let session = snapshot.sessions.first(where: { $0.id == id }) else {
            remember("Ended.")
            return
        }
        stop(session)
        remember("Ended.")
    }

    private var autoApprovedPermissionIDs = Set<String>()

    func autoApproveWaitingTools() {
        guard VoicePreferences.shared.autoApproveTools else { return }
        for session in snapshot.sessions {
            guard let permission = session.permission else { continue }
            guard autoApprovedPermissionIDs.insert(permission.id).inserted else { continue }
            allow(session)
            remember(ChatTranscript.autoApproved(permission.title))
        }
    }

    func selectComputer(_ id: String) {
        guard forcedScreen == nil else { return }
        if useDirect {
            banner = "Open the iPhone to switch computers."
            return
        }
        let queued = bridge.send(PhoneCommand(kind: .selectComputer, computerID: id))
        banner = queued ? nil : "Pair on iPhone first."
    }

    var hostIsReady: Bool { direct.hasPairing }

    func discardPendingHostAudio() {
        hostPCM.removeAll(keepingCapacity: true)
        pendingHostPCM = nil
        pendingHostID = nil
    }

    /// Records immediately. The utterance is sent when the direct socket is up.
    func beginHostCapture() {
        guard forcedScreen == nil, !uiTest else { return }
        voiceSink = .host
        hostPCM.removeAll(keepingCapacity: true)
        capture.requestPermission { [weak self] granted in
            guard let self, self.voiceSink == .host else { return }
            guard granted else {
                self.offerDictation(VoiceSpeechCopy.micDenied)
                return
            }
            self.dictationOffered = false
            self.capture.endsOnSilence = ListenEndpoint.endsOnSilence(pauseSends: VoicePreferences.shared.pauseSends)
            self.applyListenChrome()
            self.retainRuntime()
            self.capture.start()
        }
    }

    func requestPhonePairing() {
        repairOffered = true
        guard forcedScreen == nil, !uiTest else { return }
        _ = bridge.send(PhoneCommand(kind: .showPairing))
    }

    func directNoteDisplay(_ active: Bool) {
        direct.noteDisplay(active)
    }

    private func appendHostAudio(_ packet: VoicePacket) {
        guard packet.kind == .audio, let data = Data(base64Encoded: packet.pcmBase64), !data.isEmpty else { return }
        hostPCM.append(data)
    }

    private func sendHostUtterance(_ id: String) {
        let pcm = hostPCM
        hostPCM.removeAll(keepingCapacity: true)
        guard !pcm.isEmpty else {
            noteMissedUtterance()
            return
        }
        expectID = id
        voiceStatus = "Sending"
        if direct.phase == .up {
            direct.transcribe(pcm: pcm, utteranceID: id)
            scheduleHostTranscriptTimeout(id)
            return
        }
        pendingHostPCM = pcm
        pendingHostID = id
        scheduleHostConnectTimeout(id)
        direct.connectIfNeeded()
    }

    private func flushPendingHostAudio() {
        guard direct.phase == .up, let pcm = pendingHostPCM, let id = pendingHostID else { return }
        pendingHostPCM = nil
        pendingHostID = nil
        direct.transcribe(pcm: pcm, utteranceID: id)
        scheduleHostTranscriptTimeout(id)
    }

    private func scheduleHostConnectTimeout(_ id: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.expectID == id, self.pendingHostID == id else { return }
            self.giveUpOnHostTranscript(VoiceSpeechCopy.hostUnheard)
        }
    }

    private func scheduleHostTranscriptTimeout(_ id: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [weak self] in
            guard let self, self.expectID == id else { return }
            self.giveUpOnHostTranscript(VoiceSpeechCopy.hostUnheard)
        }
    }

    private func giveUpOnHostTranscript(_ text: String) {
        expectID = nil
        pendingHostPCM = nil
        pendingHostID = nil
        voiceStatus = "Paused"
        voiceLine = text
        remember(text)
    }

    private func acceptHostTranscript(_ id: String, text: String) {
        let packet = VoicePacket(kind: .transcript, utteranceID: id, isLast: true, text: text)
        guard let raw = VoiceWire.encode(packet) else { return }
        receiveVoice(raw)
    }

    private var useDirect: Bool {
        if relayProbe { return false }
        return forcedScreen == nil && !reachable && snapshot.mode != .demo && direct.phase == .up
    }

    private func route(waking: Bool = false) {
        guard forcedScreen == nil else { return }
        if relayProbe {
            pathTitle = "direct"
            if waking {
                direct.wake()
            } else {
                direct.connectIfNeeded()
            }
            applyDirect()
            return
        }
        if phoneProbe {
            pathTitle = "via iPhone"
            considerPhoneProbe()
            return
        }
        if snapshot.mode == .demo || reachable {
            direct.disconnect()
            if banner == RelayUserNotice.reconnectingText {
                banner = nil
            }
        } else if direct.hasPairing {
            if waking {
                direct.wake()
            } else {
                direct.connectIfNeeded()
            }
        }
        pathTitle = Self.pathTitle(for: nil, snapshot: snapshot, reachable: reachable, direct: direct.hasPairing)
        if !reachable && (direct.phase == .up || pendingPrompt != nil) {
            applyDirect()
        }
    }

    private func applyDirect() {
        guard forcedScreen == nil else { return }
        guard relayProbe || !reachable else { return }
        snapshot.mode = .ssh
        if !direct.label.isEmpty {
            snapshot.hostLabel = direct.label
        }
        pathTitle = "direct"
        switch direct.phase {
        case .up:
            snapshot.sessions = direct.sessions
            snapshot.approvalsAvailable = direct.approvalsAvailable
            snapshot.link = .connected
            absorbOpenTranscript(preferRestored: false)
            if let prompt = pendingPrompt {
                pendingPrompt = nil
                let sessionID = pendingContinues ? resumedSessionID : nil
                pendingContinues = false
                direct.start(prompt, cwd: nil, sessionID: sessionID)
                heldVoiceTask = nil
                if voiceStatus == "Sending" {
                    voiceStatus = "Sent"
                }
            }
            considerRelayProbe()
            if let id = pendingResumeID {
                pendingResumeID = nil
                direct.resume(id)
            }
            flushPendingHostAudio()
            flushHeldVoiceTask()
        case .connecting:
            snapshot.link = .connecting
        case .failed(let text):
            if !direct.sessions.isEmpty {
                snapshot.sessions = direct.sessions
            }
            snapshot.link = .offline
            banner = text
        case .idle:
            break
        }
    }

    private func send(_ command: PhoneCommand) {
        guard forcedScreen == nil else { return }
        if bridge.send(command) {
            banner = nil
        } else if direct.hasPairing {
            banner = "The iPhone is away. This Watch is using the direct connection."
            direct.connectIfNeeded()
        } else {
            banner = "Pair on iPhone first."
        }
    }

    private static func pathTitle(for screen: String?, snapshot: PhoneSnapshot, reachable: Bool, direct: Bool) -> String {
        switch screen {
        case "direct":
            return "direct"
        case "via":
            return "via iPhone"
        case "watch-unpaired", "pairing", "unpaired":
            return "Pair on iPhone first"
        case .some(_):
            return snapshot.mode == .demo ? "Demo" : "via iPhone"
        case nil:
            break
        }
        if snapshot.mode == .demo { return "Demo" }
        if reachable { return "via iPhone" }
        if direct { return "direct" }
        return "Pair on iPhone first"
    }

    private static func isUITest(arguments: [String], environment: [String: String]) -> Bool {
        arguments.contains("-WatchRemoteUITest") || environment["WATCHREMOTE_UI_TEST"] == "1"
    }

    private static func argument(_ name: String, arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name), arguments.index(after: index) < arguments.endIndex else { return nil }
        return arguments[arguments.index(after: index)]
    }

    private func considerPhoneProbe() {
        guard phoneProbe else { return }
        if transcriptHas("I can hear you.") { return }
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        guard let chat = snapshot.sessions.first else { return }
        let now = Date()
        if let phoneProbeSentAt, now.timeIntervalSince(phoneProbeSentAt) < 2 { return }
        let firstSend = phoneProbeSentAt == nil
        phoneProbeSentAt = now
        voiceModeActive = true
        resumedSessionID = chat.id
        if firstSend {
            absorbOpenTranscript(preferRestored: true)
        }
        voiceStatus = "Sending"
        if start("Can you hear me", continueRestored: true) {
            voiceStatus = "Sent"
        }
    }

    private func considerRelayProbe() {
        guard relayProbe, direct.phase == .up else { return }
        switch probeStep {
        case .idle:
            probeStep = .sentFresh
            voiceModeActive = true
            voiceStatus = "Sending"
            direct.start("Can you hear me", cwd: nil, sessionID: nil)
        case .dropped:
            probeStep = .sentAgain
            voiceModeActive = true
            voiceStatus = "Sending"
            direct.start("Again", cwd: nil, sessionID: resumedSessionID)
        case .sentAgain:
            guard transcriptHas("Heard again."),
                  let seed = direct.sessions.first(where: { $0.id == "session-seed" }) else { return }
            probeStep = .sentReopen
            resumedSessionID = seed.id
            voiceModeActive = true
            absorbOpenTranscript(preferRestored: false)
            voiceStatus = "Sending"
            direct.start("Reopen the chat", cwd: nil, sessionID: seed.id)
        case .sentFresh, .sentReopen:
            break
        }
    }

    private func transcriptHas(_ needle: String) -> Bool {
        if voiceLine.contains(needle) || voiceLog.contains(where: { $0.contains(needle) }) {
            return true
        }
        guard let id = resumedSessionID,
              let lines = snapshot.sessions.first(where: { $0.id == id })?.transcript else { return false }
        return lines.contains(where: { $0.contains(needle) })
    }
}

private enum TransportProbeStep {
    case idle
    case sentFresh
    case dropped
    case sentAgain
    case sentReopen
}

final class WatchBridge: NSObject, WCSessionDelegate {
    private var onUpdate: ((PhoneSnapshot?, Bool, String?) -> Void)?

    func start(_ onUpdate: @escaping (PhoneSnapshot?, Bool, String?) -> Void) {
        self.onUpdate = onUpdate
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    @discardableResult
    func send(_ command: PhoneCommand) -> Bool {
        guard WCSession.isSupported(), let payload = LinkCodec.encodeCommand(command) else { return false }
        let session = WCSession.default
        let body = ["command": payload]
        guard session.activationState == .activated else { return false }
        if session.isReachable {
            session.sendMessage(body, replyHandler: nil) { _ in
                session.transferUserInfo(body)
            }
            return true
        }
        session.transferUserInfo(body)
        return true
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let snapshot = decode(session.receivedApplicationContext)
        let direct = session.receivedApplicationContext["direct"] as? String
        let reachable = session.isReachable
        Task { @MainActor in self.onUpdate?(snapshot, reachable, direct) }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in self.onUpdate?(nil, reachable, nil) }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let snapshot = decode(applicationContext)
        let direct = applicationContext["direct"] as? String
        Task { @MainActor in self.onUpdate?(snapshot, session.isReachable, direct) }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        deliver(session, message)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        deliver(session, message)
        replyHandler([:])
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        deliver(session, userInfo)
    }

    private func deliver(_ session: WCSession, _ message: [String: Any]) {
        if message["snapshot"] != nil || message["direct"] != nil {
            let snapshot = decode(message)
            let direct = message["direct"] as? String
            let reachable = session.isReachable
            Task { @MainActor in self.onUpdate?(snapshot, reachable, direct) }
        }
        deliverVoice(message)
    }

    private func deliverVoice(_ message: [String: Any]) {
        guard let voice = message["voice"] as? String else { return }
        Task { @MainActor in VoiceInbox.handler?(voice) }
    }

    private func decode(_ context: [String: Any]) -> PhoneSnapshot? {
        guard let payload = context["snapshot"] as? String else { return nil }
        return LinkCodec.decodeSnapshot(payload)
    }
}
