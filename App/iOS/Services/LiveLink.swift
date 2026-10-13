import Foundation
import NIOSSH
import Security
import WatchRemoteCore

final class ByteWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var channel: DirectChannel?

    func bind(_ channel: DirectChannel) {
        lock.lock()
        self.channel = channel
        lock.unlock()
    }

    func write(_ data: Data) async -> Bool {
        lock.lock()
        let channel = channel
        lock.unlock()
        guard let channel else { return false }
        return await channel.write(data)
    }

    func writeAndForget(_ data: Data) {
        lock.lock()
        let channel = channel
        lock.unlock()
        channel?.writeAndForget(data)
    }

    func close() {
        lock.lock()
        let channel = channel
        self.channel = nil
        lock.unlock()
        channel?.close()
    }
}

/// One app process talking to one computer through the agent door. The door keeps Grok's
/// connection for this link while the phone is away and resends what the phone missed, so the
/// link id, the count of frames seen, and the request ids all outlive a single SSH channel.
final class DoorLinkState: @unchecked Sendable {
    let linkID = UUID().uuidString.lowercased()
    let hostKey: String
    private let lock = NSLock()
    private var seenFrames = 0
    private var nextRequestID = 1

    init(hostKey: String) {
        self.hostKey = hostKey
    }

    var seen: Int {
        lock.lock()
        defer { lock.unlock() }
        return seenFrames
    }

    func noteFrame() {
        lock.lock()
        seenFrames += 1
        lock.unlock()
    }

    /// The door opened a fresh Grok connection (it restarted, or never knew this link).
    func restart() {
        lock.lock()
        seenFrames = 0
        lock.unlock()
    }

    /// Ids keep counting across channels. A parked link can still answer a request from the old channel.
    func takeID() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let id = nextRequestID
        nextRequestID += 1
        return id
    }
}

/// Speaks ACP through an SSH direct-tcpip channel to `grok agent serve` on the computer's loopback.
final class ACPPipe: @unchecked Sendable {
    private let writer: ByteWriter
    private let link: DoorLinkState
    private let lock = NSLock()
    private var framer = WebSocketFramer()
    private let codec = ACPCodec()
    private var header = Data()
    private var upgraded = false
    private var upgradeWait: CheckedContinuation<Void, Error>?
    private var waiters: [Int: CheckedContinuation<String, Error>] = [:]
    private let onEvent: @Sendable (ACPInbound) -> Void
    private let onDead: @Sendable () -> Void
    private var failed = false
    /// Updates for a chat being loaded. Until its load result arrives they are the replayed history.
    /// After it, they are held until the caller has merged that history, then handed back in order.
    private var captures: [String: [StreamEvent]] = [:]
    private var loadRequests: [Int: String] = [:]
    private var replays: [Int: [StreamEvent]] = [:]
    private(set) var doorVersion = 0
    private(set) var resumed = false

    var isUsable: Bool {
        lock.lock()
        let usable = !failed
        lock.unlock()
        return usable
    }

    private init(writer: ByteWriter, link: DoorLinkState, onEvent: @escaping @Sendable (ACPInbound) -> Void, onDead: @escaping @Sendable () -> Void) {
        self.writer = writer
        self.link = link
        self.onEvent = onEvent
        self.onDead = onDead
    }

