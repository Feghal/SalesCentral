import XCTest
@testable import SalesCentral

/// Apple's Billing Grace Period / billing retry on the wire. The server now
/// answers a grace period as a PAID state (`expiresAt` extended to the grace
/// end, so the pre-existing `isPaid` rule keeps working) and adds three
/// fields so the app can say "update your payment method" instead of
/// showing a paywall: `status`, `gracePeriodExpiresAt`,
/// `billingIssueDetectedAt`. Older servers omit all three.
final class BillingIssueTests: XCTestCase {

    private func decoder() -> JSONDecoder {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }

    func testGracePeriodDecodesAsPaidWithBillingIssue() throws {
        let json = """
        { "tier": "pro", "expiresAt": "2099-01-01T00:00:00Z", "source": "subscription",
          "isTrial": false, "trialEndsAt": null,
          "billingIssueDetectedAt": "2026-08-23T10:00:00Z",
          "gracePeriodExpiresAt": "2099-01-01T00:00:00Z",
          "status": "grace" }
        """.data(using: .utf8)!
        let p = try decoder().decode(PremiumState.self, from: json)
        XCTAssertTrue(p.isPaid, "a grace period keeps the subscriber paid")
        XCTAssertEqual(p.status, "grace")
        XCTAssertTrue(p.hasBillingIssue)
        XCTAssertTrue(p.isInGracePeriod)
        XCTAssertFalse(p.isInBillingRetry, "billing retry is the no-access phase")
        XCTAssertEqual(p.gracePeriodExpiresAt, p.expiresAt)
        XCTAssertNotNil(p.billingIssueDetectedAt)
    }

    func testBillingRetryAfterGraceDecodesAsNotPaidWithBillingIssue() throws {
        let json = """
        { "tier": "free", "expiresAt": null, "source": "expired",
          "billingIssueDetectedAt": "2026-08-23T10:00:00Z",
          "gracePeriodExpiresAt": "2026-09-08T10:00:00Z",
          "status": "billing_retry" }
        """.data(using: .utf8)!
        let p = try decoder().decode(PremiumState.self, from: json)
        XCTAssertFalse(p.isPaid)
        XCTAssertEqual(p.status, "billing_retry")
        XCTAssertTrue(p.hasBillingIssue, "updating the payment method restores service — not a paywall")
        XCTAssertFalse(p.isInGracePeriod)
        XCTAssertTrue(p.isInBillingRetry)
    }

    func testOlderServersOmitTheFields() throws {
        let json = """
        { "tier": "pro", "expiresAt": "2099-01-01T00:00:00Z", "source": "subscription" }
        """.data(using: .utf8)!
        let p = try decoder().decode(PremiumState.self, from: json)
        XCTAssertTrue(p.isPaid)
        XCTAssertNil(p.status)
        XCTAssertFalse(p.hasBillingIssue)
        XCTAssertFalse(p.isInGracePeriod)
        XCTAssertFalse(p.isInBillingRetry)
    }

    func testGraceIsDerivedLocallyWhenStatusIsMissing() {
        // `status` is a convenience; the derivation must not depend on it, so
        // a server that sends the timestamps but no status still reads right.
        let p = PremiumState(tier: "pro", expiresAt: Date(timeIntervalSinceNow: 3600), source: "subscription",
                             isTrial: false, trialEndsAt: nil,
                             billingIssueDetectedAt: Date(timeIntervalSinceNow: -86_400),
                             gracePeriodExpiresAt: Date(timeIntervalSinceNow: 3600))
        XCTAssertTrue(p.isInGracePeriod)
        XCTAssertFalse(p.isInBillingRetry)
        let lapsed = PremiumState(tier: "free", expiresAt: nil, source: "expired",
                                  isTrial: false, trialEndsAt: nil,
                                  billingIssueDetectedAt: Date(timeIntervalSinceNow: -86_400),
                                  gracePeriodExpiresAt: Date(timeIntervalSinceNow: -60))
        XCTAssertFalse(lapsed.isInGracePeriod)
        XCTAssertTrue(lapsed.isInBillingRetry)
    }

    func testCurrentSubscriptionCarriesBillingFields() throws {
        let json = """
        { "ok": true,
          "subscription": { "id": "s", "productId": "sku.yearly", "status": "expired",
                            "expiresAt": "2026-08-23T10:00:00Z", "isAutoRenewing": true, "environment": "Production",
                            "billingIssueDetectedAt": "2026-08-23T10:00:00Z",
                            "gracePeriodExpiresAt": "2026-09-08T10:00:00Z",
                            "isInBillingRetry": true },
          "premium": { "tier": "free", "source": "expired", "status": "billing_retry",
                       "billingIssueDetectedAt": "2026-08-23T10:00:00Z" } }
        """.data(using: .utf8)!
        let r = try decoder().decode(CurrentSubscriptionResponse.self, from: json)
        XCTAssertEqual(r.subscription?.isInBillingRetry, true)
        XCTAssertNotNil(r.subscription?.gracePeriodExpiresAt)
        XCTAssertNotNil(r.subscription?.billingIssueDetectedAt)
        XCTAssertEqual(r.premium.status, "billing_retry")
    }
}
