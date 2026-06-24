import XCTest
@testable import SalesCentral

/// The reported bug: a long-running app kept showing "pro" after the
/// subscription expired, because `isPaid` was `tier != "free"` with no time
/// component. These tests pin the client-side expiry behaviour — no network.
final class PremiumExpiryTests: XCTestCase {

    private func premium(_ tier: String, expiresAt: Date?) -> PremiumState {
        PremiumState(tier: tier, expiresAt: expiresAt, source: "subscription",
                     isTrial: false, trialEndsAt: nil)
    }

    func testExpiredPremiumReportsNotPaid() {
        let p = premium("pro", expiresAt: Date(timeIntervalSinceNow: -60))
        XCTAssertFalse(p.isPaid, "lapsed premium must report not-paid without a server call")
        XCTAssertEqual(p.effectiveTier, "free")
    }

    func testActivePremiumReportsPaid() {
        let p = premium("pro", expiresAt: Date(timeIntervalSinceNow: 3600))
        XCTAssertTrue(p.isPaid)
        XCTAssertEqual(p.effectiveTier, "pro")
    }

    func testLifetimePremiumHasNoExpiry() {
        let p = premium("lifetime", expiresAt: nil)
        XCTAssertTrue(p.isPaid, "nil expiresAt means no expiry (e.g. lifetime)")
        XCTAssertEqual(p.effectiveTier, "lifetime")
    }

    func testFreeTierNeverPaid() {
        XCTAssertFalse(premium("free", expiresAt: nil).isPaid)
        XCTAssertFalse(premium("free", expiresAt: Date(timeIntervalSinceNow: 3600)).isPaid)
    }
}