    static func open(
        ssh: SSHConnection,
        secret: String,
        link: DoorLinkState,
        onEvent: @escaping @Sendable (ACPInbound) -> Void,
        onDead: @escaping @Sendable () -> Void
    ) async throws -> ACPPipe {
        let writer = ByteWriter()
        let pipe = ACPPipe(writer: writer, link: link, onEvent: onEvent, onDead: onDead)
        let channel = try await ssh.openDirectTCP(
            host: OverlayPolicy.agentLoopback,
            port: OverlayPolicy.agentPort,
            onData: { data in pipe.ingest(data) },
            onClose: { pipe.fail(SSHClientError.disconnected("The agent connection closed.")) }
        )
        writer.bind(channel)
        var keyBytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, keyBytes.count, &keyBytes)
        let key = Data(keyBytes).base64EncodedString()
        guard await writer.write(WebSocketFramer.upgradeRequest(
            host: "127.0.0.1:\(OverlayPolicy.agentPort)",
            path: "/ws",
            webSocketKey: key,
            authorization: secret,
            extraHeaders: DoorLink.requestHeaders(linkID: link.linkID, seen: link.seen)
        )) else {
            pipe.fail(SSHClientError.disconnected("The agent connection closed."))
            throw SSHClientError.disconnected("The agent connection closed.")
        }
        try await pipe.waitForUpgrade()
        return pipe
    }

    /// Drops the channel without telling the owner. Used when a replacement pipe is about to open.
    func retire() {
        lock.lock()
        failed = true
        lock.unlock()
        writer.close()
    }

    func initialize() async throws -> Bool {
        let raw = try await roundTrip(timeout: true) { $0.initialize() }
        return ACPCodec.approvalsAvailable(inResultJSON: raw)
    }

    /// `session/load` replays the conversation as `session/update` before the result.
    /// Those updates are returned here and are not applied as a new live turn. Only this chat is
    /// captured; other chats keep streaming. Call `releaseHeld(sessionID:)` after merging.
    func loadSessionCaptured(sessionID: String, cwd: String) async throws -> (raw: String, replay: [StreamEvent]) {
        lock.lock()
        captures[sessionID] = []
        lock.unlock()
        var requestID = 0
        do {
            let raw = try await roundTrip(timeout: true, onID: { id in
                requestID = id
                self.lock.lock()
                self.loadRequests[id] = sessionID
                self.lock.unlock()
            }) { $0.loadSession(sessionID: sessionID, cwd: cwd) }
            lock.lock()
            let replay = replays.removeValue(forKey: requestID) ?? []
            lock.unlock()
            return (raw, replay)
        } catch {
            // Without a load result the captured updates are history, not news. They are dropped.
            lock.lock()
            loadRequests[requestID] = nil
            replays[requestID] = nil
            captures[sessionID] = nil
            lock.unlock()
            throw error
        }
    }

    /// Live updates that arrived after the load result, in order. Capture for this chat ends here.
    func releaseHeld(sessionID: String) -> [StreamEvent] {
        lock.lock()
        defer { lock.unlock() }
        return captures.removeValue(forKey: sessionID) ?? []
    }

    func sessionUsage(sessionID: String) async throws -> String? {
        let raw = try await roundTrip(timeout: true) { $0.sessionUsage(sessionID: sessionID) }
        return GrokOutput.parseUsage(raw)
    }

    func listSessions() async throws -> [GrokSession] {
        do {
            let raw = try await roundTrip(timeout: true) { $0.listSessions() }
            return ACPCodec.sessions(inResultJSON: raw)
        } catch {
            // A door that has not been updated still answers the bare method name.
            guard isUnknownMethod(error) else { throw error }
            let raw = try await roundTrip(timeout: true) { $0.listSessionsLegacy() }
            return ACPCodec.sessions(inResultJSON: raw)
        }
    }

    private func isUnknownMethod(_ error: Error) -> Bool {
        let text = error.localizedDescription
        return text == "Method not found" || text == "That command is not supported."
    }

    func newSession(cwd: String) async throws -> String {
        let raw = try await roundTrip(timeout: true) { $0.newSession(cwd: cwd) }
        guard let sessionID = ACPCodec.sessionID(inResultJSON: raw) else {
            throw SSHClientError.disconnected("The agent did not return a session.")
        }
        return sessionID
    }

    func prompt(sessionID: String, text: String) async throws -> String {
        try await roundTrip(timeout: false) { $0.prompt(sessionID: sessionID, text: text) }
    }

    func cancel(sessionID: String) {
        writer.writeAndForget(masked(codec.cancel(sessionID: sessionID)))
    }

    func respond(_ request: PermissionRequest, allow: Bool) async -> Bool {
        guard isUsable else { return false }
        let text = codec.permissionResponse(for: request, allow: allow)
        let wrote = await writer.write(masked(text))
        guard wrote else {
            fail(SSHClientError.disconnected("The approval was not written."))
            return false
        }
        return true
    }

    private func roundTrip(
        timeout: Bool,
        onID: (Int) -> Void = { _ in },
        _ make: (inout ACPCodec) -> (Int, String)
    ) async throws -> String {
        var requestCodec = ACPCodec(nextID: link.takeID())
        let (id, json) = make(&requestCodec)
        onID(id)
        return try await withCheckedThrowingContinuation { continuation in
            self.lock.lock()
            self.waiters[id] = continuation
            self.lock.unlock()
            Task {
                let wrote = await self.writer.write(self.masked(json))
                guard wrote else {
                    self.fail(SSHClientError.disconnected("The computer is not connected."))
                    return
                }
                guard timeout else { return }
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                self.resume(id: String(id), result: .failure(SSHClientError.disconnected("The agent server did not answer.")))
            }
        }
    }

    private func masked(_ text: String) -> Data {
        var mask = [UInt8](repeating: 0, count: 4)
        _ = SecRandomCopyBytes(kSecRandomDefault, mask.count, &mask)
        return WebSocketFramer.encodeClientText(text, mask: mask)
    }

    private func waitForUpgrade() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await self.awaitUpgrade() }
            group.addTask {
                try await Task.sleep(nanoseconds: 4_000_000_000)
                throw SSHClientError.disconnected("Grok agent server is not answering on 127.0.0.1:2419.")
            }
            try await group.next()
            group.cancelAll()
            while (try? await group.next()) != nil {}
        }
    }

    private func awaitUpgrade() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            if upgraded {
                lock.unlock()
                continuation.resume()
                return
            }
            if failed {
                lock.unlock()
                continuation.resume(throwing: SSHClientError.disconnected("Agent connection closed."))
                return
            }
            upgradeWait = continuation
            lock.unlock()
        }
    }

    fileprivate func ingest(_ data: Data) {
        lock.lock()
        if !upgraded {
            header.append(data)
            guard let range = header.range(of: Data("\r\n\r\n".utf8)) else {
                lock.unlock()
                return
            }
            let head = String(decoding: header[..<range.lowerBound], as: UTF8.self)
            let rest = Data(header[range.upperBound...])
            header.removeAll()
            guard WebSocketFramer.acceptsUpgrade(head) else {
                lock.unlock()
                fail(SSHClientError.disconnected("The agent port did not accept a WebSocket."))
                return
            }
            doorVersion = DoorLink.doorVersion(in: head)
            resumed = DoorLink.resumed(in: head)
            if !resumed { link.restart() }
            upgraded = true
            let waiter = upgradeWait
            upgradeWait = nil
            let frames = framer.append(rest)
            lock.unlock()
            waiter?.resume()
            deliver(frames)
            return
        }
        let frames = framer.append(data)
        lock.unlock()
        deliver(frames)
    }

    private func deliver(_ frames: [WebSocketFrame]) {
        for frame in frames {
            switch frame.opcode {
            case .text:
                link.noteFrame()
                guard let text = String(data: frame.payload, encoding: .utf8), let inbound = codec.parse(text) else { continue }
                route(inbound, raw: text)
            case .ping:
                var mask = [UInt8](repeating: 0, count: 4)
                _ = SecRandomCopyBytes(kSecRandomDefault, mask.count, &mask)
                writer.writeAndForget(WebSocketFramer.encodeClientPong(frame.payload, mask: mask))
            case .close:
                fail(SSHClientError.disconnected("The agent closed the connection."))
            case .binary, .continuation, .pong:
                break
            }
        }
    }

    private func route(_ inbound: ACPInbound, raw: String) {
        switch inbound {
        case .result(let id, _, _):
            endReplay(id: id)
            resume(id: id, result: .success(raw))
        case .failure(let id, _, let message):
            resume(id: id, result: .failure(SSHClientError.disconnected(message)))
        case .update(let sessionID, let event):
            lock.lock()
            let captured = captures[sessionID] != nil
            if captured { captures[sessionID]?.append(event) }
            lock.unlock()
            if !captured { onEvent(inbound) }
        case .permission, .activity, .notification:
            onEvent(inbound)
        }
    }

    /// The load result is the line between replayed history and live updates.
    private func endReplay(id: String) {
        guard let number = Int(id) else { return }
        lock.lock()
        if let sessionID = loadRequests.removeValue(forKey: number) {
            replays[number] = captures[sessionID] ?? []
            captures[sessionID] = []
        }
        lock.unlock()
    }

    private func resume(id: String, result: Result<String, Error>) {
        guard let number = Int(id) else { return }
        lock.lock()
        let waiter = waiters.removeValue(forKey: number)
        lock.unlock()
        waiter?.resume(with: result)
    }

    private func fail(_ error: Error) {
        lock.lock()
        let first = !failed
        failed = true
        let upgrade = upgradeWait
        upgradeWait = nil
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        upgrade?.resume(throwing: error)
        for waiter in pending.values {
            waiter.resume(throwing: error)
        }
        if first { onDead() }
    }
}

