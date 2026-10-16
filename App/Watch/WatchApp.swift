import SwiftUI
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

/// A launch that drives the real network path from a UI test. The microphone stays off: each
/// listen takes the next scripted utterance as if speech recognition had produced it.
enum WatchTransportTest: String {
    case relay
    case phone
}

@MainActor
enum WatchApprovalStore {
    /// v2 starts everyone at on. The first key saved the old default (off) whether or not anyone chose it.
    private static let key = "watch.approval.setting.v2"

    static func load() -> WatchApprovalSetting {
        guard let data = UserDefaults.standard.data(forKey: key),
              let setting = try? JSONDecoder().decode(WatchApprovalSetting.self, from: data) else {
            return WatchApprovalSetting()
        }
        return setting
    }

    static func save(_ setting: WatchApprovalSetting) {
        guard let data = try? JSONEncoder().encode(setting) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

/// The words in flight, where they went, and the chats that existed before them.
private struct WatchTurn {
    var prompt: String
    var path: WatchTurnPath
    var requestID: String?
    var sessionID: String?
    var known: Set<String>
    var sentAt = Date()
}

@MainActor
final class WatchModel: ObservableObject {
    static let stillWaitingStatus = "Still waiting for Grok"

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
    /// Auto-approve: the default, kept in step with the iPhone, plus per-chat choices.
    @Published private(set) var approval = WatchApprovalSetting()
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
    /// Set by `-WatchRemoteTransportTest`. The network is real; only the microphone is scripted.
    private(set) var transportTest: WatchTransportTest?
    private var injectedUtterances: [String] = []
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
    private let bridge = WatchBridge()
    private let direct = DirectSession()
    /// The iPhone's latest snapshot. Relay sessions are merged over it.
    private var phoneSnapshot: PhoneSnapshot?
    private var turn: WatchTurn?
    /// Lines a resume returned, kept until the session list carries at least as many.
    private var restoredTranscripts: [String: [String]] = [:]
    private var autoApprovedPermissionIDs = Set<String>()
    @Published var showTransportDiagnostics = false
    /// The open chat. Later voice turns prompt that session.
    var resumedSessionID: String?

    var isTransportTest: Bool { transportTest != nil }

    /// A follow-up waits for the computer to name the chat the first turn created.
    var promptIsQueued: Bool { heldVoiceTask != nil && awaitingNewChat }

    var diagnosticsLine: String {
        let phase = reachable ? "\(direct.phaseLabel) · iPhone reachable" : direct.phaseLabel
        return WatchTransportDiagnostics.line(path: pathTitle, phase: phase, lastError: direct.lastError)
    }

    func toggleTransportDiagnostics() {
        showTransportDiagnostics.toggle()
    }

    var hostIsReady: Bool { direct.hasPairing }

    /// Where a turn goes right now.
    var turnPath: WatchTurnPath {
        WatchRouting.path(
            hasRelayPairing: direct.hasPairing,
            relayHostOnline: direct.hostReachable,
            phoneReachable: reachable,
            phoneActivated: phoneActivated,
            watchHasNetwork: !direct.networkDown
        )
    }

    /// "No network", "Reconnecting…", or "Computer offline" while the iPhone is not carrying turns.
    var connectionNotice: String? {
        WatchRouting.notice(
            hasRelayPairing: direct.hasPairing,
            relayUp: direct.phase == .up,
            relayTrouble: direct.inTrouble,
            relayHostOnline: direct.hostOnline,
            phoneReachable: reachable,
            noNetwork: direct.networkDown
        )
    }

    private var phoneActivated: Bool {
        transportTest != .relay && bridge.isActivated
    }

    private var awaitingNewChat: Bool {
        guard resumedSessionID == nil, let turn, turn.sessionID == nil else { return false }
        return Date().timeIntervalSince(turn.sentAt) < 20
    }

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
            pathTitle = Self.pathTitle(for: forcedScreen, snapshot: snapshot)
            if forcedScreen == "voice-chat" || forcedScreen == "voice-loop" {
                voiceStatus = "Listening"
                voiceLine = ListenEndpoint.manualHint
                voiceLog = forcedScreen == "voice-chat" ? VoiceConversationFixture.history : []
                if forcedScreen == "voice-chat" {
                    pendingAllowSessionID = DemoCatalog.approvalID
                }
            }
        }
        approval = WatchApprovalStore.load()
        transportTest = Self.argument("-WatchRemoteTransportTest", arguments: arguments).flatMap(WatchTransportTest.init(rawValue:))
        if let transportTest {
            injectedUtterances = (Self.argument("-WatchRemoteInjectUtterance", arguments: arguments) ?? "")
                .split(separator: "|")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            approval = WatchApprovalSetting(value: Self.argument("-WatchRemoteAutoApprove", arguments: arguments) == "1")
            WatchApprovalStore.save(approval)
            VoicePreferences.shared.actionHintSeen = true
            VoicePreferences.shared.pauseSends = false
            VoiceSpeaker.shared.muted = true
            snapshot = PhoneSnapshot(mode: .ssh, link: .connecting, sessions: [], banner: nil, approvalsAvailable: true, hostLabel: "example-host")
            pathTitle = transportTest == .relay ? "direct" : "via iPhone"
        }
        syncApprovalPreference()
        direct.autoApproveDefault = approval.value
        if transportTest != .phone {
            direct.restore()
            if let pairing = Self.argument("-WatchRemoteDirectPairing", arguments: arguments) {
                direct.ingest(pairing, resetCounters: true)
            }
        }
        direct.onBanner = { [weak self] text in
            self?.receiveRelayBanner(text)
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
        }
        direct.onStarted = { [weak self] requestID, sessionID in
            self?.noteStarted(requestID: requestID, sessionID: sessionID)
        }
        direct.onFailed = { [weak self] requestID, _ in
            self?.noteFailed(requestID: requestID)
        }
        direct.onRepair = { [weak self] in
            guard let self else { return }
            self.repairOffered = true
            self.requestPhonePairing()
        }
        let loopback = transportTest == .phone && arguments.contains("-WatchRemotePhoneLoopback")
        bridge.start(loopback: loopback) { [weak self] snapshot, reachable, directText in
            self?.receivePhone(snapshot: snapshot, reachable: reachable, directText: directText)
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
        guard forcedScreen == nil else { return }
        if let pending = VoiceHandoff.takePending() {
            submitSpokenTask(pending)
        }
        if direct.hasPairing {
            direct.connectIfNeeded()
        }
        refreshState()
    }

    func consumeUITestLaunch() {
        guard uiOpenMissing else { return }
        uiOpenMissing = false
        openHistory(GrokSession(id: "missing-session", title: "Gone", summary: "Gone.", status: .idle))
    }

    func wake() {
        guard forcedScreen == nil, !uiTest else { return }
        if direct.hasPairing {
            direct.wake()
        }
        refreshState()
    }

    func refresh() {
        guard forcedScreen == nil, !uiTest else { return }
        if direct.hasPairing {
            direct.refresh()
        }
        if transportTest != .relay, reachable || !direct.hasPairing {
            _ = bridge.send(PhoneCommand(kind: .refresh))
        }
    }

    // MARK: - Chats

    func openHistory(_ session: GrokSession) {
        resumedSessionID = session.id
        if turn?.sessionID != session.id {
            turn = nil
        }
        voiceModeActive = true
        voiceLine = ""
        voiceLog = SessionResume.displayLines(
            title: session.title,
            summary: session.summary,
            transcript: session.transcript ?? []
        )
        voiceStatus = "Restoring"
        if !isConnectionNotice(banner) {
            banner = nil
        }
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
        switch route(for: session.id) {
        case .relay:
            direct.resume(session.id, autoApprove: approval.chats[session.id])
        case .phone:
            if !bridge.send(PhoneCommand(kind: .resume, sessionID: session.id)) {
                banner = "Pair on iPhone first."
                voiceStatus = "Unavailable"
            }
        case .unavailable:
            banner = "Pair on iPhone first."
            voiceStatus = "Unavailable"
        }
        let id = session.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.resumedSessionID == id, self.voiceStatus == "Restoring" else { return }
            self.voiceStatus = "Restored"
        }
        applyConnectionNotice()
    }

