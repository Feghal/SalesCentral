import XCTest
@testable import SalesCentral

/// spendCredits idempotency-key support + ingestion of the state the server
/// attaches to error responses (409 already_claimed carries retention status).
final class SpendIdempotencyTests: XCTestCase {

    final class Stub: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var next: ((URLRequest) -> (Int, Data))?
        nonisolated(unsafe) static var lastBody: Data?
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            if let body = request.httpBody {
                Self.lastBody = body
            } else if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var data = Data()
                let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
                defer { buf.deallocate() }
                while stream.hasBytesAvailable {
                    let n = stream.read(buf, maxLength: 4096)
                    if n <= 0 { break }
                    data.append(buf, count: n)
                }
                Self.lastBody = data
            }
            let (status, data) = Self.next?(request) ?? (500, Data())
            let resp = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    /// Trivial `AppAttestServicing` mock — these tests exercise the spend /
    /// claimReward wire format, not attestation itself, so the mock just
    /// needs to satisfy the asserted-endpoint gate. See AttestTests.swift
    /// for the real attestation-flow coverage.
    struct StubAttestService: AppAttestServicing, Sendable {
        var isSupported: Bool { true }
        func generateKey() async throws -> String { "stub-key-id" }
        func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data { Data("stub-attestation".utf8) }
        func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data { Data("stub-assertion".utf8) }
    }

    private func makeClient() -> SalesClient {
        let store = InMemoryTokenStore(initial: "user-token-1")
        store.writeAttestKeyId("stub-key-id")
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
                recordEvent:         "777777777777",
                attestChallenge:     "attc00000000",
                attestKey:           "attk00000000",
                claimReward:         "888888888888"
            ),
            tokenStore: store
        )
        let sc = URLSessionConfiguration.ephemeral
        sc.protocolClasses = [Stub.self]
        return SalesClient(config, urlSession: URLSession(configuration: sc), attestService: StubAttestService())
    }

    override func tearDown() {
        Stub.next = nil
        Stub.lastBody = nil
        super.tearDown()
    }

    /// Canned response shared by every request the client makes during a
    /// test — including the attest-challenge fetch, which needs a
    /// `challenge` field to decode.
    private static let okWithChallenge =
        #"{"ok":true,"balance":70,"locked":0,"challenge":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}"#

    func testSpendCreditsSendsIdempotencyKey() async throws {
        Stub.next = { _ in (200, Data(Self.okWithChallenge.utf8)) }
        let client = makeClient()
        _ = try await client.spendCredits(30, reason: "image_gen", idempotencyKey: "op-123")
        let body = String(decoding: Stub.lastBody ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains(#""idempotencyKey":"op-123""#), "key rides on the wire: \(body)")
    }

    func testSpendCreditsOmitsIdempotencyKeyWhenNil() async throws {
        Stub.next = { _ in (200, Data(Self.okWithChallenge.utf8)) }
        let client = makeClient()
        _ = try await client.spendCredits(30, reason: "image_gen")
        let body = String(decoding: Stub.lastBody ?? Data(), as: UTF8.self)
        XCTAssertFalse(body.contains("idempotencyKey"), "nil key must not serialize: \(body)")
    }

    func testClaimRewardConflictRefreshesRetentionStatus() async {
        let payload = """
        {"ok":false,"error":"already_claimed",
         "retention":{"enabled":true,"available":false,"reason":"already_claimed",
                      "mode":"daily","dailyAmount":100,
                      "nextClaimAt":"2026-07-03T00:00:00.000Z"},
         "balance":590,"locked":0}
        """
        // Only the claimReward call itself should conflict — the attest
        // challenge fetch that precedes it (an unrelated round trip) must
        // succeed, or the 409 below would be misattributed to the wrong
        // request.
        Stub.next = { req in
            req.url!.path == "/attc00000000"
                ? (200, Data(Self.okWithChallenge.utf8))
                : (409, Data(payload.utf8))
        }
        let client = makeClient()
        do {
            _ = try await client.claimReward()
            XCTFail("expected 409 to throw")
        } catch let SalesError.http(status, code, _) {
            XCTAssertEqual(status, 409)
            XCTAssertEqual(code, "already_claimed")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        // The error body's retention status must land in the cache so the app
        // can show "come back at <nextClaimAt>" without another round trip.
        let cached = await client.retentionStatus
        XCTAssertEqual(cached?.available, false)
        XCTAssertEqual(cached?.reason, "already_claimed")
        XCTAssertNotNil(cached?.nextClaimAt, "nextClaimAt from the 409 body is cached")
    }
}
