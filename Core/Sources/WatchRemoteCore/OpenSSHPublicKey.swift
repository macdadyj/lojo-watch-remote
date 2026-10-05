import Foundation

/// One-line OpenSSH public keys. The blob uses the standard alphabet (`+` and `/`),
/// never URL-safe base64 and never a hyphen inserted by line wrapping.
public enum OpenSSHPublicKey {
    public static let comment = "watch-remote@iphone"

    private static let keyTypes = [
        "sk-ssh-ed25519@openssh.com",
        "sk-ecdsa-sha2-nistp256@openssh.com",
        "ecdsa-sha2-nistp521",
        "ecdsa-sha2-nistp384",
        "ecdsa-sha2-nistp256",
        "ssh-ed25519",
        "ssh-rsa",
    ]

    /// `ssh-ed25519 <standard-base64> comment` for a 32-byte public key.
    public static func ed25519(rawPublicKey: Data, comment: String = OpenSSHPublicKey.comment) -> String? {
        guard rawPublicKey.count == 32, isComment(comment) else { return nil }
        let payload = sshString(Data("ssh-ed25519".utf8)) + sshString(rawPublicKey)
        let encoded = payload.base64EncodedString(options: [])
        guard isStandardBlob(encoded) else { return nil }
        return "ssh-ed25519 \(encoded) \(comment)"
    }

    /// Repairs a key line, including one copied from a wrapped label or encoded as base64url.
    public static func canonical(_ text: String) -> String? {
        let flat = flatten(text)
        guard let located = locateType(in: flat) else { return nil }
        var rest = flat[located.range.upperBound...].drop(while: { $0 == " " || $0 == "\t" })
        let blobChars = rest.prefix(while: isBlobCharacter)
        guard !blobChars.isEmpty, let blob = canonicalBlob(String(blobChars)) else { return nil }
        rest = rest[blobChars.endIndex...].drop(while: { $0 == " " || $0 == "\t" })
        let commentEnd = rest.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "'" }) ?? rest.endIndex
        let parsedComment = String(rest[..<commentEnd])
        let comment = parsedComment.isEmpty ? Self.comment : parsedComment
        guard isComment(comment) else { return nil }
        return "\(located.type) \(blob) \(comment)"
    }

    private static func flatten(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\u{00AD}", with: "")
            .replacingOccurrences(of: "\u{2010}", with: "")
            .replacingOccurrences(of: "\u{2011}", with: "")
            .replacingOccurrences(of: "-\r\n", with: "")
            .replacingOccurrences(of: "-\n", with: "")
            .replacingOccurrences(of: "\r\n", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
    }

    private static func locateType(in text: String) -> (type: String, range: Range<String.Index>)? {
        var found: (type: String, range: Range<String.Index>)?
        for type in keyTypes {
            guard let range = text.range(of: type) else { continue }
            if let current = found {
                if range.lowerBound < current.range.lowerBound
                    || (range.lowerBound == current.range.lowerBound && type.count > current.type.count) {
                    found = (type, range)
                }
            } else {
                found = (type, range)
            }
        }
        return found
    }

    private static func canonicalBlob(_ blob: String) -> String? {
        if let encoded = standardEncoded(blob) {
            return encoded
        }
        // A hyphen inside the blob is a '+' from URL-safe text or from OCR of the screenshot.
        if blob.contains("-") || blob.contains("_") {
            let converted = blob.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            if let encoded = standardEncoded(converted) {
                return encoded
            }
        }
        return nil
    }

    /// Standard base64 only. Returns the canonical encoding when `text` round-trips.
    private static func standardEncoded(_ text: String) -> String? {
        guard !text.isEmpty, !text.contains("-"), !text.contains("_") else { return nil }
        let remainder = text.count % 4
        if remainder == 1 { return nil }
        var padded = text
        if remainder != 0 {
            guard !text.contains("=") else { return nil }
            padded += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: padded) else { return nil }
        let encoded = data.base64EncodedString(options: [])
        guard encoded == padded, isStandardBlob(encoded) else { return nil }
        return encoded
    }

    private static func isStandardBlob(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { character in
            guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else { return false }
            return isStandardBase64(scalar)
        }
    }

    private static func isStandardBase64(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        if scalar == "+" || scalar == "/" || scalar == "=" { return true }
        return (value >= 48 && value <= 57) || (value >= 65 && value <= 90) || (value >= 97 && value <= 122)
    }

    private static func isBlobCharacter(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else { return false }
        if scalar == "+" || scalar == "/" || scalar == "=" || scalar == "-" || scalar == "_" { return true }
        return isStandardBase64(scalar) && scalar != "="
    }

    private static func isComment(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 64 else { return false }
        return text.allSatisfy { character in
            guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else { return false }
            if "@._+-".unicodeScalars.contains(scalar) { return true }
            let value = scalar.value
            return (value >= 48 && value <= 57) || (value >= 65 && value <= 90) || (value >= 97 && value <= 122)
        }
    }

    private static func sshString(_ payload: Data) -> Data {
        var encoded = Data()
        let length = UInt32(payload.count)
        encoded.append(UInt8((length >> 24) & 0xff))
        encoded.append(UInt8((length >> 16) & 0xff))
        encoded.append(UInt8((length >> 8) & 0xff))
        encoded.append(UInt8(length & 0xff))
        encoded.append(payload)
        return encoded
    }
}
