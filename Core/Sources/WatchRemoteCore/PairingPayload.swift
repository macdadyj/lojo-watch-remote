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
    /// `wss` URL of the outbound relay. Nil when this pairing is SSH only.
    public var relayURL: String?
    public var token: String?
    /// 32-byte end-to-end key, unpadded base64url. Nil when this pairing is SSH only.
    public var e2eKey: String?
    /// One-time ticket for the pairing channel. Nil on older codes.
    public var ticket: String?
    /// Port of the short-lived pairing channel. Nil when `ticket` is nil.
    public var enrollPort: Int?

    public static let defaultEnrollPort = 2478

    public init(
        label: String,
        address: String,
        user: String,
        port: Int,
        secret: String? = nil,
        fingerprint: String? = nil,
        relayURL: String? = nil,
        token: String? = nil,
        e2eKey: String? = nil,
        ticket: String? = nil,
        enrollPort: Int? = nil
    ) throws {
        let payload = try Self.make(
            version: Self.version,
            label: label,
            address: address,
            user: user,
            port: port,
            secret: secret,
            fingerprint: fingerprint,
            relayURL: relayURL,
            token: token,
            e2eKey: e2eKey,
            ticket: ticket,
            enrollPort: enrollPort
        )
        self = payload
    }

    public var hasDirectRelay: Bool {
        relayURL != nil && token != nil && e2eKey != nil
    }

    public var canEnroll: Bool { ticket != nil }

    /// Label, address, user, port, and whether a secret, fingerprint, or direct relay is present.
    /// Never the secret, the room token, or the end-to-end key.
    public var summary: String {
        var lines = ["\(label) · \(user)@\(address):\(port)"]
        if let fingerprint {
            lines.append(fingerprint)
        }
        lines.append(secret == nil ? "No agent secret in this code." : "Agent secret included.")
        lines.append(hasDirectRelay ? "Direct connection included." : "No direct connection in this code.")
        if canEnroll {
            lines.append("This iPhone can authorize itself.")
        }
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
            fingerprint: raw.fingerprint,
            relayURL: raw.relay,
            token: raw.token,
            e2eKey: raw.e2e,
            ticket: raw.ticket,
            enrollPort: raw.enroll
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
        fingerprint: String?,
        relayURL: String? = nil,
        token: String? = nil,
        e2eKey: String? = nil,
        ticket: String? = nil,
        enrollPort: Int? = nil
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
        let direct = try normalizedDirect(relayURL: relayURL, token: token, e2eKey: e2eKey)
        let enroll = try normalizedEnroll(ticket: ticket, port: enrollPort)
        return PairingPayload(
            version: version,
            label: resolvedLabel,
            address: canonical,
            user: resolvedUser,
            port: port,
            secret: resolvedSecret,
            fingerprint: resolvedFingerprint,
            relayURL: direct?.url,
            token: direct?.token,
            e2eKey: direct?.key,
            ticket: enroll?.ticket,
            enrollPort: enroll?.port
        )
    }

    private init(
        version: Int,
        label: String,
        address: String,
        user: String,
        port: Int,
        secret: String?,
        fingerprint: String?,
        relayURL: String?,
        token: String?,
        e2eKey: String?,
        ticket: String?,
        enrollPort: Int?
    ) {
        self.version = version
        self.label = label
        self.address = address
        self.user = user
        self.port = port
        self.secret = secret
        self.fingerprint = fingerprint
        self.relayURL = relayURL
        self.token = token
        self.e2eKey = e2eKey
        self.ticket = ticket
        self.enrollPort = enrollPort
    }

    private static func normalizedEnroll(ticket: String?, port: Int?) throws -> (ticket: String, port: Int)? {
        let trimmed = ticket?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty && port == nil { return nil }
        guard let room = RelayMaterial.normalizeToken(trimmed) else { throw PairingError.invalidTicket }
        let resolved = port ?? defaultEnrollPort
        guard (1...65535).contains(resolved) else { throw PairingError.invalidPort }
        return (room, resolved)
    }

    private static func normalizedDirect(relayURL: String?, token: String?, e2eKey: String?) throws -> (url: String, token: String, key: String)? {
        let urlText = relayURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let tokenText = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let keyText = e2eKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if urlText.isEmpty && tokenText.isEmpty && keyText.isEmpty { return nil }
        guard let url = RelayMaterial.normalizeURL(urlText) else { throw PairingError.invalidRelay }
        guard let room = RelayMaterial.normalizeToken(tokenText) else { throw PairingError.invalidToken }
        guard let key = RelayMaterial.normalizeKey(keyText) else { throw PairingError.invalidE2EKey }
        return (url, room, key)
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
        case relayURL = "relay"
        case token
        case e2eKey = "e2e"
        case ticket
        case enrollPort = "enroll"
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
        try container.encodeIfPresent(relayURL, forKey: .relayURL)
        try container.encodeIfPresent(token, forKey: .token)
        try container.encodeIfPresent(e2eKey, forKey: .e2eKey)
        try container.encodeIfPresent(ticket, forKey: .ticket)
        try container.encodeIfPresent(enrollPort, forKey: .enrollPort)
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
            fingerprint: raw.fingerprint,
            relayURL: raw.relay,
            token: raw.token,
            e2eKey: raw.e2e,
            ticket: raw.ticket,
            enrollPort: raw.enroll
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
    var relay: String?
    var token: String?
    var e2e: String?
    var ticket: String?
    var enroll: Int?
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
    case invalidRelay
    case invalidToken
    case invalidE2EKey
    case invalidTicket
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
        case .invalidRelay:
            return "The direct relay address in the pairing code is not a wss address."
        case .invalidToken:
            return "The direct relay token in the pairing code is not usable."
        case .invalidE2EKey:
            return "The direct connection key in the pairing code is not usable."
        case .invalidTicket:
            return "The one-time pairing ticket in the pairing code is not usable."
        case .tooLarge:
            return "That pairing code is too large."
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
