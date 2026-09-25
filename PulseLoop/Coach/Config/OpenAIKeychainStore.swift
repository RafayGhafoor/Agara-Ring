import Foundation
import Security

/// Abstraction over the secret store so the coach can later swap a Keychain key
/// for a backend-proxy token without touching call sites.
protocol APIKeyStore {
    func readKey() throws -> String?
    func saveKey(_ key: String) throws
    func deleteKey() throws
}

enum KeychainError: Error, LocalizedError {
    case unexpectedStatus(OSStatus)
    case dataEncoding

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            return "Keychain error (status \(status))."
        case .dataEncoding:
            return "Could not encode the key for storage."
        }
    }
}

/// Shared generic-password plumbing for every Keychain item the app keeps (provider keys, Strava tokens,
/// the cloud session). Items are `AfterFirstUnlockThisDeviceOnly`: readable by background sync after the
/// first unlock, but never copied into a backup or migrated to another device. Items written before that
/// change (plain `AfterFirstUnlock`) are moved to the new class the first time they are read or written.
nonisolated enum KeychainItem {
    static let accessibility = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

    private static func query(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// The item's data, or nil when absent. Migrates an item still in an older accessibility class.
    static func read(service: String, account: String) throws -> Data? {
        var lookup = query(service: service, account: account)
        lookup[kSecReturnData as String] = true
        lookup[kSecReturnAttributes as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        guard let attributes = item as? [String: Any], let data = attributes[kSecValueData as String] as? Data else {
            return nil
        }
        if let current = attributes[kSecAttrAccessible as String] as? String, current != accessibility as String {
            try? write(data, service: service, account: account)
        }
        return data
    }

    /// Upsert the item, always in `accessibility`.
    static func write(_ data: Data, service: String, account: String) throws {
        let base = query(service: service, account: account)
        let update: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: accessibility]
        let updateStatus = SecItemUpdate(base as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound {
            // Some keychains refuse to change the accessibility class in place: replace the item instead.
            SecItemDelete(base as CFDictionary)
        }
        var insert = base
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = accessibility
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
    }

    static func delete(service: String, account: String) throws {
        let status = SecItemDelete(query(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// A trimmed, non-empty UTF-8 string, or nil.
    static func readString(service: String, account: String) throws -> String? {
        guard let data = try read(service: service, account: account),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func writeString(_ text: String, service: String, account: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8) else { throw KeychainError.dataEncoding }
        try write(data, service: service, account: account)
    }
}

/// Stores the user's OpenAI API key in the iOS Keychain (generic password).
/// The key is never written to UserDefaults or embedded in the binary.
struct OpenAIKeychainStore: APIKeyStore {
    private let service: String
    private let account: String

    init(service: String = "com.pulseloop.coach.openai", account: String = "openai_api_key") {
        self.service = service
        self.account = account
    }

    func readKey() throws -> String? {
        try KeychainItem.readString(service: service, account: account)
    }

    func saveKey(_ key: String) throws {
        try KeychainItem.writeString(key, service: service, account: account)
    }

    func deleteKey() throws {
        try KeychainItem.delete(service: service, account: account)
    }

    var hasKey: Bool {
        ((try? readKey()) ?? nil) != nil
    }
}
