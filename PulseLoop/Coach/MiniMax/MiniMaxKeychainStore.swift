import Foundation
import Security

/// Stores the user's MiniMax API key in the iOS Keychain (generic password).
/// Mirrors `OpenAIKeychainStore` / `GeminiKeychainStore` / `OpenRouterKeychainStore`
/// but uses a separate service + account so all provider keys can coexist.
struct MiniMaxKeychainStore: APIKeyStore {
    private let service: String
    private let account: String

    // Install-bound: Keychain service/account keep the pre-rename names so stored secrets stay readable.
    init(service: String = "com.pulseloop.coach.minimax", account: String = "minimax_api_key") {
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
