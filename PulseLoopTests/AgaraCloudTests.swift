import Security
import XCTest
@testable import PulseLoop

/// The Keychain plumbing under the Agara Cloud session (release 1.1). The v1 PocketBase client, its settings screen and
/// its tests are gone (the cloud never shipped in 1.0); the auth, sync and center suites are `AgaraAuthClientTests`,
/// `AgaraSyncEngineTests` and `AgaraCloudCenterTests`.
@MainActor
final class AgaraKeychainTests: XCTestCase {

    // MARK: Real Keychain (the unit tests run hosted in the app, so the simulator Keychain is available)

    private let service = "com.agara.tests.keychain-\(UUID().uuidString)"

    private func accessibility(account: String, service override: String? = nil) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: override ?? service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == -34018 { throw XCTSkip("no Keychain entitlement in this test host") }
        XCTAssertEqual(status, errSecSuccess)
        return (item as? [String: Any])?[kSecAttrAccessible as String] as? String
    }

    func testKeychainItemsAreThisDeviceOnly() throws {
        do {
            try KeychainItem.writeString("secret", service: service, account: "a")
        } catch KeychainError.unexpectedStatus(-34018) {
            throw XCTSkip("no Keychain entitlement in this test host")
        }
        XCTAssertEqual(try KeychainItem.readString(service: service, account: "a"), "secret")
        XCTAssertEqual(try accessibility(account: "a"), kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        try KeychainItem.delete(service: service, account: "a")
        XCTAssertNil(try KeychainItem.readString(service: service, account: "a"))
    }

    func testOldAccessibilityItemIsMigratedOnRead() throws {
        let insert: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "a",
            kSecValueData as String: Data("legacy".utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemAdd(insert as CFDictionary, nil)
        if status == -34018 { throw XCTSkip("no Keychain entitlement in this test host") }
        XCTAssertEqual(status, errSecSuccess)
        XCTAssertEqual(try accessibility(account: "a"), kSecAttrAccessibleAfterFirstUnlock as String)

        XCTAssertEqual(try KeychainItem.readString(service: service, account: "a"), "legacy")

        XCTAssertEqual(try accessibility(account: "a"), kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertEqual(try KeychainItem.readString(service: service, account: "a"), "legacy")
        try KeychainItem.delete(service: service, account: "a")
    }

    func testKeychainAuthStoreRoundTripsAndIsThisDeviceOnly() throws {
        let service = "com.agara.tests.authstore-\(UUID().uuidString)"
        let store = AgaraKeychainAuthStore(service: service)
        let session = AgaraAuthSession(uid: "u1", email: "a@b.co", idToken: "id", refreshToken: "rt",
                                       expiresAt: Date(timeIntervalSince1970: 1_790_000_000), emailVerified: true)
        store.save(session)
        guard store.load() != nil else { throw XCTSkip("Keychain unavailable in this test host") }
        XCTAssertEqual(store.load(), session)
        XCTAssertEqual(try accessibility(account: "session", service: service), kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        store.clear()
        XCTAssertNil(store.load())
    }
}
