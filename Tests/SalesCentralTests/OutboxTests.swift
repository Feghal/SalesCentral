import XCTest
@testable import SalesCentral

/// Analytics outbox: pure queue model tests (Task 1) + SalesClient
/// send-or-enqueue integration tests (Task 2).
final class OutboxTests: XCTestCase {

    // ------------------------------------------------------------------
    // MARK: - Fixtures
    // ------------------------------------------------------------------

    private func event(_ n: Int) -> OutboxItem {
        .event(name: "e\(n)", properties: [:], occurredAt: Date(timeIntervalSince1970: Double(n)))
    }
    private func session(_ n: Int) -> OutboxItem {
        .session(start: Date(timeIntervalSince1970: Double(n)),
                 end: Date(timeIntervalSince1970: Double(n + 1)),
                 durationSec: 1)
    }

    // ------------------------------------------------------------------
    // MARK: - Outbox model
    // ------------------------------------------------------------------

    func testAppendPreservesFIFOOrder() {
        var box = Outbox()
        box.append([event(1), session(2)])
        box.append([event(3)])
        XCTAssertEqual(box.items, [event(1), session(2), event(3)])
        XCTAssertEqual(box.count, 3)
        XCTAssertFalse(box.isEmpty)
    }

    func testCapDropsOldestAndReportsCount() {
        var box = Outbox()
        box.append((0..<Outbox.cap).map(event))
        let dropped = box.append([event(9001), event(9002)])
        XCTAssertEqual(dropped, 2)
        XCTAssertEqual(box.count, Outbox.cap)
        XCTAssertEqual(box.items.first, event(2))   // items 0 and 1 were dropped
        XCTAssertEqual(box.items.last, event(9002))
    }

    func testDrainChunksLeadingEventRunAtFifty() {
        var box = Outbox()
        box.append((0..<51).map(event))
        guard case .events(let chunk)? = box.drainNext() else { return XCTFail("expected events batch") }
        XCTAssertEqual(chunk.count, Outbox.eventChunk)
        XCTAssertEqual(chunk.first, event(0))
        guard case .events(let rest)? = box.drainNext() else { return XCTFail("expected events batch") }
        XCTAssertEqual(rest, [event(50)])
        XCTAssertNil(box.drainNext())
        XCTAssertTrue(box.isEmpty)
    }

    func testDrainSplitsRunsAtSessionBoundaries() {
        var box = Outbox()
        box.append([event(1), event(2), session(3), event(4)])
        XCTAssertEqual(box.drainNext(), .events([event(1), event(2)]))
        XCTAssertEqual(box.drainNext(), .session(session(3)))
        XCTAssertEqual(box.drainNext(), .events([event(4)]))
        XCTAssertNil(box.drainNext())
    }

    func testRequeueRestoresFrontOrder() {
        var box = Outbox()
        box.append([event(1), event(2), session(3)])
        let batch = box.drainNext()!                 // events [1, 2]
        box.requeue(batch)
        XCTAssertEqual(box.items, [event(1), event(2), session(3)])
    }

    func testRequeueOverCapDropsEntireBatchWhenQueueRefilled() {
        var box = Outbox()
        box.append((0..<Outbox.cap).map(event))     // e0..e499 — full
        let batch = box.drainNext()!                 // e0..e49 drained; 450 left
        box.append((1000..<1050).map(event))         // refilled to 500
        let dropped = box.requeue(batch)             // 550 → clamp to 500
        XCTAssertEqual(dropped, 50)
        XCTAssertEqual(box.count, Outbox.cap)
        XCTAssertEqual(box.items.first, event(50), "the whole requeued batch was the oldest — dropped")
    }

