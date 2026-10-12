import Foundation
import Security
import WatchRemoteCore

/// The Watch's own copy of the direct pairing. It is not the iPhone Keychain.
enum DirectKeychain {
    static let service = "com.lojo.WatchRemote.direct"
    private static let account = "pairing"
    private static let countersAccount = "counters"
    private static var memory: DirectPairing?
    private static var memoryCounters: (send: UInt64, recv: UInt64)?

    static func save(_ pairing: DirectPairing) {
        guard let text = pairing.jsonText(), let data = text.data(using: .utf8) else { return }
        write(data, account: account)
    }

    static func load() -> DirectPairing? {
        if let memory { return memory }
        guard let data = read(account: account), let text = String(data: data, encoding: .utf8) else { return nil }
        guard let pairing = DirectPairing.decode(text), !pairing.clear else { return nil }
        guard RelayMaterial.normalizeURL(pairing.relayURL) != nil, RelayMaterial.keyData(pairing.key) != nil else { return nil }
        memory = pairing
        return pairing
    }

    static func delete() {
        memory = nil
        memoryCounters = nil
        SecItemDelete(base(account: account) as CFDictionary)
        SecItemDelete(base(account: countersAccount) as CFDictionary)
    }

    static func saveCounters(send: UInt64, recv: UInt64) {
        let text = #"{"recv":\#(recv),"send":\#(send)}"#
        memoryCounters = (send, recv)
        write(Data(text.utf8), account: countersAccount)
    }

    static func counters() -> (send: UInt64, recv: UInt64) {
        if let memoryCounters { return memoryCounters }
        guard let data = read(account: countersAccount),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (0, 0) }
        let send = (object["send"] as? NSNumber)?.uint64Value ?? 0
        let recv = (object["recv"] as? NSNumber)?.uint64Value ?? 0
        memoryCounters = (send, recv)
        return (send, recv)
    }

    private static func write(_ data: Data, account: String) {
        let query = base(account: account)
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
        if account == Self.account, let text = String(data: data, encoding: .utf8), let pairing = DirectPairing.decode(text) {
            memory = pairing
        }
    }

    private static func read(account: String) -> Data? {
        var query = base(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess else { return nil }
        return out as? Data
    }

    private static func base(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
    }
}

/// The Watch's link to the relay: HTTPS long-polls to `/v1/watch`.
///
/// A real Apple Watch denies WebSockets to ordinary apps (TN3135), so every frame goes in a
/// plain HTTPS request. Commands queue while the link comes up instead of being dropped.
@MainActor
final class DirectSession: ObservableObject {
    enum Phase: Equatable {
        case idle
        case connecting
        case up
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var sessions: [GrokSession] = []
    @Published private(set) var approvalsAvailable = false
    /// What the relay last said about the computer. Nil until the first poll answers.
    @Published private(set) var hostOnline: Bool?
    @Published private(set) var lastError = ""
    var onChange: (() -> Void)?
    var onBanner: ((String?) -> Void)?
    var onRestored: ((String, [String]) -> Void)?
    var onTranscript: ((String, String) -> Void)?
    var onUp: (() -> Void)?
    /// Request id, then the session the computer started or continued.
    var onStarted: ((String, String) -> Void)?
    /// Request id, then the computer's error text.
    var onFailed: ((String, String) -> Void)?
    /// The relay refused the pairing token. The Keychain pairing is kept until a new one arrives.
    var onRepair: (() -> Void)?
    /// The Watch's auto-approve default. It rides on every list and ping so the computer applies it.
    var autoApproveDefault: Bool?

    private(set) var pairing: DirectPairing?
    private var key = Data()
    private var pollURL: URL?
    private var sendCounter: UInt64 = 0
    private var replay = RelayReplay()
    private var cursor = RelayPollCursor()
    private var outbox: [Data] = []
    private var next = 0
    private var generation = 0
    private var loop: Task<Void, Never>?
    private var inflight: URLSessionDataTask?
    private var inflightWaits = false
    private var kicked = false
    private var failures = 0
    private var displayOff = false
    private var giveUp = false
    private lazy var http: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Double(RelayPoll.maxWaitMilliseconds) / 1000 + 15
        configuration.timeoutIntervalForResource = 120
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    var hasPairing: Bool { pairing != nil }
    var label: String { pairing?.label ?? "" }
    var hasPendingSends: Bool { !outbox.isEmpty }
    /// The relay failed at least once since it last answered.
    var inTrouble: Bool { phase == .connecting && failures > 0 }

