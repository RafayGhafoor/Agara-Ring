import Foundation
import Security

/// Stores the user's Gemini API key in the iOS Keychain (generic password).
/// Mirrors OpenAIKeychainStore but uses a separate service + account so both
/// keys can coexist independently.
struct GeminiKeychainStore: APIKeyStore {
    private let service: String
    private let account: String

    init(service: String = "com.pulseloop.coach.gemini", account: String = "gemini_api_key") {
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

    var hasKey: Bool { ((try? readKey()) ?? nil) != nil }
}
