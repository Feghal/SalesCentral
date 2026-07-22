import XCTest
@testable import SalesCentral

/// First-launch attestation + per-call assertions, against a mocked
/// DCAppAttestService and a stub URLProtocol transport.
final class AttestTests: XCTestCase {

    final class MockAttestService: AppAttestServicing, @unchecked Sendable {
        var supported = true
        private let lock = NSLock()
        private var _generateKeyCalls = 0
        var generateKeyCalls: Int {
            lock.lock(); defer { lock.unlock() }
            return _generateKeyCalls
        }
        var isSupported: Bool { supported }
        func generateKey() async throws -> String {
            lock.lock(); _generateKeyCalls += 1; lock.unlock()
            return "mock-key-id"
        }
        func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data {
            Data("attestation-for-\(keyId)".utf8)
        }
        /// When set, generateAssertion throws for this keyId — simulating a
        /// Secure Enclave key that was invalidated (device restore / rotation).
        var failAssertionForKeyId: String?
        func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data {
            if let bad = failAssertionForKeyId, keyId == bad {
                throw SalesError.invalidState("mock: enclave key invalidated")
            }
            return Data("assertion-\(clientDataHash.base64EncodedString())".utf8)
        }
    }

    /// Stub for `AppTransactionProviding` — returns a canned JWS (or nil,
    /// simulating an `.xcode` environment / unavailable install proof).
    final class StubAppTransactionProvider: AppTransactionProviding, @unchecked Sendable {
        var jws: String?
        init(jws: String? = nil) { self.jws = jws }
        func installProofJWS() async -> String? { jws }
    }

