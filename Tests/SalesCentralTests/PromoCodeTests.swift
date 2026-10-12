import XCTest
@testable import SalesCentral

/// `redeemPromoCode` (1.5.0): spelling normalisation parity with the server and the
/// Android SDK, the request/response wire shape, and the mapping of every business
/// outcome to a value.
final class PromoStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var next: ((URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var lastBody: Data?
    nonisolated(unsafe) static var lastPath: String?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if let body = request.httpBody {
            Self.lastBody = body
        } else if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(); var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: buf.count); if n <= 0 { break }; data.append(buf, count: n) }
            Self.lastBody = data
        }
        if request.url?.path != "/attc00000000" { Self.lastPath = request.url?.path }
        let (status, data) = Self.next?(request) ?? (500, Data())
        let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class PromoCodeTests: XCTestCase {
    static let okWithChallenge = #"{"ok":true,"challenge":"Y2hhbGxlbmdl"}"#
    static let userJSON = #"{"id":"u1","premium":{"tier":"pro","expiresAt":"2026-11-11T10:00:00.000Z","source":"promo"},"credits":{"balance":150,"locked":0}}"#

    /// Trivial `AppAttestServicing` mock — these tests exercise the redeem wire format,
    /// not attestation itself, so it just needs to satisfy the asserted-endpoint gate.
    struct StubAttestService: AppAttestServicing, Sendable {
        var isSupported: Bool { true }
        func generateKey() async throws -> String { "stub-key-id" }
        func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data { Data("stub-attestation".utf8) }
        func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data { Data("stub-assertion".utf8) }
    }

    private func makeClient(redeemToken: String? = "999999999999") -> SalesClient {
        let store = InMemoryTokenStore(initial: "user-token-1")
        store.writeAttestKeyId("stub-key-id")
        let config = SalesConfig(
            baseURL: URL(string: "https://sales.example.com")!,
            apiKey: "csk_test",
            tokens: .init(
                createOrFetchUser: "111111111111", restoreUser: "222222222222",
                applyPurchases: "333333333333", currentSubscription: "444444444444",
                spendCredits: "555555555555", recordSession: "666666666666", recordEvent: "777777777777",
                attestChallenge: "attc00000000", attestKey: "888888888888", claimReward: "aaaaaaaaaaaa",
                redeemPromoCode: redeemToken
            ),
            tokenStore: store
        )
        let sc = URLSessionConfiguration.ephemeral
        sc.protocolClasses = [PromoStub.self]
        return SalesClient(config, urlSession: URLSession(configuration: sc), attestService: StubAttestService())
    }

    override func tearDown() {
        PromoStub.next = nil
        PromoStub.lastBody = nil
        PromoStub.lastPath = nil
        super.tearDown()
    }

    func testParityTableMatchesTheServer() {
        let table: [(String, String)] = [
            ("launch50", "LAUNCH50"), ("  abcde-fghjk ", "ABCDEFGHJK"), ("ab_cd ef", "ABCDEF"),
            ("ＬＡＵＮＣＨ５０", "LAUNCH50"), ("LAUNCH\u{200B}50", "LAUNCH50"), ("ЛАУНЧ", ""),
            ("LАUNCH50", "LUNCH50"), ("goai://redeem?code=abc", "GOAIREDEEMCODEABC"), ("straße", "STRASSE"),
        ]
        for (input, want) in table { XCTAssertEqual(SalesClient.normalisePromoCode(input), want, input) }
        XCTAssertEqual(SalesClient.normalisePromoCode(String(repeating: "a", count: 500)).count, 128)
        // The raw input is cut at 128 UTF-16 code units, as the server (`slice(0, 128)`) and
        // Android (`take(128)`) do — 128 combining marks fill the budget, so "AB" is cut off.
        // A cut at 128 grapheme clusters would wrongly keep "AB".
        XCTAssertEqual(SalesClient.normalisePromoCode(String(repeating: "\u{301}", count: 128) + "AB"), "")
    }

    func testRedeemedPostsTheNormalisedCodeAndReplacesTheCachedUser() async throws {
        let client = makeClient()
        let payload = #"{"ok":true,"redemption":{"id":"r1","code":"LAUNCH50","campaign":"launch","credits":100,"premium":{"tier":"pro","expiresAt":"2026-11-11T10:00:00.000Z"},"premiumSkipped":null,"redeemedAt":"2026-10-12T10:00:00.000Z"},"user":\#(Self.userJSON)}"#
        PromoStub.next = { req in req.url!.path == "/attc00000000" ? (200, Data(Self.okWithChallenge.utf8)) : (200, Data(payload.utf8)) }
        let result = try await client.redeemPromoCode("  launch-50 ")
        XCTAssertEqual(PromoStub.lastPath, "/999999999999")
        let sent = try JSONSerialization.jsonObject(with: PromoStub.lastBody ?? Data()) as? [String: Any]
        XCTAssertEqual(sent?["code"] as? String, "LAUNCH50")
        guard case let .redeemed(redemption, user) = result else { return XCTFail("expected redeemed") }
        XCTAssertEqual(redemption.credits, 100)
        XCTAssertEqual(redemption.campaign, "launch")
        XCTAssertEqual(redemption.premium?.isLifetime, false)
        XCTAssertEqual(user?.credits.balance, 150)
        let cached = await client.currentUser
        XCTAssertEqual(cached?.credits.balance, 150)
    }

    func testEveryRejectionMaps() async throws {
        let client = makeClient()
        let table: [(String, PromoRejectReason)] = [
            ("invalid_code", .invalidCode), ("code_not_started", .notStarted), ("code_expired", .expired),
            ("code_used_up", .usedUp), ("already_redeemed", .alreadyRedeemed), ("already_redeemed_batch", .alreadyRedeemedBatch),
            ("already_premium", .alreadyPremium), ("too_many_attempts", .tooManyAttempts), ("not_eligible", .notEligible),
            ("brand_new_reason", .unknown("brand_new_reason")),
        ]
        for (wire, reason) in table {
            PromoStub.next = { req in req.url!.path == "/attc00000000" ? (200, Data(Self.okWithChallenge.utf8)) : (200, Data(#"{"ok":false,"error":"\#(wire)","retryAfterSeconds":720}"#.utf8)) }
            let result = try await client.redeemPromoCode("CODE1234")
            guard case let .rejected(got, retryAfter, _) = result else { return XCTFail("expected rejected for \(wire)") }
            XCTAssertEqual(got, reason, wire)
            XCTAssertEqual(retryAfter, 720)
        }
    }

    func testMissingTokenIsADescriptiveInvalidState() async {
        let client = makeClient(redeemToken: nil)
        do {
            _ = try await client.redeemPromoCode("LAUNCH50")
            XCTFail("expected invalidState")
        } catch let SalesError.invalidState(message) {
            XCTAssertTrue(message.contains("redeemPromoCode token not configured"))
        } catch { XCTFail("unexpected \(error)") }
    }
}
