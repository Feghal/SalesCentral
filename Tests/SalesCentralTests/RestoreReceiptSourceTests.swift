import XCTest
@testable import SalesCentral

/// Restore must source its receipts from the device's full purchase HISTORY,
/// not just its *current entitlements*.
///
/// `Transaction.currentEntitlements` holds only purchases that currently
/// entitle the user — active subscriptions and unconsumed non-consumables. It
/// is empty in exactly the cases where the user is not premium: a lapsed
/// subscriber, or someone whose only purchases were consumable credit packs
/// (StoreKit never lists those as entitlements). `restorePurchases()`
/// short-circuited on that empty list and fell back to `ensureUser()`, so the
/// server was never asked to resolve the owning account. On a device that had
/// also lost its keychain identity — a new device or an App Store Connect app
/// transfer, the very situations that make someone tap "Restore Purchases" —
/// `ensureUser()` mints a BRAND-NEW user with a zero balance, stranding the
/// paid credits on the old account.
///
/// The server was never the problem: given any receipt it resolves the owner
/// and returns their credits regardless of premium state (proved server-side
/// in central_sales_rest/tests/restoreNonPremiumCredits.integration.test.js).
/// The fix is to hand it the receipts it needs.
final class RestoreReceiptSourceTests: XCTestCase {

    /// Records the path of every request, and answers each with a canned body.
    final class RecordingProtocol: URLProtocol {
        nonisolated(unsafe) static var paths: [String] = []
        nonisolated(unsafe) static var body = Data()
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.paths.append(request.url?.path ?? "")
            let resp = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.body)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    /// Stands in for StoreKit: yields whatever receipts the test says the
    /// device holds.
    struct StubReceiptProvider: ReceiptProviding {
        let receipts: [String]
        func restoreReceiptJWS() async -> [String] { receipts }
    }

    /// Per-endpoint tokens are baked into the URL path, so the recorded path
    /// says which endpoint the SDK actually chose.
    private static let restoreToken = "222222222222"
    private static let createToken  = "111111111111"

    private func makeClient(deviceReceipts: [String]) -> SalesClient {
        RecordingProtocol.paths = []
        RecordingProtocol.body = Data(#"""
        {"ok":true,"token":"next-token","restored":true,"applied":[],
         "user":{"id":"owner-1","premium":{"tier":"free"},"credits":{"balance":500},
                 "entitlements":{},"features":[],"properties":{}}}
        """#.utf8)
        let config = SalesConfig(
            baseURL: URL(string: "https://sales.example.com")!,
            apiKey: "csk_xyz",
            tokens: .init(
                createOrFetchUser:   Self.createToken,
                restoreUser:         Self.restoreToken,
                applyPurchases:      "333333333333",
                currentSubscription: "444444444444",
                spendCredits:        "555555555555",
                recordSession:       "666666666666",
                recordEvent:         "777777777777",
                attestChallenge:     "attc00000000",
                attestKey:           "attk00000000"
            ),
            tokenStore: InMemoryTokenStore()
        )
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [RecordingProtocol.self]
        return SalesClient(
            config,
            urlSession: URLSession(configuration: sessionConfig),
            receiptProvider: StubReceiptProvider(receipts: deviceReceipts)
        )
    }

    /// THE BUG: a lapsed subscriber (or consumable-only buyer) holds receipts
    /// in their purchase history but has no current entitlement. Restore must
    /// still ask the server to resolve the owning account.
    func testRestoreAsksServerWhenDeviceHasHistoryButNoEntitlement() async throws {
        let client = makeClient(deviceReceipts: ["lapsed.subscription.jws"])

        let result = try await client.restorePurchases()

        XCTAssertTrue(
            RecordingProtocol.paths.contains { $0.contains(Self.restoreToken) },
            "restore must POST /users/restore when the device has purchase history — got \(RecordingProtocol.paths)"
        )
        XCTAssertFalse(
            RecordingProtocol.paths.contains { $0.contains(Self.createToken) },
            "restore must NOT fall back to createOrFetchUser and mint a new empty account"
        )
        XCTAssertTrue(result.restored, "the server resolved the owning account")
        XCTAssertEqual(result.user.credits.balance, 500, "the owner's credits come back with the account")
    }

    /// The fallback is still correct when the device genuinely never purchased
    /// anything — there is no account to recover, so create one.
    func testRestoreFallsBackToCreateOnlyWhenDeviceHasNoHistory() async throws {
        let client = makeClient(deviceReceipts: [])

        let result = try await client.restorePurchases()

        XCTAssertTrue(
            RecordingProtocol.paths.contains { $0.contains(Self.createToken) },
            "with no purchases at all, restore falls back to create-or-fetch — got \(RecordingProtocol.paths)"
        )
        XCTAssertFalse(result.restored, "nothing was restored")
    }

    /// Explicit receipts still win over the device provider.
    func testExplicitReceiptsOverrideTheDeviceProvider() async throws {
        let client = makeClient(deviceReceipts: [])

        _ = try await client.restorePurchases(receipts: ["caller.supplied.jws"])

        XCTAssertTrue(
            RecordingProtocol.paths.contains { $0.contains(Self.restoreToken) },
            "caller-supplied receipts are sent even when the device provider is empty"
        )
    }
}
