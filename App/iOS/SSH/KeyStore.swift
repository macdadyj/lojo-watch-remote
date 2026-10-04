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
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
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

    var errorDescription: String? { description }

    var description: String {
        switch self {
        case .status(let status): return "Keychain error \(status)"
        case .missing: return "That secret is not in the Keychain"
        case .secureEnclaveUnavailable: return "Secure Enclave is not available on this device"
        }
    }
}

@MainActor
final class KeyStore: ObservableObject {
    @Published private(set) var key: PhoneKey?
    private let directory: URL

    init(directory: URL) {
        self.directory = directory
        let url = directory.appendingPathComponent("phone-key.json")
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(PhoneKey.self, from: data) {
            key = saved
        }
    }

    var secureEnclaveAvailable: Bool { SecureEnclave.isAvailable }

    func generateEd25519() throws {
        let raw = Curve25519.Signing.PrivateKey()
        let ssh = NIOSSHPrivateKey(ed25519Key: raw)
        try store(kind: .ed25519, secret: raw.rawRepresentation, ssh: ssh, label: "Watch Remote")
    }

    func generateSecureEnclave() throws {
        guard SecureEnclave.isAvailable else { throw KeyStoreError.secureEnclaveUnavailable }
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .privateKeyUsage, &error
        ) else {
            throw error?.takeRetainedValue() ?? KeyStoreError.secureEnclaveUnavailable
        }
        let enclave = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
        let ssh = NIOSSHPrivateKey(secureEnclaveP256Key: enclave)
        try store(kind: .secureEnclaveP256, secret: enclave.dataRepresentation, ssh: ssh, label: "Watch Remote")
    }

    func privateKey() throws -> NIOSSHPrivateKey {
        guard let key else { throw KeyStoreError.missing }
        let secret = try KeychainStore.read(service: KeychainStore.keyService, account: key.id)
        switch key.kind {
        case .ed25519:
            return NIOSSHPrivateKey(ed25519Key: try Curve25519.Signing.PrivateKey(rawRepresentation: secret))
        case .secureEnclaveP256:
            return NIOSSHPrivateKey(secureEnclaveP256Key: try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: secret))
        }
    }

    func saveSecret(_ value: String, account: String) throws {
        try KeychainStore.write(Data(value.utf8), service: KeychainStore.secretService, account: account)
    }

    func secret(account: String) -> String? {
        guard let data = try? KeychainStore.read(service: KeychainStore.secretService, account: account) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        return text.isEmpty ? nil : text
    }

    func forgetSecret(account: String) {
        KeychainStore.delete(service: KeychainStore.secretService, account: account)
    }

    private func store(kind: PhoneKey.Kind, secret: Data, ssh: NIOSSHPrivateKey, label: String) throws {
        let id = UUID().uuidString
        let record = PhoneKey(
            id: id,
            label: label,
            kind: kind,
            publicKey: String(openSSHPublicKey: ssh.publicKey) + " watch-remote@iphone",
            created: Date()
        )
        try KeychainStore.write(secret, service: KeychainStore.keyService, account: id)
        if let previous = key {
            KeychainStore.delete(service: KeychainStore.keyService, account: previous.id)
        }
        key = record
        let url = directory.appendingPathComponent("phone-key.json")
        if let data = try? JSONEncoder().encode(record) {
            try? data.write(to: url, options: [.atomic, .completeFileProtection])
        }
    }
}