    /// Whether the computer can be reached through the relay right now. Nil while unknown.
    var hostReachable: Bool? {
        switch phase {
        case .up:
            return hostOnline
        case .failed:
            return false
        case .connecting:
            return failures >= 2 ? false : nil
        case .idle:
            return nil
        }
    }

    var phaseLabel: String {
        switch phase {
        case .idle:
            return "idle"
        case .connecting:
            return "connecting"
        case .up:
            return hostOnline == false ? "up, computer offline" : "up"
        case .failed:
            return "failed"
        }
    }

    func restore() {
        pairing = DirectKeychain.load()
        let saved = DirectKeychain.counters()
        sendCounter = saved.send
        replay = RelayReplay.restored(highest: saved.recv)
    }

    func ingest(_ text: String, resetCounters: Bool = false) {
        guard let incoming = DirectPairing.decode(text) else { return }
        if incoming.clear {
            if pairing?.computerID == incoming.computerID || pairing == nil {
                DirectKeychain.delete()
                pairing = nil
                disconnect()
            }
            return
        }
        guard RelayMaterial.normalizeURL(incoming.relayURL) != nil, RelayMaterial.keyData(incoming.key) != nil else { return }
        let changed = pairing?.key != incoming.key || pairing?.token != incoming.token || pairing?.relayURL != incoming.relayURL
        pairing = incoming
        DirectKeychain.save(incoming)
        giveUp = false
        if changed || resetCounters {
            replay = RelayReplay()
            cursor = RelayPollCursor()
            DirectKeychain.saveCounters(send: sendCounter, recv: 0)
        }
        if changed {
            outbox.removeAll()
            hostOnline = nil
            disconnect()
        }
    }

    func noteDisplay(_ active: Bool) {
        displayOff = !active
        if active {
            connectIfNeeded()
        }
    }

    func connectIfNeeded() {
        guard pairing != nil, !giveUp, !displayOff else { return }
        guard loop == nil else { return }
        startLoop()
    }

    func disconnect() {
        stopLoop()
        if phase != .idle {
            phase = .idle
            onChange?()
        }
    }

    func wake() {
        displayOff = false
        guard hasPairing, !giveUp else { return }
        failures = 0
        if loop == nil {
            startLoop()
        } else {
            send(listMessage())
        }
    }

    func refresh() {
        guard hasPairing else { return }
        send(listMessage())
    }

    @discardableResult
    func start(_ prompt: String, cwd: String?, sessionID: String? = nil, autoApprove: Bool? = nil) -> String {
        var message = DirectMessage(op: .start, id: freshID(), prompt: prompt, cwd: cwd, sessionID: sessionID)
        message.autoApprove = autoApprove
        send(message)
        return message.id
    }

    func resume(_ sessionID: String, autoApprove: Bool? = nil) {
        var message = DirectMessage(op: .resume, id: freshID(), sessionID: sessionID)
        message.autoApprove = autoApprove
        send(message)
    }

    /// Tells the computer this chat's auto-approve choice, or the default when `sessionID` is nil.
    func sendAutoApprove(_ enabled: Bool, sessionID: String?) {
        guard hasPairing else { return }
        var message = DirectMessage(op: .ping, id: freshID(), sessionID: sessionID)
        message.autoApprove = enabled
        send(message)
    }

    func transcribe(pcm: Data, utteranceID: String) {
        guard !pcm.isEmpty else { return }
        send(DirectMessage(op: .transcribe, id: utteranceID, audio: pcm.base64EncodedString()))
    }

    func approve(_ session: GrokSession) {
        send(DirectMessage(op: .approve, id: freshID(), sessionID: session.id, permissionID: session.permission?.id))
    }

    func deny(_ session: GrokSession) {
        send(DirectMessage(op: .deny, id: freshID(), sessionID: session.id, permissionID: session.permission?.id))
    }

    func stop(_ session: GrokSession) {
        send(DirectMessage(op: .stop, id: freshID(), sessionID: session.id))
    }

    private func listMessage() -> DirectMessage {
        var message = DirectMessage(op: .list, id: freshID())
        message.autoApprove = autoApproveDefault
        return message
    }

