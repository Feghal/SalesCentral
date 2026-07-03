import XCTest
@testable import SalesCentral

/// Smoke tests covering the parts that don't need a real server.
final class SalesCentralTests: XCTestCase {

    func testTokenURLComposition() throws {
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
        XCTAssertEqual(config.url(for: .createOrFetchUser).absoluteString,
                       "https://sales.example.com/111111111111")
        XCTAssertEqual(config.url(for: .recordEvent).absoluteString,
                       "https://sales.example.com/777777777777")
    }

    func testTokenStoreRoundtrip() {
        let store = InMemoryTokenStore()
        XCTAssertNil(store.read())
        store.write("eyJ-test")
        XCTAssertEqual(store.read(), "eyJ-test")
        store.clear()
        XCTAssertNil(store.read())
    }

    /// `KeychainTokenStore` shadows the JWT in UserDefaults so an app
    /// transfer (which leaves the new build unable to read the prior
    /// keychain entries) can still recover the user. Simulate the transfer
    /// by wiping the keychain underneath the store and confirming the read
    /// recovers from UserDefaults, then self-heals on next access.
    func testKeychainTokenStoreFallsBackToDefaults() throws {
        let suiteName = "SalesCentralTests.keychainFallback.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let service = "central.sales.test.\(UUID().uuidString)"

        let store = KeychainTokenStore(service: service, defaults: defaults)
        store.clear()
        store.write("eyJ-real")
        XCTAssertEqual(store.read(), "eyJ-real")

        // Simulate post-transfer keychain blackout: drop only the keychain
        // entry, leave the UserDefaults shadow alone.
        let q: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "user_token",
        ]
        SecItemDelete(q as CFDictionary)

        // The fallback path returns the shadowed value.
        XCTAssertEqual(store.read(), "eyJ-real")

        // And self-healed back into the keychain: re-delete only the
        // defaults shadow and verify the keychain copy now satisfies reads.
        defaults.removeObject(forKey: "\(service).user_token")
        XCTAssertEqual(store.read(), "eyJ-real")

