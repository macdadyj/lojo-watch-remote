import SwiftUI
import WatchConnectivity
import WatchRemoteCore

@main
struct WatchRemoteWatchApp: App {
    @StateObject private var model = WatchModel()

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environmentObject(model)
        }
    }
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
    var heldVoiceTask: String?
    private let bridge = WatchBridge()
    private let direct = DirectSession()
    private var pendingPrompt: String?

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let environment = ProcessInfo.processInfo.environment
        forcedScreen = Self.argument("-WatchRemoteScreen", arguments: arguments) ?? environment["WATCHREMOTE_SCREEN"]
        let appearanceName = Self.argument("-WatchRemoteAppearance", arguments: arguments) ?? environment["WATCHREMOTE_APPEARANCE"]
        if let appearanceName, let choice = AppearanceChoice(rawValue: appearanceName) {
            appearance = choice
        }
        if forcedScreen != nil {
            snapshot = DemoCatalog.preview(named: forcedScreen ?? "") ?? DemoCatalog.snapshot()
            if forcedScreen == "session" || forcedScreen == "long" { selectedID = DemoCatalog.approvalID }
            pathTitle = Self.pathTitle(for: forcedScreen, snapshot: snapshot, reachable: false, direct: false)
        }
        direct.restore()
        direct.onBanner = { [weak self] text in
            self?.banner = text
        }
        direct.onChange = { [weak self] in
            self?.applyDirect()
        }
        bridge.start { [weak self] snapshot, reachable, directText in
            guard let self, self.forcedScreen == nil else { return }
            if let directText {
                self.direct.ingest(directText)
            }
            if let snapshot {
                let previous = Set(self.snapshot.sessions.compactMap(\.permission?.id))
                let arrived = Set(snapshot.sessions.compactMap(\.permission?.id)).subtracting(previous)
                self.snapshot = snapshot
                if !arrived.isEmpty { WatchFeedback.notification() }
            }
            self.reachable = reachable
            self.route()
            self.deliverPendingPromptIfPhoneIsBack()
            self.flushHeldVoiceTask()
        }
        VoiceHandoff.handler = { [weak self] prompt in
            self?.submitSpokenTask(prompt)
        }
        if forcedScreen == nil, let pending = VoiceHandoff.takePending() {
            submitSpokenTask(pending)
        }
    }

    func wake() {
        guard forcedScreen == nil else { return }
        route(waking: true)
    }

    func refresh() {
        guard forcedScreen == nil else { return }
        if useDirect {
            direct.refresh()
            return
        }
        _ = bridge.send(PhoneCommand(kind: .refresh))
    }

    @discardableResult
    func start(_ prompt: String, announcingFailure: Bool = true) -> Bool {
        if forcedScreen != nil {
            return true
        }
        if useDirect {
            direct.start(prompt, cwd: nil)
            banner = nil
            return true
        }
        if !reachable && direct.hasPairing {
            pendingPrompt = prompt
            direct.connectIfNeeded()
            banner = "Connecting directly."
            return true
        }
        let queued = bridge.send(PhoneCommand(kind: .start, prompt: prompt))
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
        guard bridge.send(PhoneCommand(kind: .start, prompt: prompt)) else { return }
        pendingPrompt = nil
        banner = nil
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

    func selectComputer(_ id: String) {
        guard forcedScreen == nil else { return }
        if useDirect {
            banner = "Open the iPhone to switch computers."
            return
        }
        let queued = bridge.send(PhoneCommand(kind: .selectComputer, computerID: id))
        banner = queued ? nil : "Pair on iPhone first."
    }

    private var useDirect: Bool {
        forcedScreen == nil && !reachable && snapshot.mode != .demo && direct.phase == .up
    }

    private func route(waking: Bool = false) {
        guard forcedScreen == nil else { return }
        if snapshot.mode == .demo || reachable {
            direct.disconnect()
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
        guard forcedScreen == nil, !reachable else { return }
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
            if let prompt = pendingPrompt {
                pendingPrompt = nil
                direct.start(prompt, cwd: nil)
            }
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

    private static func argument(_ name: String, arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name), arguments.index(after: index) < arguments.endIndex else { return nil }
        return arguments[arguments.index(after: index)]
    }
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

    private func decode(_ context: [String: Any]) -> PhoneSnapshot? {
        guard let payload = context["snapshot"] as? String else { return nil }
        return LinkCodec.decodeSnapshot(payload)
    }
}
