import XCTest
import DeviceCheck
@testable import SalesCentral

/// First-launch attestation + per-call assertions, against a mocked
/// DCAppAttestService and a stub URLProtocol transport.
final class AttestTests: XCTestCase {

    final class MockAttestService: AppAttestServicing, @unchecked Sendable {
        var supported = true
        private let lock = NSLock()
        private var _generateKeyCalls = 0
        private var _assertionKeyIds: [String] = []
        private var _inFlight = 0
        private var _maxInFlight = 0
        private var _counters: [String: Int] = [:]
        var generateKeyCalls: Int {
            lock.lock(); defer { lock.unlock() }
            return _generateKeyCalls
        }
        /// The keyId of every generateAssertion call, in call order.
        var assertionKeyIds: [String] {
            lock.lock(); defer { lock.unlock() }
            return _assertionKeyIds
        }
        /// The most generateAssertion calls that were ever running at once.
        var maxConcurrentAssertions: Int {
            lock.lock(); defer { lock.unlock() }
            return _maxInFlight
        }
        var isSupported: Bool { supported }
        func generateKey() async throws -> String {
            countKeyGeneration()
            return "mock-key-id"
        }
        func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data {
            Data("attestation-for-\(keyId)".utf8)
        }
        /// When set, generateAssertion throws invalidKey for this keyId — a
        /// Secure Enclave key that no longer exists (reinstall / restore).
        var failAssertionForKeyId: String?
        /// Scripted DeviceCheck failures: given the keyId and the 0-based
        /// attempt on that key, the error to throw — or nil to sign.
        var assertionError: ((_ keyId: String, _ attempt: Int) -> Error?)?
        /// Simulated Secure Enclave time per assertion (nanoseconds), so
        /// concurrent callers actually overlap.
        var assertionLatency: UInt64 = 0
        func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data {
            let attempt = beginAssertion(keyId)
            defer { endAssertion() }
            if assertionLatency > 0 { try? await Task.sleep(nanoseconds: assertionLatency) }
            if let bad = failAssertionForKeyId, keyId == bad { throw DCError(.invalidKey) }
            if let error = assertionError?(keyId, attempt) { throw error }
            // Like the Secure Enclave, every signature bumps the key's counter;
            // the stub server reads it back out of the assertion.
            return Data("assertion|\(nextCounter(keyId))|\(clientDataHash.base64EncodedString())".utf8)
        }

        private func countKeyGeneration() {
            lock.lock(); defer { lock.unlock() }
            _generateKeyCalls += 1
        }
        private func beginAssertion(_ keyId: String) -> Int {
            lock.lock(); defer { lock.unlock() }
            let attempt = _assertionKeyIds.filter { $0 == keyId }.count
            _assertionKeyIds.append(keyId)
            _inFlight += 1
            _maxInFlight = max(_maxInFlight, _inFlight)
            return attempt
        }
        private func endAssertion() {
            lock.lock(); defer { lock.unlock() }
            _inFlight -= 1
        }
        private func nextCounter(_ keyId: String) -> Int {
            lock.lock(); defer { lock.unlock() }
            _counters[keyId, default: 0] += 1
            return _counters[keyId]!
        }
    }

