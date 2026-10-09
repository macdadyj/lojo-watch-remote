import Foundation
import WatchConnectivity
import WatchRemoteCore

struct SavedHost: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var label: String
    var address: String
    var port: Int
    var username: String
    var pinnedFingerprint: String? = nil
    var paired: Bool = false

    enum CodingKeys: String, CodingKey {
        case id
        case label
        case address
        case port
        case username
        case pinnedFingerprint
        case paired
    }

    init(id: String, label: String, address: String, port: Int, username: String, pinnedFingerprint: String? = nil, paired: Bool = false) {
        self.id = id
        self.label = label
        self.address = address
        self.port = port
        self.username = username
        self.pinnedFingerprint = pinnedFingerprint
        self.paired = paired
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        address = try container.decode(String.self, forKey: .address)
        port = try container.decode(Int.self, forKey: .port)
        username = try container.decode(String.self, forKey: .username)
        pinnedFingerprint = try container.decodeIfPresent(String.self, forKey: .pinnedFingerprint)
        if let stored = try container.decodeIfPresent(Bool.self, forKey: .paired) {
            paired = stored
        } else {
            // Older builds did not store this flag. A customized host stays paired.
            // The untouched placeholder is the unpaired first-run computer.
            let untouched = label == OverlayPolicy.exampleLabel
                && address == OverlayPolicy.exampleAddress
                && username == OverlayPolicy.exampleUser
                && port == OverlayPolicy.examplePort
                && pinnedFingerprint == nil
            paired = !untouched
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(label, forKey: .label)
        try container.encode(address, forKey: .address)
        try container.encode(port, forKey: .port)
        try container.encode(username, forKey: .username)
        try container.encodeIfPresent(pinnedFingerprint, forKey: .pinnedFingerprint)
        try container.encode(paired, forKey: .paired)
    }

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

struct PairingNotice: Identifiable, Equatable {
    var id = UUID()
    var label: String
    var fingerprint: String?
    var storedSecret: Bool
}

struct TrustPrompt: Identifiable, Equatable {
    var id = UUID()
    var host: SavedHost
    var key: PresentedHostKey
    var previousFingerprint: String?
    var changed: Bool
    var matchesPin: Bool
}

enum AppTab: String, Hashable {
    case sessions, computer, settings
}

enum ConnectionTest: Equatable {
    case idle
    case running
    case connected
    case failed(String)
}

enum PairingMoment: Equatable {
    case none
    case ask
    case working
    case ready
    case problem(String)
}

enum PairingBanner: Equatable {
    case notPaired
    case waiting
    case connected

    var title: String {
        switch self {
        case .notPaired:
            return "Not paired"
        case .waiting:
            return "Waiting for authorization"
        case .connected:
            return "Connected"
        }
    }
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
    @Published var computers: [SavedHost]
    @Published var showPairing = false
    @Published var launchScanner = false
    @Published var connectionTest: ConnectionTest = .idle
    @Published var offer: PairingPayload?
    @Published var pairingMoment: PairingMoment = .none
    @Published var pairingNotice: PairingNotice?
    @Published var trustPrompt: TrustPrompt?
    @Published var showCompose = false
    @Published var selectedSessionID: String?
    @Published var autoApproveTools = false
    /// One-line state when a saved chat cannot be loaded or a send cannot be delivered.
    @Published var resumeNotice: String?
    private var resumeNoticeID: String?
    private var holdsLaunchFixture = false
    private var echoProbe = false
    private var echoPushTask: Task<Void, Never>?
    private var userDisconnected = false
    private var heartbeatTask: Task<Void, Never>?
    private var autoApprovedPermissionIDs = Set<String>()
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
    private var directContext: String?

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WatchRemote", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        self.support = support
        keys = KeyStore(directory: support)
        let defaults = UserDefaults.standard
        mode = ConnectionMode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .demo
        if defaults.object(forKey: "appearance") == nil {
            appearance = .dark
        } else {
            appearance = AppearanceChoice(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .dark
        }
        autoApproveTools = defaults.bool(forKey: "autoApproveTools")
        cwd = defaults.string(forKey: "cwd") ?? ""
        relayURL = defaults.string(forKey: "relayURL") ?? ""
        if let data = defaults.data(forKey: "computers"),
           let saved = try? JSONDecoder().decode([SavedHost].self, from: data),
           !saved.isEmpty {
            computers = saved
            let activeID = defaults.string(forKey: "activeComputerID")
            host = saved.first { $0.id == activeID } ?? saved[0]
        } else if let data = defaults.data(forKey: "host"), let saved = try? JSONDecoder().decode(SavedHost.self, from: data) {
            computers = [saved]
            host = saved
        } else {
            computers = [.placeholder]
            host = .placeholder
        }
        if let text = try? String(contentsOf: support.appendingPathComponent("known_hosts"), encoding: .utf8) {
            knownHosts = KnownHosts(text: text)
        } else {
            knownHosts = KnownHosts()
        }
        migrateLegacySecret()
        hasAgentSecret = keys.secret(account: agentAccount(host.id)) != nil
        directContext = keys.secret(account: directAccount(host.id))
        hasRelayToken = keys.secret(account: "relay-token") != nil
        hasRelayPin = keys.secret(account: "relay-pin") != nil
        live = LiveLink(
            onEvent: { [weak self] event in self?.apply(event) },
            onCLI: { [weak self] id, event in self?.applyCLI(id: id, event: event) },
            onDropped: { [weak self] in
                guard let self, self.mode == .ssh, !self.userDisconnected else { return }
                self.link = .connecting
                self.statusLine = "Reconnecting"
                self.banner = nil
                self.publish()
                Task { await self.reconnectIfNeeded() }
            },
            onAgentLost: { [weak self] in
                guard let self, self.mode == .ssh else { return }
                self.approvalsAvailable = false
                self.statusLine = self.live?.statusLine ?? "SSH connected. The agent server is not answering."
                self.publish()
            }
        )
        applyLaunch()
        restoreThreads()
        armHeartbeat()
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
            hostLabel: host.label,
            computers: computers.map { ComputerSummary(id: $0.id, label: $0.label) },
            activeComputerID: host.id,
            directReady: directContext?.contains("\"clear\":true") == false && directContext != nil,
            autoApproveTools: autoApproveTools
        )
    }

    var pairingBanner: PairingBanner {
        if mode != .demo && link == .connected {
            return .connected
        }
        if host.paired {
            return .waiting
        }
        return .notPaired
    }

    func beginScan() {
        launchScanner = true
        showPairing = true
    }

    func testConnection() async {
        guard !holdsLaunchFixture else { return }
        connectionTest = .running
        if mode == .demo {
            setMode(.ssh)
        }
        guard keys.key != nil else {
            link = .needsPairing
            statusLine = "Waiting for authorization"
            connectionTest = .failed("This iPhone has no key yet. Use Copy authorize command, run it on the computer, then test again.")
            publish()
            return
        }
        await refresh()
        if link == .connected {
            connectionTest = .connected
            statusLine = "Connected"
            banner = nil
        } else {
            let words = (banner ?? "The computer did not connect.").trimmingCharacters(in: .whitespacesAndNewlines)
            connectionTest = .failed(words.isEmpty ? "The computer did not connect." : words)
        }
        publish()
    }

    func selectComputer(id: String) {
        guard let next = computers.first(where: { $0.id == id }), next.id != host.id else { return }
        let previous = host.id
        host = next
        persistComputers()
        disconnectForHostChange()
        refreshSecretFlag()
        directContext = keys.secret(account: directAccount(host.id)) ?? clearDirect(computerID: previous, label: next.label)
        connectionTest = .idle
        publish()
    }

    func addComputer() {
        let created = SavedHost(
            id: UUID().uuidString.lowercased(),
            label: "Computer",
            address: OverlayPolicy.exampleAddress,
            port: OverlayPolicy.examplePort,
            username: OverlayPolicy.exampleUser
        )
        let previous = host.id
        computers.append(created)
        host = created
        persistComputers()
        disconnectForHostChange()
        refreshSecretFlag()
        directContext = clearDirect(computerID: previous, label: created.label)
        connectionTest = .idle
        publish()
    }

    func removeActiveComputer() {
        let removed = host
        keys.forgetSecret(account: agentAccount(removed.id))
        keys.forgetSecret(account: directAccount(removed.id))
        knownHosts.forget(host: removed.address, port: removed.port)
        persistKnownHosts()
        computers.removeAll { $0.id == removed.id }
        if computers.isEmpty {
            computers = [.placeholder]
        }
        host = computers[0]
        pairingNotice = nil
        persistComputers()
        disconnectForHostChange()
        refreshSecretFlag()
        directContext = keys.secret(account: directAccount(host.id)) ?? clearDirect(computerID: removed.id, label: removed.label)
        connectionTest = .idle
        banner = "Removed \(removed.label)."
        publish()
    }

    func dismissPairingNotice() {
        pairingNotice = nil
    }

    /// Stages a scanned code and asks "Is this your computer?" before anything is saved.
    func importPairing(_ text: String) -> String? {
        do {
            offer = try PairingPayload.decode(text)
        } catch let error as LocalizedError {
            return error.errorDescription ?? "That pairing code could not be read."
        } catch {
            return "That pairing code could not be read."
        }
        pairingMoment = .ask
        showPairing = false
        return nil
    }

    func dismissMoment() {
        guard pairingMoment != .working else { return }
        if pairingMoment == .ask { offer = nil }
        pairingMoment = .none
    }

    func acceptOffer() async {
        guard !holdsLaunchFixture, let payload = offer else { return }
        pairingMoment = .working
        if keys.key == nil {
            do {
                try keys.generateEd25519()
            } catch {
                pairingMoment = .problem("A key could not be created on this iPhone.")
                return
            }
        }
        guard let publicKey = keys.key?.publicKey else {
            pairingMoment = .problem("A key could not be created on this iPhone.")
            return
        }
        let saved = commitOffer(payload)
        if saved == nil {
            pairingMoment = .problem("The computer was saved, but the agent secret was not stored in the Keychain.")
            return
        }
        if let ticket = payload.ticket {
            let port = payload.enrollPort ?? PairingPayload.defaultEnrollPort
            if let failure = await HostEnroll.submit(address: payload.address, port: port, ticket: ticket, publicKey: publicKey) {
                pairingMoment = .problem(failure)
                return
            }
        }
        setMode(.ssh)
        await testConnection()
        if connectionTest == .connected {
            pairingMoment = .ready
            return
        }
        if payload.ticket == nil {
            pairingMoment = .problem("This code cannot authorize the iPhone by itself. Open Advanced and copy the authorize command.")
            return
        }
        if case .failed(let message) = connectionTest {
            pairingMoment = .problem(message)
        } else {
            pairingMoment = .problem("The computer did not connect.")
        }
    }

    /// Saves the staged computer. Returns nil when the agent secret could not be stored.
    private func commitOffer(_ payload: PairingPayload) -> SavedHost? {
        let existing = computers.first {
            $0.address == payload.address && $0.port == payload.port && $0.username == payload.user
        }
        let untouched = computers.count == 1 && computers[0] == .placeholder && keys.secret(account: agentAccount(computers[0].id)) == nil
        let id = existing?.id ?? UUID().uuidString.lowercased()
        let saved = SavedHost(
            id: id,
            label: payload.label,
            address: payload.address,
            port: payload.port,
            username: payload.user,
            pinnedFingerprint: payload.fingerprint ?? existing?.pinnedFingerprint,
            paired: true
        )
        if untouched && existing == nil {
            knownHosts.forget(host: computers[0].address, port: computers[0].port)
            persistKnownHosts()
            computers = [saved]
        } else if let index = computers.firstIndex(where: { $0.id == id }) {
            computers[index] = saved
        } else {
            computers.append(saved)
        }
        let changed = host.id != saved.id || host.address != saved.address || host.port != saved.port || host.username != saved.username
        host = saved
        persistComputers()
        var storedSecret = false
        if let secret = payload.secret {
            do {
                try keys.saveSecret(secret, account: agentAccount(id))
                storedSecret = true
            } catch {
                refreshSecretFlag()
                pairingNotice = PairingNotice(label: saved.label, fingerprint: saved.pinnedFingerprint, storedSecret: false)
                if changed { disconnectForHostChange() }
                showPairing = false
                publish()
                return nil
            }
        }
        refreshSecretFlag()
        storeDirect(payload, computerID: id, label: saved.label)
        pairingNotice = PairingNotice(label: saved.label, fingerprint: saved.pinnedFingerprint, storedSecret: storedSecret)
        if changed { disconnectForHostChange() }
        banner = storedSecret ? "Paired \(saved.label). The agent secret is in the Keychain." : "Paired \(saved.label)."
        showPairing = false
        publish()
        return saved
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
        let pin = changed ? nil : host.pinnedFingerprint
        let updated = SavedHost(
            id: host.id,
            label: name.isEmpty ? OverlayPolicy.exampleLabel : name,
            address: canonical,
            port: port,
            username: user,
            pinnedFingerprint: pin,
            paired: true
        )
        if computers.contains(where: { $0.id != updated.id && $0.address == canonical && $0.port == port && $0.username == user }) {
            return "That computer is already in the list."
        }
        host = updated
        if let index = computers.firstIndex(where: { $0.id == updated.id }) {
            computers[index] = updated
        } else {
            computers.append(updated)
        }
        persistComputers()
        if changed {
            disconnectForHostChange()
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
        try? keys.saveSecret(trimmed, account: agentAccount(host.id))
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
        await refresh(quiet: false)
    }

    func refresh(quiet: Bool) async {
        guard !holdsLaunchFixture else { return }
        if !quiet {
            userDisconnected = false
        }
        switch mode {
        case .demo:
            sessions = engine.sessions
            link = .demo
            approvalsAvailable = true
            statusLine = "Demo on this iPhone. Nothing is sent."
        case .ssh:
            await refreshSSH(quiet: quiet)
        case .relay:
            await refreshRelay(quiet: quiet)
        }
        sweepAutoApprovals()
        publish()
    }

    func start(prompt: String, sessionID: String? = nil) async {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let sessionID, !sessionID.isEmpty {
            await continueSession(sessionID, prompt: text)
            return
        }
        switch mode {
        case .demo:
            let session = engine.start(prompt: text, cwd: cwd)
            sessions = engine.sessions
            selectedSessionID = session.id
            publish()
            try? await Task.sleep(nanoseconds: 200_000_000)
            _ = engine.deliverReply(sessionID: session.id, reply: "Done. \(text)")
            sessions = engine.sessions
        case .ssh:
            await startSSH(prompt: text)
        case .relay:
            await startRelay(prompt: text)
        }
        publish()
    }

    func resume(sessionID: String) async {
        let id = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            banner = SessionResume.missingMessage
            publish()
            return
        }
        switch mode {
        case .demo:
            resumeDemo(id)
        case .ssh:
            await resumeSSH(id)
        case .relay:
            await resumeRelay(id)
        }
    }

    func openChat(_ sessionID: String) {
        let id = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        userDisconnected = false
        selectedSessionID = id
        Task { await resume(sessionID: id) }
    }

    func resumeNotice(for sessionID: String) -> String? {
        guard resumeNoticeID == sessionID else { return nil }
        let text = resumeNotice?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    func retryChat(_ sessionID: String) async {
        let pending = undeliveredPrompt(sessionID)
        await resume(sessionID: sessionID)
        guard let pending else { return }
        dropTrailingUserLine(sessionID, matching: pending)
        await continueSession(sessionID, prompt: pending)
    }

    func continueInNewChat(_ sessionID: String) async {
        let history = sessions.first { $0.id == sessionID }?.transcript ?? []
        let pending = undeliveredPrompt(sessionID) ?? ChatTranscript.spokenText(history.last { $0.hasPrefix("You:") } ?? "")
        let prompt = pending.isEmpty ? "Continue this chat." : pending
        var prior = history
        if prior.last == "You: \(prompt)" {
            prior.removeLast()
        }
        clearResumeNotice(sessionID)
        await respawn(threadID: sessionID, prompt: prompt, history: prior)
    }

    func endChat(_ sessionID: String) {
        let existing = sessions.first { $0.id == sessionID }?.transcript ?? []
        mirrorDemo(sessionID)
        stop(sessionID)
        let lines = ChatTranscript.append("Ended.", to: existing)
        update(sessionID) { session in
            session.transcript = lines
            session.status = .stopped
        }
        mirrorDemo(sessionID)
        publish()
    }

    func disconnectLink() {
        userDisconnected = true
        heartbeatTask?.cancel()
        live?.disconnect()
        if mode != .demo {
            link = .offline
            approvalsAvailable = false
            statusLine = "Disconnected"
        }
        banner = nil
        publish()
        armHeartbeat()
    }

    func setAutoApprove(_ enabled: Bool) {
        autoApproveTools = enabled
        UserDefaults.standard.set(enabled, forKey: "autoApproveTools")
        publish()
        sweepAutoApprovals()
    }

    func setSessionAutoApprove(_ sessionID: String, _ enabled: Bool) {
        update(sessionID) { $0.autoApprove = enabled }
        publish()
        if let request = sessions.first(where: { $0.id == sessionID })?.permission {
            considerAutoApprove(sessionID: sessionID, request: request)
        }
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
        let hadPin = host.pinnedFingerprint != nil
        knownHosts.forget(host: host.address, port: host.port)
        persistKnownHosts()
        if hadPin {
            host.pinnedFingerprint = nil
            if let index = computers.firstIndex(where: { $0.id == host.id }) {
                computers[index].pinnedFingerprint = nil
            }
            persistComputers()
        }
        banner = hadPin
            ? "Saved host key forgotten, including the fingerprint from pairing. The next connection asks again."
            : "Saved host key forgotten. The next connection asks again."
        publish()
    }

    func perform(_ command: PhoneCommand) {
        switch command.kind {
        case .refresh:
            Task { await refresh() }
        case .start:
            if echoProbe {
                echoStart(prompt: command.prompt ?? "", sessionID: command.sessionID)
                return
            }
            Task { await start(prompt: command.prompt ?? "", sessionID: command.sessionID) }
        case .approve:
            if let id = command.sessionID { allow(id) }
        case .deny:
            if let id = command.sessionID { deny(id) }
        case .stop:
            if let id = command.sessionID { stop(id) }
        case .selectComputer:
            if let id = command.computerID { selectComputer(id: id) }
        case .resume:
            if let id = command.sessionID {
                Task { await resume(sessionID: id) }
            } else {
                banner = SessionResume.missingMessage
                publish()
            }
        case .showPairing:
            tab = .computer
            beginScan()
        case .setAutoApprove:
            setAutoApprove(command.enabled == true)
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

    private func refreshSSH(quiet: Bool) async {
        guard let live else { return }
        do {
            try await ensureSSH()
            let listed = try await live.list(cwd: cwd.isEmpty ? nil : cwd)
            sessions = mergeThreads(listed)
            link = .connected
            approvalsAvailable = live.approvalsAvailable
            statusLine = live.statusLine
            banner = nil
        } catch {
            if link != .needsPairing {
                if quiet, live.isSessionActive {
                    link = .connected
                    statusLine = live.statusLine
                } else {
                    link = quiet ? .connecting : .offline
                }
            }
            approvalsAvailable = live.isSessionActive && live.approvalsAvailable
            if quiet {
                if !live.isSessionActive {
                    statusLine = "Reconnecting"
                }
            } else if !ChatTranscript.isStatusNoise(error.localizedDescription) {
                banner = error.localizedDescription
                statusLine = live.statusLine
            }
        }
    }

    private func continueSession(_ sessionID: String, prompt: String) async {
        switch mode {
        case .demo:
            mirrorDemo(sessionID)
            guard engine.continueSession(sessionID: sessionID, prompt: prompt) else {
                await respawnDemo(threadID: sessionID, prompt: prompt)
                return
            }
            sessions = engine.sessions
            selectedSessionID = sessionID
            banner = nil
            publish()
            try? await Task.sleep(nanoseconds: 200_000_000)
            _ = engine.deliverReply(sessionID: sessionID, reply: "Done. \(prompt)")
            sessions = engine.sessions
        case .ssh:
            await continueSSH(sessionID: sessionID, prompt: prompt)
        case .relay:
            await continueRelay(sessionID: sessionID, prompt: prompt)
        }
        publish()
    }

    private func resumeDemo(_ sessionID: String) {
        let source = sessions.first(where: { $0.id == sessionID }) ?? engine.sessions.first(where: { $0.id == sessionID })
        guard let source else {
            banner = SessionResume.missingMessage
            setResumeNotice(sessionID, SessionResume.missingMessage)
            publish()
            return
        }
        let visible = sessions.first(where: { $0.id == sessionID })?.transcript ?? []
        let cached = engine.sessions.first(where: { $0.id == sessionID })?.transcript ?? []
        let chosen = SessionResume.choose(local: visible.count >= cached.count ? visible : cached, loaded: [], replayed: [])
        if sessions.contains(where: { $0.id == sessionID }) {
            update(sessionID) { session in
                if !chosen.isEmpty {
                    session.transcript = chosen
                }
            }
        } else {
            var copy = source
            copy.transcript = chosen
            sessions.insert(copy, at: 0)
        }
        if chosen.isEmpty {
            setResumeNotice(sessionID, SessionResume.unavailableMessage)
        } else {
            clearResumeNotice(sessionID)
        }
        banner = nil
        mirrorDemo(sessionID)
        publish()
    }

    /// Demo turns live on the engine. Copy the visible transcript across first so a resume is not dropped.
    private func mirrorDemo(_ sessionID: String) {
        guard let current = sessions.first(where: { $0.id == sessionID }) else { return }
        guard let stored = engine.sessions.first(where: { $0.id == sessionID }) else { return }
        let visible = current.transcript ?? []
        let previous = stored.transcript ?? []
        engine.adopt(
            sessionID: sessionID,
            title: current.title,
            transcript: visible.count >= previous.count ? visible : previous,
            autoApprove: current.autoApprove
        )
    }

    private func resumeRelay(_ sessionID: String) async {
        let local = sessions.first(where: { $0.id == sessionID })
        do {
            let lines = try await relay.load(
                url: relayURL,
                token: keys.secret(account: "relay-token"),
                pin: keys.secret(account: "relay-pin"),
                sessionID: sessionID
            )
            let cached = local?.transcript ?? []
            let chosen = SessionResume.choose(local: cached, loaded: lines, replayed: [])
            let merged = SessionResume.keeping(sessions.first { $0.id == sessionID }?.transcript ?? cached, onto: chosen)
            if sessions.contains(where: { $0.id == sessionID }) {
                update(sessionID) { session in
                    if !merged.isEmpty { session.transcript = merged }
                }
            }
            if merged.isEmpty || sendingFailed(sessionID) {
                setResumeNotice(sessionID, merged.isEmpty ? SessionResume.unavailableMessage : (resumeNotice(for: sessionID) ?? SessionResume.unavailableMessage))
            } else {
                clearResumeNotice(sessionID)
            }
            link = .connected
            statusLine = "Relay on the overlay."
            banner = nil
        } catch {
            guard let local else {
                banner = SessionResume.missingMessage
                setResumeNotice(sessionID, SessionResume.missingMessage)
                publish()
                return
            }
            let chosen = SessionResume.chatLines(local.transcript ?? [])
            if !chosen.isEmpty {
                update(sessionID) { $0.transcript = chosen }
                clearResumeNotice(sessionID)
            } else {
                setResumeNotice(sessionID, SessionResume.unavailableMessage)
            }
            banner = nil
        }
        publish()
    }

    private func continueRelay(sessionID: String, prompt: String) async {
        let history = sessions.first(where: { $0.id == sessionID })?.transcript ?? []
        rememberOutgoing(sessionID, prompt: prompt)
        do {
            let session = try await relay.prompt(
                url: relayURL,
                token: keys.secret(account: "relay-token"),
                pin: keys.secret(account: "relay-pin"),
                sessionID: sessionID,
                prompt: prompt,
                cwd: cwd
            )
            if sessions.contains(where: { $0.id == sessionID }) {
                update(sessionID) { item in
                    item.summary = session.summary
                    item.status = session.status
                    item.updatedAt = Date()
                }
            } else {
                var copy = session
                copy.transcript = ChatTranscript.append("You: \(prompt)", to: history)
                sessions.insert(copy, at: 0)
            }
            selectedSessionID = sessionID
            link = .connected
            banner = nil
            clearResumeNotice(sessionID)
        } catch {
            let text = error.localizedDescription
            settleOutgoing(sessionID)
            if text.contains("no longer") || text.contains("Not found") || text.contains("404") {
                setResumeNotice(sessionID, SessionResume.missingMessage)
            } else {
                setResumeNotice(sessionID, SessionResume.unavailableMessage)
            }
            banner = nil
        }
    }

    private func respawnDemo(threadID: String, prompt: String) async {
        let history = sessions.first(where: { $0.id == threadID })?.transcript ?? []
        let title = sessions.first(where: { $0.id == threadID })?.title
        let created = engine.start(prompt: prompt, cwd: cwd)
        engine.rewrite(sessionID: created.id, title: title, transcript: ChatTranscript.append("You: \(prompt)", to: history))
        engine.remove(sessionID: threadID)
        sessions = engine.sessions
        selectedSessionID = created.id
        publish()
        try? await Task.sleep(nanoseconds: 200_000_000)
        _ = engine.deliverReply(sessionID: created.id, reply: "Done. \(prompt)")
        sessions = engine.sessions
        publish()
    }

    private func respawn(threadID: String, prompt: String, history: [String]) async {
        let context = ChatTranscript.followUp(history: history, message: prompt)
        let keptTitle = sessions.first(where: { $0.id == threadID })?.title
        switch mode {
        case .demo:
            await respawnDemo(threadID: threadID, prompt: prompt)
        case .ssh:
            await startSSH(prompt: context)
            stitchNewest(replacing: threadID, history: history, prompt: prompt, title: keptTitle)
        case .relay:
            await startRelay(prompt: context)
            stitchNewest(replacing: threadID, history: history, prompt: prompt, title: keptTitle)
        }
    }

    private func stitchNewest(replacing threadID: String, history: [String], prompt: String, title: String?) {
        guard let newest = sessions.first, newest.id != threadID else { return }
        update(newest.id) { session in
            if let title, !title.isEmpty { session.title = title }
            var lines = history
            lines = ChatTranscript.append("You: \(prompt)", to: lines)
            session.transcript = lines
        }
        sessions.removeAll { $0.id == threadID }
        selectedSessionID = newest.id
    }

    private func resumeSSH(_ sessionID: String) async {
        guard let live else {
            banner = SessionResume.missingMessage
            setResumeNotice(sessionID, SessionResume.missingMessage)
            publish()
            return
        }
        let cached = sessions.first(where: { $0.id == sessionID })?.transcript ?? []
        do {
            try await ensureSSH()
            let listed = try await live.list(cwd: cwd.isEmpty ? nil : cwd)
            guard let known = listed.first(where: { $0.id == sessionID }) else {
                if sendingFailed(sessionID) || SessionResume.chatLines(cached).isEmpty {
                    banner = SessionResume.missingMessage
                    setResumeNotice(sessionID, SessionResume.missingMessage)
                } else {
                    banner = nil
                    clearResumeNotice(sessionID)
                }
                publish()
                return
            }
            let loaded = try await live.loadSessionCaptured(sessionID: sessionID, cwd: known.cwd ?? cwd)
            let merged = mergedTranscript(sessionID, cached: cached, raw: loaded.raw, replay: loaded.replay)
            if sessions.contains(where: { $0.id == sessionID }) {
                update(sessionID) { session in
                    session.title = known.title.isEmpty ? session.title : known.title
                    if !known.summary.isEmpty, session.summary == "Sending." || session.summary.isEmpty {
                        session.summary = known.summary
                    }
                    if session.summary != "Sending." {
                        session.status = known.status
                    }
                    session.cwd = known.cwd ?? session.cwd
                    if !merged.isEmpty { session.transcript = merged }
                }
            } else {
                var copy = known
                copy.transcript = merged
                sessions.insert(copy, at: 0)
            }
            if merged.isEmpty || sendingFailed(sessionID) {
                setResumeNotice(sessionID, merged.isEmpty ? SessionResume.unavailableMessage : (resumeNotice(for: sessionID) ?? SessionResume.unavailableMessage))
            } else {
                clearResumeNotice(sessionID)
            }
            link = .connected
            approvalsAvailable = live.approvalsAvailable
            statusLine = live.statusLine
            banner = nil
        } catch {
            if sendingFailed(sessionID) || SessionResume.chatLines(cached).isEmpty {
                setResumeNotice(sessionID, SessionResume.unavailableMessage)
            } else {
                clearResumeNotice(sessionID)
            }
            if link != .needsPairing, live.isSessionActive != true {
                link = .offline
            }
            statusLine = live.statusLine
            banner = nil
        }
        publish()
    }

    private func continueSSH(sessionID: String, prompt: String) async {
        guard let live else {
            rememberOutgoing(sessionID, prompt: prompt)
            setResumeNotice(sessionID, SessionResume.missingMessage)
            publish()
            return
        }
        rememberOutgoing(sessionID, prompt: prompt)
        do {
            try await ensureSSH()
            let listed = try await live.list(cwd: cwd.isEmpty ? nil : cwd)
            guard let known = listed.first(where: { $0.id == sessionID }) else {
                settleOutgoing(sessionID)
                setResumeNotice(sessionID, SessionResume.missingMessage)
                publish()
                return
            }
            if !sessions.contains(where: { $0.id == sessionID }) {
                sessions.insert(known, at: 0)
                rememberOutgoing(sessionID, prompt: prompt)
            }
            publish()
            let replay = try await live.resumePrompt(sessionID: sessionID, prompt: prompt, cwd: known.cwd ?? cwd)
            let merged = mergedTranscript(sessionID, cached: sessions.first { $0.id == sessionID }?.transcript ?? [], raw: "", replay: replay)
            if !merged.isEmpty {
                update(sessionID) { session in
                    session.transcript = merged
                    if session.summary == "Sending." {
                        session.status = .running
                    }
                }
            }
            approvalsAvailable = live.approvalsAvailable
            statusLine = live.statusLine
            link = .connected
            banner = nil
            clearResumeNotice(sessionID)
        } catch {
            settleOutgoing(sessionID)
            setResumeNotice(sessionID, SessionResume.unavailableMessage)
            if link != .needsPairing, live.isSessionActive != true {
                link = .offline
            }
            approvalsAvailable = false
            statusLine = live.statusLine
            banner = nil
        }
        publish()
    }

    private func mergedTranscript(_ sessionID: String, cached: [String], raw: String, replay: [StreamEvent]) -> [String] {
        let replayed = replay.reduce(into: [String]()) { lines, event in
            lines = SessionResume.folding(event, into: lines)
        }
        let latest = sessions.first(where: { $0.id == sessionID })?.transcript ?? cached
        let chosen = SessionResume.choose(
            local: latest.count >= cached.count ? latest : cached,
            loaded: SessionResume.transcriptLines(inLoadJSON: raw),
            replayed: replayed
        )
        return SessionResume.keeping(latest, onto: chosen)
    }

    private func rememberOutgoing(_ sessionID: String, prompt: String) {
        update(sessionID) { session in
            session.transcript = ChatTranscript.append("You: \(prompt)", to: session.transcript ?? [])
            session.status = .running
            session.summary = "Sending."
        }
        clearResumeNotice(sessionID)
        publish()
    }

    private func settleOutgoing(_ sessionID: String) {
        update(sessionID) { session in
            if session.status == .running {
                session.status = .idle
            }
            if session.summary == "Sending." {
                session.summary = "Not sent."
            }
        }
    }

    private func sendingFailed(_ sessionID: String) -> Bool {
        sessions.first { $0.id == sessionID }?.summary == "Not sent."
    }

    private func undeliveredPrompt(_ sessionID: String) -> String? {
        guard resumeNoticeID == sessionID else { return nil }
        guard let last = sessions.first(where: { $0.id == sessionID })?.transcript?.last, last.hasPrefix("You:") else {
            return nil
        }
        let text = ChatTranscript.spokenText(last)
        return text.isEmpty ? nil : text
    }

    private func dropTrailingUserLine(_ sessionID: String, matching prompt: String) {
        update(sessionID) { session in
            guard session.transcript?.last == "You: \(prompt)" else { return }
            session.transcript?.removeLast()
        }
    }

    private func setResumeNotice(_ sessionID: String, _ message: String) {
        resumeNoticeID = sessionID
        resumeNotice = message
    }

    private func clearResumeNotice(_ sessionID: String) {
        guard resumeNoticeID == sessionID else { return }
        resumeNoticeID = nil
        resumeNotice = nil
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
        guard !holdsLaunchFixture, !userDisconnected else { return }
        switch mode {
        case .demo:
            return
        case .ssh, .relay:
            await refresh(quiet: true)
        }
    }

    private func ensureSSH() async throws {
        guard let live else { return }
        guard keys.key != nil else {
            link = .needsPairing
            throw SSHClientError.authenticationFailed("Generate a key on this iPhone, then authorize it on the computer.")
        }
        let secret = keys.secret(account: agentAccount(host.id))
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
            let again = keys.secret(account: agentAccount(host.id))
            try await live.connect(host: host, privateKey: privateKey, agentSecret: again, verify: { [weak self] key in
                await self?.verify(key) ?? false
            })
        }
        link = .connected
        approvalsAvailable = live.approvalsAvailable
        statusLine = live.statusLine
    }

    private func verify(_ key: PresentedHostKey) async -> Bool {
        if let pinned = host.pinnedFingerprint, pinned != key.fingerprint {
            return await askTrust(key: key, previous: pinned, changed: true, matchesPin: false)
        }
        let verdict = knownHosts.verdict(host: host.address, port: host.port, keyType: key.type, base64: key.base64)
        switch verdict {
        case .trusted:
            return true
        case .firstUse:
            let matches = host.pinnedFingerprint == key.fingerprint
            return await askTrust(key: key, previous: matches ? host.pinnedFingerprint : nil, changed: false, matchesPin: matches)
        case .changed(let previous, _):
            return await askTrust(key: key, previous: previous, changed: true, matchesPin: false)
        }
    }

    private func askTrust(key: PresentedHostKey, previous: String?, changed: Bool, matchesPin: Bool) async -> Bool {
        await withCheckedContinuation { continuation in
            trustContinuation = continuation
            trustPrompt = TrustPrompt(host: host, key: key, previousFingerprint: previous, changed: changed, matchesPin: matchesPin)
        }
    }

    private func refreshRelay(quiet: Bool) async {
        do {
            let listed = try await relay.list(url: relayURL, token: keys.secret(account: "relay-token"), pin: keys.secret(account: "relay-pin"))
            sessions = mergeThreads(listed)
            link = .connected
            approvalsAvailable = true
            statusLine = "Relay on the overlay."
            banner = nil
        } catch {
            if !(quiet && link == .connected && !sessions.isEmpty) {
                link = quiet ? .connecting : .offline
            }
            if quiet {
                if link != .connected {
                    statusLine = "Reconnecting"
                }
            } else if !ChatTranscript.isStatusNoise(error.localizedDescription) {
                banner = error.localizedDescription
            }
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
            await refreshRelay(quiet: false)
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
            await refreshRelay(quiet: false)
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
            publish()
            considerAutoApprove(sessionID: request.sessionID, request: request)
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
            case .user(let text):
                session.transcript = ChatTranscript.mergingUserEcho(text, into: session.transcript ?? [])
                session.status = .running
            case .text(let text):
                session.transcript = ChatTranscript.streamingAssistant(text, in: session.transcript ?? [])
                session.summary = PhoneSnapshot.clip(
                    ChatTranscript.lastMessage(summary: session.summary, transcript: session.transcript),
                    limit: 280
                )
                session.status = .running
            case .thought:
                break
            case .tool(let title):
                session.transcript = ChatTranscript.append(ChatTranscript.toolCard(title), to: session.transcript ?? [])
                session.summary = "Using \(title)."
                session.status = .running
            case .toolUpdate:
                break
            case .usage(let summary):
                if let summary, !summary.isEmpty { session.summary = summary }
            case .end(_, let reason, let usage):
                session.permission = nil
                session.status = reason == "cancelled" ? .stopped : .idle
                session.updatedAt = Date()
                if let usage, !usage.isEmpty { session.summary = usage }
            case .error(let message):
                session.status = .failed
                session.summary = message
                setResumeNotice(sessionID, SessionResume.unavailableMessage)
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

    private func agentAccount(_ id: String) -> String {
        "agent-secret." + id
    }

    private func directAccount(_ id: String) -> String {
        "direct-pairing." + id
    }

    private func refreshSecretFlag() {
        hasAgentSecret = keys.secret(account: agentAccount(host.id)) != nil
    }

    private func migrateLegacySecret() {
        let account = agentAccount(host.id)
        guard keys.secret(account: account) == nil, let legacy = keys.secret(account: "agent-secret") else { return }
        do {
            try keys.saveSecret(legacy, account: account)
            keys.forgetSecret(account: "agent-secret")
        } catch {
            return
        }
    }

    private func persistComputers() {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(computers) {
            defaults.set(data, forKey: "computers")
        }
        if let data = try? JSONEncoder().encode(host) {
            defaults.set(data, forKey: "host")
        }
        defaults.set(host.id, forKey: "activeComputerID")
    }

    private func disconnectForHostChange() {
        live?.disconnect()
        guard mode == .ssh else { return }
        link = .offline
        approvalsAvailable = false
        statusLine = "Not connected"
    }

    private func clearDirect(computerID: String, label: String) -> String? {
        DirectPairing(computerID: computerID, label: label, relayURL: "", token: "", key: "", clear: true).jsonText()
    }

    private func storeDirect(_ payload: PairingPayload, computerID: String, label: String) {
        guard payload.hasDirectRelay, let relayURL = payload.relayURL, let token = payload.token, let key = payload.e2eKey else {
            keys.forgetSecret(account: directAccount(computerID))
            directContext = DirectPairing(computerID: computerID, label: label, relayURL: "", token: "", key: "", clear: true).jsonText()
            return
        }
        let pairing = DirectPairing(computerID: computerID, label: label, relayURL: relayURL, token: token, key: key)
        guard let text = pairing.jsonText() else { return }
        do {
            try keys.saveSecret(text, account: directAccount(computerID))
            directContext = text
        } catch {
            directContext = nil
        }
    }

    private func publish() {
        persistThreads()
        bridge.push(snapshot, direct: directContext)
    }

    private func threadsFile() -> URL {
        support.appendingPathComponent("threads.json")
    }

    private func persistThreads() {
        guard !holdsLaunchFixture else { return }
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        try? data.write(to: threadsFile(), options: .atomic)
    }

    private func restoreThreads() {
        guard !holdsLaunchFixture else { return }
        guard let data = try? Data(contentsOf: threadsFile()),
              let saved = try? JSONDecoder().decode([GrokSession].self, from: data),
              !saved.isEmpty else { return }
        if uiTestLaunch {
            mergeDemoCache(saved)
            sessions = engine.sessions.map { session in
                var copy = session
                copy.transcript = nil
                return copy
            }
            return
        }
        sessions = saved
        engine = MockEngine(sessions: saved)
    }

    /// UI tests reopen a chat whose row has no transcript. The engine still holds the saved lines.
    private func mergeDemoCache(_ saved: [GrokSession]) {
        if engine.sessions.isEmpty {
            engine = MockEngine(preview: true)
        }
        var merged = engine.sessions
        for session in saved {
            let cached = merged.first { $0.id == session.id }?.transcript ?? []
            let prior = session.transcript ?? []
            let richer = prior.count >= cached.count ? prior : cached
            let chosen = SessionResume.choose(local: richer, loaded: [], replayed: [])
            if let index = merged.firstIndex(where: { $0.id == session.id }) {
                if !chosen.isEmpty { merged[index].transcript = chosen }
                if !session.title.isEmpty { merged[index].title = session.title }
                merged[index].autoApprove = session.autoApprove ?? merged[index].autoApprove
            } else if !chosen.isEmpty {
                var copy = session
                copy.transcript = chosen
                merged.insert(copy, at: 0)
            }
        }
        engine = MockEngine(sessions: merged)
    }

    private var uiTestLaunch: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        let environment = ProcessInfo.processInfo.environment
        return arguments.contains("-WatchRemoteUITest") || environment["WATCHREMOTE_UI_TEST"] == "1"
    }

    private func mergeThreads(_ listed: [GrokSession]) -> [GrokSession] {
        let listedIDs = Set(listed.map(\.id))
        let kept = sessions.filter { !listedIDs.contains($0.id) }
        let merged = listed.map { item -> GrokSession in
            var copy = item
            if let local = sessions.first(where: { $0.id == item.id }) {
                if copy.transcript == nil || copy.transcript?.isEmpty == true {
                    copy.transcript = local.transcript
                }
                if copy.autoApprove == nil {
                    copy.autoApprove = local.autoApprove
                }
            }
            return copy
        }
        return merged + kept
    }

    private func sweepAutoApprovals() {
        for session in sessions {
            if let request = session.permission {
                considerAutoApprove(sessionID: session.id, request: request)
            }
        }
    }

    private func considerAutoApprove(sessionID: String, request: PermissionRequest) {
        let session = sessions.first { $0.id == sessionID }
        let preference = ApprovalPreference(globalAutoApprove: autoApproveTools, sessionOverride: session?.autoApprove)
        guard preference.autoApproves else { return }
        guard autoApprovedPermissionIDs.insert(request.id).inserted else { return }
        let line = ChatTranscript.autoApproved(request.title)
        if mode == .demo {
            engine.noteLine(sessionID: sessionID, line: line)
        }
        update(sessionID) { item in
            item.transcript = ChatTranscript.append(line, to: item.transcript ?? [])
        }
        allow(sessionID)
    }

    private func armHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                let pause = UInt64(SessionKeepalive.heartbeatInterval * 1_000_000_000)
                try? await Task.sleep(nanoseconds: pause)
                await self?.heartbeat()
            }
        }
    }

    private func heartbeat() async {
        guard !holdsLaunchFixture, !userDisconnected else { return }
        guard SessionKeepalive.remainsLive(elapsed: SessionKeepalive.heartbeatInterval, userEnded: false) else { return }
        switch mode {
        case .demo:
            return
        case .ssh, .relay:
            await refresh(quiet: true)
        }
    }

    private func echoStart(prompt: String, sessionID: String?) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? sessionID!.trimmingCharacters(in: .whitespacesAndNewlines)
            : (sessions.first?.id ?? "echo-1")
        if !sessions.contains(where: { $0.id == id }) {
            sessions.insert(GrokSession(id: id, title: "New chat", summary: "Starting.", status: .running), at: 0)
        }
        if !trimmed.isEmpty {
            rememberOutgoing(id, prompt: trimmed)
        }
        update(id) { session in
            session.transcript = ChatTranscript.append("Grok: I can hear you.", to: session.transcript ?? [])
            session.status = .idle
            session.summary = "I can hear you."
            session.updatedAt = Date()
        }
        publish()
    }

    /// The Watch app is installed after this process starts. Keep the echo snapshot
    /// flowing until the tests finish, and send one immediately.
    private func scheduleEchoPublish() {
        publish()
        echoPushTask?.cancel()
        echoPushTask = Task { [weak self] in
            for _ in 0..<800 {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let self, !Task.isCancelled else { return }
                self.publish()
            }
        }
    }

    private func applyLaunch() {
        let arguments = ProcessInfo.processInfo.arguments
        let environment = ProcessInfo.processInfo.environment
        if arguments.contains("-WatchRemoteEchoProbe") || environment["WATCHREMOTE_ECHO_PROBE"] == "1" {
            holdsLaunchFixture = true
            echoProbe = true
            mode = .ssh
            link = .connected
            approvalsAvailable = true
            host.label = "example-host"
            statusLine = "Connected"
            banner = nil
            sessions = [
                GrokSession(
                    id: "echo-1",
                    title: "Greeting and Current Weather Inquiry",
                    summary: "Ready.",
                    status: .idle,
                    transcript: ["You: earlier", "Grok: Ready."]
                ),
            ]
            scheduleEchoPublish()
            return
        }
        let screen = argument("-WatchRemoteScreen", arguments: arguments) ?? environment["WATCHREMOTE_SCREEN"]
        let appearanceName = argument("-WatchRemoteAppearance", arguments: arguments) ?? environment["WATCHREMOTE_APPEARANCE"]
        if let appearanceName, let choice = AppearanceChoice(rawValue: appearanceName) {
            appearance = choice
        }
        let uiTest = arguments.contains("-WatchRemoteUITest") || environment["WATCHREMOTE_UI_TEST"] == "1"
        guard let screen else {
            if uiTest || mode == .demo {
                mode = uiTest ? .demo : mode
                if uiTest {
                    engine = MockEngine(preview: true)
                    appearance = .dark
                    sessions = engine.sessions.map { session in
                        var copy = session
                        copy.transcript = nil
                        return copy
                    }
                } else {
                    sessions = engine.sessions
                }
                link = .demo
                approvalsAvailable = true
                statusLine = "Demo on this iPhone. Nothing is sent."
                banner = nil
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
        case "hosts", "keys", "unpaired":
            tab = .computer
            mode = .ssh
            link = .needsPairing
            host = .placeholder
            computers = [.placeholder]
            statusLine = "Not paired"
            connectionTest = .idle
            showPairing = false
        case "connected":
            tab = .computer
            mode = .ssh
            link = .connected
            let paired = SavedHost(
                id: "computer",
                label: "example-host",
                address: OverlayPolicy.exampleAddress,
                port: OverlayPolicy.examplePort,
                username: OverlayPolicy.exampleUser,
                paired: true
            )
            computers = [paired]
            host = paired
            approvalsAvailable = true
            statusLine = "Connected"
            banner = nil
            connectionTest = .connected
            showPairing = false
            pairingMoment = .ready
        case "ask":
            tab = .computer
            mode = .ssh
            link = .needsPairing
            host = .placeholder
            computers = [.placeholder]
            statusLine = "Not paired"
            showPairing = false
            offer = try? PairingPayload(
                label: OverlayPolicy.exampleLabel,
                address: OverlayPolicy.exampleAddress,
                user: OverlayPolicy.exampleUser,
                port: OverlayPolicy.examplePort,
                fingerprint: "SHA256:" + String(repeating: "A", count: 43)
            )
            pairingMoment = .ask
        case "pair":
            tab = .computer
            let primary = SavedHost(
                id: "computer",
                label: "example-host",
                address: OverlayPolicy.exampleAddress,
                port: OverlayPolicy.examplePort,
                username: OverlayPolicy.exampleUser,
                pinnedFingerprint: "SHA256:" + String(repeating: "A", count: 43)
            )
            let secondary = SavedHost(
                id: "computer-2",
                label: "example-host-2",
                address: "100.64.0.1",
                port: OverlayPolicy.examplePort,
                username: OverlayPolicy.exampleUser
            )
            computers = [primary, secondary]
            host = primary
            showPairing = true
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

    func push(_ snapshot: PhoneSnapshot, direct: String?) {
        guard WCSession.isSupported(), let payload = LinkCodec.encodeSnapshot(snapshot) else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        var body = ["snapshot": payload]
        if let direct, !direct.isEmpty {
            body["direct"] = direct
        }
        try? session.updateApplicationContext(body)
        session.transferUserInfo(body)
        if session.isReachable {
            session.sendMessage(body, replyHandler: nil) { _ in }
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in self.onActivated?() }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.onActivated?() }
    }

    func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.onActivated?() }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        deliver(message)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        deliver(message)
        replyHandler([:])
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        deliver(userInfo)
    }

    private func deliver(_ message: [String: Any]) {
        if let voice = message["voice"] as? String {
            WatchSpeechRelay.shared.accept(voice)
            return
        }
        guard let payload = message["command"] as? String, let command = LinkCodec.decodeCommand(payload) else { return }
        Task { @MainActor in self.onCommand?(command) }
    }
}
