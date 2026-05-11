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
                let jws = String(decoding: txn.jsonRepresentation, as: UTF8.self)
                do {
                    _ = try await client.applyReceipts([jws])
                    // We finish() ONLY after a successful upload. If the
                    // upload fails (network, server down), Apple re-delivers
                    // on next launch.
                    await txn.finish()
                } catch {
                    // Leave the transaction unfinished so it retries. The
                    // server is idempotent on transactionId, so a retry
                    // can't double-charge or double-grant.
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