/// How a `session/prompt` request ended, as seen from this phone.
enum PromptOutcome {
    case finished(stopReason: String?, usage: String?)
    case failed(String)
    /// The channel dropped first. The turn keeps running on the computer, and `prompt_complete`
    /// or a reload says how it ended.
    case disconnected
}

@MainActor
final class LiveLink {
    var approvalsAvailable = false
    var statusLine = "Not connected"
    private var ssh: SSHConnection?
    private var pipe: ACPPipe?
    private var doorLink: DoorLinkState?
    private var acpReady = false
    private var closing = false
    private let onEvent: (ACPInbound) -> Void
    private let onDropped: () -> Void
    private let onAgentLost: () -> Void

    var isSessionActive: Bool { ssh?.isActive == true }

    /// True only while the agent WebSocket is still able to carry an approval.
    var agentIsReady: Bool { acpReady && pipe?.isUsable == true }

    /// 0 for a door that cannot keep the chat while the phone is away.
    var doorVersion: Int { pipe?.doorVersion ?? 0 }

    /// The door kept this link while the phone was away and resent what it missed.
    var resumedLink: Bool { pipe?.resumed == true }

    /// Agent channels opened so far, so the owner can tell a new one from the one it knows.
    private(set) var channelCount = 0

    func matches(host: SavedHost) -> Bool {
        guard let target = ssh?.target else { return false }
        return target.address == host.address && target.port == host.port && target.username == host.username
    }

