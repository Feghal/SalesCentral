import XCTest
@testable import SalesCentral

/// Registered ("super") event properties merge into every tracked event's
/// properties at track time; per-call properties override; removal/clear work;
/// and the merged set rides through the outbox.
final class SuperPropertiesTests: XCTestCase {

    private func makeClient(session: URLSession, tokenStore: TokenStore) -> SalesClient {
        SalesClient(
            SalesConfig(
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
                tokenStore: tokenStore
            ),
            urlSession: session,
            attestService: StubAttestSvc()
        )
    }

    private func stubbedSession() -> URLSession {
        let conf = URLSessionConfiguration.ephemeral
        conf.protocolClasses = [SPRecordingURLProtocol.self]
        return URLSession(configuration: conf)
    }

    private static func ok(_ r: URLRequest) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: r.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(#"{"ok":true}"#.utf8))
    }

    /// Read the first recorded recordEvent (token GGGGGGGGGGGG) body's first
    /// event's properties as a plain dict.
    private func firstEventProps() throws -> [String: Any] {
        let call = SPRecordingURLProtocol.recorded.last { $0.url?.lastPathComponent == "GGGGGGGGGGGG" }
        let body = try XCTUnwrap(call?.body, "no recordEvent call recorded")
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        return try XCTUnwrap(events.first?["properties"] as? [String: Any])
    }

    func testRegisteredPropertyRidesOnEvent() async throws {
        SPRecordingURLProtocol.reset()
        URLProtocol.registerClass(SPRecordingURLProtocol.self)
        defer { URLProtocol.unregisterClass(SPRecordingURLProtocol.self) }
        SPRecordingURLProtocol.next = { Self.ok($0) }
        let client = makeClient(session: stubbedSession(), tokenStore: InMemoryTokenStore(initial: "user-token"))

        await client.setEventProperties(["plan": .init("premium")])
        await client.track("chat_sent")

        let props = try firstEventProps()
        XCTAssertEqual(props["plan"] as? String, "premium")
    }

    func testPerCallOverridesSuperProperty() async throws {
        SPRecordingURLProtocol.reset()
        URLProtocol.registerClass(SPRecordingURLProtocol.self)
        defer { URLProtocol.unregisterClass(SPRecordingURLProtocol.self) }
        SPRecordingURLProtocol.next = { Self.ok($0) }
        let client = makeClient(session: stubbedSession(), tokenStore: InMemoryTokenStore(initial: "user-token"))

        await client.setEventProperty("plan", .init("free"))
        await client.track("upgrade_tapped", properties: ["plan": .init("premium")])

        let props = try firstEventProps()
        XCTAssertEqual(props["plan"] as? String, "premium", "per-call wins over the registered value")
    }

    func testRemoveAndClear() async throws {
        SPRecordingURLProtocol.reset()
        URLProtocol.registerClass(SPRecordingURLProtocol.self)
        defer { URLProtocol.unregisterClass(SPRecordingURLProtocol.self) }
        SPRecordingURLProtocol.next = { Self.ok($0) }
        let client = makeClient(session: stubbedSession(), tokenStore: InMemoryTokenStore(initial: "user-token"))

        await client.setEventProperties(["plan": .init("premium"), "cohort": .init("A")])
        await client.removeEventProperty("plan")
        await client.track("e1")
        var props = try firstEventProps()
        XCTAssertNil(props["plan"])
        XCTAssertEqual(props["cohort"] as? String, "A")

        await client.clearEventProperties()
        await client.track("e2")
        props = try firstEventProps()
        XCTAssertNil(props["cohort"])
    }

    /// Registered at track time → rides with an event that queues (no user)
    /// and flushes after the user is established.
    func testCarriedThroughOutbox() async throws {
        SPRecordingURLProtocol.reset()
        URLProtocol.registerClass(SPRecordingURLProtocol.self)
        defer { URLProtocol.unregisterClass(SPRecordingURLProtocol.self) }
        let store = InMemoryTokenStore()             // no user yet
        store.writeAttestKeyId("mock-key-id")
        let client = makeClient(session: stubbedSession(), tokenStore: store)

        await client.setEventProperties(["plan": .init("premium")])
        await client.track("queued_evt")             // no token → queued, no HTTP yet

        SPRecordingURLProtocol.next = { request in
            // createOrFetchUser is an asserted endpoint: it first triggers a
            // live attestChallenge round-trip to build the assertion headers.
            // Both calls need a response beyond the bare {"ok":true} — the
            // challenge call needs a `challenge` field, the user call needs
            // `token`/`user` — so both are served the same full payload.
            if ["AAAAAAAAAAAA", "attc00000000"].contains(request.url?.lastPathComponent) {
                let payload: [String: Any] = [
                    "ok": true, "token": "t",
                    "challenge": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                    "user": ["id": "u-1", "premium": ["tier": "free"], "credits": ["balance": 0], "entitlements": [:], "features": []],
                ]
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        try! JSONSerialization.data(withJSONObject: payload))
            }
            return Self.ok(request)
        }
        _ = try await client.ensureUser()            // establishes user → triggers flush

        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline,
              !SPRecordingURLProtocol.recorded.contains(where: { $0.url?.lastPathComponent == "GGGGGGGGGGGG" }) {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let props = try firstEventProps()
        XCTAssertEqual(props["plan"] as? String, "premium", "super property snapshotted at track time survives the outbox")
    }
}

// MARK: - Stubs (this file owns its stubs, like every test file here)

private final class SPRecordingURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var recorded: [(url: URL?, body: Data?)] = []
    nonisolated(unsafe) static var next: ((URLRequest) -> (HTTPURLResponse, Data))?
    static func reset() { recorded = []; next = nil }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data()
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096); defer { buf.deallocate() }
            while stream.hasBytesAvailable { let n = stream.read(buf, maxLength: 4096); if n <= 0 { break }; data.append(buf, count: n) }
            body = data
        }
        Self.recorded.append((url: request.url, body: body))
        let (resp, data) = Self.next?(request) ?? (
            HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private struct StubAttestSvc: AppAttestServicing, Sendable {
    var isSupported: Bool { true }
    func generateKey() async throws -> String { "stub-key-id" }
    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data { Data("a".utf8) }
    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data { Data("s".utf8) }
}