    func showRestored(_ id: String, lines: [String]) {
        let cleaned = Self.clean(lines)
        guard !cleaned.isEmpty else { return }
        restoredTranscripts[id] = cleaned
        if let index = snapshot.sessions.firstIndex(where: { $0.id == id }),
           (snapshot.sessions[index].transcript?.count ?? 0) < cleaned.count {
            snapshot.sessions[index].transcript = cleaned
        }
        guard resumedSessionID == id else { return }
        if voiceStatus == "Restoring" {
            voiceStatus = "Restored"
        }
        if banner == SessionResume.missingMessage {
            banner = nil
        }
        absorbOpenTranscript()
    }

    /// Puts the open chat's transcript on screen, plus the words still on their way.
    func absorbOpenTranscript() {
        guard let id = resumedSessionID,
              let session = snapshot.sessions.first(where: { $0.id == id }) else { return }
        var lines = Self.clean(session.transcript ?? [])
        guard !lines.isEmpty else { return }
        if let turn, turn.sessionID == id || turn.sessionID == nil, !WatchRouting.mentions(turn.prompt, in: lines) {
            lines.append("You: \(turn.prompt)")
        }
        if voiceLog != lines {
            voiceLog = lines
        }
        if voiceStatus == "Restoring" {
            voiceStatus = "Restored"
        }
    }

