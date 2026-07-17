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
}
