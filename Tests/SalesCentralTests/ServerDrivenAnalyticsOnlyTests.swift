import XCTest
@testable import SalesCentral

/// Server-driven analytics-only (SDK 1.4.0): the bootstrap bundle's
/// `analyticsOnly` is absorbed, cached in the TokenStore, and OR-ed with the
/// plist flag. Test files own their stubs (see the bottom of this file).
final class ServerDrivenAnalyticsOnlyTests: XCTestCase {

    // ------------------------------------------------------------------
    // MARK: - TokenStore cache
    // ------------------------------------------------------------------

    func testInMemoryStoreRoundTripsServerFlag() {
        let store = InMemoryTokenStore()
        XCTAssertNil(store.readServerAnalyticsOnly(), "nothing cached yet")
        store.writeServerAnalyticsOnly(true)
        XCTAssertEqual(store.readServerAnalyticsOnly(), true)
        store.writeServerAnalyticsOnly(false)
        XCTAssertEqual(store.readServerAnalyticsOnly(), false, "false is a value, not an absence")
        store.clear()
        store.clearClientId()
        XCTAssertEqual(store.readServerAnalyticsOnly(), false, "identity wipes do not touch app configuration")
    }

    func testKeychainStoreCachesServerFlagInDefaultsOnly() {
        let suite = "ServerDrivenAnalyticsOnlyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = KeychainTokenStore(service: "test.sda", defaults: defaults)
        XCTAssertNil(store.readServerAnalyticsOnly())
        store.writeServerAnalyticsOnly(true)
        XCTAssertEqual(store.readServerAnalyticsOnly(), true)
        XCTAssertEqual(defaults.object(forKey: "test.sda.serverAnalyticsOnly") as? Bool, true,
                       "persisted in UserDefaults (not secret — no Keychain entry)")
        // A second store over the same defaults sees it — this is the relaunch path.
        XCTAssertEqual(KeychainTokenStore(service: "test.sda", defaults: defaults).readServerAnalyticsOnly(), true)
    }
}
