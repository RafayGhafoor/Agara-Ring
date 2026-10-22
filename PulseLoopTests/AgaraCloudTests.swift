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

// MARK: - Certificate pinning (pre-TestFlight, 2026-10-22)

/// Real certificates (public data), captured 2026-10-22 with `openssl s_client -showcerts` (production + www.apple.com),
/// ISRG Root X1 from the macOS system trust store, and one throwaway self-signed RSA-2048 certificate.
enum PinFixtures {
    static let agaraLeaf = "MIIDkjCCAxigAwIBAgISBmCX9YIVUYTS8+6DKyovh/dRMAoGCCqGSM49BAMDMDMxCzAJBgNVBAYTAlVTMRYwFAYDVQQKEw1MZXQncyBFbmNyeXB0MQwwCgYDVQQDEwNZRTIwHhcNMjYxMDE0MTAyMDAwWhcNMjcwMTEyMTAxOTU5WjAdMRswGQYDVQQDExJhcGkuYWdhcmFoZWFydC5hcHAwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAAR65r3eOaX16DxquDhpwrZy/vQ18ClCWiOKYAtoEsRzJys6+P0nw1Iy542AXF2ZA4Q2/Ss77kbgcm5rvK97NU7Xo4ICIDCCAhwwDgYDVR0PAQH/BAQDAgeAMBMGA1UdJQQMMAoGCCsGAQUFBwMBMAwGA1UdEwEB/wQCMAAwHQYDVR0OBBYEFFlnuR826z3oecLn2BoYiryMXAa1MB8GA1UdIwQYMBaAFLlZ8o7PIvCG0zdI/3YUGLqC2FWHMDMGCCsGAQUFBwEBBCcwJTAjBggrBgEFBQcwAoYXaHR0cDovL3llMi5pLmxlbmNyLm9yZy8wHQYDVR0RBBYwFIISYXBpLmFnYXJhaGVhcnQuYXBwMBMGA1UdIAQMMAowCAYGZ4EMAQIBMC4GA1UdHwQnMCUwI6AhoB+GHWh0dHA6Ly95ZTIuYy5sZW5jci5vcmcvODIuY3JsMIIBDAYKKwYBBAHWeQIEAgSB/QSB+gD4AHUATGPcmOWcHauI9h6KPd6uj6tEozd7X5uUw/uhnPzBviYAAAGhOiKiCAAABAMARjBEAiBPgmoxJNJ/zzZMN1r8qgBZpHmRwXRqGemkuD8wavsiPAIgRPsTsf0YRhLHjp2K0pD9DGBh9lDHsjljS6DqdwVHogwAfwBZbmwzhpSyWXKiVsig6N2QSnboCD3ahzsBCDgoFDzuWQAAAaE6IqJTAAgAAAUADR1gEwQDAEgwRgIhANMhT26vuiKvBLj2bzL4E28gvO4WyfDBqVxQG8/UTQP0AiEA2duUmYw1scMqQwpytSzjaNDwa9xhO8j450ABhJ9LmHkwCgYIKoZIzj0EAwMDaAAwZQIwMITy+ZKW0G/e8HpNqgazGVAU/JUDUOJPwW/0nYTEM14NKt+Y+serDytuzgb6Pn6/AjEA73arU/c8Cyedpw5gSW/5+waigto+TjwxW06LibWN0mnAI3Tb2f2YE41lKJMicymr"
    static let agaraYE2 = "MIICjDCCAhGgAwIBAgIQTfOxXdbAeExQfNN7WObxFTAKBggqhkjOPQQDAzAuMQswCQYDVQQGEwJVUzENMAsGA1UEChMESVNSRzEQMA4GA1UEAxMHUm9vdCBZRTAeFw0yNTA5MDMwMDAwMDBaFw0yODA5MDIyMzU5NTlaMDMxCzAJBgNVBAYTAlVTMRYwFAYDVQQKEw1MZXQncyBFbmNyeXB0MQwwCgYDVQQDEwNZRTIwdjAQBgcqhkjOPQIBBgUrgQQAIgNiAARxmrQzkdbEEL3MqXt3dJQttYc47axkdDTHud5TPqM2z5uSD5cmk0WrHlWXvnlvqBLqiB34kluxIbmMyAiq3/YD6e80/vV259K8XQIdjFXloYOa0mIU71f7HQ09PvYDlw+jge4wgeswDgYDVR0PAQH/BAQDAgGGMBMGA1UdJQQMMAoGCCsGAQUFBwMBMBIGA1UdEwEB/wQIMAYBAf8CAQAwHQYDVR0OBBYEFLlZ8o7PIvCG0zdI/3YUGLqC2FWHMB8GA1UdIwQYMBaAFKPIJlqOoUzQNWP8myPIOq5W809WMDIGCCsGAQUFBwEBBCYwJDAiBggrBgEFBQcwAoYWaHR0cDovL3llLmkubGVuY3Iub3JnLzATBgNVHSAEDDAKMAgGBmeBDAECATAnBgNVHR8EIDAeMBygGqAYhhZodHRwOi8veWUuYy5sZW5jci5vcmcvMAoGCCqGSM49BAMDA2kAMGYCMQDIcnw5dcZLN9ffynXnnkLD/itSJEycJPb3sRkzeqBowup7vOsAwaqoCnNn/jh9wycCMQCJM6CPlaOC4pQYYbJtVPYbDKrIb2EKk5NpOpE6/XttQYZV/3gilB9l+Cc/DOVwmyg="
    static let agaraRootYE = "MIICpjCCAiugAwIBAgIRAIchZfw0tuX7qK3Vs3BftTowCgYIKoZIzj0EAwMwTzELMAkGA1UEBhMCVVMxKTAnBgNVBAoTIEludGVybmV0IFNlY3VyaXR5IFJlc2VhcmNoIEdyb3VwMRUwEwYDVQQDEwxJU1JHIFJvb3QgWDIwHhcNMjYwNTEzMDAwMDAwWhcNMzIwOTAyMjM1OTU5WjAuMQswCQYDVQQGEwJVUzENMAsGA1UEChMESVNSRzEQMA4GA1UEAxMHUm9vdCBZRTB2MBAGByqGSM49AgEGBSuBBAAiA2IABDwS/6vhrcVqcbBo+wgdI3fwn9x7DNJJOY/lTOti0vkwuRN87RhEhTH17E7XyFjWsPYhIPt/wzOqxTd2b+4ZJNy9ID04YywF9U5zasDVyGSNErVNtz8uSGh5izW87j77GaOB6zCB6DAOBgNVHQ8BAf8EBAMCAQYwEwYDVR0lBAwwCgYIKwYBBQUHAwEwDwYDVR0TAQH/BAUwAwEB/zAdBgNVHQ4EFgQUo8gmWo6hTNA1Y/ybI8g6rlbzT1YwHwYDVR0jBBgwFoAUfEKWrt5LSDv6kviejM9ti6lyN5UwMgYIKwYBBQUHAQEEJjAkMCIGCCsGAQUFBzAChhZodHRwOi8veDIuaS5sZW5jci5vcmcvMBMGA1UdIAQMMAowCAYGZ4EMAQIBMCcGA1UdHwQgMB4wHKAaoBiGFmh0dHA6Ly94Mi5jLmxlbmNyLm9yZy8wCgYIKoZIzj0EAwMDaQAwZgIxAMU19WCtmxVND8UHBZRoma49Z7jPs64Dma0eTu1OChVbB/2J7GV3nvYKAx54uk1G9QIxAO0miLVJu8PLNiXXXkiE/gsK3CTRTF/aeo4bMX42Zw40csRU6AC26hSW1/IWaas6dg=="
    static let isrgX2 = "MIIEcDCCAligAwIBAgIQbI8dxyfHEX97r4U6yYD5zTANBgkqhkiG9w0BAQsFADBPMQswCQYDVQQGEwJVUzEpMCcGA1UEChMgSW50ZXJuZXQgU2VjdXJpdHkgUmVzZWFyY2ggR3JvdXAxFTATBgNVBAMTDElTUkcgUm9vdCBYMTAeFw0yNjA1MTMwMDAwMDBaFw0zMjA5MDIyMzU5NTlaME8xCzAJBgNVBAYTAlVTMSkwJwYDVQQKEyBJbnRlcm5ldCBTZWN1cml0eSBSZXNlYXJjaCBHcm91cDEVMBMGA1UEAxMMSVNSRyBSb290IFgyMHYwEAYHKoZIzj0CAQYFK4EEACIDYgAEzZvVn4CDCuwJSvMWSj5cz3es3mcFDR0HttwW+1qLFNvicWDEukWVEYmO6gbf9yoWHKS5xcUy4APgHoIYOIvXRdgKam7mAHf7AlF9ItgKbppbd9/w+kHsOdx1ymgHDB/qo4H1MIHyMA4GA1UdDwEB/wQEAwIBBjAdBgNVHSUEFjAUBggrBgEFBQcDAQYIKwYBBQUHAwIwDwYDVR0TAQH/BAUwAwEB/zAdBgNVHQ4EFgQUfEKWrt5LSDv6kviejM9ti6lyN5UwHwYDVR0jBBgwFoAUebRZ5nu25eQBc4AIiMgaWPbpm24wMgYIKwYBBQUHAQEEJjAkMCIGCCsGAQUFBzAChhZodHRwOi8veDEuaS5sZW5jci5vcmcvMBMGA1UdIAQMMAowCAYGZ4EMAQIBMCcGA1UdHwQgMB4wHKAaoBiGFmh0dHA6Ly94MS5jLmxlbmNyLm9yZy8wDQYJKoZIhvcNAQELBQADggIBAD2/e9frmMxNpCV03qUHegg+MV2wz9644YoXdqtH8RyWYcBO7xfjjGEXdU1e/o0OkEFiynUCOSIk/vLLo7ttz6CPAeNlWfC0XNkoGeWgK6jjXvozBaGuGH5n0UfoshMeWTuURqNN5G00sSXDTBrpp2+mgvdZQjb8K11TYMA25QA+YHNfbIEL0BniAhKS2gsnJjSzrdZLI+EZ7SEyqdR2rkjd1KutLDU+n3TFyxjniZVGur4YlhMP3mY/dV95IruAkkjOZier6hGBdEgZXXvaCz9u9iVEadsIE75pAGL8oHV5vxdARDiotRpul1IN/UZwzAbrfUFcw1HkAcYD/mlZfnQ2ieCF2MS7j3Vhv7JPDKp45fmykmzYNSrumRW0upFFKDBOoF7hsOb7oLyHS+Uft6jOUfOrogj8YUx38hKb2K20r42OgsSdDdxdeYWcMS3Sb6mwJeSZEYxJ2gaXnDSPaKhhrNkYwljyVQyr4Nq+MEJytXNTnHqaAcrNwZlVpcJL1KBnMrMjP7eanvUwL3FYj3cF17jtboLt7gLoi4+2rWZFvn+w54jmd/FIuhhZcEaU/wvU6BUNMtcVquVGHp7itQeDth5j+XL3j4WJ2SABwzUl6OeYdgpIt/ITZa+pTT0mQ/r5XyA4MEAiabn7XJjvCERlF2dcn2wqJw+CreTkkQ2R"
    static let appleLeaf = "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"
    static let appleCA = "MIIFHjCCBAagAwIBAgIQBPIuzCH8tDgqwouPLWQfwDANBgkqhkiG9w0BAQsFADBhMQswCQYDVQQGEwJVUzEVMBMGA1UEChMMRGlnaUNlcnQgSW5jMRkwFwYDVQQLExB3d3cuZGlnaWNlcnQuY29tMSAwHgYDVQQDExdEaWdpQ2VydCBHbG9iYWwgUm9vdCBHMjAeFw0yMDA0MjkxMjU1MzRaFw0zMDA0MTAyMzU5NTlaMFExCzAJBgNVBAYTAlVTMRMwEQYDVQQKEwpBcHBsZSBJbmMuMS0wKwYDVQQDEyRBcHBsZSBQdWJsaWMgRVYgU2VydmVyIFJTQSBDQSAxIC0gRzEwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQDfn5fdV0A4cCNFu0EvUgduZVPyPZity4q8Re1TcE9qGyWoVpzHm9OluDlqwcvudbLwBe25PWA2Z9xFpVKK9jGW6Vt79N7if7dfi9w2+2zG+/wJu1Z6TA8RENTVuJTaMwqQXw1dTkZEOgjCEKa75uyzXl+mIa0s4GdxkCBclGI9WDsUFlLj3A6eBIzeTomTl7LhIV+nQUEWTqkwG5Pcxckiv7Xn1mu7EVWUukZWY8uL+KhcTJQZYtxNj3PeM73WZ3fraixPA+RBkVnG5NgObRnrk5VHwjntbit9892kp7EISZK4Izfm99QgP4V2IqHFsKxfCnZqfwUHikxftIVkjXIdAgMBAAGjggHgMIIB3DAdBgNVHQ4EFgQU073BPKDPNbk0xdTb2hAOTN5q/lgwHwYDVR0jBBgwFoAUTiJUIBiV5uNu5g/6+rkS7QYXjzkwDgYDVR0PAQH/BAQDAgGGMB0GA1UdJQQWMBQGCCsGAQUFBwMBBggrBgEFBQcDAjASBgNVHRMBAf8ECDAGAQH/AgEAMDQGCCsGAQUFBwEBBCgwJjAkBggrBgEFBQcwAYYYaHR0cDovL29jc3AuZGlnaWNlcnQuY29tMEIGA1UdHwQ7MDkwN6A1oDOGMWh0dHA6Ly9jcmwzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydEdsb2JhbFJvb3RHMi5jcmwwgdwGA1UdIASB1DCB0TCBxQYJYIZIAYb9bAIBMIG3MCgGCCsGAQUFBwIBFhxodHRwczovL3d3dy5kaWdpY2VydC5jb20vQ1BTMIGKBggrBgEFBQcCAjB+DHxBbnkgdXNlIG9mIHRoaXMgQ2VydGlmaWNhdGUgY29uc3RpdHV0ZXMgYWNjZXB0YW5jZSBvZiB0aGUgUmVseWluZyBQYXJ0eSBBZ3JlZW1lbnQgbG9jYXRlZCBhdCBodHRwczovL3d3dy5kaWdpY2VydC5jb20vcnBhLXVhMAcGBWeBDAEBMA0GCSqGSIb3DQEBCwUAA4IBAQBD9c6SmtMxGjRwc/A1bPiM+r1qj5xbDzGn6s6m6oggm9UeBLCSUNJthKffNPqqwtULeeUddssewaOZX+uHjG9bY/O9J1VQtGtXI2hndyAPiloqNjf5iBW16h3ZIUFQL319hISioItFVJZnVe4gjNEWio1ZRwO5A4e/H69/lPAX294yGtYGllAdv2NexhUMfjODhCajoTJmkXbyIpYzTNkgDXvQptTecrvr0rPzEMWfTtGSppbOC+s/5jG3aJ6GJn49Ram1ZLEGHTx9PWUoHth9Lj7vwFBD9667x9m9nUhuET9a3XvNep+N7w96ZqH2fAqUBW1kl6u3u67D6mvDsCQr"
    static let selfSigned = "MIIC+jCCAeKgAwIBAgIUVuvFKWw6L6pj4VLQZTS1t+2tMhgwDQYJKoZIhvcNAQELBQAwHTEbMBkGA1UEAwwSYXBpLmFnYXJhaGVhcnQuYXBwMB4XDTI2MTAyMjE0MDk0NloXDTM2MTAxOTE0MDk0NlowHTEbMBkGA1UEAwwSYXBpLmFnYXJhaGVhcnQuYXBwMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA44gEfv2TDEMewZo4AzKKqwlS97BiCiXc4JcafiQthiEzx0RhONxmR2M1UFFILZWRtwI5as3Agxd+3l1w0pupV6P6byPsmknZ2dan257e/8lHYcf4SbsYmkeHc6gDM8EP507PCeP9Q+t3laI1fbUoXLD/CmJHejx+LDNeikHMx7PDBrCWg2Jl4MT02dcEPoHQWAb+LRAW8XJMlah7XUIneSwXXVIwj6exvbrUnrMKOuAtbBgBXAmZLZy4x/8ZKlqmdhFfjS3SA6FgRy1E4V4/+iNXg8i4vLuw8Nh9KP8QlROPuB4Z/Esd8HhoD2dIfCplGo/J0a/dCPU+GwCcpT3n+wIDAQABozIwMDAdBgNVHQ4EFgQU/6jXJ2mZRoriMd92TMTYBLz+GjcwDwYDVR0TAQH/BAUwAwEB/zANBgkqhkiG9w0BAQsFAAOCAQEAwnNcIGMegW5ttP84yLFMnVzCGHj2YeRZPKUs4ZlTGN9/c9foz2LeK5xZ8O9ma763B+m6cfgLRRCn/z9MMt13qorGryB7YlgHHX7qdJeVtuRoeE5lXBitXd3A/lGk3bMLhi9WU/syHojvvbWCe1YMG22S9e8m7DYIUTEXqFljLcJ3DU7URLM1KRKHP0SVeimibpXzLDwsmPcr1Xin8j+S2OPT6YfQItVgDd7p85qVmz9XahqMkdqwhnZMWMTz7NBoG4ofLi8ess9J7cTHyEDBAIltYfqTFK3FnLELmNkhWOEMyqTaOdS0Iup/Zhr6oh4MIpZtUmRhV0B9P7D75udfSA=="
    static let isrgX1 = "MIIFazCCA1OgAwIBAgIRAIIQz7DSQONZRGPgu2OCiwAwDQYJKoZIhvcNAQELBQAwTzELMAkGA1UEBhMCVVMxKTAnBgNVBAoTIEludGVybmV0IFNlY3VyaXR5IFJlc2VhcmNoIEdyb3VwMRUwEwYDVQQDEwxJU1JHIFJvb3QgWDEwHhcNMTUwNjA0MTEwNDM4WhcNMzUwNjA0MTEwNDM4WjBPMQswCQYDVQQGEwJVUzEpMCcGA1UEChMgSW50ZXJuZXQgU2VjdXJpdHkgUmVzZWFyY2ggR3JvdXAxFTATBgNVBAMTDElTUkcgUm9vdCBYMTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAK3oJHP0FDfzm54rVygch77ct984kIxuPOZXoHj3dcKi/vVqbvYATyjb3miGbESTtrFj/RQSa78f0uoxmyF+0TM8ukj13Xnfs7j/EvEhmkvBioZxaUpmZmyPfjxwv60pIgbz5MDmgK7iS4+3mX6UA5/TR5d8mUgjU+g4rk8Kb4Mu0UlXjIB0ttov0DiNewNwIRt18jA8+o+u3dpjq+sWT8KOEUt+zwvo/7V3LvSye0rgTBIlDHCNAymg4VMk7BPZ7hm/ELNKjD+Jo2FR3qyHB5T0Y3HsLuJvW5iB4YlcNHlsdu87kGJ55tukmi8mxdAQ4Q7e2RCOFvu396j3x+UCB5iPNgiV5+I3lg02dZ77DnKxHZu8A/lJBdiB3QW0KtZB6awBdpUKD9jf1b0SHzUvKBds0pjBqAlkd25HN7rOrFleaJ1/ctaJxQZBKT5ZPt0m9STJEadao0xAH0ahmbWnOlFuhjuefXKnEgV4We0+UXgVCwOPjdAvBbI+e0ocS3MFEvzG6uBQE3xDk3SzynTnjh8BCNAw1FtxNrQHusEwMFxIt4I7mKZ9YIqioymCzLq9gwQbooMDQaHWBfEbwrbwqHyGO0aoSCqI3Haadr8faqU9GY/rOPNk3sgrDQoo//fb4hVC1CLQJ13hef4Y53CIrU7m2Ys6xt0nUW7/vGT1M0NPAgMBAAGjQjBAMA4GA1UdDwEB/wQEAwIBBjAPBgNVHRMBAf8EBTADAQH/MB0GA1UdDgQWBBR5tFnme7bl5AFzgAiIyBpY9umbbjANBgkqhkiG9w0BAQsFAAOCAgEAVR9YqbyyqFDQDLHYGmkgJykIrGF1XIpu+ILlaS/V9lZLubhzEFnTIZd+50xx+7LSYK05qAvqFyFWhfFQDlnrzuBZ6brJFe+GnY+EgPbk6ZGQ3BebYhtF8GaV0nxvwuo77x/Py9auJ/GpsMiu/X1+mvoiBOv/2X/qkSsisRcOj/KKNFtY2PwByVS5uCbMiogziUwthDyC3+6WVwW6LLv3xLfHTjuCvjHIInNzktHCgKQ5ORAzI4JMPJ+GslWYHb4phowim57iaztXOoJwTdwJx4nLCgdNbOhdjsnvzqvHu7UrTkXWStAmzOVyyghqpZXjFaH3pO3JLF+l+/+sKAIuvtd7u+Nxe5AW0wdeRlN8NwdCjNPElpzVmbUq4JUagEiuTDkHzsxHpFKVK7q4+63SM1N95R1NbdWhscdCb+ZAJzVcoyi3B43njTOQ5yOf+1CceWxG1bQVs5ZufpsMljq4Ui0/1lvh+wjChP4kqKOJ2qxq4RgqsahDYVvTH9w7jXbyLeiNdd8XM2w9U/t7y0Ff/9yi0GE44Za4rF2LN9d11TPAmRGunUHBcnWEvgJBQl9nJEiU0Zsnvgc/ubhPgXRR4Xq37Z0j4r7g1SgEEzwxA57demyPxgcYxn/eR44/KJ4EBs+lVDR3veyJm+kXQ99b21/+jh5Xos1AnX5iItreGCc="
}

