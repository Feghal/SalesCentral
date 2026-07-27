import Foundation
#if canImport(StoreKit)
import StoreKit
#endif

/// Auto-uploads every verified `Transaction.update` to the server.
///
/// Apple delivers every committed transaction through this stream —
/// including ones that arrived while the app was off (renewals, refunds,
/// family-purchases). Subscribing once at app boot is enough.
///
/// Owned by `SalesClient.startObservingTransactions()`; you don't normally
/// construct this directly.
final class StoreKitObserver: @unchecked Sendable {
    private weak var client: SalesClient?
    private var task: Task<Void, Never>?

    init(client: SalesClient) { self.client = client }

    func start() {
        guard task == nil else { return }
        #if canImport(StoreKit)
        task = Task.detached(priority: .background) { [weak self] in
            // Drain first. `Transaction.updates` only carries NEW updates — it
            // does not replay a transaction this app left unfinished in an
            // earlier process (an upload that failed mid-flight, or a crash
            // between upload and finish()). Without this pass nothing ever
            // retries those, and StoreKit keeps handing the stale transaction
            // back to `product.purchase()` instead of opening a purchase
            // sheet — so every later purchase attempt replays a transaction
            // that, once its (minutes-long, in sandbox) window closes, the
            // server can only reject as `expired_transaction`.
            await self?.drainUnfinished()
            for await update in StoreKit.Transaction.updates {
                guard case .verified(let txn) = update, let client = self?.client else { continue }
                // uploadObservedTransaction claims the txn (so an explicit
                // purchase() and this observer never upload the SAME one),
                // uploads Apple's SIGNED JWS (only the JWS carries the x5c
                // chain the server verifies), and on failure RELEASES the
                // claim so a redelivery retries. We finish() ONLY after a
                // successful upload — an unfinished txn is Apple's retry.
                if await client.uploadObservedTransaction(id: String(txn.id), jws: update.jwsRepresentation) {
                    await txn.finish()
                }
            }
        }
        #endif
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    #if canImport(StoreKit)
    /// Upload every transaction StoreKit still considers unfinished, then
    /// finish the ones the server settled (applied, or rejected permanently).
    /// Finite sequence — unlike `Transaction.updates` it completes once the
    /// backlog is emitted, so this returns and the caller falls through to the
    /// live stream.
    private func drainUnfinished() async {
        guard let client else { return }
        var drained = 0
        var finished = 0
        for await result in StoreKit.Transaction.unfinished {
            guard case .verified(let txn) = result else { continue }
            drained += 1
            if await client.uploadObservedTransaction(id: String(txn.id), jws: result.jwsRepresentation) {
                await txn.finish()
                finished += 1
            }
        }
        if drained > 0 {
            SalesLog.info(.observer, "drained \(drained) unfinished transaction(s) — \(finished) settled, \(drained - finished) left for retry")
        }
    }
    #endif
}