    /// The server's anti-replay rule (utils/appAttest.js verifyAssertion): an
    /// assertion's counter must exceed the last counter accepted for its key.
    final class CounterCheckingServer: @unchecked Sendable {
        private let lock = NSLock()
        private var lastCounter: [String: Int] = [:]
        private var _replays = 0
        var replays: Int {
            lock.lock(); defer { lock.unlock() }
            return _replays
        }
        /// False when the server would answer 401 assertion_replay.
        func accepts(_ headers: [String: String]) -> Bool {
            guard let keyId = headers["x-attest-key-id"], let counter = Self.counter(in: headers) else { return true }
            lock.lock(); defer { lock.unlock() }
            guard counter > lastCounter[keyId, default: 0] else {
                _replays += 1
                return false
            }
            lastCounter[keyId] = counter
            return true
        }
        static func counter(in headers: [String: String]) -> Int? {
            guard let b64 = headers["x-attest-assertion"], let data = Data(base64Encoded: b64),
                  let text = String(data: data, encoding: .utf8) else { return nil }
            let parts = text.split(separator: "|")
            return parts.count > 1 ? Int(parts[1]) : nil
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
        private static let lock = NSLock()
        private static var _seen: [(path: String, headers: [String: String], body: Data?)] = []
        /// Every request, in arrival order. Locked: concurrent tests send from
        /// several URLProtocol threads at once.
        static var seen: [(path: String, headers: [String: String], body: Data?)] {
            get { lock.lock(); defer { lock.unlock() }; return _seen }
            set { lock.lock(); defer { lock.unlock() }; _seen = newValue }
        }
        private static func record(_ entry: (path: String, headers: [String: String], body: Data?)) {
            lock.lock(); defer { lock.unlock() }
            _seen.append(entry)
        }
        /// Consulted before `routes` for paths that need stateful / sequenced
        /// responses (e.g. "fail once, then succeed"). Return nil to fall
        /// through to the static `routes` table.
        static var handler: ((String) -> (Int, String)?)?
        /// Like `handler`, but sees the request headers too — for a stub server
        /// that inspects the attest headers. Consulted first.
        static var responder: ((String, [String: String]) -> (Int, String)?)?
        /// Seconds the stub server spends on a request before `responder` /
        /// `handler` / `routes` decide the answer.
        static var delay: ((String, [String: String]) -> TimeInterval)?
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
            Self.record((path, headers, body))
            let respond = { [self] in
                let (status, json) = Self.responder?(path, headers) ?? Self.handler?(path) ?? Self.routes[path]
                    ?? (404, #"{"ok":false,"error":"not_found"}"#)
                let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data(json.utf8))
                client?.urlProtocolDidFinishLoading(self)
            }
            let wait = Self.delay?(path, headers) ?? 0
            if wait > 0 {
                DispatchQueue.global().asyncAfter(deadline: .now() + wait, execute: respond)
            } else {
                respond()
            }
        }
        override func stopLoading() {}
    }

    /// Minimal decodable ConfigBundleResponse — same shape as the fixture in
    /// SalesCentralTests.swift (id/premium/credits/entitlements/features are
    /// the fields SalesUser requires).
    static let bundleJSON = #"{"ok":true,"token":"next-token","user":{"id":"u-1","premium":{"tier":"free"},"credits":{"balance":0},"entitlements":{},"features":[],"properties":{}}}"#
    /// The same bundle carrying one paywall, key "main".
    static let bundleWithPaywallJSON = #"{"ok":true,"token":"next-token","user":{"id":"u-1","premium":{"tier":"free"},"credits":{"balance":0},"entitlements":{},"features":[],"properties":{}},"paywalls":[{"key":"main","name":"Main","productIds":["p1"],"data":{}}]}"#

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
            attestService: mock, appTransactionService: appTransactionService,
            receiptProvider: nil,
            // Production's attempts, without the pauses.
            attestRetry: AttestRetrySchedule(
                recheckRejectedKey: 0,
                transient: AttestRetrySchedule.standard.transient.map { _ in 0 }
            )
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
        StubProtocol.responder = nil
        StubProtocol.delay = nil
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

    // MARK: - Concurrent asserted calls

