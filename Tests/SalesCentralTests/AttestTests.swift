import XCTest
@testable import SalesCentral

/// First-launch attestation + per-call assertions, against a mocked
/// DCAppAttestService and a stub URLProtocol transport.
final class AttestTests: XCTestCase {

    final class MockAttestService: AppAttestServicing, @unchecked Sendable {
        var supported = true
        var generateKeyCalls = 0
        var isSupported: Bool { supported }
        func generateKey() async throws -> String { generateKeyCalls += 1; return "mock-key-id" }
        func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data {
            Data("attestation-for-\(keyId)".utf8)
        }
        func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data {
            Data("assertion-\(clientDataHash.base64EncodedString())".utf8)
        }
    }

    /// Routes stubbed responses by URL path; records every request.
    final class StubProtocol: URLProtocol {
        static var routes: [String: (Int, String)] = [:]
        static var seen: [(path: String, headers: [String: String], body: Data?)] = []
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
            let (status, json) = Self.routes[path] ?? (404, #"{"ok":false,"error":"not_found"}"#)
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

    private func makeClient(store: InMemoryTokenStore, mock: MockAttestService) -> SalesClient {
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
        return SalesClient(config, urlSession: URLSession(configuration: conf), attestService: mock)
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

    func testUnsupportedDeviceThrows() async {
        let store = InMemoryTokenStore()
        let mock = MockAttestService()
        mock.supported = false
        let client = makeClient(store: store, mock: mock)
        do {
            _ = try await client.ensureUser()
            XCTFail("must throw")
        } catch let e as SalesError {
            guard case .attestUnsupported = e else { return XCTFail("wrong error: \(e)") }
        } catch { XCTFail("wrong error type: \(error)") }
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
}
