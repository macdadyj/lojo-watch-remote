import CryptoKit
import Foundation

public struct IPv4: Equatable, Sendable {
    public let value: UInt32

    public init?(_ text: String) {
        let octets = text.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return nil }
        var packed: UInt32 = 0
        for octet in octets {
            // A leading zero is not canonical decimal. Socket APIs may read it as octal.
            guard octet.count >= 1, octet.count <= 3, octet.allSatisfy(\.isNumber) else { return nil }
            if octet.count > 1, octet.first == "0" { return nil }
            guard let number = UInt32(octet), number <= 255 else { return nil }
            packed = packed << 8 | number
        }
        value = packed
    }

    /// Dotted decimal with no leading zeros. This is the string a socket should dial.
    public var dottedDecimal: String {
        let first = (value >> 24) & 0xff
        let second = (value >> 16) & 0xff
        let third = (value >> 8) & 0xff
        let fourth = value & 0xff
        return "\(first).\(second).\(third).\(fourth)"
    }

    public func isIn(network: UInt32, prefix: Int) -> Bool {
        let mask: UInt32 = prefix == 0 ? 0 : UInt32.max << (32 - UInt32(prefix))
        return (value & mask) == (network & mask)
    }
}

/// SSH from Watch Remote goes only to the private overlay (100.64.0.0/10).
/// `exampleAddress` is a placeholder in that range, not a paired computer.
/// Public addresses and names are refused before a socket opens.
/// Loopback is not an SSH target. The optional relay may bind it.
public enum OverlayPolicy {
    public static let overlayNetwork: UInt32 = (100 << 24) | (64 << 16)
    public static let overlayPrefix = 10
    public static let exampleAddress = "100.64.0.2"
    public static let examplePort = 22
    public static let exampleUser = "user"
    public static let exampleLabel = "example-host"
    public static let agentLoopback = "127.0.0.1"
    public static let agentPort = 2419

    public static func allows(address: String) -> Bool {
        guard let ip = IPv4(address.trimmingCharacters(in: .whitespaces)) else { return false }
        return ip.isIn(network: overlayNetwork, prefix: overlayPrefix)
    }

    /// The canonical overlay address to dial, or nil when the text is not in range.
    public static func canonical(address: String) -> String? {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        guard let ip = IPv4(trimmed), ip.isIn(network: overlayNetwork, prefix: overlayPrefix) else { return nil }
        return ip.dottedDecimal
    }

    public static func refusalReason(address: String) -> String? {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        if allows(address: trimmed) { return nil }
        if IPv4(trimmed) == nil {
            return "Use the overlay address. Names and public hosts are not contacted."
        }
        return "That address is outside the private overlay."
    }
}

public enum ShellQuoting {
    public static func singleQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Remote commands run through the login shell. The agent secret is never placed on this command line.
public enum GrokCommands {
    public static func sessionsList(cwd: String? = nil) -> String {
        remoteShell(script: sessionsListScript(cwd: cwd))
    }

    public static func headless(prompt: String, cwd: String?, resume: String?) -> String {
        remoteShell(script: headlessScript(prompt: prompt, cwd: cwd, resume: resume))
    }

    public static func usage(sessionID: String) -> String {
        remoteShell(script: "\(binaryPrelude) usage \(ShellQuoting.singleQuote(sessionID))")
    }

    /// `grok sessions list` is the documented command. It has no published `--limit` flag, so the phone trims the list after parsing.
    public static func sessionsListScript(cwd: String? = nil) -> String {
        let prefix = cwd.map { "cd -- \(ShellQuoting.singleQuote($0)) || exit 1; " } ?? ""
        return "\(prefix)\(binaryPrelude) sessions list"
    }

    public static func headlessScript(prompt: String, cwd: String?, resume: String?) -> String {
        var parts = [
            binaryPrelude,
            "-p", ShellQuoting.singleQuote(prompt),
            "--output-format", "streaming-json",
            "--no-auto-update",
            "--permission-mode", "dontAsk",
        ]
        if let cwd, !cwd.isEmpty {
            parts.append(contentsOf: ["--cwd", ShellQuoting.singleQuote(cwd)])
        }
        if let resume, !resume.isEmpty {
            parts.append(contentsOf: ["-r", ShellQuoting.singleQuote(resume)])
        }
        return parts.joined(separator: " ")
    }

    public static func remoteShell(script: String) -> String {
        "bash -lc \(ShellQuoting.singleQuote(script))"
    }

    /// Resolves the Grok 1.0 binary without putting secrets in argv.
    static let binaryPrelude = #"bin="${GROK_BIN:-$HOME/.grok/bin/grok}"; [ -x "$bin" ] || bin="grok"; exec "$bin""#
}

public enum SSHFingerprint {
    public static func sha256Base64(of data: Data) -> String {
        let digest = Data(SHA256.hash(data: data))
        let encoded = digest.base64EncodedString().replacingOccurrences(of: "=", with: "")
        return "SHA256:" + encoded
    }

    public static func ofOpenSSHBlob(_ base64: String) -> String {
        let blob = Data(base64Encoded: base64) ?? Data()
        return sha256Base64(of: blob)
    }
}
