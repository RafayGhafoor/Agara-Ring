import Foundation
import Security

/// OAuth token bundle persisted for the connected Strava athlete.
nonisolated struct StravaTokens: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var athleteId: Int
    var athleteName: String
}

/// Abstraction over the Strava token store so services (and tests) can swap the
/// Keychain for an in-memory stub. Nonisolated: Keychain calls are synchronous
/// and thread-safe, and sync services run off the main actor.
nonisolated protocol StravaTokenStoring: Sendable {
    func read() throws -> StravaTokens?
    func save(_ tokens: StravaTokens) throws
    func delete() throws
}

/// Stores the Strava OAuth tokens as a single JSON-encoded generic-password
/// item in the iOS Keychain. Tokens are never written to UserDefaults.
nonisolated struct StravaKeychainTokenStore: StravaTokenStoring {
    private let service: String
    private let account: String

    // Install-bound: Keychain service/account keep the pre-rename names so stored secrets stay readable.
    init(service: String = "com.pulseloop.strava", account: String = "oauth_tokens") {
        self.service = service
        self.account = account
    }

    func read() throws -> StravaTokens? {
        guard let data = try KeychainItem.read(service: service, account: account) else { return nil }
        return try? Self.decoder.decode(StravaTokens.self, from: data)
    }

    func save(_ tokens: StravaTokens) throws {
        let data: Data
        do {
            data = try Self.encoder.encode(tokens)
        } catch {
            throw KeychainError.dataEncoding
        }
        try KeychainItem.write(data, service: service, account: account)
    }

    func delete() throws {
        try KeychainItem.delete(service: service, account: account)
    }

    // Epoch-seconds dates so the blob stays stable across encoder defaults.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}
