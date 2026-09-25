import Foundation
import Security

/// Stores the user's OpenRouter API key in the iOS Keychain (generic password).
/// Mirrors `OpenAIKeychainStore` / `GeminiKeychainStore` but uses a separate
/// service + account so all provider keys can coexist independently.
struct OpenRouterKeychainStore: APIKeyStore {
    private let service: String
    private let account: String

    init(service: String = "com.pulseloop.coach.openrouter", account: String = "openrouter_api_key") {
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
