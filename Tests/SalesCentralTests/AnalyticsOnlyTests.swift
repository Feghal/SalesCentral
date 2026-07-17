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
}