    func showMissingChat() {
        voiceModeActive = true
        voiceStatus = "Unavailable"
        voiceLine = ""
        voiceLog = []
        banner = SessionResume.missingMessage
    }

    func endChat() {
        if let id = resumedSessionID,
           let session = snapshot.sessions.first(where: { $0.id == id }),
           session.status == .running || session.status == .needsApproval {
            stop(session)
        }
        turn = nil
        endVoiceConversation()
    }

    // MARK: - Turns

    @discardableResult
    func start(_ prompt: String, announcingFailure: Bool = true, continueRestored: Bool = false) -> Bool {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        let sessionID = continueRestored ? resumedSessionID : nil
        if !continueRestored {
            resumedSessionID = nil
        }
        if forcedScreen != nil {
            return true
        }
        let known = Set(snapshot.sessions.map(\.id))
        switch route(for: sessionID) {
        case .relay:
            let override = sessionID.flatMap { approval.chats[$0] }
            let requestID = direct.start(text, cwd: nil, sessionID: sessionID, autoApprove: override)
            beginTurn(WatchTurn(prompt: text, path: .relay, requestID: requestID, sessionID: sessionID, known: known))
            return true
        case .phone:
            guard bridge.send(PhoneCommand(kind: .start, prompt: text, sessionID: sessionID)) else {
                if announcingFailure {
                    banner = "Pair on iPhone first."
                }
                return false
            }
            beginTurn(WatchTurn(prompt: text, path: .phone, requestID: nil, sessionID: sessionID, known: known))
            return true
        case .unavailable:
            if announcingFailure {
                banner = "Pair on iPhone first."
            }
            return false
        }
    }

