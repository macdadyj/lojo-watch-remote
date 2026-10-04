import Foundation

public struct KnownHostEntry: Equatable, Sendable {
    public var host: String
    public var port: Int
    public var keyType: String
    public var base64: String

    public var fingerprint: String { SSHFingerprint.ofOpenSSHBlob(base64) }

    public init(host: String, port: Int, keyType: String, base64: String) {
        self.host = host
        self.port = port
        self.keyType = keyType
        self.base64 = base64
    }
}

public enum HostTrust: Equatable, Sendable {
    case trusted
    case firstUse(KnownHostEntry)
    case changed(previous: String, presented: String)
}

/// OpenSSH-style known_hosts limited to `[host]:port type base64` rows.
public struct KnownHosts: Equatable, Sendable {
    public private(set) var entries: [KnownHostEntry]

    public init(entries: [KnownHostEntry] = []) {
        self.entries = entries
    }

    public init(text: String) {
        entries = text.split(whereSeparator: \.isNewline).compactMap(Self.parse(line:))
    }

    public func verdict(host: String, port: Int, keyType: String, base64: String) -> HostTrust {
        let presented = KnownHostEntry(host: host, port: port, keyType: keyType, base64: base64)
        guard let saved = entries.first(where: { $0.host == host && $0.port == port }) else {
            return .firstUse(presented)
        }
        if saved.fingerprint == presented.fingerprint { return .trusted }
        return .changed(previous: saved.fingerprint, presented: presented.fingerprint)
    }

    public mutating func trust(_ entry: KnownHostEntry) {
        entries.removeAll { $0.host == entry.host && $0.port == entry.port }
        entries.append(entry)
    }

    public mutating func forget(host: String, port: Int) {
        entries.removeAll { $0.host == host && $0.port == port }
    }

    public func text() -> String {
        entries.map { "[\($0.host)]:\($0.port) \($0.keyType) \($0.base64)" }.joined(separator: "\n")
            + (entries.isEmpty ? "" : "\n")
    }

    private static func parse(line: Substring) -> KnownHostEntry? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("#") { return nil }
        let parts = trimmed.split(separator: " ")
        guard parts.count >= 3 else { return nil }
        let marker = String(parts[0])
        guard marker.first == "[", let close = marker.firstIndex(of: "]") else { return nil }
        let host = String(marker[marker.index(after: marker.startIndex)..<close])
        let rest = marker[marker.index(after: close)...]
        guard rest.first == ":", let port = Int(rest.dropFirst()) else { return nil }
        return KnownHostEntry(host: host, port: port, keyType: String(parts[1]), base64: String(parts[2]))
    }
}

public enum AuthorizeCommand {
    public static func text(publicKey: String) -> String {
        let key = ShellQuoting.singleQuote(publicKey.trimmingCharacters(in: .whitespacesAndNewlines))
        return "mkdir -p ~/.ssh && chmod 700 ~/.ssh && { grep -qxF \(key) ~/.ssh/authorized_keys 2>/dev/null || echo \(key) >> ~/.ssh/authorized_keys; } && chmod 600 ~/.ssh/authorized_keys"
    }
}
