import Foundation
import Network
import WatchRemoteCore

/// Posts this iPhone's public key to the computer that is waiting after `watch-remote-pair`.
///
/// The post is cleartext HTTP on the overlay (`100.64.0.0/10`). App Transport Security does not
/// treat that range as local, and an exception domain cannot name the prefix. `URLSession` is
/// not used. This is one TCP connection, and only after the address passes the overlay check.
enum HostEnroll {
    static func submit(address: String, port: Int, ticket: String, publicKey: String) async -> String? {
        guard let host = OverlayPolicy.canonical(address: address), (1...65535).contains(port) else {
            return "That computer is outside the private overlay."
        }
        guard let line = OpenSSHPublicKey.canonical(publicKey),
              let request = EnrollHTTP.request(host: host, port: port, ticket: ticket, publicKey: line) else {
            return "The pairing channel could not be opened."
        }
        do {
            let data = try await EnrollTCP.exchange(host: host, port: port, payload: request, timeoutSeconds: 8)
            guard let parsed = EnrollHTTP.response(from: data), parsed.status == 200, parsed.body.contains("\"ok\":true") else {
                return "The computer did not accept this iPhone. Open Advanced and use the authorize command."
            }
            return nil
        } catch {
            return "The computer did not answer. Leave watch-remote-pair open, then scan again."
        }
    }
}

private enum EnrollTCPError: Error {
    case failed
}

private enum EnrollTCP {
    private static let maxResponse = 16 * 1024

    static func exchange(host: String, port: Int, payload: Data, timeoutSeconds: TimeInterval) async throws -> Data {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { throw EnrollTCPError.failed }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await transfer(connection, payload: payload)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                connection.cancel()
                throw EnrollTCPError.failed
            }
            do {
                guard let result = try await group.next() else { throw EnrollTCPError.failed }
                connection.cancel()
                group.cancelAll()
                return result
            } catch {
                connection.cancel()
                group.cancelAll()
                throw error
            }
        }
    }

    private static func transfer(_ connection: NWConnection, payload: Data) async throws -> Data {
        try await ready(connection)
        try await send(connection, payload)
        return try await receiveAll(connection)
    }

    private static func ready(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = ResumeOnce()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    gate.succeed(continuation)
                case .failed, .cancelled:
                    gate.fail(continuation)
                case .setup, .preparing, .waiting:
                    break
                @unknown default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
    }

    private static func send(_ connection: NWConnection, _ payload: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: payload, completion: .contentProcessed { error in
                if error == nil {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: EnrollTCPError.failed)
                }
            })
        }
    }

    private static func receiveAll(_ connection: NWConnection) async throws -> Data {
        var collected = Data()
        while collected.count < maxResponse {
            let chunk: Data
            do {
                chunk = try await receiveOnce(connection)
            } catch {
                // The computer closes the socket after the response. Keep the bytes already read.
                if collected.isEmpty { throw error }
                break
            }
            if chunk.isEmpty { break }
            let room = maxResponse - collected.count
            collected.append(chunk.prefix(room))
        }
        guard !collected.isEmpty else { throw EnrollTCPError.failed }
        return collected
    }

    private static func receiveOnce(_ connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
                if error != nil {
                    continuation.resume(throwing: EnrollTCPError.failed)
                    return
                }
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                    return
                }
                if isComplete {
                    continuation.resume(returning: Data())
                    return
                }
                continuation.resume(returning: Data())
            }
        }
    }
}

/// Resumes a ready-state continuation at most once. State updates can repeat.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func succeed(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        let first = !resumed
        resumed = true
        lock.unlock()
        if first { continuation.resume() }
    }

    func fail(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        let first = !resumed
        resumed = true
        lock.unlock()
        if first { continuation.resume(throwing: EnrollTCPError.failed) }
    }
}
