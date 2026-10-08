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
    var onChange: (() -> Void)?
    var onBanner: ((String?) -> Void)?
    var onRestored: ((String, [String]) -> Void)?
    var onTranscript: ((String, String) -> Void)?
    var onUp: (() -> Void)?
    var onStarted: ((String) -> Void)?
    /// The auth reply was explicitly not ok. The Keychain pairing is kept until a new one arrives.
    var onRepair: (() -> Void)?

    private(set) var pairing: DirectPairing?
    private var task: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var key = Data()
    private var sendCounter: UInt64 = 0
    private var replay = RelayReplay()
    private var next = 0
    private var authed = false
    private var generation = 0
    private var retryAttempt = 0
    private var heartbeatTask: Task<Void, Never>?
    private var retryItem: DispatchWorkItem?
    private var displayOff = false
    private var giveUp = false
    private var resumeWhenActive = false
    private var socketDelegate: SocketDelegate?
    private var openTimeout: Task<Void, Never>?
    @Published private(set) var lastError = ""

    var hasPairing: Bool { pairing != nil }
    var label: String { pairing?.label ?? "" }

    var phaseLabel: String {
        switch phase {
        case .idle:
            return "idle"
        case .connecting:
            return "connecting"
        case .up:
            return "up"
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
        resumeWhenActive = false
        if changed || resetCounters {
            sendCounter = 0
            replay = RelayReplay()
            DirectKeychain.saveCounters(send: 0, recv: 0)
        }
        if changed {
            disconnect()
        }
    }

    func noteDisplay(_ active: Bool) {
        displayOff = !active
    }

    func connectIfNeeded() {
        guard pairing != nil, !giveUp else { return }
        if displayOff {
            resumeWhenActive = true
            return
        }
        if phase == .up || phase == .connecting { return }
        connect()
    }

    func disconnect() {
        retryItem?.cancel()
        retryItem = nil
        resumeWhenActive = false
        tearSocket()
        if phase != .idle {
            phase = .idle
        }
    }

    func wake() {
        displayOff = false
        guard hasPairing, !giveUp else { return }
        if phase == .up && authed && task != nil {
            send(DirectMessage(op: .list, id: freshID()))
            return
        }
        if phase == .connecting && task != nil {
            return
        }
        resumeWhenActive = false
        retryAttempt = 0
        connect()
    }

    func refresh() {
        guard phase == .up else {
            connectIfNeeded()
            return
        }
        send(DirectMessage(op: .list, id: freshID()))
    }

    func start(_ prompt: String, cwd: String?, sessionID: String? = nil) {
        send(DirectMessage(op: .start, id: freshID(), prompt: prompt, cwd: cwd, sessionID: sessionID))
    }

    func resume(_ sessionID: String) {
        send(DirectMessage(op: .resume, id: freshID(), sessionID: sessionID))
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

    private func connect() {
        if displayOff {
            resumeWhenActive = true
            return
        }
        guard let pairing, let url = URL(string: pairing.relayURL), let key = RelayMaterial.keyData(pairing.key) else { return }
        retryItem?.cancel()
        retryItem = nil
        tearSocket()
        self.pairing = pairing
        self.key = key
        phase = .connecting
        authed = false
        let current = generation
        let delegate = SocketDelegate(owner: self, generation: current)
        socketDelegate = delegate
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        let socket = session.webSocketTask(with: url)
        urlSession = session
        task = socket
        socket.resume()
        onChange?()
        armOpenTimeout(current)
    }

    private func receive(_ current: Int) {
        task?.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.generation == current else { return }
                self.handle(result, current)
            }
        }
    }

    private func handle(_ result: Result<URLSessionWebSocketTask.Message, Error>, _ current: Int) {
        guard generation == current else { return }
        switch result {
        case .failure:
            noteFault(.disconnected)
        case .success(let message):
            switch message {
            case .string(let text):
                guard !authed else {
                    receive(current)
                    return
                }
                switch RelayUserNotice.classify(.authPayload(text)) {
                case .accepted:
                    authed = true
                    retryAttempt = 0
                    resumeWhenActive = false
                    phase = .up
                    lastError = ""
                    onBanner?(nil)
                    armHeartbeat()
                    onUp?()
                    send(DirectMessage(op: .list, id: freshID()))
                    receive(current)
                case .pairingRejected:
                    rejectPairing()
                case .reconnecting:
                    noteFault(.disconnected)
                case .ignored:
                    receive(current)
                }
            case .data(let data):
                open(data)
                receive(current)
            @unknown default:
                receive(current)
            }
        }
    }

    private func open(_ data: Data) {
        do {
            let plain = try RelayBox.open(frame: data, key: key, expecting: .hostToWatch, replay: &replay)
            DirectKeychain.saveCounters(send: sendCounter, recv: replay.highest)
            guard let message = DirectMessage.decode(plain) else { return }
            apply(message)
        } catch RelayBoxError.replayed {
            onBanner?("A repeated message was ignored.")
        } catch {
            onBanner?("A message from the computer could not be read.")
        }
    }

    private func apply(_ message: DirectMessage) {
        switch message.op {
        case .sessions, .update:
            if let sessions = message.sessions {
                self.sessions = sessions
            }
            approvalsAvailable = message.approvalsAvailable ?? true
            onBanner?(nil)
            onChange?()
        case .started:
            onBanner?(nil)
            onStarted?(message.sessionID ?? "")
            send(DirectMessage(op: .list, id: freshID()))
        case .ok, .pong:
            onChange?()
        case .restored:
            onRestored?(message.sessionID ?? "", message.lines ?? [])
            onBanner?(nil)
            onChange?()
        case .transcript:
            onTranscript?(message.id, message.message ?? "")
            onBanner?(nil)
            onChange?()
        case .error:
            onBanner?(message.message ?? "The computer could not do that.")
        case .list, .start, .approve, .deny, .stop, .ping, .resume, .transcribe:
            break
        }
    }

    private func send(_ message: DirectMessage) {
        guard authed, let task, let plain = DirectMessage.encode(message) else { return }
        sendCounter += 1
        let current = generation
        do {
            let frame = try RelayBox.seal(plaintext: plain, key: key, direction: .watchToHost, counter: sendCounter)
            DirectKeychain.saveCounters(send: sendCounter, recv: replay.highest)
            task.send(.data(frame)) { [weak self] error in
                Task { @MainActor in
                    guard let self, self.generation == current else { return }
                    if error != nil {
                        self.noteFault(.dataSendFailed)
                    }
                }
            }
        } catch {
            onBanner?("The direct connection could not be sealed.")
        }
    }

    private func noteFault(_ fault: RelaySocketFault) {
        lastError = Self.faultText(fault)
        switch RelayUserNotice.classify(fault) {
        case .pairingRejected:
            rejectPairing()
        case .accepted, .ignored:
            break
        case .reconnecting:
            if displayOff {
                quietDrop()
            } else {
                scheduleReconnect()
            }
        }
    }

    /// The socket died because the watch left the foreground. Keep the pairing and the banner quiet.
    private func quietDrop() {
        tearSocket()
        resumeWhenActive = true
        phase = .idle
        onBanner?(nil)
        onChange?()
    }

    private func scheduleReconnect() {
        guard pairing != nil, !giveUp else { return }
        retryItem?.cancel()
        retryItem = nil
        tearSocket()
        phase = .connecting
        onBanner?(RelayUserNotice.banner(for: .disconnected, displayOff: false))
        onChange?()
        let attempt = retryAttempt
        retryAttempt = min(attempt + 1, 5)
        let delay = min(8.0, 0.4 * pow(2.0, Double(attempt)))
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.connect()
            }
        }
        retryItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func rejectPairing() {
        giveUp = true
        retryItem?.cancel()
        retryItem = nil
        resumeWhenActive = false
        tearSocket()
        phase = .failed(RelayUserNotice.pairingRejectedText)
        onBanner?(RelayUserNotice.pairingRejectedText)
        onRepair?()
        onChange?()
    }

    private func tearSocket() {
        generation += 1
        authed = false
        openTimeout?.cancel()
        openTimeout = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        socketDelegate = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
    }

    /// Auth goes out only after the socket is open. Sending earlier fails on watchOS and sticks on Reconnecting.
    fileprivate func didOpenSocket(generation expected: Int) {
        guard generation == expected, phase == .connecting, !authed, task != nil else { return }
        openTimeout?.cancel()
        openTimeout = nil
        sendAuth(expected)
        receive(expected)
    }

    fileprivate func didCloseSocket(generation expected: Int, code: Int) {
        guard generation == expected else { return }
        guard phase == .connecting || phase == .up else { return }
        noteFault(.disconnected)
        lastError = "Socket closed \(code)."
    }

    fileprivate func didFinishSocket(generation expected: Int) {
        guard generation == expected else { return }
        guard phase == .connecting || phase == .up else { return }
        noteFault(.disconnected)
    }

    private func sendAuth(_ current: Int) {
        guard let pairing, let task else { return }
        let auth = AuthMessage(role: "watch", token: pairing.token)
        guard let data = try? JSONEncoder().encode(auth), let text = String(data: data, encoding: .utf8) else {
            fail("The direct pairing on this Watch could not be used.")
            return
        }
        task.send(.string(text)) { [weak self] error in
            Task { @MainActor in
                guard let self, self.generation == current else { return }
                if error != nil {
                    self.noteFault(.authSendFailed)
                }
            }
        }
    }

    private func armOpenTimeout(_ current: Int) {
        openTimeout?.cancel()
        openTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.generation == current, !self.authed else { return }
                self.noteFault(.disconnected)
                self.lastError = "The relay did not open."
            }
        }
    }

    private static func faultText(_ fault: RelaySocketFault) -> String {
        switch fault {
        case .authSendFailed:
            return "The pairing hello was not sent."
        case .dataSendFailed:
            return "A message was not sent."
        case .disconnected:
            return "The relay connection dropped."
        case .suspended:
            return "The relay connection paused."
        case .authPayload:
            return "The relay rejected the pairing."
        }
    }

    private func armHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                let pause = UInt64(SessionKeepalive.heartbeatInterval * 1_000_000_000)
                try? await Task.sleep(nanoseconds: pause)
                self?.pingIfLive()
            }
        }
    }

    private func pingIfLive() {
        guard phase == .up, authed, !displayOff else { return }
        guard SessionKeepalive.remainsLive(elapsed: SessionKeepalive.heartbeatInterval, userEnded: false) else { return }
        send(DirectMessage(op: .ping, id: freshID()))
    }

    private func fail(_ text: String) {
        retryItem?.cancel()
        retryItem = nil
        tearSocket()
        phase = .failed(text)
        onBanner?(text)
        onChange?()
    }

    private func freshID() -> String {
        next += 1
        return String(next)
    }
}

private final class SocketDelegate: NSObject, URLSessionWebSocketDelegate {
    weak var owner: DirectSession?
    let generation: Int

    init(owner: DirectSession, generation: Int) {
        self.owner = owner
        self.generation = generation
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol `protocol`: String?
    ) {
        let owner = owner
        let generation = generation
        Task { @MainActor in
            owner?.didOpenSocket(generation: generation)
        }
        _ = session
        _ = webSocketTask
        _ = `protocol`
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let owner = owner
        let generation = generation
        let code = closeCode.rawValue
        Task { @MainActor in
            owner?.didCloseSocket(generation: generation, code: code)
        }
        _ = session
        _ = webSocketTask
        _ = reason
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let owner = owner
        let generation = generation
        Task { @MainActor in
            guard error != nil else { return }
            owner?.didFinishSocket(generation: generation)
        }
        _ = session
        _ = task
    }
}

private struct AuthMessage: Codable {
    var role: String
    var token: String
}
