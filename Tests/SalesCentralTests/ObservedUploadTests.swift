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

    private func makeFailingClient() -> SalesClient {
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
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [AlwaysFailProtocol.self]
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
}
