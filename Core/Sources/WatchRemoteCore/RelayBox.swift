import CryptoKit
import Foundation

/// Checks for a pairing-time relay URL, room token, and 32-byte end-to-end key.
public enum RelayMaterial {
    public static func normalizeURL(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (12...300).contains(trimmed.count) else { return nil }
        guard !trimmed.contains(where: \.isWhitespace) else { return nil }
        guard let components = URLComponents(string: trimmed) else { return nil }
        guard components.scheme?.lowercased() == "wss" else { return nil }
        guard let host = components.host, !host.isEmpty, host.count <= 253 else { return nil }
        guard components.user == nil, components.password == nil else { return nil }
        guard components.query == nil, components.fragment == nil else { return nil }
        if let port = components.port, !(1...65535).contains(port) { return nil }
        return trimmed
    }

    public static func normalizeToken(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (16...128).contains(trimmed.count) else { return nil }
        let alphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        guard trimmed.allSatisfy({ alphabet.contains($0) }) else { return nil }
        return trimmed
    }

    /// Canonical unpadded base64url for a 32-byte key, or nil.
    public static func normalizeKey(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "=", with: "")
        guard let data = Base64URL.decode(trimmed), data.count == 32 else { return nil }
        return Base64URL.encode(data)
    }

    public static func keyData(_ text: String) -> Data? {
        guard let canonical = normalizeKey(text) else { return nil }
        return Base64URL.decode(canonical)
    }
}

public enum RelayDirection: UInt8, Equatable, Sendable {
    case watchToHost = 1
    case hostToWatch = 2
}

/// Remembers counters it has already accepted so a captured frame cannot be sent again.
public struct RelayReplay: Equatable, Sendable {
    public private(set) var highest: UInt64
    private var seen: UInt64

    public init() {
        highest = 0
        seen = 0
    }

    /// After a restart, refuse every counter at or below the stored high water.
    public static func restored(highest: UInt64) -> RelayReplay {
        var replay = RelayReplay()
        replay.highest = highest
        replay.seen = highest == 0 ? 0 : UInt64.max
        return replay
    }

    /// True when `accept` would take this counter. Does not record it.
    public func allows(_ counter: UInt64) -> Bool {
        var copy = self
        return copy.accept(counter)
    }

    public mutating func accept(_ counter: UInt64) -> Bool {
        if counter == 0 { return false }
        if highest == 0 {
            highest = counter
            seen = 1
            return true
        }
        if counter > highest {
            let shift = counter - highest
            if shift >= 64 {
                seen = 1
            } else {
                seen = (seen << shift) | 1
            }
            highest = counter
            return true
        }
        let age = highest - counter
        if age >= 64 { return false }
        let bit = UInt64(1) << age
        if seen & bit != 0 { return false }
        seen |= bit
        return true
    }
}

public enum RelayBoxError: Error, Equatable {
    case badKey
    case badFrame
    case wrongDirection
    case replayed
    case refused
}

/// ChaCha20-Poly1305 frames. The nonce is the direction plus the counter, so it is never reused.
public enum RelayBox {
    public static func seal(plaintext: Data, key: Data, direction: RelayDirection, counter: UInt64) throws -> Data {
        guard key.count == 32, counter > 0 else { throw RelayBoxError.badKey }
        let nonce = try ChaChaPoly.Nonce(data: nonceBytes(direction: direction, counter: counter))
        let box = try ChaChaPoly.seal(plaintext, using: SymmetricKey(data: key), nonce: nonce)
        var frame = Data()
        frame.append(1)
        frame.append(direction.rawValue)
        appendCounter(counter, to: &frame)
        frame.append(box.ciphertext)
        frame.append(box.tag)
        return frame
    }

