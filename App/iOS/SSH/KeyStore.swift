import Crypto
import Foundation
import NIOSSH
import Security
import WatchRemoteCore

struct PhoneKey: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case ed25519
        case secureEnclaveP256
    }

    var id: String
    var label: String
    var kind: Kind
    var publicKey: String
    var created: Date

    var fingerprint: String {
        let parts = publicKey.split(separator: " ")
        guard parts.count > 1 else { return "" }
        return SSHFingerprint.ofOpenSSHBlob(String(parts[1]))
    }
}

enum KeychainStore {
    static let keyService = "com.lojo.WatchRemote.ssh-key"
    static let secretService = "com.lojo.WatchRemote.secret"

    static func write(_ data: Data, service: String, account: String) throws {
        let query = base(service: service, account: account)
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeyStoreError.status(status) }
    }

    static func read(service: String, account: String) throws -> Data {
        var query = base(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else {
            throw status == errSecItemNotFound ? KeyStoreError.missing : KeyStoreError.status(status)
        }
        let update = [kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary
        SecItemUpdate(base(service: service, account: account) as CFDictionary, update)
        return data
    }

    static func delete(service: String, account: String) {
        SecItemDelete(base(service: service, account: account) as CFDictionary)
    }

    private static func base(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
    }
}

enum KeyStoreError: Error, LocalizedError, CustomStringConvertible {
    case status(OSStatus)
    case missing
    case secureEnclaveUnavailable
    case unusablePublicKey

    var errorDescription: String? { description }

    var description: String {
        switch self {
        case .status(let status): return "Keychain error \(status)"
        case .missing: return "That secret is not in the Keychain"
        case .secureEnclaveUnavailable: return "Secure Enclave is not available on this device"
        case .unusablePublicKey: return "The public key could not be encoded."
        }
    }
}

@MainActor
final class KeyStore: ObservableObject {
    @Published private(set) var key: PhoneKey?
    private let directory: URL
    /// Last secrets read while the phone was unlocked. A locked phone cannot prompt the keychain.
    private var secretCache: [String: String] = [:]
    private var keyMaterial: [String: Data] = [:]

    init(directory: URL) {
        self.directory = directory
        let url = directory.appendingPathComponent("phone-key.json")
        if let data = try? Data(contentsOf: url), var saved = try? JSONDecoder().decode(PhoneKey.self, from: data) {
            if let fixed = OpenSSHPublicKey.canonical(saved.publicKey), fixed != saved.publicKey {
                saved.publicKey = fixed
                if let encoded = try? JSONEncoder().encode(saved) {
                    try? encoded.write(to: url, options: [.atomic, .completeFileProtection])
                }
            }
            key = saved
        }
    }

    var secureEnclaveAvailable: Bool { SecureEnclave.isAvailable }

    func generateEd25519() throws {
        let raw = Curve25519.Signing.PrivateKey()
        guard let line = OpenSSHPublicKey.ed25519(rawPublicKey: raw.publicKey.rawRepresentation) else {
            throw KeyStoreError.unusablePublicKey
        }
        try store(kind: .ed25519, secret: raw.rawRepresentation, publicKeyLine: line, label: "Watch Remote")
    }

    func generateSecureEnclave() throws {
        guard SecureEnclave.isAvailable else { throw KeyStoreError.secureEnclaveUnavailable }
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, .privateKeyUsage, &error
        ) else {
            throw error?.takeRetainedValue() ?? KeyStoreError.secureEnclaveUnavailable
        }
        let enclave = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
        let ssh = NIOSSHPrivateKey(secureEnclaveP256Key: enclave)
        let formatted = String(openSSHPublicKey: ssh.publicKey) + " " + OpenSSHPublicKey.comment
        try store(kind: .secureEnclaveP256, secret: enclave.dataRepresentation, publicKeyLine: formatted, label: "Watch Remote")
    }

    func privateKey() throws -> NIOSSHPrivateKey {
        guard let key else { throw KeyStoreError.missing }
        let secret: Data
        if let cached = keyMaterial[key.id] {
            secret = cached
        } else {
            secret = try KeychainStore.read(service: KeychainStore.keyService, account: key.id)
            keyMaterial[key.id] = secret
        }
        switch key.kind {
        case .ed25519:
            return NIOSSHPrivateKey(ed25519Key: try Curve25519.Signing.PrivateKey(rawRepresentation: secret))
        case .secureEnclaveP256:
            return NIOSSHPrivateKey(secureEnclaveP256Key: try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: secret))
        }
    }

    func saveSecret(_ value: String, account: String) throws {
        try KeychainStore.write(Data(value.utf8), service: KeychainStore.secretService, account: account)
        secretCache[account] = value
    }

    func secret(account: String) -> String? {
        if let cached = secretCache[account], !cached.isEmpty { return cached }
        do {
            let data = try KeychainStore.read(service: KeychainStore.secretService, account: account)
            let text = String(decoding: data, as: UTF8.self)
            guard !text.isEmpty else { return nil }
            secretCache[account] = text
            return text
        } catch KeyStoreError.status(let status) where status == errSecInteractionNotAllowed {
            return secretCache[account]
        } catch {
            return nil
        }
    }

    func forgetSecret(account: String) {
        secretCache[account] = nil
        KeychainStore.delete(service: KeychainStore.secretService, account: account)
    }

    private func store(kind: PhoneKey.Kind, secret: Data, publicKeyLine: String, label: String) throws {
        guard let line = OpenSSHPublicKey.canonical(publicKeyLine) else { throw KeyStoreError.unusablePublicKey }
        let id = UUID().uuidString
        let record = PhoneKey(
            id: id,
            label: label,
            kind: kind,
            publicKey: line,
            created: Date()
        )
        try KeychainStore.write(secret, service: KeychainStore.keyService, account: id)
        keyMaterial[id] = secret
        if let previous = key {
            keyMaterial[previous.id] = nil
            KeychainStore.delete(service: KeychainStore.keyService, account: previous.id)
        }
        key = record
        let url = directory.appendingPathComponent("phone-key.json")
        if let data = try? JSONEncoder().encode(record) {
            try? data.write(to: url, options: [.atomic, .completeFileProtection])
        }
    }
}