final class CloudPinningTests: XCTestCase {
    private func cert(_ base64: String) throws -> SecCertificate {
        try XCTUnwrap(SecCertificateCreateWithData(nil, try XCTUnwrap(Data(base64Encoded: base64)) as CFData))
    }

    /// The SPKI encoding for every key type the pins use, checked against what `openssl … | dgst -sha256` printed —
    /// not against this code's own output.
    func testSpkiHashesMatchOpenSSLForEveryKeyType() throws {
        let expected: [(String, String, String)] = [
            (PinFixtures.agaraLeaf, "a0PDeCgndpXCeM7dTwbJThisom9spSazk8alAoY/Oho=", "EC P-256 leaf"),
            (PinFixtures.agaraYE2, "s/tdAOmUzd8syaTuqfgGvFcn6DzA5Cmb+Vby1ST+U3Y=", "EC P-384 intermediate"),
            (PinFixtures.agaraRootYE, "sCkq5UWXjg+7mKu9lMhhYF5bGLsy7VI/UNW3tccdR7w=", "ISRG Root YE"),
            (PinFixtures.isrgX2, "diGVwiVYbubAI3RW4hB9xU8e/CH2GnkuvVFZE8zmgzI=", "ISRG Root X2"),
            (PinFixtures.isrgX1, "C5+lpZ7tcVwmwQIMcRtPbsQtWLABXhQzejna0wHFr8M=", "ISRG Root X1 (RSA 4096)"),
            (PinFixtures.appleLeaf, "Y4IXG8Fr0usWRIkGqnw30wN1W7aRBNVbnhizvQ2tlXI=", "RSA 2048 leaf"),
            (PinFixtures.selfSigned, "si0y0EE3fvxjbpVb7KciST3tpmac+gxt4690evPYIOk=", "RSA 2048 self-signed"),
        ]
        for (base64, hash, label) in expected {
            XCTAssertEqual(CloudPinning.spkiSHA256(of: try cert(base64)), hash, label)
        }
    }