    private func beginTurn(_ next: WatchTurn) {
        turn = next
        if !isConnectionNotice(banner) {
            banner = nil
        }
        absorbOpenTranscript()
        let sentAt = next.sentAt
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            self?.noteSlowTurn(sentAt)
        }
    }

    private func noteSlowTurn(_ sentAt: Date) {
        guard let open = turn, open.sentAt == sentAt else { return }
        if let id = open.sessionID ?? resumedSessionID,
           snapshot.sessions.first(where: { $0.id == id })?.permission != nil {
            return
        }
        if ["", "Sent", "Sending"].contains(voiceStatus) {
            voiceStatus = Self.stillWaitingStatus
        }
    }

    private func noteStarted(requestID: String, sessionID: String) {
        guard !sessionID.isEmpty, var open = turn, open.requestID == requestID else { return }
        open.sessionID = sessionID
        turn = open
        if resumedSessionID == nil {
            resumedSessionID = sessionID
        }
        absorbOpenTranscript()
        flushHeldVoiceTask(announcingFailure: false)
    }

    private func noteFailed(requestID: String) {
        guard let open = turn, open.requestID == requestID else { return }
        turn = nil
        if ["", "Sent", "Sending", Self.stillWaitingStatus].contains(voiceStatus) {
            voiceStatus = "Couldn't send"
        }
    }

    /// A new chat sent through the iPhone has no started reply. Find it by its first words.
    private func adoptNewChat() {
        guard resumedSessionID == nil, var open = turn, open.sessionID == nil,
              let chat = WatchRouting.newChat(for: open.prompt, known: open.known, in: snapshot.sessions) else { return }
        open.sessionID = chat.id
        turn = open
        resumedSessionID = chat.id
        flushHeldVoiceTask(announcingFailure: false)
    }

    private func noteTurnProgress() {
        guard let open = turn, let id = open.sessionID ?? resumedSessionID,
              let lines = snapshot.sessions.first(where: { $0.id == id })?.transcript,
              WatchRouting.hasReply(after: open.prompt, in: lines) else { return }
        turn = nil
        if ["Sent", "Sending", Self.stillWaitingStatus].contains(voiceStatus) {
            voiceStatus = ""
        }
    }

    // MARK: - Approvals

    func allow(_ session: GrokSession) {
        guard forcedScreen == nil else { return }
        if route(for: session.id) == .relay {
            direct.approve(session)
            return
        }
        send(PhoneCommand(kind: .approve, sessionID: session.id, permissionID: session.permission?.id))
    }

    func deny(_ session: GrokSession) {
        guard forcedScreen == nil else { return }
        if route(for: session.id) == .relay {
            direct.deny(session)
            return
        }
        send(PhoneCommand(kind: .deny, sessionID: session.id, permissionID: session.permission?.id))
    }

    func stop(_ session: GrokSession) {
        guard forcedScreen == nil else { return }
        if route(for: session.id) == .relay {
            direct.stop(session)
            return
        }
        send(PhoneCommand(kind: .stop, sessionID: session.id))
    }

    /// The Settings switch. The iPhone and the computer hear about it.
    func setAutoApprove(_ enabled: Bool) {
        guard approval.chooseOnWatch(enabled) else { return }
        WatchApprovalStore.save(approval)
        syncApprovalPreference()
        guard forcedScreen == nil, !uiTest else { return }
        direct.autoApproveDefault = enabled
        direct.sendAutoApprove(enabled, sessionID: nil)
        if transportTest != .relay {
            _ = bridge.send(PhoneCommand(kind: .setAutoApprove, enabled: enabled))
        }
        if enabled {
            scheduleAutoApprove()
        }
    }

    /// One chat's switch. It stays put when the Settings default changes later.
    func setChatAutoApprove(_ enabled: Bool, for sessionID: String) {
        approval.setChat(sessionID, to: enabled)
        WatchApprovalStore.save(approval)
        guard forcedScreen == nil, !uiTest else { return }
        direct.sendAutoApprove(enabled, sessionID: sessionID)
        if enabled {
            scheduleAutoApprove()
        }
    }

    func autoApproves(_ sessionID: String?) -> Bool {
        approval.allows(chat: sessionID)
    }

    /// The computer applies the same choice itself. The Watch waits a moment so it does not race it.
    private func scheduleAutoApprove() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.autoApproveWaitingTools()
        }
    }

    func autoApproveWaitingTools() {
        guard forcedScreen == nil, !uiTest else { return }
        for session in snapshot.sessions {
            guard let permission = session.permission, approval.allows(chat: session.id) else { continue }
            guard autoApprovedPermissionIDs.insert(permission.id).inserted else { continue }
            allow(session)
        }
    }

    private func syncApprovalPreference() {
        if VoicePreferences.shared.autoApproveTools != approval.value {
            VoicePreferences.shared.autoApproveTools = approval.value
        }
    }

    func selectComputer(_ id: String) {
        guard forcedScreen == nil else { return }
        if !reachable && direct.hasPairing {
            banner = "Open the iPhone to switch computers."
            return
        }
        let queued = bridge.send(PhoneCommand(kind: .selectComputer, computerID: id))
        banner = queued ? nil : "Pair on iPhone first."
    }

    func requestPhonePairing() {
        repairOffered = true
        guard forcedScreen == nil, !uiTest else { return }
        _ = bridge.send(PhoneCommand(kind: .showPairing))
    }

    func directNoteDisplay(_ active: Bool) {
        direct.noteDisplay(active)
    }

    // MARK: - Scripted microphone

    /// Transport tests replace the microphone. The utterance enters the same path a final transcript does.
    func deliverInjectedUtterance() -> Bool {
        guard transportTest != nil else { return false }
        guard !injectedUtterances.isEmpty else {
            voiceStatus = "Paused"
            return true
        }
        let text = injectedUtterances.removeFirst()
        voiceModeActive = true
        voiceStatus = "Hearing you"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.missedTurns = 0
            self.voiceLine = ""
            self.remember("You: \(text)")
            self.handleVoiceTurn(text)
        }
        return true
    }

    // MARK: - Host speech

    func discardPendingHostAudio() {
        hostPCM.removeAll(keepingCapacity: true)
        pendingHostPCM = nil
        pendingHostID = nil
    }

    /// Records immediately. The utterance is sent when the relay is up.
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
    }

    private func acceptHostTranscript(_ id: String, text: String) {
        let packet = VoicePacket(kind: .transcript, utteranceID: id, isLast: true, text: text)
        guard let raw = VoiceWire.encode(packet) else { return }
        receiveVoice(raw)
    }

    // MARK: - Links

    private func receivePhone(snapshot incoming: PhoneSnapshot?, reachable phoneReachable: Bool, directText: String?) {
        guard forcedScreen == nil, !uiTest, transportTest != .relay else { return }
        if let directText, transportTest != .phone {
            direct.ingest(directText)
            if direct.hasPairing {
                direct.connectIfNeeded()
            }
        }
        if let incoming {
            phoneSnapshot = incoming
            if approval.notePhone(incoming.autoApproveTools) {
                direct.autoApproveDefault = approval.value
                syncApprovalPreference()
            }
            WatchApprovalStore.save(approval)
            if incoming.banner == SessionResume.missingMessage, resumedSessionID != nil {
                showMissingChat()
            }
        }
        reachable = phoneReachable
        refreshState()
        flushHeldVoiceTask(announcingFailure: false)
    }

    private func receiveRelayBanner(_ text: String?) {
        banner = text
        if text == SessionResume.missingMessage {
            showMissingChat()
            return
        }
        if let text, voiceSink == .host, expectID != nil {
            if text == VoiceSpeechCopy.noTranscriber {
                offerDictation(text)
            } else {
                giveUpOnHostTranscript(text)
            }
        }
        applyConnectionNotice()
    }

    private func applyDirect() {
        guard forcedScreen == nil, !uiTest else { return }
        refreshState()
        flushPendingHostAudio()
        flushHeldVoiceTask(announcingFailure: false)
    }

    /// Rebuilds what the Watch shows from both links, then moves the open turn along.
    private func refreshState() {
        guard forcedScreen == nil, !uiTest else { return }
        let before = Set(snapshot.sessions.compactMap(\.permission?.id))
        rebuildSnapshot()
        pathTitle = currentPathTitle()
        applyConnectionNotice()
        adoptNewChat()
        absorbOpenTranscript()
        noteTurnProgress()
        let arrived = snapshot.sessions.filter { session in
            guard let id = session.permission?.id else { return false }
            return !before.contains(id)
        }
        guard !arrived.isEmpty else { return }
        if arrived.contains(where: { approval.allows(chat: $0.id) }) {
            scheduleAutoApprove()
        }
        if arrived.contains(where: { !approval.allows(chat: $0.id) }) {
            WatchFeedback.notification()
        }
    }

    private func rebuildSnapshot() {
        let phone = transportTest == .relay ? nil : phoneSnapshot
        let realPhone = phone?.mode == .demo ? nil : phone
        var next: PhoneSnapshot
        if direct.hasPairing {
            next = realPhone ?? PhoneSnapshot(
                mode: .ssh,
                link: .connecting,
                sessions: [],
                banner: nil,
                approvalsAvailable: true,
                hostLabel: direct.label.isEmpty ? snapshot.hostLabel : direct.label,
                autoApproveTools: approval.value
            )
            next.sessions = WatchRouting.mergeSessions(relay: direct.sessions, phone: realPhone?.sessions ?? [])
            if direct.phase == .up && direct.hostOnline != false && !direct.networkDown {
                next.link = .connected
                next.banner = nil
                next.approvalsAvailable = direct.approvalsAvailable || (realPhone?.approvalsAvailable ?? false)
            } else if reachable, let realPhone {
                next.link = realPhone.link
            } else if direct.networkDown || direct.phase == .up {
                next.link = .offline
            } else {
                next.link = .connecting
            }
            if realPhone == nil, !direct.label.isEmpty {
                next.hostLabel = direct.label
            }
        } else if let phone {
            next = phone
        } else {
            return
        }
        for index in next.sessions.indices {
            let id = next.sessions[index].id
            guard let restored = restoredTranscripts[id] else { continue }
            if (next.sessions[index].transcript?.count ?? 0) < restored.count {
                next.sessions[index].transcript = restored
            } else {
                restoredTranscripts[id] = nil
            }
        }
        if snapshot != next {
            snapshot = next
        }
    }

    private func applyConnectionNotice() {
        guard forcedScreen == nil, !uiTest else { return }
        let notice = connectionNotice
        if let notice {
            if banner == nil || isConnectionNotice(banner) {
                banner = notice
            }
        } else if isConnectionNotice(banner) {
            banner = nil
        }
    }

    private func isConnectionNotice(_ text: String?) -> Bool {
        RelayUserNotice.isConnectionNotice(text)
    }

    /// A chat the relay knows goes through the relay. Others follow the general path.
    private func route(for sessionID: String?) -> WatchTurnPath {
        let path = turnPath
        guard path == .relay, let sessionID, direct.phase == .up, phoneSnapshot != nil, reachable else { return path }
        if direct.sessions.contains(where: { $0.id == sessionID }) {
            return .relay
        }
        return phoneSnapshot?.sessions.contains(where: { $0.id == sessionID }) == true ? .phone : .relay
    }

    private func currentPathTitle() -> String {
        switch turnPath {
        case .relay:
            return "direct"
        case .phone:
            return snapshot.mode == .demo ? "Demo" : "via iPhone"
        case .unavailable:
            return snapshot.mode == .demo ? "Demo" : "Pair on iPhone first"
        }
    }

    private func send(_ command: PhoneCommand) {
        guard forcedScreen == nil else { return }
        if bridge.send(command) {
            if !isConnectionNotice(banner) {
                banner = nil
            }
        } else {
            banner = "Pair on iPhone first."
        }
    }

    private static func clean(_ lines: [String]) -> [String] {
        lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private static func pathTitle(for screen: String?, snapshot: PhoneSnapshot) -> String {
        switch screen {
        case "direct":
            return "direct"
        case "via":
            return "via iPhone"
        case "watch-unpaired", "pairing", "unpaired":
            return "Pair on iPhone first"
        default:
            return snapshot.mode == .demo ? "Demo" : "via iPhone"
        }
    }

    private static func isUITest(arguments: [String], environment: [String: String]) -> Bool {
        arguments.contains("-WatchRemoteUITest") || environment["WATCHREMOTE_UI_TEST"] == "1"
    }

    private static func argument(_ name: String, arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name), arguments.index(after: index) < arguments.endIndex else { return nil }
        return arguments[arguments.index(after: index)]
    }
}
