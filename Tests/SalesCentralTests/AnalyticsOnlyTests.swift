import XCTest
@testable import SalesCentral

/// Analytics-only mode: config parsing, client guards, bootstrap skips.
final class AnalyticsOnlyTests: XCTestCase {

    // ------------------------------------------------------------------
    // MARK: - Config parsing
    // ------------------------------------------------------------------

    /// A plist dict with `analyticsOnly` and NO transaction tokens parses.
    func testParseAnalyticsOnlyConfigWithoutTransactionTokens() {
        let raw: [String: Any] = [
            "baseURL": "https://sales.test",
            "apiKey": "csk_x",
            "analyticsOnly": true,
            "tokens": [
                "createOrFetchUser": "AAAAAAAAAAAA",
                "restoreUser":       "BBBBBBBBBBBB",
                "recordSession":     "FFFFFFFFFFFF",
                "recordEvent":       "GGGGGGGGGGGG",
                "attestChallenge":   "attc00000000",
                "attestKey":         "attk00000000",
            ],
        ]
        let config = SalesConfig.parse(raw, source: "test")
        XCTAssertTrue(config.analyticsOnly)
        XCTAssertNil(config.tokens.applyPurchases)
        XCTAssertNil(config.tokens.currentSubscription)
        XCTAssertNil(config.tokens.spendCredits)
        XCTAssertNil(config.tokens.claimReward)
        XCTAssertEqual(config.tokens.createOrFetchUser, "AAAAAAAAAAAA")
        XCTAssertEqual(config.tokens.recordEvent, "GGGGGGGGGGGG")
    }

    /// The flag defaults to false and a full config parses exactly as today.
    func testParseFullConfigDefaultsAnalyticsOnlyFalse() {
        let raw: [String: Any] = [
            "baseURL": "https://sales.test",
            "apiKey": "csk_x",
            "tokens": [
                "createOrFetchUser":   "AAAAAAAAAAAA",
                "restoreUser":         "BBBBBBBBBBBB",
                "applyPurchases":      "CCCCCCCCCCCC",
                "currentSubscription": "DDDDDDDDDDDD",
                "spendCredits":        "EEEEEEEEEEEE",
                "recordSession":       "FFFFFFFFFFFF",
                "recordEvent":         "GGGGGGGGGGGG",
                "attestChallenge":     "attc00000000",
                "attestKey":           "attk00000000",
            ],
        ]
        let config = SalesConfig.parse(raw, source: "test")
        XCTAssertFalse(config.analyticsOnly)
        XCTAssertEqual(config.tokens.applyPurchases, "CCCCCCCCCCCC")
        XCTAssertEqual(config.tokens.currentSubscription, "DDDDDDDDDDDD")
        XCTAssertEqual(config.tokens.spendCredits, "EEEEEEEEEEEE")
    }

    /// Flag + transaction tokens both present: parses, flag wins (tokens
    /// are read but the mode stays analytics-only).
    func testParseAnalyticsOnlyWithTokensPresentKeepsFlag() {
        let raw: [String: Any] = [
            "baseURL": "https://sales.test",
            "apiKey": "csk_x",
            "analyticsOnly": true,
            "tokens": [
                "createOrFetchUser":   "AAAAAAAAAAAA",
                "restoreUser":         "BBBBBBBBBBBB",
                "applyPurchases":      "CCCCCCCCCCCC",
                "currentSubscription": "DDDDDDDDDDDD",
                "spendCredits":        "EEEEEEEEEEEE",
                "recordSession":       "FFFFFFFFFFFF",
                "recordEvent":         "GGGGGGGGGGGG",
                "attestChallenge":     "attc00000000",
                "attestKey":           "attk00000000",
            ],
        ]
        let config = SalesConfig.parse(raw, source: "test")
        XCTAssertTrue(config.analyticsOnly)
        XCTAssertEqual(config.tokens.applyPurchases, "CCCCCCCCCCCC")
    }