    func testTheCatalogPinsTheRootsAndNothingThatRotates() {
        XCTAssertEqual(CloudPinning.pinnedHost, "api.agaraheart.app")
        XCTAssertEqual(CloudPinning.pins.count, 5)
        XCTAssertTrue(CloudPinning.pins.isSuperset(of: ["C5+lpZ7tcVwmwQIMcRtPbsQtWLABXhQzejna0wHFr8M=",
                                                        "diGVwiVYbubAI3RW4hB9xU8e/CH2GnkuvVFZE8zmgzI="]))
        XCTAssertFalse(CloudPinning.pins.contains("a0PDeCgndpXCeM7dTwbJThisom9spSazk8alAoY/Oho="), "never the 90-day leaf")
        XCTAssertFalse(CloudPinning.pins.contains("s/tdAOmUzd8syaTuqfgGvFcn6DzA5Cmb+Vby1ST+U3Y="), "never an intermediate")
        XCTAssertNotNil(CloudPinning.expiry)
    }

    func testOnlyTheAgaraHostIsPinnedAndOnlyUntilTheExpiry() throws {
        let expiry = try XCTUnwrap(CloudPinning.expiry)
        XCTAssertTrue(CloudPinning.isEnforced(host: "api.agaraheart.app", now: expiry.addingTimeInterval(-60)))
        XCTAssertTrue(CloudPinning.isEnforced(host: "API.AgaraHeart.app", now: expiry.addingTimeInterval(-60)))
        XCTAssertFalse(CloudPinning.isEnforced(host: "api.agaraheart.app", now: expiry.addingTimeInterval(60)),
                       "past the expiry an old install falls back to normal TLS instead of being locked out")
        for other in ["identitytoolkit.googleapis.com", "securetoken.googleapis.com", "127.0.0.1", "api.agaraheart.app.evil.com"] {
            XCTAssertFalse(CloudPinning.isEnforced(host: other, now: expiry.addingTimeInterval(-60)), other)
        }
    }