    init(
        onEvent: @escaping (ACPInbound) -> Void,
        onDropped: @escaping () -> Void = {},
        onAgentLost: @escaping () -> Void = {}
    ) {
        self.onEvent = onEvent
        self.onDropped = onDropped
        self.onAgentLost = onAgentLost
    }

    /// The door link survives this, so the next connection to the same computer picks up where it left.
    func disconnect() {
        closing = true
        pipe = nil
        ssh?.close()
        ssh = nil
        acpReady = false
        approvalsAvailable = false
        statusLine = "Not connected"
        closing = false
    }

    private func dropFromSocket() {
        guard !closing, ssh != nil || pipe != nil else { return }
        pipe = nil
        ssh = nil
        acpReady = false
        approvalsAvailable = false
        statusLine = "Not connected"
        onDropped()
    }

    /// The SSH session is still up, but the agent channel is not. Tasks stay on that channel.
    private func noteAgentClosed() {
        guard pipe != nil || acpReady || approvalsAvailable else { return }
        pipe?.retire()
        pipe = nil
        acpReady = false
        approvalsAvailable = false
        if ssh?.isActive == true {
            statusLine = "SSH connected. The agent server is not answering."
        } else {
            statusLine = "Not connected"
        }
        onAgentLost()
    }

    func connect(
        host: SavedHost,
        privateKey: NIOSSHPrivateKey,
        agentSecret: String?,
        verify: @escaping @Sendable (PresentedHostKey) async -> Bool
    ) async throws {
        disconnect()
        let target = SSHTarget(address: host.address, port: host.port, username: host.username)
        let hostKey = "\(host.username)@\(host.address):\(host.port)"
        if doorLink?.hostKey != hostKey {
            doorLink = DoorLinkState(hostKey: hostKey)
        }
        let connection = try await SSHConnection.connect(to: target, privateKey: privateKey, verifyHostKey: verify)
        ssh = connection
        connection.observeClose { [weak self] in
            Task { @MainActor in self?.dropFromSocket() }
        }
        statusLine = "SSH to \(host.label)"
        try await openAgent(secret: agentSecret)
    }

