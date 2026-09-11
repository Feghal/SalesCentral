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

    // ------------------------------------------------------------------
    // MARK: - Client: server flag absorbed, OR-ed with config
    // ------------------------------------------------------------------

    /// Plist off, server says analytics-only → bootstrap skips the
    /// subscription fetch and the observer; guards throw; events still flow.
    @MainActor
    func testServerFlagSkipsTransactionMachinery() async throws {
        let session = Self.recordingSession()
        SDARecordingURLProtocol.next = { req in Self.ok(Self.bundle(analyticsOnly: true), for: req) }
        let tokenStore = InMemoryTokenStore()
        tokenStore.writeAttestKeyId("mock-key-id")
        let client = SalesClient(Self.fullConfig(tokenStore: tokenStore), urlSession: session, attestService: SDAStubAttestService())
        XCTAssertFalse(client.analyticsOnly, "before bootstrap: plist off, nothing cached")

        let store = SalesStore(client: client)
        await store.ensureBootstrapped()

        XCTAssertNotNil(store.user, "identity bootstrap must succeed")
        XCTAssertTrue(client.analyticsOnly, "server flag absorbed")
        XCTAssertFalse(client.configAnalyticsOnly, "plist value untouched")
        XCTAssertNil(store.subscription, "no subscription fetch")
        let observing = await client.isObservingTransactions
        XCTAssertFalse(observing, "no StoreKit observer")
        let allowed: Set<String> = ["AAAAAAAAAAAA", "attc00000000", "attk00000000"]
        let hit = Set(SDARecordingURLProtocol.requests.compactMap { $0.url?.lastPathComponent })
        XCTAssertTrue(hit.isSubset(of: allowed), "unexpected requests: \(hit.subtracting(allowed))")
        XCTAssertEqual(tokenStore.readServerAnalyticsOnly(), true, "cached for the next launch")

        do { _ = try await client.currentSubscription(); XCTFail("expected analytics_only") }
        catch let SalesError.invalidState(reason) { XCTAssertEqual(reason, "analytics_only") }
        catch { XCTFail("unexpected \(error)") }
    }

    /// Plist ON wins even when the server says false.
    func testPlistFlagWinsOverServerFalse() async throws {
        let session = Self.recordingSession()
        SDARecordingURLProtocol.next = { req in Self.ok(Self.bundle(analyticsOnly: false), for: req) }
        let tokenStore = InMemoryTokenStore()
        tokenStore.writeAttestKeyId("mock-key-id")
        let client = SalesClient(Self.analyticsConfig(tokenStore: tokenStore), urlSession: session, attestService: SDAStubAttestService())
        _ = try await client.ensureUser()
        XCTAssertTrue(client.analyticsOnly, "plist true is never overridden by the server")
        XCTAssertEqual(tokenStore.readServerAnalyticsOnly(), false, "the server value is still recorded")
    }

    /// A response WITHOUT the field (older server) leaves config/cache alone.
    func testAbsentFieldLeavesValueAlone() async throws {
        let session = Self.recordingSession()
        SDARecordingURLProtocol.next = { req in Self.ok(Self.bundle(analyticsOnly: nil), for: req) }
        let tokenStore = InMemoryTokenStore()
        tokenStore.writeAttestKeyId("mock-key-id")
        tokenStore.writeServerAnalyticsOnly(true)   // cached from an earlier launch
        let client = SalesClient(Self.fullConfig(tokenStore: tokenStore), urlSession: session, attestService: SDAStubAttestService())
        XCTAssertTrue(client.analyticsOnly, "seeded from the cache before any request")
        _ = try await client.ensureUser()
        XCTAssertTrue(client.analyticsOnly, "absent field is not a reset")
        XCTAssertEqual(tokenStore.readServerAnalyticsOnly(), true)
    }

    /// Server true on one bootstrap, false on the next → machinery back.
    func testServerFalseClearsAnEarlierTrue() async throws {
        let session = Self.recordingSession()
        SDARecordingURLProtocol.next = { req in Self.ok(Self.bundle(analyticsOnly: true), for: req) }
        let tokenStore = InMemoryTokenStore()
        tokenStore.writeAttestKeyId("mock-key-id")
        let client = SalesClient(Self.fullConfig(tokenStore: tokenStore), urlSession: session, attestService: SDAStubAttestService())
        _ = try await client.ensureUser()
        XCTAssertTrue(client.analyticsOnly)

        SDARecordingURLProtocol.next = { req in Self.ok(Self.bundle(analyticsOnly: false), for: req) }
        _ = try await client.ensureUser()
        XCTAssertFalse(client.analyticsOnly, "server false clears")
        XCTAssertEqual(tokenStore.readServerAnalyticsOnly(), false)
        await client.startObservingTransactions()
        let observing = await client.isObservingTransactions
        XCTAssertTrue(observing, "observer allowed again")
        await client.stopObservingTransactions()
    }

    /// Relaunch: a FRESH client over the same store is analytics-only before
    /// any request; a different store (another app) is not.
    func testFreshClientReadsCache() {
        let cached = InMemoryTokenStore()
        cached.writeServerAnalyticsOnly(true)
        XCTAssertTrue(SalesClient(Self.fullConfig(tokenStore: cached), attestService: SDAStubAttestService()).analyticsOnly)
        XCTAssertFalse(SalesClient(Self.fullConfig(tokenStore: InMemoryTokenStore()), attestService: SDAStubAttestService()).analyticsOnly)
    }

    /// Server-driven analytics-only blocks only transactions: events and
    /// sessions still reach their endpoints.
    func testEventsAndSessionsStillFireUnderServerFlag() async throws {
        let session = Self.recordingSession()
        SDARecordingURLProtocol.next = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             Data(#"{"ok":true}"#.utf8))
        }
        let tokenStore = InMemoryTokenStore(initial: "user-token")
        tokenStore.writeServerAnalyticsOnly(true)   // as if learned on an earlier launch
        let client = SalesClient(Self.fullConfig(tokenStore: tokenStore), urlSession: session, attestService: SDAStubAttestService())
        XCTAssertTrue(client.analyticsOnly)
        await client.track("paywall_viewed")
        try await client.recordSession(start: Date(timeIntervalSinceNow: -60), end: Date())
        let hit = SDARecordingURLProtocol.requests.compactMap { $0.url?.lastPathComponent }
        XCTAssertTrue(hit.contains("GGGGGGGGGGGG"), "recordEvent endpoint must be reachable; saw \(hit)")
        XCTAssertTrue(hit.contains("FFFFFFFFFFFF"), "recordSession endpoint must be reachable; saw \(hit)")
    }

    /// The facade's synchronous guard sees the server-learned value.
    @MainActor
    func testFacadeGuardHonoursServerFlag() async throws {
        SalesCentral.reset()
        defer { SalesCentral.reset() }
        let cached = InMemoryTokenStore()
        cached.writeServerAnalyticsOnly(true)
        SalesCentral.configure(Self.fullConfig(tokenStore: cached))
        do { _ = try await SalesCentral.loadProducts(); XCTFail("expected analytics_only") }
        catch let SalesError.invalidState(reason) { XCTAssertEqual(reason, "analytics_only") }
        catch { XCTFail("unexpected \(error)") }
    }
}

