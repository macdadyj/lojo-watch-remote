import Foundation

/// `watchremote://pair?d=` carries a versioned JSON document as base64url.
/// The document may include an agent secret. Callers show `summary`, which never includes that secret.
public struct PairingPayload: Equatable, Sendable {
    public static let version = 1
    public static let urlPrefix = "watchremote://pair?d="

    public var version: Int
    public var label: String
    public var address: String
    public var user: String
    public var port: Int
    public var secret: String?
    public var fingerprint: String?

    public init(label: String, address: String, user: String, port: Int, secret: String? = nil, fingerprint: String? = nil) throws {
        let payload = try Self.make(
            version: Self.version,
            label: label,
            address: address,
            user: user,
            port: port,
            secret: secret,
            fingerprint: fingerprint
        )
        self = payload
    }

    /// Label, address, user, port, and whether a secret or fingerprint is present. Never the secret.
    public var summary: String {
        var lines = ["\(label) · \(user)@\(address):\(port)"]
        if let fingerprint {
            lines.append(fingerprint)
        }
        lines.append(secret == nil ? "No agent secret in this code." : "Agent secret included.")
        return lines.joined(separator: "\n")
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public func token() throws -> String {
        try Base64URL.encode(jsonData())
    }

    public func urlString() throws -> String {
        try Self.urlPrefix + token()
    }

    public static func decode(_ text: String) throws -> PairingPayload {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count >= 2 {
            let quote = trimmed.first
            if (quote == "\"" || quote == "'"), trimmed.last == quote {
                trimmed = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if trimmed.isEmpty { throw PairingError.empty }
        if trimmed.count > 8192 { throw PairingError.tooLarge }
        let data: Data
        if trimmed.hasPrefix("{") {
            guard let json = trimmed.data(using: .utf8) else { throw PairingError.malformed }
            data = json
        } else {
            let token = try tokenText(from: trimmed)
            guard let decoded = Base64URL.decode(token) else { throw PairingError.malformed }
            if decoded.count > 8192 { throw PairingError.tooLarge }
            data = decoded
        }
        let decoder = JSONDecoder()
        let raw: RawPayload
        do {
            raw = try decoder.decode(RawPayload.self, from: data)
        } catch let error as PairingError {
            throw error
        } catch {
            throw PairingError.malformed
        }
        return try make(
            version: raw.v,
            label: raw.label,
            address: raw.address,
            user: raw.user,
            port: raw.port,
            secret: raw.secret,
            fingerprint: raw.fingerprint
        )
    }

    /// `SHA256:` plus 43 unpadded base64 characters, or nil when the text is not that shape.
    public static func normalizeFingerprint(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "SHA256:"
        guard trimmed.lowercased().hasPrefix(prefix.lowercased()) else { return nil }
        let body = trimmed.dropFirst(prefix.count).replacingOccurrences(of: "=", with: "")
        guard body.count == 43 else { return nil }
        let alphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
        guard body.allSatisfy({ alphabet.contains($0) }) else { return nil }
        return prefix + body
    }

    private static func make(
        version: Int,
        label: String,
        address: String,
        user: String,
        port: Int,
        secret: String?,
        fingerprint: String?
    ) throws -> PairingPayload {
        guard version == Self.version else { throw PairingError.unsupportedVersion(version) }
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedLabel = name.isEmpty ? OverlayPolicy.exampleLabel : name
        guard resolvedLabel.count <= 64, !resolvedLabel.unicodeScalars.contains(where: Self.isControl) else {
            throw PairingError.invalidLabel
        }
        guard let canonical = OverlayPolicy.canonical(address: address) else {
            throw PairingError.addressOutsideOverlay
        }
        let resolvedUser = user.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidUser(resolvedUser) else { throw PairingError.invalidUser }
        guard (1...65535).contains(port) else { throw PairingError.invalidPort }
        let resolvedSecret = try normalizedSecret(secret)
        let resolvedFingerprint: String?
        if let fingerprint {
            let trimmed = fingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                resolvedFingerprint = nil
            } else if let normalized = normalizeFingerprint(trimmed) {
                resolvedFingerprint = normalized
            } else {
                throw PairingError.invalidFingerprint
            }
        } else {
            resolvedFingerprint = nil
        }
        return PairingPayload(
            version: version,
            label: resolvedLabel,
            address: canonical,
            user: resolvedUser,
            port: port,
            secret: resolvedSecret,
            fingerprint: resolvedFingerprint
        )
    }

    private init(version: Int, label: String, address: String, user: String, port: Int, secret: String?, fingerprint: String?) {
        self.version = version
        self.label = label
        self.address = address
        self.user = user
        self.port = port
        self.secret = secret
        self.fingerprint = fingerprint
    }

    private static func normalizedSecret(_ raw: String?) throws -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        guard (8...128).contains(trimmed.count) else { throw PairingError.invalidSecret }
        let printable = CharacterSet(charactersIn: Unicode.Scalar(0x21)!...Unicode.Scalar(0x7e)!)
        guard trimmed.unicodeScalars.allSatisfy({ printable.contains($0) }) else { throw PairingError.invalidSecret }
        return trimmed
    }

    private static func isValidUser(_ user: String) -> Bool {
        guard (1...32).contains(user.count) else { return false }
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return user.allSatisfy { allowed.contains($0) }
    }

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || scalar.value == 0x7f
    }

