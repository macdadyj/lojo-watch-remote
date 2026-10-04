import Foundation
import WatchConnectivity
import WatchRemoteCore

struct SavedHost: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var label: String
    var address: String
    var port: Int
    var username: String

    static var placeholder: SavedHost {
        SavedHost(
            id: "computer",
            label: HostDefaults.label,
            address: HostDefaults.address,
            port: HostDefaults.port,
            username: HostDefaults.username
        )
    }
}

enum HostDefaults {
    static var label: String { value("WatchRemoteHostLabel", fallback: OverlayPolicy.exampleLabel) }
    static var address: String { value("WatchRemoteHostAddress", fallback: OverlayPolicy.exampleAddress) }
    static var username: String { value("WatchRemoteHostUser", fallback: OverlayPolicy.exampleUser) }
    static var port: Int { Int(value("WatchRemoteHostPort", fallback: String(OverlayPolicy.examplePort))) ?? OverlayPolicy.examplePort }

    private static func value(_ key: String, fallback: String) -> String {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return fallback }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.contains("$(") { return fallback }
        return trimmed
    }
}

struct TrustPrompt: Identifiable, Equatable {
    var id = UUID()
    var host: SavedHost
    var key: PresentedHostKey
    var previousFingerprint: String?
    var changed: Bool
}

enum AppTab: String, Hashable {
    case sessions, computer, settings
}

@MainActor
final class RemoteStore: ObservableObject {
    @Published var mode: ConnectionMode
    @Published var appearance: AppearanceChoice
    @Published var tab: AppTab = .sessions
    @Published var sessions: [GrokSession] = []
    @Published var banner: String?
    @Published var link: LinkState = .offline
    @Published var approvalsAvailable = false
    @Published var statusLine = "Not connected"
    @Published var cwd: String
    @Published var relayURL: String
    @Published var host: SavedHost
    @Published var trustPrompt: TrustPrompt?
    @Published var showCompose = false
    @Published var selectedSessionID: String?
    private var holdsLaunchFixture = false
    @Published var hasAgentSecret = false
    @Published var hasRelayToken = false
    @Published var hasRelayPin = false
    @Published private(set) var knownHosts: KnownHosts

    let keys: KeyStore
    private var engine = MockEngine(preview: true)
    private var live: LiveLink?
    private var trustContinuation: CheckedContinuation<Bool, Never>?
    private let support: URL
    private let bridge = PhoneBridge()
    private let relay = RelayClient()

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WatchRemote", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        self.support = support
        keys = KeyStore(directory: support)
        let defaults = UserDefaults.standard
        mode = ConnectionMode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .demo
        appearance = AppearanceChoice(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        cwd = defaults.string(forKey: "cwd") ?? ""
        relayURL = defaults.string(forKey: "relayURL") ?? ""
        if let data = defaults.data(forKey: "host"), let saved = try? JSONDecoder().decode(SavedHost.self, from: data) {
            host = saved
        } else {
            host = .placeholder
        }
        if let text = try? String(contentsOf: support.appendingPathComponent("known_hosts"), encoding: .utf8) {
            knownHosts = KnownHosts(text: text)
        } else {
            knownHosts = KnownHosts()
        }
        hasAgentSecret = keys.secret(account: "agent-secret") != nil
        hasRelayToken = keys.secret(account: "relay-token") != nil
        hasRelayPin = keys.secret(account: "relay-pin") != nil
        live = LiveLink(
            onEvent: { [weak self] event in self?.apply(event) },
            onCLI: { [weak self] id, event in self?.applyCLI(id: id, event: event) },
            onDropped: { [weak self] in
                guard let self, self.mode == .ssh else { return }
                self.link = .offline
                self.approvalsAvailable = false
                self.statusLine = "Not connected"
                self.publish()
            },
            onAgentLost: { [weak self] in
                guard let self, self.mode == .ssh else { return }
                self.approvalsAvailable = false
                self.statusLine = self.live?.statusLine ?? "SSH connected. Command mode is on, so tasks cannot ask for approval."
                self.publish()
            }
        )
        applyLaunch()
        bridge.start { [weak self] command in
            self?.perform(command)
        } onActivated: { [weak self] in
            self?.publish()
        }
        publish()
    }

