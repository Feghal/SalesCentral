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

    /// Direct `SalesConfig` construction defaults the flag off, and the
    /// trimmed `Tokens` initializer (optional params omitted) compiles.
    func testDirectInitDefaultsAndTrimmedTokensInit() {
        let config = SalesConfig(
            baseURL: URL(string: "https://sales.test")!,
            apiKey: "csk_x",
            tokens: .init(
                createOrFetchUser: "AAAAAAAAAAAA",
                restoreUser:       "BBBBBBBBBBBB",
                recordSession:     "FFFFFFFFFFFF",
                recordEvent:       "GGGGGGGGGGGG",
                attestChallenge:   "attc00000000",
                attestKey:         "attk00000000"
            )
        )
        XCTAssertFalse(config.analyticsOnly)
        XCTAssertNil(config.tokens.applyPurchases)
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