    /// Full decisions on real chains, at a date inside every certificate's validity (fixtures expire).
    private func trust(_ chain: [String], host: String) throws -> SecTrust {
        var trust: SecTrust?
        let certificates = try chain.map(cert) as CFArray
        XCTAssertEqual(SecTrustCreateWithCertificates(certificates, SecPolicyCreateSSL(true, host as CFString), &trust), errSecSuccess)
        let t = try XCTUnwrap(trust)
        SecTrustSetVerifyDate(t, Date(timeIntervalSince1970: 1_793_000_000) as CFDate)   // 2026-10-26
        return t
    }

    func testProductionsRealChainIsAccepted() throws {
        let t = try trust([PinFixtures.agaraLeaf, PinFixtures.agaraYE2, PinFixtures.agaraRootYE], host: "api.agaraheart.app")
        XCTAssertEqual(CloudPinning.evaluate(trust: t, host: "api.agaraheart.app", now: Date(timeIntervalSince1970: 1_793_000_000)), .accept)
    }

    /// The case pinning exists for: a chain every phone trusts (a public CA, valid, right shape) that is NOT ours —
    /// what a compromised or coerced CA, or a corporate TLS-inspection root, would present.
    func testAValidChainFromAnotherCAIsRejected() throws {
        let pins = CloudPinning.pins
        // www.apple.com's chain is valid for www.apple.com; pretend that is the pinned host.
        let t = try trust([PinFixtures.appleLeaf, PinFixtures.appleCA], host: "www.apple.com")
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        XCTAssertTrue(SecTrustEvaluateWithError(t, nil), "precondition: the system itself trusts this chain")
        XCTAssertEqual(CloudPinning.evaluate(trust: t, host: "www.apple.com", now: now, pins: pins,
                                             pinnedHost: "www.apple.com", expiry: now.addingTimeInterval(86_400)), .reject)
    }