    /// Routes stubbed responses by URL path; records every request.
    final class StubProtocol: URLProtocol {
        static var routes: [String: (Int, String)] = [:]
        static var seen: [(path: String, headers: [String: String], body: Data?)] = []
        /// Consulted before `routes` for paths that need stateful / sequenced
        /// responses (e.g. "fail once, then succeed"). Return nil to fall
        /// through to the static `routes` table.
        static var handler: ((String) -> (Int, String)?)?
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let path = request.url!.path
            var headers: [String: String] = [:]
            for (k, v) in request.allHTTPHeaderFields ?? [:] { headers[k.lowercased()] = v }
            let body = request.httpBody ?? request.httpBodyStream.map { stream -> Data in
                stream.open(); defer { stream.close() }
                var d = Data(); var buf = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let n = stream.read(&buf, maxLength: buf.count)
                    if n <= 0 { break }
                    d.append(buf, count: n)
                }
                return d
            }
            Self.seen.append((path, headers, body))
            let (status, json) = Self.handler?(path) ?? Self.routes[path] ?? (404, #"{"ok":false,"error":"not_found"}"#)
            let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(json.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    /// Minimal decodable ConfigBundleResponse — same shape as the fixture in
    /// SalesCentralTests.swift (id/premium/credits/entitlements/features are
    /// the fields SalesUser requires).
    static let bundleJSON = #"{"ok":true,"token":"next-token","user":{"id":"u-1","premium":{"tier":"free"},"credits":{"balance":0},"entitlements":{},"features":[],"properties":{}}}"#

    private func makeClient(
        store: InMemoryTokenStore, mock: MockAttestService,
        appTransactionService: AppTransactionProviding = StubAppTransactionProvider()
    ) -> SalesClient {
        let conf = URLSessionConfiguration.ephemeral
        conf.protocolClasses = [StubProtocol.self]
        let config = SalesConfig(
            baseURL: URL(string: "https://unit.test")!,
            apiKey: "csk_test",
            tokens: .init(
                createOrFetchUser: "c0ffee000001", restoreUser: "c0ffee000002",
                applyPurchases: "c0ffee000003", currentSubscription: "c0ffee000004",
                spendCredits: "c0ffee000005", recordSession: "c0ffee000006",
                recordEvent: "c0ffee000007",
                attestChallenge: "c0ffee000008", attestKey: "c0ffee000009",
                claimReward: "c0ffee000010"
            ),
            tokenStore: store
        )
        return SalesClient(
            config, urlSession: URLSession(configuration: conf),
            attestService: mock, appTransactionService: appTransactionService
        )
    }

    override func setUp() {
        super.setUp()
        StubProtocol.routes = [
            "/c0ffee000008": (200, #"{"ok":true,"challenge":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}"#),
            "/c0ffee000009": (200, #"{"ok":true}"#),
            "/c0ffee000001": (200, Self.bundleJSON),
            "/c0ffee000007": (200, #"{"ok":true}"#),
        ]
        StubProtocol.seen = []
        StubProtocol.handler = nil
    }

    func testFirstLaunchAttestsRegistersAndAsserts() async throws {
        let store = InMemoryTokenStore()
        let mock = MockAttestService()
        let client = makeClient(store: store, mock: mock)
        _ = try await client.ensureUser()

        XCTAssertEqual(mock.generateKeyCalls, 1)
        XCTAssertEqual(store.readAttestKeyId(), "mock-key-id")
        let paths = StubProtocol.seen.map(\.path)
        // challenge (attest) → register → challenge (assert) → createOrFetch
        XCTAssertEqual(paths, ["/c0ffee000008", "/c0ffee000009", "/c0ffee000008", "/c0ffee000001"])
        let create = StubProtocol.seen.last!
        XCTAssertEqual(create.headers["x-attest-key-id"], "mock-key-id")
        XCTAssertNotNil(create.headers["x-attest-challenge"])
        XCTAssertNotNil(create.headers["x-attest-assertion"])
    }

    func testInvalidStoredKeyReattestsAndRecovers() async throws {
        // The stored keyId points to an Enclave key that can no longer sign
        // (device restore / container reset). The keyId survives in the
        // Keychain, so without self-heal this is a permanent failure.
        let store = InMemoryTokenStore()
        store.writeAttestKeyId("stale-key-id")
        let mock = MockAttestService()
        mock.failAssertionForKeyId = "stale-key-id"
        let client = makeClient(store: store, mock: mock)

        _ = try await client.ensureUser()   // must self-heal, not throw

        XCTAssertEqual(mock.generateKeyCalls, 1, "generated exactly one fresh key")
        XCTAssertEqual(store.readAttestKeyId(), "mock-key-id", "stale key replaced")
        let create = StubProtocol.seen.last!
        XCTAssertEqual(create.path, "/c0ffee000001")
        XCTAssertEqual(create.headers["x-attest-key-id"], "mock-key-id", "asserted with fresh key")
    }

    func testStoredKeySkipsAttestation() async throws {
        let store = InMemoryTokenStore()
        store.writeAttestKeyId("mock-key-id")
        let mock = MockAttestService()
        let client = makeClient(store: store, mock: mock)
        _ = try await client.ensureUser()
        XCTAssertEqual(mock.generateKeyCalls, 0, "no re-attestation with a stored key")
        XCTAssertEqual(StubProtocol.seen.map(\.path), ["/c0ffee000008", "/c0ffee000001"])
    }

    func testTelemetryIsNotAsserted() async throws {
        let store = InMemoryTokenStore(initial: "user-jwt")
        store.writeAttestKeyId("mock-key-id")
        let client = makeClient(store: store, mock: MockAttestService())
        await client.track("opened_app")
        let event = StubProtocol.seen.last!
        XCTAssertEqual(event.path, "/c0ffee000007")
        XCTAssertNil(event.headers["x-attest-key-id"], "telemetry carries no assertion")
        XCTAssertFalse(StubProtocol.seen.contains { $0.path == "/c0ffee000008" }, "no challenge fetched")
    }

    func testUnsupportedDeviceRunsSandboxed() async throws {
        let store = InMemoryTokenStore()
        let mock = MockAttestService()
        mock.supported = false
        let client = makeClient(store: store, mock: mock)
        _ = try await client.ensureUser()   // must NOT throw

        XCTAssertEqual(mock.generateKeyCalls, 0, "no key generation on unsupported platforms")
        let create = StubProtocol.seen.last!
        XCTAssertEqual(create.headers["x-attest-unsupported"], "1", "explicit sandbox signal sent")
        XCTAssertNil(create.headers["x-attest-key-id"], "no attest headers")
        XCTAssertFalse(StubProtocol.seen.contains { $0.path == "/c0ffee000008" }, "no challenge fetched")
    }

    func testUnknownKeyTriggersOneReattestThenStops() async throws {
        let store = InMemoryTokenStore()
        store.writeAttestKeyId("stale-key-id")
        let mock = MockAttestService()
        let client = makeClient(store: store, mock: mock)
        // The server rejects the stale key on EVERY attempt: the client must
        // clear the key, re-attest exactly once, retry once, then give up
        // with the server error (no infinite attest/retry loop).
        StubProtocol.routes["/c0ffee000001"] = (401, #"{"ok":false,"error":"unknown_attest_key"}"#)
        do {
            _ = try await client.ensureUser()
            XCTFail("must surface the server rejection after one retry")
        } catch let e as SalesError {
            XCTAssertEqual(e.code, "unknown_attest_key")
        } catch { XCTFail("wrong error type: \(error)") }
        XCTAssertEqual(store.readAttestKeyId(), "mock-key-id", "stale key replaced by re-attested key")
        XCTAssertEqual(mock.generateKeyCalls, 1, "re-attested exactly once")
        let createAttempts = StubProtocol.seen.filter { $0.path == "/c0ffee000001" }.count
        XCTAssertEqual(createAttempts, 2, "original attempt + exactly one retry")
    }

    func testConcurrentFirstCallsShareOneAttestation() async throws {
        let store = InMemoryTokenStore()
        let mock = MockAttestService()
        let client = makeClient(store: store, mock: mock)
        async let a: SalesUser = client.ensureUser()
        async let b: SalesUser = client.ensureUser()
        _ = try await (a, b)
        XCTAssertEqual(mock.generateKeyCalls, 1, "concurrent first calls must share one attest flow")
        let registrations = StubProtocol.seen.filter { $0.path == "/c0ffee000009" }.count
        XCTAssertEqual(registrations, 1, "exactly one key registration")
    }

    func testTokenKeyMismatchRecoversByReMintingUserToken() async throws {
        let store = InMemoryTokenStore(initial: "stale-user-token")
        store.writeAttestKeyId("mock-key-id")
        let mock = MockAttestService()
        let client = makeClient(store: store, mock: mock)

        // First spendCredits attempt fails with 403 token_key_mismatch (the
        // stored user JWT names a previous device key); every attempt after
        // that succeeds with a valid Credits payload.
        var spendAttempts = 0
        StubProtocol.handler = { path in
            guard path == "/c0ffee000005" else { return nil }
            spendAttempts += 1
            if spendAttempts == 1 {
                return (403, #"{"ok":false,"error":"token_key_mismatch"}"#)
            }
            return (200, #"{"balance":5,"locked":0}"#)
        }

        let credits = try await client.spendCredits(5, reason: "test")
        XCTAssertEqual(credits.balance, 5)
        XCTAssertEqual(spendAttempts, 2, "original attempt + exactly one retry")

        let paths = StubProtocol.seen.map(\.path)
        // spendCredits(403) → (assertion challenge) → createOrFetchUser(re-mint)
        // → (assertion challenge) → spendCredits(200)
        XCTAssertEqual(paths, [
            "/c0ffee000008", "/c0ffee000005",
            "/c0ffee000008", "/c0ffee000001",
            "/c0ffee000008", "/c0ffee000005",
        ])
        XCTAssertEqual(paths.filter { $0 == "/c0ffee000005" }.count, 2, "exactly 2 spendCredits attempts")
        XCTAssertEqual(paths.filter { $0 == "/c0ffee000001" }.count, 1, "exactly 1 createOrFetchUser")
        XCTAssertEqual(store.read(), "next-token", "stale user token replaced by the re-minted one")
    }

    // MARK: - AppTransaction (App Store install proof) fallback tier

    func testAppTransactionHeaderSentWhenUnattestedAndProofAvailable() async throws {
        let store = InMemoryTokenStore()
        let mock = MockAttestService()
        mock.supported = false
        let provider = StubAppTransactionProvider(jws: "fake-app-transaction-jws")
        let client = makeClient(store: store, mock: mock, appTransactionService: provider)
        _ = try await client.ensureUser()   // must NOT throw

        let create = StubProtocol.seen.last!
        XCTAssertEqual(create.headers["x-attest-unsupported"], "1", "still signals attest is unavailable")
        XCTAssertEqual(create.headers["x-app-transaction"], "fake-app-transaction-jws", "install proof attached alongside it")
    }

    func testAppTransactionHeaderOmittedWhenProviderReturnsNil() async throws {
        let store = InMemoryTokenStore()
        let mock = MockAttestService()
        mock.supported = false
        // nil mirrors an unverified / .xcode-environment AppTransaction.
        let provider = StubAppTransactionProvider(jws: nil)
        let client = makeClient(store: store, mock: mock, appTransactionService: provider)
        _ = try await client.ensureUser()

        let create = StubProtocol.seen.last!
        XCTAssertEqual(create.headers["x-attest-unsupported"], "1")
        XCTAssertNil(create.headers["x-app-transaction"], "no install proof available — header omitted")
    }

    func testAppTransactionHeaderNotSentWhenAttestIsSupported() async throws {
        let store = InMemoryTokenStore()
        let mock = MockAttestService()   // supported = true (default)
        let provider = StubAppTransactionProvider(jws: "fake-app-transaction-jws")
        let client = makeClient(store: store, mock: mock, appTransactionService: provider)
        _ = try await client.ensureUser()

        let create = StubProtocol.seen.last!
        XCTAssertNil(create.headers["x-attest-unsupported"], "device can attest — no fallback signal")
        XCTAssertNil(create.headers["x-app-transaction"], "attest path taken — install proof fallback never consulted")
        XCTAssertNotNil(create.headers["x-attest-key-id"], "real attest headers attached instead")
    }

    func testAppTransactionHeaderOmittedOnceUserTokenExists() async throws {
        // Once a session already has a user token, createOrFetchUser is no
        // longer a "tokenless bootstrap" — the install-proof fallback must
        // not attach (mirrors how a reuse-limit reject must never be able
        // to touch a live session).
        let store = InMemoryTokenStore(initial: "existing-user-token")
        let mock = MockAttestService()
        mock.supported = false
        let provider = StubAppTransactionProvider(jws: "fake-app-transaction-jws")
        let client = makeClient(store: store, mock: mock, appTransactionService: provider)
        _ = try await client.ensureUser()

        let create = StubProtocol.seen.last!
        XCTAssertEqual(create.headers["x-attest-unsupported"], "1")
        XCTAssertEqual(create.headers["x-user-token"], "existing-user-token")
        XCTAssertNil(create.headers["x-app-transaction"], "not a tokenless bootstrap — fallback omitted")
    }

    func testAppTransactionErrorCodesDoNotWipeUserSession() async throws {
        let store = InMemoryTokenStore(initial: "user-jwt")
        let mock = MockAttestService()
        let client = makeClient(store: store, mock: mock)
        StubProtocol.routes["/c0ffee000001"] = (401, #"{"ok":false,"error":"app_transaction_reuse_limit"}"#)

        do {
            _ = try await client.ensureUser()
            XCTFail("expected the reuse-limit rejection to surface")
        } catch let e as SalesError {
            XCTAssertEqual(e.code, "app_transaction_reuse_limit")
        } catch {
            XCTFail("wrong error type: \(error)")
        }
        XCTAssertEqual(store.read(), "user-jwt", "an app_transaction reject must not wipe the user session")
    }
}