        store.clear()
        XCTAssertNil(store.read())
    }

    func testContextCurrentDoesNotCrash() {
        let ctx = UserContext.current()
        // We don't assert specifics — the contents depend on the host
        // environment — but the call must not crash and it must produce
        // *some* device data.
        XCTAssertNotNil(ctx.device)
        XCTAssertNotNil(ctx.locale)
    }

    func testContextMergePrefersOther() {
        var a = UserContext(locale: LocaleContext(language: "en"))
        let b = UserContext(locale: LocaleContext(language: "ja"))
        a.merge(b)
        XCTAssertEqual(a.locale?.language, "ja")
    }

    func testCreditsDecodesSpendReceiptFields() throws {
        // Shape of a POST credits/spend response (Task: spend receipts).
        let json = #"{"ok":true,"transactionId":"led-1","receipt":"eyJhbGciOiJIUzI1NiJ9.e30.sig","balance":50,"locked":0}"#
        let credits = try JSONDecoder().decode(Credits.self, from: Data(json.utf8))
        XCTAssertEqual(credits.balance, 50)
        XCTAssertEqual(credits.transactionId, "led-1")
        XCTAssertEqual(credits.receipt, "eyJhbGciOiJIUzI1NiJ9.e30.sig")
    }

    func testCreditsWithoutReceiptFieldsDecodesNil() throws {
        // Non-spend sources of Credits (user fetch, claimReward) omit both.
        let json = #"{"balance":10,"locked":3}"#
        let credits = try JSONDecoder().decode(Credits.self, from: Data(json.utf8))
        XCTAssertEqual(credits.balance, 10)
        XCTAssertNil(credits.transactionId)
        XCTAssertNil(credits.receipt)
    }

    /// `SalesClient.setUserProperties` posts the right wire shape to the
    /// `createOrFetchUser` endpoint: a body of `{ "properties": {...} }`
    /// where string / number / bool / null are each encoded correctly.
    /// Integer-valued doubles encode as JSON integers (cosmetic, but the
    /// admin renders them raw).
    func testSetUserPropertiesPostsExpectedJSON() async throws {
        // Stub URLSession that records the request body and returns a
        // minimal success response.
        URLProtocol.registerClass(StubURLProtocol.self)
        defer { URLProtocol.unregisterClass(StubURLProtocol.self) }
        let conf = URLSessionConfiguration.ephemeral
        conf.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: conf)

        StubURLProtocol.next = { _ in
            let payload: [String: Any] = [
                "ok": true,
                "token": "next-token",
                "challenge": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                "user": [
                    "id": "u-1",
                    "premium": ["tier": "free"],
                    "credits": ["balance": 0],
                    "entitlements": [:],
                    "features": [],
                    "properties": [
                        "email": "alice@example.com",
                        "lifetime_orders": 3,
                        "wants_emails": true,
                    ],
                ],
            ]
            return (
                HTTPURLResponse(url: URL(string: "https://test")!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                try! JSONSerialization.data(withJSONObject: payload)
            )
        }

        let store = InMemoryTokenStore(initial: "starting-token")
        store.writeAttestKeyId("mock-key-id")
        let config = SalesConfig(
            baseURL: URL(string: "https://sales.test")!,
            apiKey: "csk_x",
            tokens: .init(
                createOrFetchUser:   "AAAAAAAAAAAA",
                restoreUser:         "BBBBBBBBBBBB",
                applyPurchases:      "CCCCCCCCCCCC",
                currentSubscription: "DDDDDDDDDDDD",
                spendCredits:        "EEEEEEEEEEEE",
                recordSession:       "FFFFFFFFFFFF",
                recordEvent:         "GGGGGGGGGGGG",
                attestChallenge:     "attc00000000",
                attestKey:           "attk00000000"
            ),
            tokenStore: store
        )
        let client = SalesClient(config, urlSession: session, attestService: StubAttestService())

        let user = try await client.setUserProperties([
            "email": "alice@example.com",
            "lifetime_orders": 3,
            "wants_emails": true,
            "old_key": nil,                  // delete
        ])

        // Body assertions: the recorded request must include each value
        // encoded in its natural JSON form, plus a JSON null for the
        // delete sentinel.
        let body = try XCTUnwrap(StubURLProtocol.lastBody)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let props = try XCTUnwrap(json?["properties"] as? [String: Any])
        XCTAssertEqual(props["email"]           as? String, "alice@example.com")
        XCTAssertEqual(props["lifetime_orders"] as? Int,    3)
        XCTAssertEqual(props["wants_emails"]    as? Bool,   true)
        XCTAssertTrue(props["old_key"] is NSNull)

        // The decoded user surfaces the properties dict via the typed enum.
        XCTAssertEqual(user.properties["email"], .string("alice@example.com"))
        XCTAssertEqual(user.properties["lifetime_orders"], .number(3))
        XCTAssertEqual(user.properties["wants_emails"], .bool(true))

        // And the rotated token was persisted.
        XCTAssertEqual(store.read(), "next-token")
    }

    /// `ensureUser` decodes the new bundled blocks (paywalls /
    /// remoteConfig / experimentAssignments) and caches them on the
    /// client so later reads are synchronous.
    func testEnsureUserAbsorbsConfigBundle() async throws {
        URLProtocol.registerClass(StubURLProtocol.self)
        defer { URLProtocol.unregisterClass(StubURLProtocol.self) }
        let conf = URLSessionConfiguration.ephemeral
        conf.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: conf)

        StubURLProtocol.next = { _ in
            let payload: [String: Any] = [
                "ok": true,
                "token": "t",
                "challenge": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                "user": [
                    "id": "u-1",
                    "premium": ["tier": "free"],
                    "credits": ["balance": 0],
                    "entitlements": [:],
                    "features": [],
                ],
                "paywalls": [
                    [
                        "key": "main",
                        "name": "Main paywall",
                        "productIds": ["com.app.pro.year"],
                        "data": [
                            "headline": "Go Pro",
                            "bullets": ["Unlimited", "Priority support"],
                            "show_trial": true,
                            "trial_days": 7,
                        ],
                    ],
                ],
                "remoteConfig": [
                    "cta_label": "Continue",
                    "max_retries": 3,
                    "feature_x_enabled": true,
                ],
                "experimentAssignments": [
                    "headline_test": "A",
                ],
            ]
            return (
                HTTPURLResponse(url: URL(string: "https://t")!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                try! JSONSerialization.data(withJSONObject: payload)
            )
        }

        let store = InMemoryTokenStore()
        let config = SalesConfig(
            baseURL: URL(string: "https://sales.test")!,
            apiKey: "csk_x",
            tokens: .init(
                createOrFetchUser:   "AAAAAAAAAAAA",
                restoreUser:         "BBBBBBBBBBBB",
                applyPurchases:      "CCCCCCCCCCCC",
                currentSubscription: "DDDDDDDDDDDD",
                spendCredits:        "EEEEEEEEEEEE",
                recordSession:       "FFFFFFFFFFFF",
                recordEvent:         "GGGGGGGGGGGG",
                attestChallenge:     "attc00000000",
                attestKey:           "attk00000000"
            ),
            tokenStore: store
        )
        let client = SalesClient(config, urlSession: session, attestService: StubAttestService())
        _ = try await client.ensureUser()

        // Paywall is cached.
        let pw = try await client.paywall(key: "main")
        XCTAssertEqual(pw.name, "Main paywall")
        XCTAssertEqual(pw.productIds, ["com.app.pro.year"])
        XCTAssertEqual(pw.data["headline"]?.stringValue, "Go Pro")
        XCTAssertEqual(pw.data["bullets"]?.arrayValue?.count, 2)
        XCTAssertEqual(pw.data["show_trial"]?.boolValue, true)
        XCTAssertEqual(pw.data["trial_days"]?.intValue, 7)

        // Remote config typed lookups.
        let label: String = await client.remoteConfig("cta_label", default: "fallback")
        XCTAssertEqual(label, "Continue")
        let retries: Int = await client.remoteConfig("max_retries", default: 99)
        XCTAssertEqual(retries, 3)
        let flag: Bool = await client.remoteConfig("feature_x_enabled", default: false)
        XCTAssertTrue(flag)
        // Missing key → default.
        let missing: String = await client.remoteConfig("nonexistent", default: "fallback")
        XCTAssertEqual(missing, "fallback")

        // Experiment assignments are surfaced.
        let assignments = await client.activeExperiments()
        XCTAssertEqual(assignments["headline_test"], "A")
    }

    /// Calling `setUserProperties` with no token bubbles an
    /// `invalidState` error rather than silently creating a fresh user.
    func testSetUserPropertiesRequiresUserToken() async {
        let store = InMemoryTokenStore()   // no token
        let config = SalesConfig(
            baseURL: URL(string: "https://sales.test")!,
            apiKey: "csk_x",
            tokens: .init(
                createOrFetchUser:   "AAAAAAAAAAAA",
                restoreUser:         "BBBBBBBBBBBB",
                applyPurchases:      "CCCCCCCCCCCC",
                currentSubscription: "DDDDDDDDDDDD",
                spendCredits:        "EEEEEEEEEEEE",
                recordSession:       "FFFFFFFFFFFF",
                recordEvent:         "GGGGGGGGGGGG",
                attestChallenge:     "attc00000000",
                attestKey:           "attk00000000"
            ),
            tokenStore: store
        )
        let client = SalesClient(config)
        do {
            _ = try await client.setUserProperties(["email": "alice@example.com"])
            XCTFail("expected invalidState error")
        } catch let SalesError.invalidState(reason) {
            XCTAssertTrue(reason.contains("no user token"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}

// MARK: - Stub URLProtocol

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var next: ((URLRequest) -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var lastBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLProtocol drops httpBody when the request has been adapted to a
        // stream; pull it from httpBodyStream as a fallback.
        if let body = request.httpBody {
            Self.lastBody = body
        } else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
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
        let (resp, data) = Self.next?(request) ?? (
            HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
            Data()
        )
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Stub AppAttestServicing

/// App Attest is unavailable on the machine running `swift test` (no
/// DeviceCheck), so these HTTP-plumbing tests inject a trivial mock — they
/// aren't exercising attestation itself, just need calls to asserted
/// endpoints to get past the local `isSupported` gate. See AttestTests.swift
/// for the real attestation-flow coverage.
private struct StubAttestService: AppAttestServicing, Sendable {
    var isSupported: Bool { true }
    func generateKey() async throws -> String { "stub-key-id" }
    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data { Data("stub-attestation".utf8) }
    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data { Data("stub-assertion".utf8) }
}
