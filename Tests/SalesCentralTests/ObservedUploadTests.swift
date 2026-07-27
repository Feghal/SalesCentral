import XCTest
@testable import SalesCentral

/// The StoreKit observer's per-transaction upload: claim → upload →
/// unclaim on failure. A failed upload must release the claim, otherwise a
/// StoreKit redelivery in the same session is silently skipped and a paid
/// transaction is stranded until the next cold launch.
final class ObservedUploadTests: XCTestCase {

    /// URLProtocol that fails every request with a connection error.
    final class AlwaysFailProtocol: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        }
        override func stopLoading() {}
    }

    /// URLProtocol that answers every request with a canned 200 body. The
    /// body is a static so the protocol (constructed by URLSession) can read
    /// it without an injection seam.
    final class CannedProtocol: URLProtocol {
        nonisolated(unsafe) static var body = Data()
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let resp = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.body)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    /// A client whose applyPurchases returns one receipt result carrying
    /// `error` (or an applied receipt when `error` is nil).
    private func makeCannedClient(error: String?) -> SalesClient {
        let receipt = error.map { #"{"ok":false,"error":"\#($0)"}"# } ?? #"{"ok":true}"#
        CannedProtocol.body = Data(#"{"ok":true,"applied":[\#(receipt)]}"#.utf8)
        return makeClient(protocolClass: CannedProtocol.self)
    }

    private func makeFailingClient() -> SalesClient {
        makeClient(protocolClass: AlwaysFailProtocol.self)
    }

    private func makeClient(protocolClass: AnyClass) -> SalesClient {
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
                attestKey:           "attk00000000"
            )
        )
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [protocolClass]
        return SalesClient(config, urlSession: URLSession(configuration: sessionConfig))
    }

    func testFailedObservedUploadReleasesClaim() async {
        let client = makeFailingClient()
        let shouldFinish = await client.uploadObservedTransaction(id: "tx-9", jws: "fake.jws.sig")
        XCTAssertFalse(shouldFinish, "failed upload must not finish() the transaction")
        // The claim must have been released so a redelivery can retry.
        let reclaimable = await client.claimTransaction("tx-9")
        XCTAssertTrue(reclaimable, "failed upload releases the claim for the next redelivery")
    }

    func testAlreadyClaimedObservedUploadIsSkipped() async {
        let client = makeFailingClient()
        _ = await client.claimTransaction("tx-5") // e.g. an explicit purchase() owns it
        let shouldFinish = await client.uploadObservedTransaction(id: "tx-5", jws: "fake.jws.sig")
        XCTAssertFalse(shouldFinish, "a transaction someone else claimed is skipped")
        // And skipping must NOT release the other owner's claim.
        let reclaimable = await client.claimTransaction("tx-5")
        XCTAssertFalse(reclaimable, "skip does not steal/release the existing claim")
    }

    // MARK: - Terminal vs. retryable server rejections
    //
    // A transaction the server can NEVER accept must be finished, or StoreKit
    // replays it forever — and `product.purchase()` returns that replay
    // instead of opening a purchase sheet, wedging every later purchase on
    // `expired_transaction`. A rejection a later attempt could satisfy must
    // stay unfinished so Apple redelivers it.

    func testShouldFinishClassification() {
        XCTAssertTrue(SalesClient.shouldFinish(after: nil),
                      "no per-receipt result → treat as handled, don't replay forever")
        XCTAssertTrue(SalesClient.shouldFinish(after: receipt(ok: true)))
        for code in ["expired_transaction", "revoked_transaction", "invalid_transaction", "invalid_receipt"] {
            XCTAssertTrue(SalesClient.shouldFinish(after: receipt(ok: false, error: code)),
                          "\(code) can never succeed on retry — must finish")
        }
        for code in ["product_not_registered", "ownership_boundary",
                     "production_receipt_on_sandbox_user", "verification_failed"] {
            XCTAssertFalse(SalesClient.shouldFinish(after: receipt(ok: false, error: code)),
                           "\(code) is fixable — leave unfinished so Apple redelivers")
        }
    }

    func testTerminalRejectionFinishesAndKeepsClaim() async {
        let client = makeCannedClient(error: "expired_transaction")
        let shouldFinish = await client.uploadObservedTransaction(id: "tx-exp", jws: "fake.jws.sig")
        XCTAssertTrue(shouldFinish, "an expired transaction must be finished, not replayed")
        let reclaimable = await client.claimTransaction("tx-exp")
        XCTAssertFalse(reclaimable, "a settled transaction stays claimed — no re-upload")
    }

    func testRetryableRejectionReleasesClaimAndLeavesUnfinished() async {
        let client = makeCannedClient(error: "product_not_registered")
        let shouldFinish = await client.uploadObservedTransaction(id: "tx-unreg", jws: "fake.jws.sig")
        XCTAssertFalse(shouldFinish, "an unregistered SKU may be registered later — don't eat the purchase")
        let reclaimable = await client.claimTransaction("tx-unreg")
        XCTAssertTrue(reclaimable, "the claim is released so Apple's redelivery retries")
    }

    func testAppliedReceiptFinishes() async {
        let client = makeCannedClient(error: nil)
        let shouldFinish = await client.uploadObservedTransaction(id: "tx-ok", jws: "fake.jws.sig")
        XCTAssertTrue(shouldFinish, "an applied receipt is done")
    }

    private func receipt(ok: Bool, error: String? = nil) -> AppliedReceipt {
        let json = ok ? #"{"ok":true}"# : #"{"ok":false,"error":"\#(error ?? "")"}"#
        return try! JSONDecoder().decode(AppliedReceipt.self, from: Data(json.utf8))
    }
}