    private static func tokenText(from text: String) throws -> String {
        let lower = text.lowercased()
        guard lower.hasPrefix("watchremote://") else {
            guard Self.isToken(text) else { throw PairingError.malformed }
            return text
        }
        guard let components = URLComponents(string: text), components.scheme?.lowercased() == "watchremote" else {
            throw PairingError.malformed
        }
        let host = components.host?.lowercased()
        let path = components.path.lowercased()
        guard host == "pair" || path == "/pair" || path == "pair" else { throw PairingError.malformed }
        guard let token = components.queryItems?.first(where: { $0.name == "d" })?.value, !token.isEmpty else {
            throw PairingError.malformed
        }
        guard isToken(token) else { throw PairingError.malformed }
        return token
    }

    private static func isToken(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 8192 else { return false }
        let alphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        return text.allSatisfy { alphabet.contains($0) }
    }
}

extension PairingPayload: Codable {
    enum CodingKeys: String, CodingKey {
        case version = "v"
        case label
        case address
        case user
        case port
        case secret
        case fingerprint
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(label, forKey: .label)
        try container.encode(address, forKey: .address)
        try container.encode(user, forKey: .user)
        try container.encode(port, forKey: .port)
        try container.encodeIfPresent(secret, forKey: .secret)
        try container.encodeIfPresent(fingerprint, forKey: .fingerprint)
    }

    public init(from decoder: Decoder) throws {
        let raw = try RawPayload(from: decoder)
        self = try Self.make(
            version: raw.v,
            label: raw.label,
            address: raw.address,
            user: raw.user,
            port: raw.port,
            secret: raw.secret,
            fingerprint: raw.fingerprint
        )
    }
}

private struct RawPayload: Decodable {
    var v: Int
    var label: String
    var address: String
    var user: String
    var port: Int
    var secret: String?
    var fingerprint: String?
}

public enum PairingError: Error, Equatable {
    case empty
    case malformed
    case unsupportedVersion(Int)
    case addressOutsideOverlay
    case invalidPort
    case invalidUser
    case invalidLabel
    case invalidFingerprint
    case invalidSecret
    case tooLarge
}

extension PairingError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .empty:
            return "Paste the pairing text from the computer."
        case .malformed:
            return "That pairing code could not be read."
        case .unsupportedVersion:
            return "This pairing code is from a newer Watch Remote. Update the app."
        case .addressOutsideOverlay:
            return "That address is outside the private overlay."
        case .invalidPort:
            return "The pairing code has a port Watch Remote cannot use."
        case .invalidUser:
            return "The pairing code has an SSH user Watch Remote cannot use."
        case .invalidLabel:
            return "The pairing code has a label Watch Remote cannot use."
        case .invalidFingerprint:
            return "The host key fingerprint in the pairing code is not a SHA256 fingerprint."
        case .invalidSecret:
            return "The agent secret in the pairing code is not usable."
        case .tooLarge:
            return "That pairing code is too large."
        default:
            let unknown: Never = self
            return unknown
        }
    }
}

public enum Base64URL {
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ text: String) -> Data? {
        var padded = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = padded.count % 4
        if remainder > 0 {
            padded += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: padded)
    }
}