    func testASelfSignedCertificateForOurNameIsRejected() throws {
        let t = try trust([PinFixtures.selfSigned], host: "api.agaraheart.app")
        XCTAssertEqual(CloudPinning.evaluate(trust: t, host: "api.agaraheart.app", now: Date(timeIntervalSince1970: 1_793_000_000)), .reject)
    }

    func testAChainCutBelowThePinnedRootsDoesNotMatch() throws {
        XCTAssertFalse(CloudPinning.chainMatches([try cert(PinFixtures.agaraLeaf), try cert(PinFixtures.agaraYE2)],
                                                 pins: CloudPinning.pins))
        XCTAssertTrue(CloudPinning.chainMatches([try cert(PinFixtures.agaraLeaf), try cert(PinFixtures.isrgX2)],
                                                pins: CloudPinning.pins))
    }
}

/// Live, opt-in (`TEST_RUNNER_LIVE_PIN=1 xcodebuild test …`): the real pinned session against production over real TLS —
/// proves the delegate path and that the chain iOS builds for api.agaraheart.app ends in a pinned key.
final class CloudPinningLiveTests: XCTestCase {
    func testThePinnedSessionReachesProduction() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LIVE_PIN"] == "1", "live network test; set TEST_RUNNER_LIVE_PIN=1")
        let url = try XCTUnwrap(URL(string: AgaraConfig.Cloud.v2BaseUrl + "/api/health"))
        let response = try await URLSessionCloudTransport().send(CloudRequest(method: "GET", url: url))
        XCTAssertEqual(response.status, 200)
    }
}