    var snapshot: PhoneSnapshot {
        PhoneSnapshot(
            mode: mode,
            link: link,
            sessions: sessions,
            banner: banner,
            approvalsAvailable: approvalsAvailable,
            hostLabel: host.label
        )
    }

    func updateHost(label: String, address: String, portText: String, username: String) -> String? {
        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let canonical = OverlayPolicy.canonical(address: trimmedAddress) else {
            return OverlayPolicy.refusalReason(address: trimmedAddress)
        }
        guard let port = Int(portText.trimmingCharacters(in: .whitespacesAndNewlines)), (1...65535).contains(port) else {
            return "Use a port from 1 to 65535."
        }
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty, !user.contains(where: \.isWhitespace) else {
            return "Enter the SSH user."
        }
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let changed = host.address != canonical || host.port != port || host.username != user
        host = SavedHost(
            id: host.id,
            label: name.isEmpty ? OverlayPolicy.exampleLabel : name,
            address: canonical,
            port: port,
            username: user
        )
        if let data = try? JSONEncoder().encode(host) {
            UserDefaults.standard.set(data, forKey: "host")
        }
        if changed {
            live?.disconnect()
            link = .offline
            approvalsAvailable = false
            statusLine = "Not connected"
            publish()
        }
        return nil
    }

