import XCTest
@testable import SalesCentral

/// Covers the client-side pieces of the offline-first-launch user-creation fix:
/// the stable `clientId` (idempotent-create key) and that it rides on the
/// createOrFetch body. The single-flight bootstrap, reconnect retry, and the
/// server-side dedup are exercised at the integration level.
final class OfflineUserCreationTests: XCTestCase {

    func testInMemoryClientIdRoundTrip() {
        let s = InMemoryTokenStore()
        XCTAssertNil(s.readClientId(), "no client id before first write")
        s.writeClientId("uuid-1")
        XCTAssertEqual(s.readClientId(), "uuid-1")
        // Clearing the token must NOT wipe the client id (it stays stable so
        // dedup keeps working across token rotations).
        s.clear()
        XCTAssertEqual(s.readClientId(), "uuid-1")
    }

    /// Back-compat: a custom TokenStore that predates the client-id methods
    /// keeps compiling and is a safe no-op via the protocol default.
    func testCustomTokenStoreDefaultsAreNoOp() {
        struct MinimalStore: TokenStore {
            func read() -> String? { nil }
            func write(_ token: String) {}
            func clear() {}
        }
        let s = MinimalStore()
        XCTAssertNil(s.readClientId())
        s.writeClientId("x")            // no-op, must not crash
        XCTAssertNil(s.readClientId())  // still nil — default impl doesn't persist
    }

    func testUserContextEncodesClientId() throws {
        var ctx = UserContext()
        ctx.clientId = "abc-123"
        let json = String(decoding: try JSONEncoder().encode(ctx), as: UTF8.self)
        XCTAssertTrue(json.contains("\"clientId\":\"abc-123\""), "clientId must be sent on the wire: \(json)")
    }

    func testUserContextOmitsClientIdWhenNil() throws {
        let json = String(decoding: try JSONEncoder().encode(UserContext()), as: UTF8.self)
        XCTAssertFalse(json.contains("clientId"), "nil clientId should not be serialized")
    }

    /// Issue 2: a full identity reset must be possible — clearing wipes the
    /// client id so the next create makes a brand-new guest user.
    func testClearClientIdResetsIdentity() {
        let s = InMemoryTokenStore()
        s.writeClientId("uuid-x")
        XCTAssertEqual(s.readClientId(), "uuid-x")
        s.clearClientId()
        XCTAssertNil(s.readClientId(), "clearClientId wipes the stored id")
    }

    /// Issue 1 dedup: a transaction is claimed once — the StoreKit observer
    /// skips one an explicit purchase() already claimed, so they don't both
    /// upload the same transaction.
    func testClaimTransactionDeduplicates() async {
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
        let client = SalesClient(config)
        let first  = await client.claimTransaction("tx-1")
        let second = await client.claimTransaction("tx-1")
        let other  = await client.claimTransaction("tx-2")
        XCTAssertTrue(first,  "first claim wins")
        XCTAssertFalse(second, "duplicate claim is rejected")
        XCTAssertTrue(other,  "a different transaction claims fine")
    }
}
