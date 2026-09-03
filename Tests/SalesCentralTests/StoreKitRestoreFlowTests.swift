import XCTest
import StoreKit
@testable import SalesCentral

#if canImport(StoreKitTest)
import StoreKitTest

/// Drives REAL StoreKit transactions through Apple's StoreKit Testing
/// framework, so the claim the restore fix rests on gets executed rather than
/// only reasoned about:
///
///   `Transaction.currentEntitlements` — what restore used to upload — drops a
///   subscription the moment it lapses, while `Transaction.all` (what
///   `LiveReceiptProvider` now reads) still carries it. That gap IS the bug: a
///   lapsed subscriber had nothing to send, so the SDK never called
///   /users/restore and minted a fresh empty account instead.
///
/// ─────────────────────────────────────────────────────────────────────────
/// THESE TESTS SKIP UNDER `swift test` AND UNDER A BARE `xcodebuild test` ON
/// THE PACKAGE. StoreKit refuses to sell to a process with no app identity: a
/// SwiftPM test bundle reports `Bundle.main.bundleIdentifier` as
/// `com.apple.dt.xctest.tool`, so `Product.purchase()` fails with
/// `StoreKitError.unknown` (no foreground window scene) and
/// `SKTestSession.buyProduct` likewise. Products DO load from the
/// configuration below on an iOS simulator, so everything except the sale
/// itself is verified here.
///
/// To actually run them, host the suite in an app test target:
///   1. Add SalesCentral to an iOS app project (the integrating app works).
///   2. Add this file + SalesCentralTest.storekit to its unit-test target.
///   3. Scheme ▸ Test ▸ Options ▸ StoreKit Configuration →
///      SalesCentralTest.storekit
/// They then run for real, and a skip turns into a pass or a failure.
/// ─────────────────────────────────────────────────────────────────────────
@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
final class StoreKitRestoreFlowTests: XCTestCase {

    private var session: SKTestSession!

    override func setUpWithError() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "SalesCentralTest", withExtension: "storekit"),
            "StoreKit configuration missing from the test bundle"
        )
        session = try SKTestSession(contentsOf: url)
        session.disableDialogs = true
        session.clearTransactions()
    }

    override func tearDown() {
        session?.clearTransactions()
        session = nil
    }

    /// Buy through StoreKit's own API — the same call the app makes — with the
    /// test session standing in for the App Store. Skips (never fails) when
    /// the host process cannot transact, so an unhosted run reports honestly
    /// instead of going green on nothing.
    @discardableResult
    private func purchase(_ id: String) async throws -> Transaction {
        let products: [Product]
        do { products = try await Product.products(for: [id]) }
        catch { throw XCTSkip("StoreKit could not load products (\(error)) — needs an app-hosted test target") }
        guard let product = products.first else {
            throw XCTSkip("no products in this process — needs an app-hosted test target")
        }
        let result: Product.PurchaseResult
        do { result = try await product.purchase() }
        catch { throw XCTSkip("StoreKit refused to transact (\(error)) — needs an app-hosted test target") }
        guard case .success(let verification) = result, case .verified(let txn) = verification else {
            throw XCTSkip("purchase did not complete (\(result)) — needs an app-hosted test target")
        }
        return txn
    }

    private func entitlementIDs() async -> [String] {
        var out: [String] = []
        for await r in Transaction.currentEntitlements {
            if case .verified(let t) = r { out.append(t.productID) }
        }
        return out
    }

    private func historyIDs() async -> [String] {
        var out: [String] = []
        for await r in Transaction.all {
            if case .verified(let t) = r { out.append(t.productID) }
        }
        return out
    }

    /// THE BUG, executed: once the subscription lapses the old receipt source
    /// goes empty while the new one still carries the purchase.
    func testLapsedSubscriptionLeavesEntitlementsEmptyButStaysInHistory() async throws {
        let sub = try await purchase("sku.sub")
        await sub.finish()

        var entitled = await entitlementIDs()
        XCTAssertTrue(entitled.contains("sku.sub"), "precondition: an active subscription IS an entitlement")

        try session.expireSubscription(productIdentifier: "sku.sub")

        entitled = await entitlementIDs()
        let history = await historyIDs()

        XCTAssertFalse(
            entitled.contains("sku.sub"),
            "a lapsed subscription is NOT a current entitlement — this is why restore sent nothing"
        )
        XCTAssertTrue(
            history.contains("sku.sub"),
            "Transaction.all still carries the lapsed subscription — the receipt restore now uploads"
        )
    }

    /// The same gap through the SDK's own seams: the provider restore actually
    /// uses must beat the one it used to use, for a user who is not premium.
    func testReceiptProviderYieldsReceiptsWhenEntitlementsAreEmpty() async throws {
        let sub = try await purchase("sku.sub")
        await sub.finish()
        try session.expireSubscription(productIdentifier: "sku.sub")

        let oldSource = await SalesClient.currentEntitlementJWSStrings()
        let newSource = await LiveReceiptProvider().restoreReceiptJWS()

        XCTAssertTrue(oldSource.isEmpty, "the old source is empty for a lapsed subscriber — restore short-circuited here")
        XCTAssertFalse(newSource.isEmpty, "LiveReceiptProvider still has a receipt to identify the account with")
    }

    /// Settles the open question behind the retroactive-grant risk: does a
    /// FINISHED consumable survive in the history the SDK now uploads? The
    /// answer decides both whether consumable-only buyers are recoverable and
    /// whether old uncredited packs can be granted on a first restore.
    func testFinishedConsumableVisibilityInHistory() async throws {
        let txn = try await purchase("sku.credits")
        await txn.finish()

        let entitled = await entitlementIDs()
        let history = await historyIDs()

        XCTAssertFalse(
            entitled.contains("sku.credits"),
            "consumables are never current entitlements — the documented reason restore missed them"
        )
        // Recorded, not asserted: this is the observation the deploy decision
        // needs, and it is what an app-hosted run is for.
        print("FINISHED_CONSUMABLE_IN_HISTORY=\(history.contains("sku.credits"))")
    }
}
#endif