    /// Direct `SalesConfig` construction defaults the flag off (full-token
    /// config), and the trimmed `Tokens` initializer (optional params
    /// omitted) compiles. Exercised as two separate constructions —
    /// combining trimmed tokens with the flag left at its full-mode default
    /// is exactly the unsafe construction this fix's init validation now
    /// rejects with a `preconditionFailure` (see
    /// `testMissingTransactionTokenMatrix` below for that matrix).
    func testDirectInitDefaultsAndTrimmedTokensInit() {
        let config = Self.fullConfig(tokenStore: InMemoryTokenStore())
        XCTAssertFalse(config.analyticsOnly)

        let trimmedTokens = SalesConfig.Tokens(
            createOrFetchUser: "AAAAAAAAAAAA",
            restoreUser:       "BBBBBBBBBBBB",
            recordSession:     "FFFFFFFFFFFF",
            recordEvent:       "GGGGGGGGGGGG",
            attestChallenge:   "attc00000000",
            attestKey:         "attk00000000"
        )
        XCTAssertNil(trimmedTokens.applyPurchases)
        XCTAssertNil(trimmedTokens.currentSubscription)
        XCTAssertNil(trimmedTokens.spendCredits)
        XCTAssertNil(trimmedTokens.claimReward)
    }

    // ------------------------------------------------------------------
    // MARK: - Client guards
    // ------------------------------------------------------------------

    /// Every guarded transaction API throws `invalidState("analytics_only")`
    /// without issuing ANY network request.
    func testGuardedClientAPIsThrowAnalyticsOnlyWithoutNetwork() async {
        RecordingURLProtocol.reset()
        URLProtocol.registerClass(RecordingURLProtocol.self)
        defer { URLProtocol.unregisterClass(RecordingURLProtocol.self) }
        let conf = URLSessionConfiguration.ephemeral
        conf.protocolClasses = [RecordingURLProtocol.self]
        let session = URLSession(configuration: conf)
        let client = SalesClient(
            Self.analyticsConfig(tokenStore: InMemoryTokenStore(initial: "user-token")),
            urlSession: session,
            attestService: StubAttestService()
        )

        func expectAnalyticsOnly(_ op: String, _ body: () async throws -> Void) async {
            do { try await body(); XCTFail("\(op): expected analytics_only error") }
            catch let SalesError.invalidState(reason) { XCTAssertEqual(reason, "analytics_only", op) }
            catch { XCTFail("\(op): unexpected error \(error)") }
        }
        await expectAnalyticsOnly("applyReceipt")        { _ = try await client.applyReceipt("jws") }
        await expectAnalyticsOnly("applyReceipts")       { _ = try await client.applyReceipts(["jws"]) }
        await expectAnalyticsOnly("currentSubscription") { _ = try await client.currentSubscription() }
        await expectAnalyticsOnly("spendCredits")        { _ = try await client.spendCredits(1, reason: "t") }
        await expectAnalyticsOnly("claimReward")         { _ = try await client.claimReward() }
        await expectAnalyticsOnly("restorePurchases")    { _ = try await client.restorePurchases(receipts: ["jws"]) }
        XCTAssertTrue(RecordingURLProtocol.requests.isEmpty,
                      "guards must fire before any network I/O; saw \(RecordingURLProtocol.requests.compactMap(\.url))")
    }

    /// `startObservingTransactions()` is a no-op under analyticsOnly…
    func testStartObservingTransactionsIsNoOpInAnalyticsMode() async {
        let client = SalesClient(
            Self.analyticsConfig(tokenStore: InMemoryTokenStore()),
            attestService: StubAttestService()
        )
        await client.startObservingTransactions()
        let observing = await client.isObservingTransactions
        XCTAssertFalse(observing)
    }

    /// …and still starts in full mode (regression guard).
    func testStartObservingTransactionsStartsInFullMode() async {
        let client = SalesClient(
            Self.fullConfig(tokenStore: InMemoryTokenStore()),
            attestService: StubAttestService()
        )
        await client.startObservingTransactions()
        let observing = await client.isObservingTransactions
        XCTAssertTrue(observing)
        await client.stopObservingTransactions()
    }

    // ------------------------------------------------------------------
    // MARK: - Bootstrap + store behavior
    // ------------------------------------------------------------------

    /// Analytics-only bootstrap establishes the user and hits ONLY the
    /// identity/attest endpoints — no subscription fetch, no observer.
    @MainActor
    func testBootstrapSkipsTransactionMachineryInAnalyticsMode() async throws {
        RecordingURLProtocol.reset()
        URLProtocol.registerClass(RecordingURLProtocol.self)
        defer { URLProtocol.unregisterClass(RecordingURLProtocol.self) }
        let conf = URLSessionConfiguration.ephemeral
        conf.protocolClasses = [RecordingURLProtocol.self]
        let session = URLSession(configuration: conf)

        RecordingURLProtocol.next = { request in
            let payload: [String: Any] = [
                "ok": true, "token": "t",
                "challenge": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                "user": [
                    "id": "u-1",
                    "premium": ["tier": "free"],
                    "credits": ["balance": 0],
                    "entitlements": [:],
                    "features": [],
                ],
            ]
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                try! JSONSerialization.data(withJSONObject: payload)
            )
        }