    func testRequeuePartialOverCapDropsOnlyOldestOfBatch() {
        var box = Outbox()
        box.append((0..<Outbox.cap).map(event))     // e0..e499 — full
        let batch = box.drainNext()!                 // e0..e49 drained; 450 left
        box.append((1000..<1030).map(event))         // 480 total
        let dropped = box.requeue(batch)             // 530 → clamp to 500
        XCTAssertEqual(dropped, 30)
        XCTAssertEqual(box.count, Outbox.cap)
        XCTAssertEqual(box.items.first, event(30), "e0..e29 dropped; e30 is the oldest survivor")
    }

    func testRemoveAllEmptiesTheQueue() {
        var box = Outbox()
        box.append([event(1), session(2)])
        box.removeAll()
        XCTAssertTrue(box.isEmpty)
        XCTAssertNil(box.drainNext())
    }

    // ------------------------------------------------------------------
    // MARK: - Client integration
    // ------------------------------------------------------------------

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
            attestService: StubAttestService()
        )
    }

    private func stubbedSession() -> URLSession {
        let conf = URLSessionConfiguration.ephemeral
        conf.protocolClasses = [BodyRecordingURLProtocol.self]
        return URLSession(configuration: conf)
    }

    private static func ok200(_ request: URLRequest) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
         Data(#"{"ok":true}"#.utf8))
    }

    private static func status(_ code: Int) -> (URLRequest) -> (HTTPURLResponse, Data) {
        { request in
            (HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!,
             Data(#"{"error":"stub_error"}"#.utf8))
        }
    }

    /// Wire shapes for asserting flushed bodies. The SDK's encoder uses
    /// non-fractional ISO8601 — decode with a matching formatter.
    private struct WireEvent: Decodable { let name: String; let occurredAt: String }
    private struct WireBatch: Decodable { let events: [WireEvent] }
    private struct WireSession: Decodable { let startedAt: String; let endedAt: String; let durationSec: Int? }

    /// Pre-user track: queued locally with ZERO network traffic (today's
    /// behavior fires a doomed 401 round-trip; the outbox removes it).
    func testPreUserTrackQueuesWithoutNetwork() async {
        BodyRecordingURLProtocol.reset()
        URLProtocol.registerClass(BodyRecordingURLProtocol.self)
        defer { URLProtocol.unregisterClass(BodyRecordingURLProtocol.self) }
        let client = makeClient(session: stubbedSession(), tokenStore: InMemoryTokenStore())

        await client.track("pre_user_event", properties: ["k": .init("v")])
        await client.track("another")

        let pending = await client.pendingAnalyticsCount
        XCTAssertEqual(pending, 2)
        XCTAssertTrue(BodyRecordingURLProtocol.recorded.isEmpty, "no doomed pre-user round-trips")
    }

    /// A successful ensureUser auto-flushes the backlog (fire-and-forget
    /// trigger — polled), sending ONE batch that preserves call order and
    /// each event's ORIGINAL occurredAt.
    func testEnsureUserAutoFlushesQueueWithOriginalTimestamps() async throws {
        BodyRecordingURLProtocol.reset()
        URLProtocol.registerClass(BodyRecordingURLProtocol.self)
        defer { URLProtocol.unregisterClass(BodyRecordingURLProtocol.self) }
        let store = InMemoryTokenStore()
        store.writeAttestKeyId("mock-key-id")
        let client = makeClient(session: stubbedSession(), tokenStore: store)

        let beforeTrack = Date()
        await client.track("first")
        await client.track("second")

        BodyRecordingURLProtocol.next = { request in
            let payload: [String: Any] = [
                "ok": true, "token": "t",
                "challenge": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                "user": [
                    "id": "u-1",
                    "premium": ["tier": "free"],
                    "credits": ["balance": 0],
                    "entitlements": [:],
                    "features": [],
                ],
            ]
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                try! JSONSerialization.data(withJSONObject: payload)
            )
        }
        _ = try await client.ensureUser()

        // The post-ensureUser flush is a detached hop on the actor — poll
        // briefly for the recordEvent request instead of sleeping blind.
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline,
              !BodyRecordingURLProtocol.recorded.contains(where: { $0.url?.lastPathComponent == "GGGGGGGGGGGG" }) {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        let eventCall = BodyRecordingURLProtocol.recorded.last { $0.url?.lastPathComponent == "GGGGGGGGGGGG" }
        let body = try XCTUnwrap(eventCall?.body, "queued events never flushed")
        let batch = try JSONDecoder().decode(WireBatch.self, from: body)
        XCTAssertEqual(batch.events.map(\.name), ["first", "second"], "one batch, call order preserved")

        let iso = ISO8601DateFormatter()
        for wire in batch.events {
            let sent = try XCTUnwrap(iso.date(from: wire.occurredAt))
            XCTAssertLessThan(abs(sent.timeIntervalSince(beforeTrack)), 2,
                              "flush must carry the ORIGINAL occurredAt, not flush time")
        }
        let pending = await client.pendingAnalyticsCount
        XCTAssertEqual(pending, 0)
    }

    /// Retryable failure (500): the batch requeues — nothing lost, and the
    /// next explicit flush retries exactly once more.
    func testRetryableFailureRequeuesBatch() async {
        BodyRecordingURLProtocol.reset()
        URLProtocol.registerClass(BodyRecordingURLProtocol.self)
        defer { URLProtocol.unregisterClass(BodyRecordingURLProtocol.self) }
        let client = makeClient(session: stubbedSession(),
                                tokenStore: InMemoryTokenStore(initial: "user-token"))

        BodyRecordingURLProtocol.next = Self.status(500)
        await client.track("evt")                       // direct send → 500 → enqueued
        var pending = await client.pendingAnalyticsCount
        XCTAssertEqual(pending, 1)
        let afterFirst = BodyRecordingURLProtocol.recorded.count

        await client.flushOutbox()                      // still 500 → requeued
        pending = await client.pendingAnalyticsCount
        XCTAssertEqual(pending, 1)
        XCTAssertEqual(BodyRecordingURLProtocol.recorded.count, afterFirst + 1)

        BodyRecordingURLProtocol.next = { OutboxTests.ok200($0) }
        await client.flushOutbox()                      // recovers
        pending = await client.pendingAnalyticsCount
        XCTAssertEqual(pending, 0)
    }

    /// Non-retryable failure (400): dropped with a warn — not queued, not
    /// thrown (track is fire-and-forget).
    func testNonRetryableEventIsDroppedNotQueued() async {
        BodyRecordingURLProtocol.reset()
        URLProtocol.registerClass(BodyRecordingURLProtocol.self)
        defer { URLProtocol.unregisterClass(BodyRecordingURLProtocol.self) }
        let client = makeClient(session: stubbedSession(),
                                tokenStore: InMemoryTokenStore(initial: "user-token"))

        BodyRecordingURLProtocol.next = Self.status(400)
        await client.track("rejected")
        let pending = await client.pendingAnalyticsCount
        XCTAssertEqual(pending, 0)
    }

    /// New calls while backlogged go BEHIND the queue: the flush that the
    /// new call triggers sends one batch with the backlog first.
    func testNewEventGoesBehindBacklogAndFlushCoalesces() async throws {
        BodyRecordingURLProtocol.reset()
        URLProtocol.registerClass(BodyRecordingURLProtocol.self)
        defer { URLProtocol.unregisterClass(BodyRecordingURLProtocol.self) }
        let client = makeClient(session: stubbedSession(),
                                tokenStore: InMemoryTokenStore(initial: "user-token"))

        BodyRecordingURLProtocol.next = Self.status(500)
        await client.track("one")                       // 500 → queued
        BodyRecordingURLProtocol.next = { OutboxTests.ok200($0) }
        await client.track("two")                       // backlog → enqueue behind + flush

        let eventCall = BodyRecordingURLProtocol.recorded.last { $0.url?.lastPathComponent == "GGGGGGGGGGGG" }
        let body = try XCTUnwrap(eventCall?.body)
        let batch = try JSONDecoder().decode(WireBatch.self, from: body)
        XCTAssertEqual(batch.events.map(\.name), ["one", "two"])
        let pending = await client.pendingAnalyticsCount
        XCTAssertEqual(pending, 0)
    }

    /// Pre-user recordSession queues WITHOUT throwing; flush delivers it to
    /// the session endpoint with the original timestamps.
    func testPreUserSessionQueuesThenFlushes() async throws {
        BodyRecordingURLProtocol.reset()
        URLProtocol.registerClass(BodyRecordingURLProtocol.self)
        defer { URLProtocol.unregisterClass(BodyRecordingURLProtocol.self) }
        let store = InMemoryTokenStore()
        let client = makeClient(session: stubbedSession(), tokenStore: store)

        let start = Date(timeIntervalSinceNow: -60)
        let end = Date()
        try await client.recordSession(start: start, end: end, durationSec: 60)   // must NOT throw
        var pending = await client.pendingAnalyticsCount
        XCTAssertEqual(pending, 1)
        XCTAssertTrue(BodyRecordingURLProtocol.recorded.isEmpty)

        store.write("user-token")
        BodyRecordingURLProtocol.next = { OutboxTests.ok200($0) }
        await client.flushOutbox()

        let call = BodyRecordingURLProtocol.recorded.last { $0.url?.lastPathComponent == "FFFFFFFFFFFF" }
        let body = try XCTUnwrap(call?.body, "session never flushed")
        let wire = try JSONDecoder().decode(WireSession.self, from: body)
        XCTAssertEqual(wire.durationSec, 60)
        pending = await client.pendingAnalyticsCount
        XCTAssertEqual(pending, 0)
    }

    /// recordSession still throws on permanent rejections (contract keeps
    /// its throws for the non-retryable class only).
    func testSessionThrowsOnNonRetryableFailure() async {
        BodyRecordingURLProtocol.reset()
        URLProtocol.registerClass(BodyRecordingURLProtocol.self)
        defer { URLProtocol.unregisterClass(BodyRecordingURLProtocol.self) }
        let client = makeClient(session: stubbedSession(),
                                tokenStore: InMemoryTokenStore(initial: "user-token"))

        BodyRecordingURLProtocol.next = Self.status(422)
        do {
            try await client.recordSession(start: Date(timeIntervalSinceNow: -10), end: Date())
            XCTFail("expected a non-retryable throw")
        } catch let SalesError.http(status, _, _) {
            XCTAssertEqual(status, 422)
        } catch {
            XCTFail("unexpected error \(error)")
        }
        let pending = await client.pendingAnalyticsCount
        XCTAssertEqual(pending, 0, "non-retryable must not queue")
    }

    /// clearUser wipes the queue — items belong to the abandoned identity.
    func testClearUserEmptiesOutbox() async {
        let client = makeClient(session: stubbedSession(), tokenStore: InMemoryTokenStore())
        await client.track("orphan")
        var pending = await client.pendingAnalyticsCount
        XCTAssertEqual(pending, 1)
        await client.clearUser()
        pending = await client.pendingAnalyticsCount
        XCTAssertEqual(pending, 0)
    }
}

// MARK: - Stubs (this file owns its stubs, like every test file here)

/// Records (url, body) per request — the outbox tests assert flushed BODIES.
private final class BodyRecordingURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var recorded: [(url: URL?, body: Data?)] = []
    nonisolated(unsafe) static var next: ((URLRequest) -> (HTTPURLResponse, Data))?
    static func reset() { recorded = []; next = nil }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
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
            body = data
        }
        Self.recorded.append((url: request.url, body: body))
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

private struct StubAttestService: AppAttestServicing, Sendable {
    var isSupported: Bool { true }
    func generateKey() async throws -> String { "stub-key-id" }
    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data { Data("stub-attestation".utf8) }
    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data { Data("stub-assertion".utf8) }
}
