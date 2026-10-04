import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOSSH
import NIOTransportServices
import Network
import WatchRemoteCore

struct SSHTarget: Sendable, Hashable {
    var address: String
    var port: Int
    var username: String
}

enum SSHClientError: Error, LocalizedError, CustomStringConvertible {
    case notOverlay(String)
    case hostKeyRejected
    case authenticationFailed(String)
    case connectFailed(String)
    case channelRejected(String)
    case disconnected(String)

    var errorDescription: String? { description }

    var description: String {
        switch self {
        case .notOverlay(let why): return why
        case .hostKeyRejected: return "Host key not trusted"
        case .authenticationFailed(let why): return why
        case .connectFailed(let why): return "Can’t connect: \(why)"
        case .channelRejected(let what): return "Server refused \(what)"
        case .disconnected(let why): return why
        }
    }

    static func wrap(_ error: Error) -> SSHClientError {
        if let error = error as? SSHClientError { return error }
        if let error = error as? IOError, let why = describe(errno: error.errnoCode) {
            return .connectFailed(why)
        }
        if let error = error as? NWError, case .posix(let code) = error, let why = describe(errno: code.rawValue) {
            return .connectFailed(why)
        }
        if let error = error as? ChannelError, case .connectTimeout = error {
            return .connectFailed("timed out. Is the VPN up?")
        }
        return .connectFailed(String(describing: error))
    }

    private static func describe(errno code: Int32) -> String? {
        switch code {
        case ECONNREFUSED: return "nothing is listening on that port"
        case EHOSTUNREACH, ENETUNREACH, ENETDOWN: return "no route. Turn on the LOJO VPN"
        case ETIMEDOUT: return "timed out. Is the VPN up?"
        case ECONNRESET: return "connection reset"
        default: return nil
        }
    }
}

struct PresentedHostKey: Sendable, Equatable {
    var type: String
    var base64: String
    var fingerprint: String
}

enum ExecChunk: Sendable {
    case stdout(Data)
    case stderr(Data)
}

final class ExecChannel: @unchecked Sendable {
    fileprivate let channel: Channel
    init(channel: Channel) { self.channel = channel }
    func close() { channel.close(promise: nil) }
}

final class DirectChannel: @unchecked Sendable {
    fileprivate let channel: Channel
    init(channel: Channel) { self.channel = channel }

    /// Completes only after the bytes are flushed. `false` means they were not written.
    func write(_ data: Data) async -> Bool {
        guard channel.isActive, !data.isEmpty else { return false }
        let promise = channel.eventLoop.makePromise(of: Void.self)
        writeAndFlush(data, promise: promise)
        do {
            try await promise.futureResult.get()
        } catch {
            return false
        }
        return channel.isActive
    }

    /// Queues a flush from the channel's event loop. Awaiting `write` there would deadlock.
    func writeAndForget(_ data: Data) {
        guard channel.isActive, !data.isEmpty else { return }
        let promise = channel.eventLoop.makePromise(of: Void.self)
        writeAndFlush(data, promise: promise)
    }

    private func writeAndFlush(_ data: Data, promise: EventLoopPromise<Void>) {
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buffer)), promise: promise)
    }

    func close() { channel.close(promise: nil) }
}

/// One SSH session to the paired computer. The iPhone holds it; the Watch never opens its own socket.
final class SSHConnection: @unchecked Sendable {
    let target: SSHTarget
    let hostKey: PresentedHostKey
    private let channel: Channel
    private let onClose: NIOLockedValueBox<(@Sendable () -> Void)?>

    var isActive: Bool { channel.isActive }

    private init(
        target: SSHTarget,
        hostKey: PresentedHostKey,
        channel: Channel,
        onClose: NIOLockedValueBox<(@Sendable () -> Void)?>
    ) {
        self.target = target
        self.hostKey = hostKey
        self.channel = channel
        self.onClose = onClose
    }

