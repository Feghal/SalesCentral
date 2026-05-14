import XCTest
@testable import SalesCentral

/// Smoke tests covering the parts that don't need a real server.
final class SalesCentralTests: XCTestCase {

    func testTokenURLComposition() throws {
        let config = SalesConfig(
            baseURL: URL(string: "https://sales.example.com")!,
            apiKey: "csk_xyz",
            tokens: .init(
                createOrFetchUser:   "111111111111",
                restoreUser:         "222222222222",
                applyPurchases:      "333333333333",
                currentSubscription: "444444444444",
                spendCredits:        "555555555555",
                recordSession:       "666666666666",
                recordEvent:         "777777777777"
            )
        )
        XCTAssertEqual(config.url(for: .createOrFetchUser).absoluteString,
                       "https://sales.example.com/111111111111")
        XCTAssertEqual(config.url(for: .recordEvent).absoluteString,
                       "https://sales.example.com/777777777777")
    }

    func testTokenStoreRoundtrip() {
        let store = InMemoryTokenStore()
        XCTAssertNil(store.read())
        store.write("eyJ-test")
        XCTAssertEqual(store.read(), "eyJ-test")
        store.clear()
        XCTAssertNil(store.read())
    }

    /// `KeychainTokenStore` shadows the JWT in UserDefaults so an app
    /// transfer (which leaves the new build unable to read the prior
    /// keychain entries) can still recover the user. Simulate the transfer
    /// by wiping the keychain underneath the store and confirming the read
    /// recovers from UserDefaults, then self-heals on next access.
    func testKeychainTokenStoreFallsBackToDefaults() throws {
        let suiteName = "SalesCentralTests.keychainFallback.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let service = "central.sales.test.\(UUID().uuidString)"

        let store = KeychainTokenStore(service: service, defaults: defaults)
        store.clear()
        store.write("eyJ-real")
        XCTAssertEqual(store.read(), "eyJ-real")

        // Simulate post-transfer keychain blackout: drop only the keychain
        // entry, leave the UserDefaults shadow alone.
        let q: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "user_token",
        ]
        SecItemDelete(q as CFDictionary)

        // The fallback path returns the shadowed value.
        XCTAssertEqual(store.read(), "eyJ-real")

        // And self-healed back into the keychain: re-delete only the
        // defaults shadow and verify the keychain copy now satisfies reads.
        defaults.removeObject(forKey: "\(service).user_token")
        XCTAssertEqual(store.read(), "eyJ-real")

        store.clear()
        XCTAssertNil(store.read())
    }

    func testContextCurrentDoesNotCrash() {
        let ctx = UserContext.current()
        // We don't assert specifics — the contents depend on the host
        // environment — but the call must not crash and it must produce
        // *some* device data.
        XCTAssertNotNil(ctx.device)
        XCTAssertNotNil(ctx.locale)
    }

    func testContextMergePrefersOther() {
        var a = UserContext(locale: LocaleContext(language: "en"))
        let b = UserContext(locale: LocaleContext(language: "ja"))
        a.merge(b)
        XCTAssertEqual(a.locale?.language, "ja")
    }
}