    // MARK: - Poll loop

    private func startLoop() {
        guard let pairing, let key = RelayMaterial.keyData(pairing.key), let url = RelayPoll.pollURL(fromRelayURL: pairing.relayURL) else {
            fail("The direct pairing on this Watch could not be used.")
            return
        }
        stopLoop()
        self.key = key
        pollURL = url
        generation += 1
        let current = generation
        if phase != .up {
            phase = .connecting
            onChange?()
        }
        if outbox.isEmpty {
            enqueue(listMessage())
        }
        loop = Task { [weak self] in
            await self?.run(current)
        }
    }

    private func stopLoop() {
        generation += 1
        loop?.cancel()
        loop = nil
        inflight?.cancel()
        inflight = nil
    }

    /// A send while a long poll is parked cancels that poll so the frame leaves now.
    private func kick() {
        guard inflightWaits, let inflight else { return }
        kicked = true
        inflight.cancel()
    }

    private func run(_ current: Int) async {
        while generation == current, !Task.isCancelled {
            if displayOff {
                quietPause()
                return
            }
            let batch = Array(outbox.prefix(RelayPoll.maxFramesPerRequest))
            let wait = batch.isEmpty && phase == .up ? RelayPoll.maxWaitMilliseconds : 0
            let result = await post(batch, wait: wait)
            guard generation == current else { return }
            switch result {
            case .answered(let response):
                outbox.removeFirst(min(batch.count, outbox.count))
                noteAnswered(response)
            case .kicked:
                continue
            case .refused(let outcome):
                failures += 1
                switch outcome {
                case .pairingRejected:
                    rejectPairing()
                    return
                case .relayOutdated:
                    lastError = "The relay has no Watch endpoint."
                    phase = .failed(RelayPoll.relayOutdatedText)
                    onBanner?(RelayPoll.relayOutdatedText)
                    onChange?()
                case .ok, .slowDown, .retry:
                    lastError = outcome == .slowDown ? "The relay asked the Watch to slow down." : "The relay answered with an error."
                    noteTrouble()
                }
                await pause(RelayPoll.backoff(failures: failures, outcome: outcome), current)
            case .unreachable(let text):
                failures += 1
                lastError = text
                noteTrouble()
                await pause(RelayPoll.backoff(failures: failures, outcome: .retry), current)
            }
        }
    }

    private enum PostResult {
        case answered(RelayPoll.Response)
        case refused(RelayPoll.Outcome)
        case unreachable(String)
        case kicked
    }

