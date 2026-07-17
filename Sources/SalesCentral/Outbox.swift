import Foundation

/// One queued analytics call, carrying its original wall-clock data so a
/// late flush is indistinguishable server-side from a timely send (the
/// server honors client `occurredAt`).
enum OutboxItem: Sendable {
    case event(name: String, properties: [String: AnyEncodable], occurredAt: Date)
    case session(start: Date, end: Date, durationSec: Int?)
}

extension OutboxItem: Equatable {
    /// Equality ignores event `properties` — `AnyEncodable` is opaque, and
    /// name + timestamps are sufficient for the order/cap/chunk assertions
    /// the queue tests make. Property VALUES are asserted from decoded wire
    /// bodies in the client tests instead.
    static func == (lhs: OutboxItem, rhs: OutboxItem) -> Bool {
        switch (lhs, rhs) {
        case let (.event(ln, _, lo), .event(rn, _, ro)):
            return ln == rn && lo == ro
        case let (.session(ls, le, ld), .session(rs, re, rd)):
            return ls == rs && le == re && ld == rd
        default:
            return false
        }
    }
}

/// One unit of flush work drained from the outbox: a batch of events
/// (≤ `Outbox.eventChunk`, sent as one recordEvent batch body) or a single
/// session (recordSession has no batch form).
enum OutboxBatch: Sendable, Equatable {
    case events([OutboxItem])   // invariant: every element is .event
    case session(OutboxItem)    // invariant: the element is .session

    var items: [OutboxItem] {
        switch self {
        case .events(let e): return e
        case .session(let s): return [s]
        }
    }
}

/// In-memory FIFO for analytics calls that couldn't be sent (no user yet,
/// offline, server 5xx). Pure value type — the `SalesClient` actor owns
/// the instance and performs all I/O.
struct Outbox: Sendable {
    static let cap = 500        // total queued items
    static let eventChunk = 50  // server's MAX_BATCH for recordEvent

    private(set) var items: [OutboxItem] = []

    var isEmpty: Bool { items.isEmpty }
    var count: Int { items.count }

    /// Append preserving call order. When the result would exceed `cap`,
    /// the OLDEST items are dropped. Returns how many were dropped so the
    /// caller can log the loss.
    @discardableResult
    mutating func append(_ newItems: [OutboxItem]) -> Int {
        items.append(contentsOf: newItems)
        let overflow = items.count - Self.cap
        if overflow > 0 { items.removeFirst(overflow) }
        return max(0, overflow)
    }

    /// Next unit of work in FIFO order: the leading run of events (at most
    /// `eventChunk` of them) as one batch, or the single leading session.
    /// Removes the returned items. nil when empty.
    mutating func drainNext() -> OutboxBatch? {
        guard let first = items.first else { return nil }
        if case .session = first {
            items.removeFirst()
            return .session(first)
        }
        var run: [OutboxItem] = []
        while run.count < Self.eventChunk, let next = items.first, case .event = next {
            run.append(next)
            items.removeFirst()
        }
        return .events(run)
    }

    /// Put a failed batch back at the FRONT, restoring the pre-drain order.
    mutating func requeue(_ batch: OutboxBatch) {
        items.insert(contentsOf: batch.items, at: 0)
    }

    mutating func removeAll() { items = [] }
}
