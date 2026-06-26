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
}