    func openAgent(secret: String?) async throws {
        guard let connection = ssh, connection.isActive, let doorLink else {
            throw SSHClientError.disconnected("The computer is not connected.")
        }
        guard let secret, !secret.isEmpty else {
            pipe?.retire()
            pipe = nil
            acpReady = false
            approvalsAvailable = false
            statusLine = "SSH connected. Save the agent secret to approve actions."
            return
        }
        if agentIsReady { return }
        pipe?.retire()
        pipe = nil
        acpReady = false
        do {
            let opened = try await ACPPipe.open(ssh: connection, secret: secret, link: doorLink, onEvent: { [onEvent] event in
                Task { @MainActor in onEvent(event) }
            }, onDead: { [weak self] in
                Task { @MainActor in self?.noteAgentClosed() }
            })
            let approvals = try await opened.initialize()
            pipe = opened
            acpReady = true
            channelCount += 1
            approvalsAvailable = approvals
            statusLine = approvals
                ? "SSH connected. Approvals go through the agent server."
                : "SSH connected. Tasks run on the computer and cannot ask for approval."
        } catch {
            pipe = nil
            acpReady = false
            approvalsAvailable = false
            statusLine = "SSH connected. The agent server is not answering."
        }
    }

    /// Updates for this chat that arrive after the load result are held until `releaseHeld`.
    func loadSessionCaptured(sessionID: String, cwd: String?) async throws -> (raw: String, replay: [StreamEvent]) {
        let pipe = try requirePipe()
        do {
            return try await pipe.loadSessionCaptured(sessionID: sessionID, cwd: agentCwd(cwd))
        } catch {
            if pipe.isUsable == false { noteAgentClosed() }
            throw error
        }
    }

    func releaseHeld(sessionID: String) -> [StreamEvent] {
        pipe?.releaseHeld(sessionID: sessionID) ?? []
    }

    func list(cwd: String?) async throws -> [GrokSession] {
        let pipe = try requirePipe()
        do {
            return try await pipe.listSessions()
        } catch {
            if pipe.isUsable == false { noteAgentClosed() }
            throw error
        }
    }

    func newSession(cwd: String?) async throws -> String {
        let pipe = try requirePipe()
        do {
            return try await pipe.newSession(cwd: agentCwd(cwd))
        } catch {
            if pipe.isUsable == false { noteAgentClosed() }
            throw error
        }
    }

    func prompt(sessionID: String, text: String) async -> PromptOutcome {
        guard let pipe = try? requirePipe() else { return .disconnected }
        do {
            let raw = try await pipe.prompt(sessionID: sessionID, text: text)
            return .finished(stopReason: GrokOutput.stopReason(in: raw), usage: GrokOutput.parseUsage(raw))
        } catch {
            guard pipe.isUsable else {
                noteAgentClosed()
                return .disconnected
            }
            return .failed(error.localizedDescription)
        }
    }

    func respond(_ request: PermissionRequest, allow: Bool) async -> Bool {
        guard let pipe, pipe.isUsable else {
            noteAgentClosed()
            return false
        }
        let wrote = await pipe.respond(request, allow: allow)
        if !wrote { noteAgentClosed() }
        return wrote
    }

    func stop(sessionID: String) {
        pipe?.cancel(sessionID: sessionID)
    }

    func usage(sessionID: String) async -> String? {
        guard agentIsReady, let pipe else { return nil }
        return try? await pipe.sessionUsage(sessionID: sessionID)
    }

    private func requirePipe() throws -> ACPPipe {
        guard agentIsReady, let pipe else {
            throw SSHClientError.disconnected("The agent server on this computer is not answering.")
        }
        return pipe
    }

    /// The computer resolves `~` and an empty directory. The phone does not run a shell to find them.
    private func agentCwd(_ cwd: String?) -> String {
        cwd?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
