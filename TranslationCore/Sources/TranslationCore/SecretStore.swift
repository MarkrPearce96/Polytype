import Foundation
import Security

public let deepLKeyName = "deepl-api-key"
public let googleKeyName = "google-api-key"

public protocol SecretStore: Sendable {
    func get(_ key: String) -> String?
    func set(_ value: String?, for key: String)
}

/// Thread-safe in-memory store for tests and no-key runs.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private var storage: [String: String] = [:]
    private let lock = NSLock()
    public init() {}
    public func get(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[key]
    }
    public func set(_ value: String?, for key: String) {
        lock.lock(); defer { lock.unlock() }
        if let value { storage[key] = value } else { storage[key] = nil }
    }
}

/// Keychain-backed store (generic password). Verified manually in the app.
public final class KeychainSecretStore: SecretStore, @unchecked Sendable {
    private let service: String
    public init(service: String = "com.typetranslator.secrets") { self.service = service }

    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }

    public func get(_ key: String) -> String? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func set(_ value: String?, for key: String) {
        SecItemDelete(query(key) as CFDictionary)
        guard let value, let data = value.data(using: .utf8) else { return }
        var q = query(key)
        q[kSecValueData as String] = data
        SecItemAdd(q as CFDictionary, nil)
    }
}
