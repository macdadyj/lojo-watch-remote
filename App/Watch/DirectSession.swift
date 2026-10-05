import Foundation
import Security
import WatchRemoteCore

/// The Watch's own copy of the direct pairing. It is not the iPhone Keychain.
enum DirectKeychain {
    static let service = "com.lojo.WatchRemote.direct"
    private static let account = "pairing"
    private static let countersAccount = "counters"

    static func save(_ pairing: DirectPairing) {
        guard let text = pairing.jsonText(), let data = text.data(using: .utf8) else { return }
        write(data, account: account)
    }

    static func load() -> DirectPairing? {
        guard let data = read(account: account), let text = String(data: data, encoding: .utf8) else { return nil }
        guard let pairing = DirectPairing.decode(text), !pairing.clear else { return nil }
        guard RelayMaterial.normalizeURL(pairing.relayURL) != nil, RelayMaterial.keyData(pairing.key) != nil else { return nil }
        return pairing
    }

    static func delete() {
        SecItemDelete(base(account: account) as CFDictionary)
        SecItemDelete(base(account: countersAccount) as CFDictionary)
    }

    static func saveCounters(send: UInt64, recv: UInt64) {
        let text = #"{"recv":\#(recv),"send":\#(send)}"#
        write(Data(text.utf8), account: countersAccount)
    }

    static func counters() -> (send: UInt64, recv: UInt64) {
        guard let data = read(account: countersAccount),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (0, 0) }
        let send = (object["send"] as? NSNumber)?.uint64Value ?? 0
        let recv = (object["recv"] as? NSNumber)?.uint64Value ?? 0
        return (send, recv)
    }

    private static func write(_ data: Data, account: String) {
        let query = base(account: account)
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
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

    private(set) var pairing: DirectPairing?
    private var task: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var key = Data()
    private var sendCounter: UInt64 = 0
    private var replay = RelayReplay()
    private var next = 0
    private var authed = false
    private var generation = 0

    var hasPairing: Bool { pairing != nil }
    var label: String { pairing?.label ?? "" }

    func restore() {
        pairing = DirectKeychain.load()
        let saved = DirectKeychain.counters()
        sendCounter = saved.send
        replay = RelayReplay.restored(highest: saved.recv)
    }

    func ingest(_ text: String) {
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
        if changed {
            sendCounter = 0
            replay = RelayReplay()
            DirectKeychain.saveCounters(send: 0, recv: 0)
            disconnect()
        }
    }

    func connectIfNeeded() {
        guard pairing != nil else { return }
        if phase == .up || phase == .connecting { return }
        connect()
    }

    func disconnect() {
        generation += 1
        authed = false
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        if phase != .idle {
            phase = .idle
        }
    }

    func wake() {
        guard hasPairing else { return }
        if phase != .up {
            disconnect()
            connect()
        } else {
            send(DirectMessage(op: .list, id: freshID()))
        }
    }

    func refresh() {
        guard phase == .up else {
            connectIfNeeded()
            return
        }
        send(DirectMessage(op: .list, id: freshID()))
    }

    func start(_ prompt: String, cwd: String?) {
        send(DirectMessage(op: .start, id: freshID(), prompt: prompt, cwd: cwd))
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
        guard let pairing, let url = URL(string: pairing.relayURL), let key = RelayMaterial.keyData(pairing.key) else { return }
        disconnect()
        self.pairing = pairing
        self.key = key
        phase = .connecting
        authed = false
        let session = URLSession(configuration: .ephemeral)
        let socket = session.webSocketTask(with: url)
        urlSession = session
        task = socket
        socket.resume()
        onChange?()
        let auth = AuthMessage(role: "watch", token: pairing.token)
        guard let data = try? JSONEncoder().encode(auth), let text = String(data: data, encoding: .utf8) else {
            fail("The direct pairing on this Watch could not be used.")
            return
        }
        let current = generation
        socket.send(.string(text)) { [weak self] error in
            Task { @MainActor in
                guard let self, self.generation == current else { return }
                if error != nil {
                    self.fail("The relay did not accept this pairing.")
                }
            }
        }
        receive(current)
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
            fail("The direct connection stopped. Open Watch Remote to try again.")
        case .success(let message):
            switch message {
            case .string(let text):
                if text.contains("\"ok\":true") {
                    authed = true
                    phase = .up
                    onBanner?(nil)
                    send(DirectMessage(op: .list, id: freshID()))
                }
                receive(current)
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
            send(DirectMessage(op: .list, id: freshID()))
        case .ok, .pong:
            onChange?()
        case .error:
            onBanner?(message.message ?? "The computer could not do that.")
        case .list, .start, .approve, .deny, .stop, .ping:
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
                        self.fail("The direct connection stopped. Open Watch Remote to try again.")
                    }
                }
            }
        } catch {
            onBanner?("The direct connection could not be sealed.")
        }
    }

    private func fail(_ text: String) {
        authed = false
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        phase = .failed(text)
        onBanner?(text)
        onChange?()
    }

    private func freshID() -> String {
        next += 1
        return String(next)
    }
}

private struct AuthMessage: Codable {
    var role: String
    var token: String
}