    private func post(_ batch: [Data], wait: Int) async -> PostResult {
        guard let pollURL, let pairing else { return .unreachable("No relay address.") }
        let body = RelayPoll.Request(
            send: batch.map { $0.base64EncodedString() },
            after: cursor.after,
            epoch: cursor.epoch,
            wait: wait
        )
        guard let data = RelayPoll.encode(body) else { return .unreachable("A request could not be built.") }
        var request = URLRequest(url: pollURL)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(pairing.token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = Double(wait) / 1000 + 15
        kicked = false
        inflightWaits = wait > 0
        let (payload, response, error): (Data?, URLResponse?, Error?) = await withCheckedContinuation { continuation in
            let task = http.dataTask(with: request) { payload, response, error in
                continuation.resume(returning: (payload, response, error))
            }
            inflight = task
            task.resume()
        }
        inflight = nil
        inflightWaits = false
        if kicked {
            kicked = false
            return .kicked
        }
        if let error {
            return .unreachable(Self.describe(error))
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let outcome = RelayPoll.outcome(status: status)
        guard outcome == .ok else { return .refused(outcome) }
        guard let payload, let decoded = RelayPoll.decode(payload), decoded.ok else {
            return .refused(.retry)
        }
        return .answered(decoded)
    }

    private func noteAnswered(_ response: RelayPoll.Response) {
        failures = 0
        let wasUp = phase == .up
        let host = response.host
        if !wasUp || hostOnline != host {
            phase = .up
            hostOnline = host
            lastError = host == false ? "The computer is not connected to the relay." : ""
            onBanner?(nil)
            onChange?()
        }
        if !wasUp {
            onUp?()
        }
        for frame in cursor.take(response) {
            guard let data = Data(base64Encoded: frame.data) else { continue }
            open(data)
        }
    }

    private func noteTrouble() {
        guard !displayOff else { return }
        if phase != .connecting || failures == 1 {
            phase = .connecting
            onBanner?(RelayUserNotice.reconnectingText)
            onChange?()
        } else if failures == 2 {
            onChange?()
        }
    }

    private func pause(_ seconds: Double, _ current: Int) async {
        guard seconds > 0 else { return }
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, generation == current, !Task.isCancelled, !kickedWhilePaused {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        kickedWhilePaused = false
    }

    private var kickedWhilePaused = false

    /// The Watch went to the wrist-down state. Keep the pairing and the banner quiet.
    private func quietPause() {
        loop = nil
        inflight?.cancel()
        inflight = nil
        if phase == .connecting {
            phase = .idle
        }
        onBanner?(nil)
        onChange?()
    }

    private func open(_ data: Data) {
        do {
            let plain = try RelayBox.open(frame: data, key: key, expecting: .hostToWatch, replay: &replay)
            DirectKeychain.saveCounters(send: sendCounter, recv: replay.highest)
            guard let message = DirectMessage.decode(plain) else { return }
            apply(message)
        } catch RelayBoxError.replayed {
            return
        } catch {
            lastError = "A frame from the computer could not be opened."
        }
    }

    private func apply(_ message: DirectMessage) {
        switch message.op {
        case .sessions, .update:
            if let sessions = message.sessions {
                self.sessions = sessions
            }
            approvalsAvailable = message.approvalsAvailable ?? true
            onChange?()
        case .started:
            onStarted?(message.id, message.sessionID ?? "")
        case .ok, .pong:
            onChange?()
        case .restored:
            onRestored?(message.sessionID ?? "", message.lines ?? [])
            onChange?()
        case .transcript:
            onTranscript?(message.id, message.message ?? "")
            onChange?()
        case .error:
            let text = message.message ?? "The computer could not do that."
            onFailed?(message.id, text)
            onBanner?(text)
        case .list, .start, .approve, .deny, .stop, .ping, .resume, .transcribe:
            break
        }
    }

    @discardableResult
    private func enqueue(_ message: DirectMessage) -> Bool {
        guard let pairing, let plain = DirectMessage.encode(message), let key = RelayMaterial.keyData(pairing.key) else { return false }
        sendCounter = RelayCounter.next(after: sendCounter)
        do {
            let frame = try RelayBox.seal(plaintext: plain, key: key, direction: .watchToHost, counter: sendCounter)
            DirectKeychain.saveCounters(send: sendCounter, recv: replay.highest)
            outbox.append(frame)
            if outbox.count > 32 {
                outbox.removeFirst(outbox.count - 32)
            }
            return true
        } catch {
            onBanner?("The direct connection could not be sealed.")
            return false
        }
    }

    private func send(_ message: DirectMessage) {
        guard enqueue(message) else { return }
        if loop == nil {
            connectIfNeeded()
        } else if inflightWaits {
            kick()
        } else {
            kickedWhilePaused = true
        }
    }

    private func rejectPairing() {
        giveUp = true
        loop = nil
        inflight?.cancel()
        inflight = nil
        outbox.removeAll()
        phase = .failed(RelayUserNotice.pairingRejectedText)
        onBanner?(RelayUserNotice.pairingRejectedText)
        onRepair?()
        onChange?()
    }

    private func fail(_ text: String) {
        stopLoop()
        phase = .failed(text)
        onBanner?(text)
        onChange?()
    }

    private func freshID() -> String {
        next += 1
        return "w\(next)"
    }

    private static func describe(_ error: Error) -> String {
        let code = (error as? URLError)?.code
        switch code {
        case .some(.notConnectedToInternet), .some(.networkConnectionLost):
            return "The Watch has no network."
        case .some(.timedOut):
            return "The relay did not answer in time."
        case .some(.cannotFindHost), .some(.cannotConnectToHost), .some(.dnsLookupFailed):
            return "The relay could not be reached."
        case .some(.secureConnectionFailed), .some(.serverCertificateUntrusted), .some(.serverCertificateHasBadDate):
            return "The relay's certificate was refused."
        case .some(.appTransportSecurityRequiresSecureConnection):
            return "App Transport Security blocked the relay address."
        default:
            return "The relay connection failed."
        }
    }
}
