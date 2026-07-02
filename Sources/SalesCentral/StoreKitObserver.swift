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
}