// MARK: - Fixtures

extension ServerDrivenAnalyticsOnlyTests {
    static func fullConfig(tokenStore: TokenStore) -> SalesConfig {
        SalesConfig(
            baseURL: URL(string: "https://sales.test")!, apiKey: "csk_sda",
            tokens: .init(
                createOrFetchUser: "AAAAAAAAAAAA", restoreUser: "BBBBBBBBBBBB",
                applyPurchases: "CCCCCCCCCCCC", currentSubscription: "DDDDDDDDDDDD",
                spendCredits: "EEEEEEEEEEEE", recordSession: "FFFFFFFFFFFF",
                recordEvent: "GGGGGGGGGGGG", attestChallenge: "attc00000000", attestKey: "attk00000000"
            ),
            tokenStore: tokenStore
        )
    }

    static func analyticsConfig(tokenStore: TokenStore) -> SalesConfig {
        SalesConfig(
            baseURL: URL(string: "https://sales.test")!, apiKey: "csk_sda",
            tokens: .init(
                createOrFetchUser: "AAAAAAAAAAAA", restoreUser: "BBBBBBBBBBBB",
                recordSession: "FFFFFFFFFFFF", recordEvent: "GGGGGGGGGGGG",
                attestChallenge: "attc00000000", attestKey: "attk00000000"
            ),
            tokenStore: tokenStore, analyticsOnly: true
        )
    }

    /// A bundle payload; `analyticsOnly: nil` omits the key (older server).
    static func bundle(analyticsOnly: Bool?) -> [String: Any] {
        var payload: [String: Any] = [
            "ok": true, "token": "t",
            "challenge": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            "user": ["id": "u-1", "premium": ["tier": "free"], "credits": ["balance": 0], "entitlements": [:], "features": []],
        ]
        if let v = analyticsOnly { payload["analyticsOnly"] = v }
        return payload
    }

    static func ok(_ payload: [String: Any], for request: URLRequest) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
         try! JSONSerialization.data(withJSONObject: payload))
    }

    static func recordingSession() -> URLSession {
        SDARecordingURLProtocol.reset()
        let conf = URLSessionConfiguration.ephemeral
        conf.protocolClasses = [SDARecordingURLProtocol.self]
        return URLSession(configuration: conf)
    }
}

private final class SDARecordingURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var next: ((URLRequest) -> (HTTPURLResponse, Data))?
    static func reset() { requests = []; next = nil }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        let (resp, data) = Self.next?(request) ?? (
            HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data()
        )
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private struct SDAStubAttestService: AppAttestServicing, Sendable {
    var isSupported: Bool { true }
    func generateKey() async throws -> String { "stub-key-id" }
    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data { Data("stub-attestation".utf8) }
    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data { Data("stub-assertion".utf8) }
}