    func observeClose(_ handler: @escaping @Sendable () -> Void) {
        onClose.withLockedValue { $0 = handler }
    }

    static func connect(
        to target: SSHTarget,
        privateKey: NIOSSHPrivateKey,
        verifyHostKey: @escaping @Sendable (PresentedHostKey) async -> Bool
    ) async throws -> SSHConnection {
        guard let canonical = OverlayPolicy.canonical(address: target.address) else {
            throw SSHClientError.notOverlay(OverlayPolicy.refusalReason(address: target.address) ?? "Outside the overlay")
        }
        let dial = SSHTarget(address: canonical, port: target.port, username: target.username)
        let seen = NIOLockedValueBox<PresentedHostKey?>(nil)
        let authenticated = NIOLockedValueBox<EventLoopPromise<Void>?>(nil)
        let firstError = NIOLockedValueBox<SSHClientError?>(nil)
        let onClose = NIOLockedValueBox<(@Sendable () -> Void)?>(nil)

        let initializer: @Sendable (Channel) -> EventLoopFuture<Void> = { channel in
            let done = channel.eventLoop.makePromise(of: Void.self)
            authenticated.withLockedValue { $0 = done }
            return channel.eventLoop.makeCompletedFuture {
                let userAuth = KeyAuth(username: dial.username, privateKey: privateKey)
                let serverAuth = HostKeyGate(seen: seen, verify: verifyHostKey)
                let ssh = NIOSSHHandler(
                    role: .client(.init(userAuthDelegate: userAuth, serverAuthDelegate: serverAuth)),
                    allocator: channel.allocator,
                    inboundChildChannelInitializer: nil
                )
                try channel.pipeline.syncOperations.addHandlers([
                    ssh,
                    ConnectionWatcher(firstError: firstError, authenticated: done, onClose: onClose),
                ])
            }
        }

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 30
        let bootstrap = NIOTSConnectionBootstrap(group: NIOTSEventLoopGroup.singleton)
            .connectTimeout(.seconds(12))
            .channelOption(NIOTSChannelOptions.waitForActivity, value: false)
            .tcpOptions(tcp)
            .channelInitializer(initializer)
        let channel: Channel
        do {
            channel = try await bootstrap.connect(host: dial.address, port: dial.port).get()
        } catch {
            throw SSHClientError.wrap(error)
        }
        do {
            guard let done = authenticated.withLockedValue({ $0 }) else {
                throw SSHClientError.disconnected("SSH pipeline did not start")
            }
            try await done.futureResult.get()
        } catch {
            channel.close(promise: nil)
            throw firstError.withLockedValue { $0 } ?? SSHClientError.wrap(error)
        }
        guard let key = seen.withLockedValue({ $0 }) else {
            channel.close(promise: nil)
            throw SSHClientError.hostKeyRejected
        }
        return SSHConnection(target: dial, hostKey: key, channel: channel, onClose: onClose)
    }

    func close() { channel.close(promise: nil) }

    func exec(_ command: String, onChunk: @escaping @Sendable (ExecChunk) -> Void) async throws -> Int {
        let exit = try await execStream(command, onChunk: onChunk, onReady: { _ in })
        return exit
    }

    func execStream(
        _ command: String,
        onChunk: @escaping @Sendable (ExecChunk) -> Void,
        onReady: @escaping @Sendable (ExecChannel) -> Void
    ) async throws -> Int {
        let parent = channel
        let created = parent.eventLoop.makePromise(of: Channel.self)
        let ready = parent.eventLoop.makePromise(of: Void.self)
        let finished = parent.eventLoop.makePromise(of: Int.self)
        parent.eventLoop.execute {
            guard let ssh = try? parent.pipeline.syncOperations.handler(type: NIOSSHHandler.self) else {
                created.fail(SSHClientError.disconnected("connection closed"))
                return
            }
            ssh.createChannel(created, channelType: .session) { child, _ in
                child.eventLoop.makeCompletedFuture {
                    try child.pipeline.syncOperations.addHandler(ExecHandler(
                        command: command,
                        ready: ready,
                        finished: finished,
                        onChunk: onChunk
                    ))
                }
            }
        }
        created.futureResult.whenFailure { ready.fail($0) }
        let child = try await created.futureResult.get()
        try await ready.futureResult.get()
        onReady(ExecChannel(channel: child))
        return try await finished.futureResult.get()
    }

