import Foundation
#if canImport(StoreKit)
import StoreKit
#endif

/// Abstraction over the device's purchase receipts so tests can inject a stub.
///
/// Mirrors `AppTransactionProviding` — the SDK never parses a receipt, it just
/// collects the App Store-signed JWS strings and uploads them.
public protocol ReceiptProviding: Sendable {
    /// Every receipt this device can present for ACCOUNT RECOVERY.
    ///
    /// This is deliberately the full transaction history, not the current
    /// entitlements: restore's job is to identify the account that owns a
    /// purchase, and a lapsed subscription or a spent consumable identifies
    /// its owner just as well as an active one. The server resolves the owner
    /// from the receipt and returns that account — it does NOT re-grant the
    /// purchase (`processPurchase` is idempotent on `(appId, transactionId)`),
    /// so presenting more history can never mint credits.
    func restoreReceiptJWS() async -> [String]
}

#if canImport(StoreKit)
/// Production implementation backed by StoreKit 2's `Transaction.all`.
///
/// `Transaction.all` is the device's full purchase history for the current
/// Apple Account. `Transaction.currentEntitlements` — what this used to read —
/// holds only purchases that CURRENTLY entitle the user, so it is empty for a
/// lapsed subscriber and never lists consumables at all. Restore then had
/// nothing to send and silently degraded into "create a new account", which is
/// how a non-premium user lost their credit balance on a new device.
struct LiveReceiptProvider: ReceiptProviding {
    func restoreReceiptJWS() async -> [String] {
        var out: [String] = []
        for await result in StoreKit.Transaction.all {
            // Send the signed JWS (carries the x5c chain), not the decoded
            // Transaction.jsonRepresentation which the server can't verify.
            if case .verified = result { out.append(result.jwsRepresentation) }
        }
        return out
    }
}
#else
/// No StoreKit on this platform — no receipts are ever available.
struct LiveReceiptProvider: ReceiptProviding {
    func restoreReceiptJWS() async -> [String] { [] }
}
#endif