        let tokenStore = InMemoryTokenStore()
        tokenStore.writeAttestKeyId("mock-key-id")
        let client = SalesClient(
            Self.analyticsConfig(tokenStore: tokenStore),
            urlSession: session,
            attestService: StubAttestService()
        )
        let store = SalesStore(client: client)
        await store.ensureBootstrapped()

        XCTAssertNotNil(store.user, "identity bootstrap must still succeed")
        XCTAssertNil(store.subscription, "no subscription fetch in analytics mode")
        let observing = await client.isObservingTransactions
        XCTAssertFalse(observing, "no StoreKit observer in analytics mode")

        // Whitelist assertion: only identity + attest endpoints may be hit.
        let allowed: Set<String> = ["AAAAAAAAAAAA", "attc00000000", "attk00000000"]
        let hit = Set(RecordingURLProtocol.requests.compactMap { $0.url?.lastPathComponent })
        XCTAssertTrue(hit.isSubset(of: allowed), "unexpected requests: \(hit.subtracting(allowed))")
    }

    /// `SalesStore.restorePurchases()` surfaces the guard through its
    /// existing `lastError` channel (non-throwing method).
    @MainActor
    func testStoreRestorePurchasesSurfacesAnalyticsOnlyError() async {
        let client = SalesClient(
            Self.analyticsConfig(tokenStore: InMemoryTokenStore()),
            attestService: StubAttestService()
        )
        let store = SalesStore(client: client)
        await store.restorePurchases()
        guard case .invalidState(let reason)? = store.lastError else {
            return XCTFail("expected invalidState lastError, got \(String(describing: store.lastError))")
        }
        XCTAssertEqual(reason, "analytics_only")
    }

    /// The analytics surface itself still works: events and sessions go
    /// out to their endpoints in analytics-only mode.
    func testEventsAndSessionsStillFireInAnalyticsMode() async throws {
        RecordingURLProtocol.reset()
        URLProtocol.registerClass(RecordingURLProtocol.self)
        defer { URLProtocol.unregisterClass(RecordingURLProtocol.self) }
        let conf = URLSessionConfiguration.ephemeral
        conf.protocolClasses = [RecordingURLProtocol.self]
        let session = URLSession(configuration: conf)
        RecordingURLProtocol.next = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"ok":true}"#.utf8)
            )
        }
        let client = SalesClient(
            Self.analyticsConfig(tokenStore: InMemoryTokenStore(initial: "user-token")),
            urlSession: session,
            attestService: StubAttestService()
        )
        await client.track("paywall_viewed")
        try await client.recordSession(start: Date(timeIntervalSinceNow: -60), end: Date())
        let hit = RecordingURLProtocol.requests.compactMap { $0.url?.lastPathComponent }
        XCTAssertTrue(hit.contains("GGGGGGGGGGGG"), "recordEvent endpoint must be reachable; saw \(hit)")
        XCTAssertTrue(hit.contains("FFFFFFFFFFFF"), "recordSession endpoint must be reachable; saw \(hit)")
    }

    // ------------------------------------------------------------------
    // MARK: - SalesCentral static guards
    // ------------------------------------------------------------------

    /// The static facade throws before touching StoreKit or the network.
    @MainActor
    func testSalesCentralStaticsThrowAnalyticsOnly() async {
        SalesCentral.reset()
        defer { SalesCentral.reset() }
        SalesCentral.configure(Self.analyticsConfig(tokenStore: InMemoryTokenStore()))

        func expectAnalyticsOnly(_ op: String, _ body: () async throws -> Void) async {
            do { try await body(); XCTFail("\(op): expected analytics_only error") }
            catch let SalesError.invalidState(reason) { XCTAssertEqual(reason, "analytics_only", op) }
            catch { XCTFail("\(op): unexpected error \(error)") }
        }
        await expectAnalyticsOnly("loadProducts")   { _ = try await SalesCentral.loadProducts() }
        await expectAnalyticsOnly("reloadProducts") { _ = try await SalesCentral.reloadProducts() }
        await expectAnalyticsOnly("loadProduct")    { _ = try await SalesCentral.loadProduct("com.x.pro") }
        await expectAnalyticsOnly("purchase")       { _ = try await SalesCentral.purchase(productID: "com.x.pro") }
    }

    /// Full-mode configs must not silently lose transaction tokens: the
    /// init validation matrix flags exactly the missing ones, and flags
    /// nothing under analyticsOnly. (The preconditionFailure in `init`
    /// consumes a non-empty result; crash paths aren't testable in XCTest.)
    func testMissingTransactionTokenMatrix() {
        let trimmed = SalesConfig.Tokens(
            createOrFetchUser: "AAAAAAAAAAAA",
            restoreUser:       "BBBBBBBBBBBB",
            recordSession:     "FFFFFFFFFFFF",
            recordEvent:       "GGGGGGGGGGGG",
            attestChallenge:   "attc00000000",
            attestKey:         "attk00000000"
        )
        XCTAssertEqual(
            SalesConfig.missingTransactionTokens(trimmed, analyticsOnly: false),
            ["applyPurchases", "currentSubscription", "spendCredits"]
        )
        XCTAssertEqual(SalesConfig.missingTransactionTokens(trimmed, analyticsOnly: true), [])

        let partial = SalesConfig.Tokens(
            createOrFetchUser: "AAAAAAAAAAAA",
            restoreUser:       "BBBBBBBBBBBB",
            applyPurchases:    "CCCCCCCCCCCC",
            currentSubscription: "",
            recordSession:     "FFFFFFFFFFFF",
            recordEvent:       "GGGGGGGGGGGG",
            attestChallenge:   "attc00000000",
            attestKey:         "attk00000000"
        )
        XCTAssertEqual(
            SalesConfig.missingTransactionTokens(partial, analyticsOnly: false),
            ["currentSubscription", "spendCredits"]
        )

        let full = Self.fullConfig(tokenStore: InMemoryTokenStore())
        XCTAssertEqual(SalesConfig.missingTransactionTokens(full.tokens, analyticsOnly: false), [])
    }
}