    func testConcurrentAssertedCallsReachTheServerInCounterOrder() async throws {
        // Startup fires several asserted calls at once. Signed in parallel and
        // sent in parallel, they can reach the server out of counter order, and
        // the server rejects the late one as assertion_replay.
        let store = InMemoryTokenStore(initial: "user-jwt")
        store.writeAttestKeyId("mock-key-id")
        let mock = MockAttestService()
        mock.assertionLatency = 20_000_000
        let client = makeClient(store: store, mock: mock)
        let server = CounterCheckingServer()
        StubProtocol.routes["/c0ffee000005"] = (200, #"{"balance":5,"locked":0}"#)
        // The server is slow on the first assertion it receives, so anything
        // signed after it but answered before it moves the counter past it.
        StubProtocol.delay = { _, headers in CounterCheckingServer.counter(in: headers) == 1 ? 0.2 : 0 }
        StubProtocol.responder = { _, headers in
            guard headers["x-attest-assertion"] != nil, !server.accepts(headers) else { return nil }
            return (401, #"{"ok":false,"error":"assertion_replay"}"#)
        }

        // Three different asserted calls, none a duplicate of another.
        async let spend = client.spendCredits(1, reason: "concurrency")
        async let user = client.ensureUser()
        async let property = client.setUserProperty("plan", "pro")
        _ = try await (spend, user, property)

        XCTAssertEqual(server.replays, 0, "every assertion reached the server in counter order")
        XCTAssertEqual(mock.maxConcurrentAssertions, 1, "DeviceCheck never signs two requests at once")
    }

    func testCallsQueuedBehindATokenKeyMismatchKeepTheirUserToken() async throws {
        // A spend answered 403 token_key_mismatch clears the stored token while
        // it re-mints. Calls already queued behind it must go out with the
        // token they were made with: the server answers a tokenless spend 401
        // user_token_required, and makes a brand-new user for a tokenless
        // properties update, which carries no clientId.
        let store = InMemoryTokenStore(initial: "user-jwt")
        store.writeAttestKeyId("mock-key-id")
        let mock = MockAttestService()
        mock.assertionLatency = 20_000_000   // the others queue while the first call signs
        let client = makeClient(store: store, mock: mock)
        StubProtocol.routes["/c0ffee000005"] = (200, #"{"balance":5,"locked":0}"#)
        StubProtocol.responder = { path, headers in
            guard path == "/c0ffee000005", headers["x-user-token"] == nil else { return nil }
            return (401, #"{"ok":false,"error":"user_token_required"}"#)
        }
        var spends = 0
        StubProtocol.handler = { path in
            guard path == "/c0ffee000005" else { return nil }
            spends += 1
            return spends == 1 ? (403, #"{"ok":false,"error":"token_key_mismatch"}"#) : nil
        }

        async let first = client.spendCredits(1, reason: "first")
        try await Task.sleep(nanoseconds: 5_000_000)   // the first spend takes its turn; the rest queue
        async let property = client.setUserProperty("plan", "pro")
        async let second = client.spendCredits(1, reason: "second")
        var failures: [String] = []
        do { _ = try await first } catch { failures.append("first spend: \(error)") }
        do { _ = try await property } catch { failures.append("setUserProperty: \(error)") }
        do { _ = try await second } catch { failures.append("second spend: \(error)") }

        XCTAssertEqual(failures, [], "every call succeeds")
        let tokenlessCreates = StubProtocol.seen.filter { $0.path == "/c0ffee000001" && $0.headers["x-user-token"] == nil }
        XCTAssertFalse(tokenlessCreates.isEmpty, "the re-mint went out")
        for create in tokenlessCreates {
            XCTAssertTrue(String(decoding: create.body ?? Data(), as: UTF8.self).contains("clientId"),
                          "only the clientId re-mint may go out tokenless; anything else makes a new user")
        }
    }

    func testConcurrentIdenticalUserFetchesShareOneRequest() async throws {
        // What app startup fires at once: the bootstrap, paywall-driven
        // refreshes, and a paywall lookup that misses the still-empty cache.
        let store = InMemoryTokenStore(initial: "user-jwt")
        store.writeAttestKeyId("mock-key-id")
        let mock = MockAttestService()
        mock.assertionLatency = 50_000_000   // the first fetch is still in flight when the rest arrive
        StubProtocol.routes["/c0ffee000001"] = (200, Self.bundleWithPaywallJSON)
        let client = makeClient(store: store, mock: mock)

        async let boot = client.ensureUser()
        async let again = client.ensureUser()
        async let refreshA: Void = client.refreshConfig()
        async let refreshB: Void = client.refreshConfig()
        async let paywall = client.paywall(key: "main")
        _ = try await (boot, again, refreshA, refreshB, paywall)

        XCTAssertEqual(StubProtocol.seen.filter { $0.path == "/c0ffee000001" }.count, 1, "one createOrFetchUser")
        XCTAssertEqual(StubProtocol.seen.filter { $0.path == "/c0ffee000008" }.count, 1, "one challenge")
        XCTAssertEqual(mock.assertionKeyIds.count, 1, "one assertion")
    }

    func testUserFetchesWithDifferentBodiesAreNotMerged() async throws {
        let store = InMemoryTokenStore(initial: "user-jwt")
        store.writeAttestKeyId("mock-key-id")
        let mock = MockAttestService()
        mock.assertionLatency = 50_000_000
        let client = makeClient(store: store, mock: mock)

        async let plain = client.ensureUser()
        async let push = client.updateContext(UserContext(push: PushContext(token: "apns-abc123")))
        _ = try await (plain, push)

        let creates = StubProtocol.seen.filter { $0.path == "/c0ffee000001" }
        XCTAssertEqual(creates.count, 2, "a call carrying its own context is never folded into another")
        XCTAssertTrue(creates.contains { String(decoding: $0.body ?? Data(), as: UTF8.self).contains("apns-abc123") },
                      "the push token reached the server")
    }

    func testTokenKeyMismatchDuringEnsureUserRecovers() async throws {
        // The re-mint inside a user fetch is itself a user fetch; it must not
        // wait on the very request that triggered it. The server only sends
        // token_key_mismatch on user-token endpoints today, but the SDK's 403
        // path is endpoint-agnostic, so this pins the no-self-wait property.
        let store = InMemoryTokenStore(initial: "stale-user-token")
        store.writeAttestKeyId("mock-key-id")
        let client = makeClient(store: store, mock: MockAttestService())
        var creates = 0
        StubProtocol.handler = { path in
            guard path == "/c0ffee000001" else { return nil }
            creates += 1
            return creates == 1 ? (403, #"{"ok":false,"error":"token_key_mismatch"}"#) : nil
        }

        let user = try await client.ensureUser()

        XCTAssertEqual(user.id, "u-1")
        XCTAssertEqual(creates, 3, "rejected call, tokenless re-mint, retried call")
        XCTAssertEqual(store.read(), "next-token")
    }

    // MARK: - Which DeviceCheck errors retire the stored key

    func testDeviceCheckErrorsAreClassified() {
        XCTAssertEqual(AttestFailure(DCError(.invalidKey)), .keyRejected)
        XCTAssertEqual(AttestFailure(DCError(.invalidInput)), .keyRejected)
        XCTAssertEqual(AttestFailure(DCError(.unknownSystemFailure)), .systemFailure)
        XCTAssertEqual(AttestFailure(DCError(.serverUnavailable)), .serviceUnavailable)
        XCTAssertEqual(AttestFailure(DCError(.featureUnsupported)), .other)
        XCTAssertEqual(AttestFailure(SalesError.network("offline")), .other)
        // As the framework hands them over — the shape the device log printed.
        XCTAssertEqual(AttestFailure(NSError(domain: "com.apple.devicecheck.error", code: 3)), .keyRejected)
        XCTAssertEqual(AttestFailure(NSError(domain: "com.apple.devicecheck.error", code: 0)), .systemFailure)
        XCTAssertEqual(AttestFailure(NSError(domain: NSURLErrorDomain, code: 3)), .other, "same code, other domain")
    }

    /// A client whose stored, registered key is "stored-key-id"; a new key
    /// would be "mock-key-id". `failure` scripts generateAssertion.
    private func makeStoredKeyClient(
        _ failure: @escaping (_ keyId: String, _ attempt: Int) -> Error?
    ) -> (client: SalesClient, store: InMemoryTokenStore, mock: MockAttestService) {
        let store = InMemoryTokenStore()
        store.writeAttestKeyId("stored-key-id")
        let mock = MockAttestService()
        mock.assertionError = failure
        return (makeClient(store: store, mock: mock), store, mock)
    }

    func testOneOffTransientFailureRetriesTheSameKey() async throws {
        for code in [DCError.Code.unknownSystemFailure, .serverUnavailable] {
            StubProtocol.seen = []
            let (client, store, mock) = makeStoredKeyClient { keyId, attempt in
                keyId == "stored-key-id" && attempt == 0 ? DCError(code) : nil
            }

            _ = try await client.ensureUser()

            XCTAssertEqual(mock.assertionKeyIds, ["stored-key-id", "stored-key-id"], "\(code): retried on the same key")
            XCTAssertEqual(mock.generateKeyCalls, 0, "\(code): no new key for a one-off failure")
            XCTAssertEqual(store.readAttestKeyId(), "stored-key-id", "\(code): stored key kept")
            XCTAssertEqual(StubProtocol.seen.last?.headers["x-attest-key-id"], "stored-key-id", "\(code)")
        }
    }

    func testPersistentServerUnavailableKeepsTheKeyAndFails() async throws {
        let (client, store, mock) = makeStoredKeyClient { _, _ in DCError(.serverUnavailable) }

        do {
            _ = try await client.ensureUser()
            XCTFail("expected the DeviceCheck error to surface")
        } catch let error as DCError {
            XCTAssertEqual(error.code, .serverUnavailable)
        }

        XCTAssertEqual(mock.assertionKeyIds, Array(repeating: "stored-key-id", count: 3), "three attempts on the same key")
        XCTAssertEqual(mock.generateKeyCalls, 0, "a busy service is no reason to spend an attestation")
        XCTAssertEqual(store.readAttestKeyId(), "stored-key-id")
        XCTAssertFalse(StubProtocol.seen.contains { $0.path == "/c0ffee000001" }, "nothing sent without an assertion")
    }

    func testPersistentUnknownSystemFailureRetiresTheKeyAfterRetries() async throws {
        // Code 0 that never clears is a known stuck state that only a new key
        // fixes (google/app-check#96). Our keyId survives reinstalls in the
        // Keychain, so keeping it would lock the device out for good.
        let (client, store, mock) = makeStoredKeyClient { keyId, _ in
            keyId == "stored-key-id" ? DCError(.unknownSystemFailure) : nil
        }

        _ = try await client.ensureUser()

        XCTAssertEqual(mock.assertionKeyIds, ["stored-key-id", "stored-key-id", "stored-key-id", "mock-key-id"])
        XCTAssertEqual(mock.generateKeyCalls, 1, "exactly one new key")
        XCTAssertEqual(store.readAttestKeyId(), "mock-key-id")
    }

    func testOneOffKeyRejectionIsRecheckedBeforeRetiringTheKey() async throws {
        for code in [DCError.Code.invalidKey, .invalidInput] {
            StubProtocol.seen = []
            let (client, store, mock) = makeStoredKeyClient { keyId, attempt in
                keyId == "stored-key-id" && attempt == 0 ? DCError(code) : nil
            }

            _ = try await client.ensureUser()

            XCTAssertEqual(mock.assertionKeyIds, ["stored-key-id", "stored-key-id"], "\(code): re-checked on the same key")
            XCTAssertEqual(mock.generateKeyCalls, 0, "\(code): one rejection is not proof the key is gone")
            XCTAssertEqual(store.readAttestKeyId(), "stored-key-id", "\(code)")
        }
    }

    func testConfirmedKeyRejectionRetiresTheKeyOnce() async throws {
        for code in [DCError.Code.invalidKey, .invalidInput] {
            StubProtocol.seen = []
            let (client, store, mock) = makeStoredKeyClient { keyId, _ in keyId == "stored-key-id" ? DCError(code) : nil }

            _ = try await client.ensureUser()

            XCTAssertEqual(mock.assertionKeyIds, ["stored-key-id", "stored-key-id", "mock-key-id"], "\(code)")
            XCTAssertEqual(mock.generateKeyCalls, 1, "\(code): exactly one new key")
            XCTAssertEqual(store.readAttestKeyId(), "mock-key-id", "\(code)")
            XCTAssertEqual(StubProtocol.seen.last?.headers["x-attest-key-id"], "mock-key-id", "\(code)")
        }
    }

    func testUnrecognizedFailureKeepsTheKeyAndFails() async throws {
        let failures: [Error] = [DCError(.featureUnsupported), SalesError.invalidState("not a DeviceCheck error")]
        for failure in failures {
            StubProtocol.seen = []
            let (client, store, mock) = makeStoredKeyClient { _, _ in failure }

            do {
                _ = try await client.ensureUser()
                XCTFail("expected \(failure) to surface")
            } catch {}

            XCTAssertEqual(mock.assertionKeyIds, ["stored-key-id"], "\(failure): not retried")
            XCTAssertEqual(mock.generateKeyCalls, 0, "\(failure): key kept")
            XCTAssertEqual(store.readAttestKeyId(), "stored-key-id", "\(failure)")
        }
    }
}
