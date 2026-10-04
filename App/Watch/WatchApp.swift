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
    private let bridge = WatchBridge()

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
        }
        bridge.start { [weak self] snapshot, reachable in
            guard let self, self.forcedScreen == nil else { return }
            if let snapshot {
                let previous = Set(self.snapshot.sessions.compactMap(\.permission?.id))
                let arrived = Set(snapshot.sessions.compactMap(\.permission?.id)).subtracting(previous)
                self.snapshot = snapshot
                if !arrived.isEmpty { WatchFeedback.notification() }
            }
            self.reachable = reachable
        }
    }

    func refresh() {
        guard forcedScreen == nil else { return }
        _ = bridge.send(PhoneCommand(kind: .refresh))
    }

    @discardableResult
    func start(_ prompt: String) -> Bool {
        if forcedScreen != nil {
            return true
        }
        let queued = bridge.send(PhoneCommand(kind: .start, prompt: prompt))
        banner = queued ? nil : "The iPhone app is closed."
        return queued
    }

    func allow(_ session: GrokSession) {
        send(PhoneCommand(kind: .approve, sessionID: session.id, permissionID: session.permission?.id))
    }

    func deny(_ session: GrokSession) {
        send(PhoneCommand(kind: .deny, sessionID: session.id, permissionID: session.permission?.id))
    }

    func stop(_ session: GrokSession) {
        send(PhoneCommand(kind: .stop, sessionID: session.id))
    }

    private func send(_ command: PhoneCommand) {
        guard forcedScreen == nil else { return }
        if bridge.send(command) {
            banner = nil
        } else {
            banner = "The iPhone app is closed."
        }
    }

    private static func argument(_ name: String, arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name), arguments.index(after: index) < arguments.endIndex else { return nil }
        return arguments[arguments.index(after: index)]
    }
}

final class WatchBridge: NSObject, WCSessionDelegate {
    private var onUpdate: ((PhoneSnapshot?, Bool) -> Void)?

    func start(_ onUpdate: @escaping (PhoneSnapshot?, Bool) -> Void) {
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
        let reachable = session.isReachable
        Task { @MainActor in self.onUpdate?(snapshot, reachable) }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in self.onUpdate?(nil, reachable) }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let snapshot = decode(applicationContext)
        Task { @MainActor in self.onUpdate?(snapshot, session.isReachable) }
    }

    private func decode(_ context: [String: Any]) -> PhoneSnapshot? {
        guard let payload = context["snapshot"] as? String else { return nil }
        return LinkCodec.decodeSnapshot(payload)
    }
}