// MARK: - Shared fixtures

extension AnalyticsOnlyTests {

    /// Analytics-only config: no transaction tokens.
    static func analyticsConfig(tokenStore: TokenStore) -> SalesConfig {
        SalesConfig(
            baseURL: URL(string: "https://sales.test")!,
            apiKey: "csk_x",
            tokens: .init(
                createOrFetchUser: "AAAAAAAAAAAA",
                restoreUser:       "BBBBBBBBBBBB",
                recordSession:     "FFFFFFFFFFFF",
                recordEvent:       "GGGGGGGGGGGG",
                attestChallenge:   "attc00000000",
                attestKey:         "attk00000000"
            ),
            tokenStore: tokenStore,
            analyticsOnly: true
        )
    }

    /// Full config with every token, flag off.
    static func fullConfig(tokenStore: TokenStore) -> SalesConfig {
        SalesConfig(
            baseURL: URL(string: "https://sales.test")!,
            apiKey: "csk_x",
            tokens: .init(
                createOrFetchUser:   "AAAAAAAAAAAA",
                restoreUser:         "BBBBBBBBBBBB",
                applyPurchases:      "CCCCCCCCCCCC",
                currentSubscription: "DDDDDDDDDDDD",
                spendCredits:        "EEEEEEEEEEEE",
                recordSession:       "FFFFFFFFFFFF",
                recordEvent:         "GGGGGGGGGGGG",
                attestChallenge:     "attc00000000",
                attestKey:           "attk00000000"
            ),
            tokenStore: tokenStore
        )
    }
}

// MARK: - Stub URLProtocol (records every request; test files own their stubs)

private final class RecordingURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var next: ((URLRequest) -> (HTTPURLResponse, Data))?
    static func reset() { requests = []; next = nil }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        let (resp, data) = Self.next?(request) ?? (
            HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
            Data()
        )
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Stub AppAttestServicing (mirrors SalesCentralTests' stub)

private struct StubAttestService: AppAttestServicing, Sendable {
    var isSupported: Bool { true }
    func generateKey() async throws -> String { "stub-key-id" }
    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data { Data("stub-attestation".utf8) }
    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data { Data("stub-assertion".utf8) }
}