    func openDirectTCP(
        host: String,
        port: Int,
        onData: @escaping @Sendable (Data) -> Void,
        onClose: @escaping @Sendable () -> Void = {}
    ) async throws -> DirectChannel {
        let parent = channel
        let created = parent.eventLoop.makePromise(of: Channel.self)
        let ready = parent.eventLoop.makePromise(of: Void.self)
        let origin = try SocketAddress(ipAddress: OverlayPolicy.agentLoopback, port: 1)
        let kind = SSHChannelType.directTCPIP(.init(targetHost: host, targetPort: port, originatorAddress: origin))
        parent.eventLoop.execute {
            guard let ssh = try? parent.pipeline.syncOperations.handler(type: NIOSSHHandler.self) else {
                created.fail(SSHClientError.disconnected("connection closed"))
                return
            }
            ssh.createChannel(created, channelType: kind) { child, _ in
                child.eventLoop.makeCompletedFuture {
                    try child.pipeline.syncOperations.addHandler(DirectHandler(ready: ready, onData: onData, onClose: onClose))
                }
            }
        }
        created.futureResult.whenFailure { ready.fail($0) }
        let child = try await created.futureResult.get()
        try await ready.futureResult.get()
        return DirectChannel(channel: child)
    }
}

private final class KeyAuth: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private let privateKey: NIOSSHPrivateKey
    private var offeredNone = false
    private var offeredKey = false

    init(username: String, privateKey: NIOSSHPrivateKey) {
        self.username = username
        self.privateKey = privateKey
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        if !offeredNone {
            offeredNone = true
            nextChallengePromise.succeed(.init(username: username, serviceName: "ssh-connection", offer: .none))
            return
        }
        if !offeredKey, availableMethods.contains(.publicKey) {
            offeredKey = true
            let offer = NIOSSHUserAuthenticationOffer.Offer.privateKey(.init(privateKey: privateKey))
            nextChallengePromise.succeed(.init(username: username, serviceName: "ssh-connection", offer: offer))
            return
        }
        nextChallengePromise.fail(SSHClientError.authenticationFailed(
            "Login as \(username) was denied. Add this iPhone’s key to authorized_keys on the computer."
        ))
    }
}

private final class HostKeyGate: NIOSSHClientServerAuthenticationDelegate {
    private let seen: NIOLockedValueBox<PresentedHostKey?>
    private let verify: @Sendable (PresentedHostKey) async -> Bool

    init(seen: NIOLockedValueBox<PresentedHostKey?>, verify: @escaping @Sendable (PresentedHostKey) async -> Bool) {
        self.seen = seen
        self.verify = verify
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let parts = String(openSSHPublicKey: hostKey).split(separator: " ")
        let type = parts.first.map(String.init) ?? ""
        let blob = parts.count > 1 ? String(parts[1]) : ""
        let info = PresentedHostKey(type: type, base64: blob, fingerprint: SSHFingerprint.ofOpenSSHBlob(blob))
        let verify = self.verify
        let seen = self.seen
        Task {
            if await verify(info) {
                seen.withLockedValue { $0 = info }
                validationCompletePromise.succeed(())
            } else {
                validationCompletePromise.fail(SSHClientError.hostKeyRejected)
            }
        }
    }
}

private final class ConnectionWatcher: ChannelInboundHandler {
    typealias InboundIn = Any
    private let firstError: NIOLockedValueBox<SSHClientError?>
    private let authenticated: EventLoopPromise<Void>
    private let onClose: NIOLockedValueBox<(@Sendable () -> Void)?>
    private var settled = false

