import Foundation
import Security

/// Stores the **optional** API key for the user's self-hosted server in the iOS Keychain
/// (generic password). Mirrors the other provider stores and uses its own service + account so all
/// provider keys can coexist.
///
/// Optional is the operative word: llama.cpp/vLLM/SGLang only want a key when started with
/// `--api-key`, and Ollama ignores the field entirely. A missing key here is the normal case, not
/// an unconfigured provider — readiness is the base URL (see `CoachClientResolver`).
struct LocalLLMKeychainStore: APIKeyStore {
    private let service: String
    private let account: String

    init(service: String = "com.pulseloop.coach.local", account: String = "local_api_key") {
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