    func setMode(_ mode: ConnectionMode) {
        self.mode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "mode")
        if mode == .demo {
            engine = MockEngine(preview: true)
            sessions = engine.sessions
            link = .demo
            approvalsAvailable = true
            statusLine = "Demo on this iPhone. Nothing is sent."
            live?.disconnect()
        } else {
            sessions = []
            link = .offline
            approvalsAvailable = false
            statusLine = "Not connected"
            live?.disconnect()
        }
        publish()
    }

    func setAppearance(_ appearance: AppearanceChoice) {
        self.appearance = appearance
        UserDefaults.standard.set(appearance.rawValue, forKey: "appearance")
    }

    func setCwd(_ cwd: String) {
        self.cwd = cwd
        UserDefaults.standard.set(cwd, forKey: "cwd")
    }

    func setRelayURL(_ url: String) {
        relayURL = url
        UserDefaults.standard.set(url, forKey: "relayURL")
    }

    func saveAgentSecret(_ secret: String) {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? keys.saveSecret(trimmed, account: "agent-secret")
        hasAgentSecret = true
        banner = "Agent secret saved in the Keychain."
        publish()
        if mode == .ssh {
            Task { await self.refresh() }
        }
    }

    func saveRelayToken(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? keys.saveSecret(trimmed, account: "relay-token")
        hasRelayToken = true
        publish()
    }

    func saveRelayPin(_ pin: String) {
        let trimmed = pin.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? keys.saveSecret(trimmed, account: "relay-pin")
        hasRelayPin = true
        publish()
    }

    func refresh() async {
        guard !holdsLaunchFixture else { return }
        switch mode {
        case .demo:
            sessions = engine.sessions
            link = .demo
            approvalsAvailable = true
            statusLine = "Demo on this iPhone. Nothing is sent."
        case .ssh:
            await refreshSSH()
        case .relay:
            await refreshRelay()
        }
        publish()
    }

    func start(prompt: String) async {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        switch mode {
        case .demo:
            let session = engine.start(prompt: text, cwd: cwd)
            sessions = engine.sessions
            selectedSessionID = session.id
            publish()
            try? await Task.sleep(nanoseconds: 700_000_000)
            _ = engine.raisePermission(sessionID: session.id)
            sessions = engine.sessions
        case .ssh:
            await startSSH(prompt: text)
        case .relay:
            await startRelay(prompt: text)
        }
        publish()
    }

    func allow(_ sessionID: String) {
        decide(sessionID, allow: true)
    }

    func deny(_ sessionID: String) {
        decide(sessionID, allow: false)
    }

    func stop(_ sessionID: String) {
        switch mode {
        case .demo:
            _ = engine.stop(sessionID: sessionID)
            sessions = engine.sessions
        case .ssh:
            live?.stop(sessionID: sessionID)
            update(sessionID) { session in
                session.status = .stopped
                session.permission = nil
                session.summary = "Stopped."
            }
        case .relay:
            Task { await relayStop(sessionID) }
        }
        publish()
    }

    func acceptTrust() {
        guard let prompt = trustPrompt, !prompt.changed else { return }
        let entry = KnownHostEntry(host: prompt.host.address, port: prompt.host.port, keyType: prompt.key.type, base64: prompt.key.base64)
        knownHosts.trust(entry)
        persistKnownHosts()
        let continuation = trustContinuation
        trustContinuation = nil
        trustPrompt = nil
        continuation?.resume(returning: true)
    }

    func rejectTrust() {
        let continuation = trustContinuation
        trustContinuation = nil
        trustPrompt = nil
        continuation?.resume(returning: false)
    }

    func forgetHostKey() {
        knownHosts.forget(host: host.address, port: host.port)
        persistKnownHosts()
        banner = "Saved host key forgotten. The next connection asks again."
        publish()
    }

    func perform(_ command: PhoneCommand) {
        switch command.kind {
        case .refresh:
            Task { await refresh() }
        case .start:
            Task { await start(prompt: command.prompt ?? "") }
        case .approve:
            if let id = command.sessionID { allow(id) }
        case .deny:
            if let id = command.sessionID { deny(id) }
        case .stop:
            if let id = command.sessionID { stop(id) }
        }
    }

    private func decide(_ sessionID: String, allow: Bool) {
        switch mode {
        case .demo:
            if allow { _ = engine.allow(sessionID: sessionID) } else { _ = engine.deny(sessionID: sessionID) }
            sessions = engine.sessions
        case .ssh:
            guard let request = sessions.first(where: { $0.id == sessionID })?.permission else { return }
            Task { await self.applySSHDecision(sessionID, request: request, allow: allow) }
            return
        case .relay:
            guard let request = sessions.first(where: { $0.id == sessionID })?.permission else { return }
            Task { await relayDecide(request, allow: allow) }
        }
        publish()
    }

    private func applySSHDecision(_ sessionID: String, request: PermissionRequest, allow: Bool) async {
        let wrote = await live?.respond(request, allow: allow) ?? false
        guard wrote else {
            approvalsAvailable = false
            banner = "The approval was not sent."
            if live?.isSessionActive != true {
                link = .offline
                statusLine = "Not connected"
            } else {
                statusLine = live?.statusLine ?? statusLine
            }
            publish()
            return
        }
        update(sessionID) { session in
            session.permission = nil
            session.status = allow ? .running : .stopped
            session.summary = allow ? "Allowed. Waiting for the rest of the turn." : "Denied."
        }
        publish()
    }

    private func refreshSSH() async {
        guard let live else { return }
        do {
            try await ensureSSH()
            sessions = try await live.list(cwd: cwd.isEmpty ? nil : cwd)
            link = .connected
            approvalsAvailable = live.approvalsAvailable
            statusLine = live.statusLine
            banner = nil
        } catch {
            if link != .needsPairing {
                link = .offline
            }
            approvalsAvailable = false
            banner = error.localizedDescription
            statusLine = live.statusLine
        }
    }

    private func startSSH(prompt: String) async {
        guard let live else { return }
        let localID = "local-\(UUID().uuidString.lowercased())"
        let title = prompt.split(whereSeparator: \.isWhitespace).prefix(6).joined(separator: " ")
        sessions.insert(GrokSession(id: localID, title: title, summary: "Starting.", status: .running, cwd: cwd), at: 0)
        publish()
        do {
            try await ensureSSH()
            let remoteID = try await live.start(localID: localID, prompt: prompt, cwd: cwd.isEmpty ? nil : cwd)
            if remoteID != localID {
                update(localID) { $0.id = remoteID }
            }
            approvalsAvailable = live.approvalsAvailable
            statusLine = live.statusLine
            link = .connected
        } catch {
            if link != .needsPairing {
                link = .offline
            }
            approvalsAvailable = false
            update(localID) {
                $0.status = .failed
                $0.summary = error.localizedDescription
            }
            banner = error.localizedDescription
        }
    }

    func reconnectIfNeeded() async {
        guard !holdsLaunchFixture, mode == .ssh else { return }
        await refresh()
    }

    private func ensureSSH() async throws {
        guard let live else { return }
        guard keys.key != nil else {
            link = .needsPairing
            throw SSHClientError.authenticationFailed("Generate a key on this iPhone, then authorize it on the computer.")
        }
        let secret = keys.secret(account: "agent-secret")
        if live.matches(host: host), live.isSessionActive {
            if secret != nil, !live.agentIsReady {
                try await live.openAgent(secret: secret)
            }
            link = .connected
            approvalsAvailable = live.approvalsAvailable
            statusLine = live.statusLine
            return
        }
        link = .connecting
        let privateKey = try keys.privateKey()
        let requested = host
        try await live.connect(host: requested, privateKey: privateKey, agentSecret: secret, verify: { [weak self] key in
            await self?.verify(key) ?? false
        })
        if host.address != requested.address || host.port != requested.port || host.username != requested.username {
            live.disconnect()
            let again = keys.secret(account: "agent-secret")
            try await live.connect(host: host, privateKey: privateKey, agentSecret: again, verify: { [weak self] key in
                await self?.verify(key) ?? false
            })
        }
        link = .connected
        approvalsAvailable = live.approvalsAvailable
        statusLine = live.statusLine
    }

    private func verify(_ key: PresentedHostKey) async -> Bool {
        let verdict = knownHosts.verdict(host: host.address, port: host.port, keyType: key.type, base64: key.base64)
        switch verdict {
        case .trusted:
            return true
        case .firstUse:
            return await askTrust(key: key, previous: nil, changed: false)
        case .changed(let previous, _):
            return await askTrust(key: key, previous: previous, changed: true)
        }
    }

    private func askTrust(key: PresentedHostKey, previous: String?, changed: Bool) async -> Bool {
        await withCheckedContinuation { continuation in
            trustContinuation = continuation
            trustPrompt = TrustPrompt(host: host, key: key, previousFingerprint: previous, changed: changed)
        }
    }

    private func refreshRelay() async {
        do {
            sessions = try await relay.list(url: relayURL, token: keys.secret(account: "relay-token"), pin: keys.secret(account: "relay-pin"))
            link = .connected
            approvalsAvailable = true
            statusLine = "Relay on the overlay."
            banner = nil
        } catch {
            link = .offline
            banner = error.localizedDescription
        }
    }

    private func startRelay(prompt: String) async {
        do {
            let session = try await relay.start(
                url: relayURL,
                token: keys.secret(account: "relay-token"),
                pin: keys.secret(account: "relay-pin"),
                prompt: prompt,
                cwd: cwd
            )
            sessions.insert(session, at: 0)
            link = .connected
        } catch {
            banner = error.localizedDescription
        }
    }

    private func relayDecide(_ request: PermissionRequest, allow: Bool) async {
        do {
            try await relay.decide(
                url: relayURL,
                token: keys.secret(account: "relay-token"),
                pin: keys.secret(account: "relay-pin"),
                permissionID: request.id,
                allow: allow
            )
            await refreshRelay()
        } catch {
            banner = error.localizedDescription
            publish()
        }
    }

    private func relayStop(_ sessionID: String) async {
        do {
            try await relay.cancel(
                url: relayURL,
                token: keys.secret(account: "relay-token"),
                pin: keys.secret(account: "relay-pin"),
                sessionID: sessionID
            )
            await refreshRelay()
        } catch {
            banner = error.localizedDescription
            publish()
        }
    }

    private func apply(_ event: ACPInbound) {
        switch event {
        case .update(let sessionID, let stream):
            applyStream(sessionID: sessionID, event: stream)
        case .permission(let request):
            update(request.sessionID) { session in
                session.status = .needsApproval
                session.permission = request
                session.summary = request.title
            }
        case .result, .failure, .notification:
            break
        }
        publish()
    }

    private func applyCLI(id: String, event: StreamEvent) {
        if case .end(let sessionID, _, _) = event, let sessionID, sessionID != id {
            update(id) { $0.id = sessionID }
            applyStream(sessionID: sessionID, event: event)
        } else {
            applyStream(sessionID: id, event: event)
        }
        publish()
    }

    private func applyStream(sessionID: String, event: StreamEvent) {
        update(sessionID) { session in
            switch event {
            case .text(let text):
                let combined = (session.summary + text).trimmingCharacters(in: .whitespacesAndNewlines)
                session.summary = PhoneSnapshot.clip(combined, limit: 280)
                session.status = .running
            case .thought:
                break
            case .tool(let title):
                session.summary = "Using \(title)."
                session.status = .running
            case .toolUpdate:
                break
            case .usage(let summary):
                if let summary, !summary.isEmpty { session.summary = summary }
            case .end(_, let reason, let usage):
                session.permission = nil
                session.status = reason == "cancelled" ? .stopped : .idle
                if let usage, !usage.isEmpty { session.summary = usage }
            case .error(let message):
                session.status = .failed
                session.summary = message
            case .ignored:
                break
            }
        }
    }

    private func update(_ id: String, _ body: (inout GrokSession) -> Void) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        body(&sessions[index])
    }

    private func persistKnownHosts() {
        try? knownHosts.text().write(to: support.appendingPathComponent("known_hosts"), atomically: true, encoding: .utf8)
    }

    private func publish() {
        bridge.push(snapshot)
    }

    private func applyLaunch() {
        let arguments = ProcessInfo.processInfo.arguments
        let environment = ProcessInfo.processInfo.environment
        let screen = argument("-WatchRemoteScreen", arguments: arguments) ?? environment["WATCHREMOTE_SCREEN"]
        let appearanceName = argument("-WatchRemoteAppearance", arguments: arguments) ?? environment["WATCHREMOTE_APPEARANCE"]
        if let appearanceName, let choice = AppearanceChoice(rawValue: appearanceName) {
            appearance = choice
        }
        guard let screen else {
            if mode == .demo {
                sessions = engine.sessions
                link = .demo
                approvalsAvailable = true
                statusLine = "Demo on this iPhone. Nothing is sent."
            }
            return
        }
        holdsLaunchFixture = true
        if let preview = DemoCatalog.preview(named: screen) {
            mode = preview.mode
            link = preview.link
            sessions = preview.sessions
            banner = preview.banner
            approvalsAvailable = preview.approvalsAvailable
            host.label = preview.hostLabel
            statusLine = preview.link.title
            tab = .sessions
            selectedSessionID = screen == "long" ? preview.sessions.first?.id : nil
            return
        }
        mode = .demo
        engine = MockEngine(preview: true)
        sessions = engine.sessions
        link = .demo
        approvalsAvailable = true
        statusLine = "Demo on this iPhone. Nothing is sent."
        banner = nil
        switch screen {
        case "hosts", "keys":
            tab = .computer
        case "settings":
            tab = .settings
        case "compose":
            tab = .sessions
            showCompose = true
        case "session":
            tab = .sessions
            selectedSessionID = DemoCatalog.approvalID
        default:
            tab = .sessions
            selectedSessionID = nil
        }
    }

    private func argument(_ name: String, arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name), arguments.index(after: index) < arguments.endIndex else { return nil }
        return arguments[arguments.index(after: index)]
    }
}

final class PhoneBridge: NSObject, WCSessionDelegate {
    private var onCommand: ((PhoneCommand) -> Void)?
    private var onActivated: (() -> Void)?

    func start(_ onCommand: @escaping (PhoneCommand) -> Void, onActivated: @escaping () -> Void) {
        self.onCommand = onCommand
        self.onActivated = onActivated
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    func push(_ snapshot: PhoneSnapshot) {
        guard WCSession.isSupported(), let payload = LinkCodec.encodeSnapshot(snapshot) else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        try? session.updateApplicationContext(["snapshot": payload])
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in self.onActivated?() }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        deliver(message)
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        deliver(userInfo)
    }

    private func deliver(_ message: [String: Any]) {
        guard let payload = message["command"] as? String, let command = LinkCodec.decodeCommand(payload) else { return }
        Task { @MainActor in self.onCommand?(command) }
    }
}
