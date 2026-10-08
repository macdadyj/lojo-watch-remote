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

/// Speaks ACP through an SSH direct-tcpip channel to `grok agent serve` on the computer's loopback.
final class ACPPipe: @unchecked Sendable {
    private let writer: ByteWriter
    private let lock = NSLock()
    private var framer = WebSocketFramer()
    private var codec = ACPCodec()
    private var header = Data()
    private var upgraded = false
    private var upgradeWait: CheckedContinuation<Void, Error>?
    private var waiters: [Int: CheckedContinuation<String, Error>] = [:]
    private let onEvent: @Sendable (ACPInbound) -> Void
    private let onDead: @Sendable () -> Void
    private var failed = false
    private var captureReplay = false
    private var replayBuffer: [StreamEvent] = []

    var isUsable: Bool {
        lock.lock()
        let usable = !failed
        lock.unlock()
        return usable
    }

    private init(writer: ByteWriter, onEvent: @escaping @Sendable (ACPInbound) -> Void, onDead: @escaping @Sendable () -> Void) {
        self.writer = writer
        self.onEvent = onEvent
        self.onDead = onDead
    }

    static func open(
        ssh: SSHConnection,
        secret: String,
        onEvent: @escaping @Sendable (ACPInbound) -> Void,
        onDead: @escaping @Sendable () -> Void
    ) async throws -> ACPPipe {
        let writer = ByteWriter()
        let pipe = ACPPipe(writer: writer, onEvent: onEvent, onDead: onDead)
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
            authorization: secret
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

    func loadSessionRaw(sessionID: String, cwd: String) async throws -> String {
        try await roundTrip(timeout: true) { $0.loadSession(sessionID: sessionID, cwd: cwd) }
    }

    /// `session/load` replays the conversation as `session/update` before the result.
    /// Those updates are returned here and are not applied as a new live turn.
    func loadSessionCaptured(sessionID: String, cwd: String) async throws -> (raw: String, replay: [StreamEvent]) {
        lock.lock()
        captureReplay = true
        replayBuffer = []
        lock.unlock()
        do {
            let raw = try await loadSessionRaw(sessionID: sessionID, cwd: cwd)
            lock.lock()
            let replay = replayBuffer
            replayBuffer = []
            captureReplay = false
            lock.unlock()
            return (raw, replay)
        } catch {
            lock.lock()
            replayBuffer = []
            captureReplay = false
            lock.unlock()
            throw error
        }
    }

    func loadSession(sessionID: String, cwd: String) async throws {
        _ = try await loadSessionCaptured(sessionID: sessionID, cwd: cwd)
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
        let text = codecCopyCancel(sessionID)
        writer.writeAndForget(masked(text))
    }

    func respond(_ request: PermissionRequest, allow: Bool) async -> Bool {
        guard isUsable else { return false }
        let text = codecCopyPermission(request, allow: allow)
        let wrote = await writer.write(masked(text))
        guard wrote else {
            fail(SSHClientError.disconnected("The approval was not written."))
            return false
        }
        return true
    }

    private func codecCopyCancel(_ sessionID: String) -> String {
        lock.lock()
        let text = codec.cancel(sessionID: sessionID)
        lock.unlock()
        return text
    }

    private func codecCopyPermission(_ request: PermissionRequest, allow: Bool) -> String {
        lock.lock()
        let text = codec.permissionResponse(for: request, allow: allow)
        lock.unlock()
        return text
    }

    private func roundTrip(timeout: Bool, _ make: (inout ACPCodec) -> (Int, String)) async throws -> String {
        let id: Int
        let json: String
        lock.lock()
        (id, json) = make(&codec)
        lock.unlock()
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
                guard let text = String(data: frame.payload, encoding: .utf8), let inbound = codecParse(text) else { continue }
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

    private func codecParse(_ text: String) -> ACPInbound? {
        lock.lock()
        let inbound = codec.parse(text)
        lock.unlock()
        return inbound
    }

    private func route(_ inbound: ACPInbound, raw: String) {
        switch inbound {
        case .result(let id, _, _):
            resume(id: id, result: .success(raw))
        case .failure(let id, _, let message):
            resume(id: id, result: .failure(SSHClientError.disconnected(message)))
        case .update(_, let event):
            lock.lock()
            let capture = captureReplay
            if capture { replayBuffer.append(event) }
            lock.unlock()
            if !capture { onEvent(inbound) }
        case .permission, .notification:
            onEvent(inbound)
        }
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

@MainActor
final class LiveLink {
    var approvalsAvailable = false
    var statusLine = "Not connected"
    private var ssh: SSHConnection?
    private var pipe: ACPPipe?
    private var acpReady = false
    private var closing = false
    private let onEvent: (ACPInbound) -> Void
    private let onCLI: (String, StreamEvent) -> Void
    private let onDropped: () -> Void
    private let onAgentLost: () -> Void

    var isSessionActive: Bool { ssh?.isActive == true }

    /// True only while the agent WebSocket is still able to carry an approval.
    var agentIsReady: Bool { acpReady && pipe?.isUsable == true }

    func matches(host: SavedHost) -> Bool {
        guard let target = ssh?.target else { return false }
        return target.address == host.address && target.port == host.port && target.username == host.username
    }

    init(
        onEvent: @escaping (ACPInbound) -> Void,
        onCLI: @escaping (String, StreamEvent) -> Void,
        onDropped: @escaping () -> Void = {},
        onAgentLost: @escaping () -> Void = {}
    ) {
        self.onEvent = onEvent
        self.onCLI = onCLI
        self.onDropped = onDropped
        self.onAgentLost = onAgentLost
    }

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
        let connection = try await SSHConnection.connect(to: target, privateKey: privateKey, verifyHostKey: verify)
        ssh = connection
        connection.observeClose { [weak self] in
            Task { @MainActor in self?.dropFromSocket() }
        }
        statusLine = "SSH to \(host.label)"
        try await openAgent(secret: agentSecret)
    }

    func openAgent(secret: String?) async throws {
        guard let connection = ssh, connection.isActive else {
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
            let opened = try await ACPPipe.open(ssh: connection, secret: secret, onEvent: { [onEvent] event in
                Task { @MainActor in onEvent(event) }
            }, onDead: { [weak self] in
                Task { @MainActor in self?.noteAgentClosed() }
            })
            let approvals = try await opened.initialize()
            pipe = opened
            acpReady = true
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

    func loadSessionRaw(sessionID: String, cwd: String?) async throws -> String {
        let loaded = try await loadSessionCaptured(sessionID: sessionID, cwd: cwd)
        return loaded.raw
    }

    func loadSessionCaptured(sessionID: String, cwd: String?) async throws -> (raw: String, replay: [StreamEvent]) {
        let pipe = try requirePipe()
        let directory = agentCwd(cwd)
        do {
            return try await pipe.loadSessionCaptured(sessionID: sessionID, cwd: directory)
        } catch {
            if pipe.isUsable == false { noteAgentClosed() }
            throw error
        }
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

    func start(localID: String, prompt: String, cwd: String?) async throws -> String {
        let pipe = try requirePipe()
        let directory = agentCwd(cwd)
        let sessionID: String
        do {
            sessionID = try await pipe.newSession(cwd: directory)
        } catch {
            if pipe.isUsable == false { noteAgentClosed() }
            throw error
        }
        Task { @MainActor in
            do {
                let raw = try await pipe.prompt(sessionID: sessionID, text: prompt)
                self.onCLI(sessionID, .end(sessionID: sessionID, stopReason: GrokOutput.stopReason(in: raw), usage: GrokOutput.parseUsage(raw)))
            } catch {
                if !pipe.isUsable { self.noteAgentClosed() }
                self.onCLI(sessionID, .error(error.localizedDescription))
            }
        }
        return sessionID
    }

    /// Loads the session, returns the replayed history, then sends the prompt on that session.
    func resumePrompt(sessionID: String, prompt: String, cwd: String?) async throws -> [StreamEvent] {
        let pipe = try requirePipe()
        let directory = agentCwd(cwd)
        let replay: [StreamEvent]
        do {
            let loaded = try await pipe.loadSessionCaptured(sessionID: sessionID, cwd: directory)
            replay = loaded.replay
        } catch {
            if pipe.isUsable == false { noteAgentClosed() }
            throw error
        }
        Task { @MainActor in
            do {
                let raw = try await pipe.prompt(sessionID: sessionID, text: prompt)
                self.onCLI(sessionID, .end(sessionID: sessionID, stopReason: GrokOutput.stopReason(in: raw), usage: GrokOutput.parseUsage(raw)))
            } catch {
                if !pipe.isUsable { self.noteAgentClosed() }
                self.onCLI(sessionID, .error(error.localizedDescription))
            }
        }
        return replay
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
