import Foundation
import WatchConnectivity
import WatchRemoteCore

final class WatchBridge: NSObject, WCSessionDelegate {
    private var onUpdate: ((PhoneSnapshot?, Bool, String?) -> Void)?
    /// Transport tests only: an in-process iPhone echo, used where simulator WatchConnectivity does not deliver.
    private var echo: PhoneEcho?

    var isActivated: Bool {
        if echo != nil { return true }
        return WCSession.isSupported() && WCSession.default.activationState == .activated
    }

    func start(loopback: Bool = false, _ onUpdate: @escaping (PhoneSnapshot?, Bool, String?) -> Void) {
        self.onUpdate = onUpdate
        if loopback {
            echo = PhoneEcho()
            publishEcho()
            return
        }
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    @discardableResult
    func send(_ command: PhoneCommand) -> Bool {
        if echo != nil {
            if let id = echo?.accept(command) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    self?.echo?.answer(id)
                    self?.publishEcho()
                }
            }
            publishEcho()
            return true
        }
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

    private func publishEcho() {
        guard let snapshot = echo?.snapshot else { return }
        Task { @MainActor in self.onUpdate?(snapshot, true, nil) }
    }

    private func decode(_ context: [String: Any]) -> PhoneSnapshot? {
        guard let payload = context["snapshot"] as? String else { return nil }
        return LinkCodec.decodeSnapshot(payload)
    }
}
