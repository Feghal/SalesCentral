import XCTest
import DeviceCheck
@testable import SalesCentral

/// `start()`'s log line when bootstrap fails. Only a transport failure is
/// "likely offline": on 2026-09-23 an online iOS 27 device logged exactly
/// that for an HTTP 401.
final class BootstrapFailureTests: XCTestCase {

    override func setUp() {
        super.setUp()
        AttestTests.StubProtocol.routes = [:]
        AttestTests.StubProtocol.seen = []
        AttestTests.StubProtocol.handler = nil
        AttestTests.StubProtocol.responder = nil
        AttestTests.StubProtocol.delay = nil
    }

    func testHTTPFailureIsNotReportedAsOffline() {
        let line = SalesCentral.bootstrapFailureMessage(SalesError.http(status: 401, code: "invalid_assertion", message: nil))
        XCTAssertFalse(line.localizedCaseInsensitiveContains("offline"), line)
        XCTAssertTrue(line.contains("HTTP 401 invalid_assertion"), line)
    }

    func testNetworkFailureIsReportedAsOffline() {
        let line = SalesCentral.bootstrapFailureMessage(SalesError.network("The request timed out."))
        XCTAssertTrue(line.contains("likely offline"), line)
        XCTAssertTrue(line.contains("The request timed out."), line)
    }

    func testAppAttestFailureIsNotReportedAsOffline() {
        let line = SalesCentral.bootstrapFailureMessage(DCError(.unknownSystemFailure))
        XCTAssertFalse(line.localizedCaseInsensitiveContains("offline"), line)
        XCTAssertTrue(line.contains("App Attest"), line)
    }

    @MainActor
    func testStoreKeepsWhyBootstrapFailed() async {
        // Unattested, so the call goes straight out; the server rejects it.
        let mock = AttestTests.MockAttestService()
        mock.supported = false
        AttestTests.StubProtocol.routes["/c0ffee000001"] = (401, #"{"ok":false,"error":"invalid_assertion"}"#)
        let conf = URLSessionConfiguration.ephemeral
        conf.protocolClasses = [AttestTests.StubProtocol.self]
        let config = SalesConfig(
            baseURL: URL(string: "https://unit.test")!,
            apiKey: "csk_test",
            tokens: .init(
                createOrFetchUser: "c0ffee000001", restoreUser: "c0ffee000002",
                applyPurchases: "c0ffee000003", currentSubscription: "c0ffee000004",
                spendCredits: "c0ffee000005", recordSession: "c0ffee000006",
                recordEvent: "c0ffee000007",
                attestChallenge: "c0ffee000008", attestKey: "c0ffee000009"
            ),
            tokenStore: InMemoryTokenStore()
        )
        let client = SalesClient(
            config, urlSession: URLSession(configuration: conf),
            attestService: mock, appTransactionService: AttestTests.StubAppTransactionProvider()
        )
        let store = SalesStore(client: client)

        await store.ensureBootstrapped()

        XCTAssertFalse(store.didBootstrap)
        guard case SalesError.http(401, "invalid_assertion", _)? = store.lastBootstrapError else {
            return XCTFail("expected the HTTP rejection, got \(String(describing: store.lastBootstrapError))")
        }
    }
}