    public static func open(frame: Data, key: Data, expecting: RelayDirection, replay: inout RelayReplay) throws -> Data {
        guard key.count == 32 else { throw RelayBoxError.badKey }
        guard frame.count >= 2 + 8 + 16 else { throw RelayBoxError.badFrame }
        guard frame[frame.startIndex] == 1 else { throw RelayBoxError.badFrame }
        let directionByte = frame[frame.startIndex + 1]
        guard let direction = RelayDirection(rawValue: directionByte), direction == expecting else {
            throw RelayBoxError.wrongDirection
        }
        let counter = readCounter(frame, at: frame.startIndex + 2)
        guard replay.allows(counter) else { throw RelayBoxError.replayed }
        let body = frame.subdata(in: (frame.startIndex + 10)..<frame.endIndex)
        guard body.count >= 16 else { throw RelayBoxError.badFrame }
        let tag = body.suffix(16)
        let ciphertext = body.prefix(body.count - 16)
        let plain: Data
        do {
            let nonce = try ChaChaPoly.Nonce(data: nonceBytes(direction: direction, counter: counter))
            let box = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            plain = try ChaChaPoly.open(box, using: SymmetricKey(data: key))
        } catch let error as RelayBoxError {
            throw error
        } catch {
            throw RelayBoxError.refused
        }
        guard replay.accept(counter) else { throw RelayBoxError.replayed }
        return plain
    }

    static func nonceBytes(direction: RelayDirection, counter: UInt64) -> Data {
        var data = Data(count: 12)
        data[3] = direction.rawValue
        writeCounter(counter, into: &data, at: 4)
        return data
    }

    private static func appendCounter(_ counter: UInt64, to frame: inout Data) {
        var bytes = Data(count: 8)
        writeCounter(counter, into: &bytes, at: 0)
        frame.append(bytes)
    }

    private static func writeCounter(_ counter: UInt64, into data: inout Data, at offset: Int) {
        for index in 0..<8 {
            let shift = (7 - index) * 8
            data[offset + index] = UInt8((counter >> shift) & 0xff)
        }
    }

    private static func readCounter(_ frame: Data, at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<8 {
            value = (value << 8) | UInt64(frame[offset + index])
        }
        return value
    }
}

/// Commands inside a sealed frame. The relay never sees this JSON.
public struct DirectMessage: Codable, Equatable, Sendable {
    public enum Op: String, Codable, Sendable {
        case list
        case start
        case approve
        case deny
        case stop
        case ping
        case sessions
        case started
        case ok
        case error
        case update
        case pong
    }

    public var op: Op
    public var id: String
    public var prompt: String?
    public var cwd: String?
    public var sessionID: String?
    public var permissionID: String?
    public var sessions: [GrokSession]?
    public var approvalsAvailable: Bool?
    public var message: String?

    public init(
        op: Op,
        id: String,
        prompt: String? = nil,
        cwd: String? = nil,
        sessionID: String? = nil,
        permissionID: String? = nil,
        sessions: [GrokSession]? = nil,
        approvalsAvailable: Bool? = nil,
        message: String? = nil
    ) {
        self.op = op
        self.id = id
        self.prompt = prompt
        self.cwd = cwd
        self.sessionID = sessionID
        self.permissionID = permissionID
        self.sessions = sessions
        self.approvalsAvailable = approvalsAvailable
        self.message = message
    }

    public static func encode(_ message: DirectMessage) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(message)
    }

    public static func decode(_ data: Data) -> DirectMessage? {
        try? JSONDecoder().decode(DirectMessage.self, from: data)
    }
}

/// What the iPhone hands the Watch during pairing. Stored in the Watch Keychain, not in the snapshot.
public struct DirectPairing: Codable, Equatable, Sendable {
    public var computerID: String
    public var label: String
    public var relayURL: String
    public var token: String
    public var key: String
    public var clear: Bool

    public init(computerID: String, label: String, relayURL: String, token: String, key: String, clear: Bool = false) {
        self.computerID = computerID
        self.label = label
        self.relayURL = relayURL
        self.token = token
        self.key = key
        self.clear = clear
    }

    public func jsonText() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func decode(_ text: String) -> DirectPairing? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(DirectPairing.self, from: data)
    }
}