    init(
        firstError: NIOLockedValueBox<SSHClientError?>,
        authenticated: EventLoopPromise<Void>,
        onClose: NIOLockedValueBox<(@Sendable () -> Void)?>
    ) {
        self.firstError = firstError
        self.authenticated = authenticated
        self.onClose = onClose
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent { succeedOnce() }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        let wrapped = SSHClientError.wrap(error)
        firstError.withLockedValue { if $0 == nil { $0 = wrapped } }
        failOnce(wrapped)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if settled {
            let handler = onClose.withLockedValue { $0 }
            handler?()
        } else {
            failOnce(firstError.withLockedValue { $0 } ?? .disconnected("connection closed"))
        }
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        failOnce(firstError.withLockedValue { $0 } ?? .connectFailed("connection closed"))
    }

    private func succeedOnce() {
        guard !settled else { return }
        settled = true
        authenticated.succeed(())
    }

    private func failOnce(_ error: Error) {
        guard !settled else { return }
        settled = true
        authenticated.fail(error)
    }
}

private final class ExecHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    private let command: String
    private let ready: EventLoopPromise<Void>
    private let finished: EventLoopPromise<Int>
    private let onChunk: @Sendable (ExecChunk) -> Void
    private var opened = false
    private var sent = false
    private var didFinish = false

    init(
        command: String,
        ready: EventLoopPromise<Void>,
        finished: EventLoopPromise<Int>,
        onChunk: @escaping @Sendable (ExecChunk) -> Void
    ) {
        self.command = command
        self.ready = ready
        self.finished = finished
        self.onChunk = onChunk
    }

    func handlerAdded(context: ChannelHandlerContext) {
        if context.channel.isActive { send(context: context) }
    }

    func channelActive(context: ChannelHandlerContext) {
        send(context: context)
        context.fireChannelActive()
    }

    private func send(context: ChannelHandlerContext) {
        guard !sent else { return }
        sent = true
        context.triggerUserOutboundEvent(SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true), promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case .byteBuffer(let buffer) = message.data else { return }
        let bytes = Data(buffer.readableBytesView)
        onChunk(message.type == .channel ? .stdout(bytes) : .stderr(bytes))
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent:
            if !opened {
                opened = true
                ready.succeed(())
            }
        case is ChannelFailureEvent:
            ready.fail(SSHClientError.channelRejected("the command"))
            context.close(promise: nil)
        case let status as SSHChannelRequestEvent.ExitStatus:
            finish(Int(status.exitStatus))
        case ChannelEvent.inputClosed:
            context.close(promise: nil)
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !opened { ready.fail(SSHClientError.disconnected("channel closed")) }
        finish(255)
        context.fireChannelInactive()
    }

    private func finish(_ code: Int) {
        guard !didFinish else { return }
        didFinish = true
        finished.succeed(code)
    }
}

private final class DirectHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    private let ready: EventLoopPromise<Void>
    private let onData: @Sendable (Data) -> Void
    private let onClose: @Sendable () -> Void
    private var opened = false

    init(
        ready: EventLoopPromise<Void>,
        onData: @escaping @Sendable (Data) -> Void,
        onClose: @escaping @Sendable () -> Void
    ) {
        self.ready = ready
        self.onData = onData
        self.onClose = onClose
    }

    func handlerAdded(context: ChannelHandlerContext) {
        if context.channel.isActive { markReady() }
    }

    func channelActive(context: ChannelHandlerContext) {
        markReady()
        context.fireChannelActive()
    }

    private func markReady() {
        guard !opened else { return }
        opened = true
        ready.succeed(())
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case .byteBuffer(let buffer) = message.data else { return }
        onData(Data(buffer.readableBytesView))
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if !opened { ready.fail(SSHClientError.wrap(error)) }
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !opened { ready.fail(SSHClientError.disconnected("agent port closed")) }
        onClose()
        context.fireChannelInactive()
    }
}
