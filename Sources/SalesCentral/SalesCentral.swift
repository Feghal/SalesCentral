import Foundation
import StoreKit

/// Top-level entry point for the SDK. Configure once at app launch, then
/// call methods statically anywhere in your app:
///
/// ```swift
/// // In MyApp.init() — runs once, before any view appears:
/// SalesCentral.configure(salesConfig)
///
/// // In your root scene's .task — runs once, after the first window opens:
/// await SalesCentral.bootstrap()
///
/// // Anywhere — buy a StoreKit product end-to-end:
/// switch try await SalesCentral.purchase(product) {
/// case .success(let applied):  showThanks()
/// case .userCancelled:          break
/// case .pending:                showAskToBuyPending()
/// case .unverified(let reason): showError(reason)
/// }
/// ```
///
/// `SalesCentral.configure(_:)` is idempotent — repeated calls are ignored
/// so SwiftUI scene re-creation, unit-test resets, or accidental
/// double-configuration don't blow away the existing client. To swap
/// configuration mid-process (e.g. test fixtures), call
/// `SalesCentral.reset()` first.
@MainActor
public enum SalesCentral {

    // ------------------------------------------------------------------
    // MARK: - Storage
    // ------------------------------------------------------------------

    private static var _client: SalesClient?
    private static var _store: SalesStore?

    // ------------------------------------------------------------------
    // MARK: - Configuration
    // ------------------------------------------------------------------

    /// Configure the SDK. Call **exactly once**, as early in app launch as
    /// possible — typically from `App.init()` (SwiftUI) or
    /// `application(_:didFinishLaunchingWithOptions:)` (UIKit). Subsequent
    /// calls are no-ops.
    public static func configure(_ config: SalesConfig) {
        guard _client == nil else { return }
        let c = SalesClient(config)
        _client = c
        _store = SalesStore(client: c)
    }

    /// Drop the configured client. Useful in tests or when you need to
    /// re-`configure(_:)` with different settings inside the same process.
    public static func reset() {
        _client = nil
        _store = nil
    }

    /// Has `configure(_:)` been called?
    public static var isConfigured: Bool { _client != nil }

    // ------------------------------------------------------------------
    // MARK: - Shared instances
    // ------------------------------------------------------------------

    /// The shared underlying client. Use this for plain async/await calls
    /// from non-SwiftUI code (services, view models, AppDelegate).
    public static var shared: SalesClient {
        guard let c = _client else {
            preconditionFailure("SalesCentral.configure(_:) must be called before SalesCentral.shared.")
        }
        return c
    }

    /// The shared SwiftUI store. Pass to `.environmentObject(...)` on your
    /// root view; the store's `@Published` properties drive re-renders
    /// when user / subscription state changes.
    public static var store: SalesStore {
        guard let s = _store else {
            preconditionFailure("SalesCentral.configure(_:) must be called before SalesCentral.store.")
        }
        return s
    }

    // ------------------------------------------------------------------
    // MARK: - Lifecycle
    // ------------------------------------------------------------------

    /// Bootstrap the SDK. Ensures a user exists, fetches their current
    /// subscription, starts the StoreKit transaction observer, and starts
    /// the session tracker. Idempotent; safe to call multiple times.
    public static func bootstrap(_ context: UserContext = .current()) async {
        await store.bootstrap(context)
    }

    // ------------------------------------------------------------------
    // MARK: - Purchase
    // ------------------------------------------------------------------

    /// End-to-end purchase: drives StoreKit's purchase dialog, validates
    /// the verified transaction, uploads the signed JWS receipt to your
    /// SalesCentral backend, applies effects on the user, finishes the
    /// transaction so it doesn't re-emit on next launch, and refreshes the
    /// shared `SalesStore` so SwiftUI views see the new state immediately.
    ///
    /// Throws on network errors or backend rejection
    /// (e.g. `product_not_registered`). UI should:
    ///   - branch on the returned `PurchaseResult` for normal flow outcomes,
    ///   - and `catch` for retryable failures.
    @discardableResult
    public static func purchase(_ product: Product) async throws -> PurchaseResult {
        let result = try await product.purchase()
        switch result {
        case .success(let verification):
            switch verification {
            case .verified(let txn):
                let jws = String(decoding: txn.jsonRepresentation, as: UTF8.self)
                let resp = try await shared.applyReceipt(jws)
                await txn.finish()
                // Sync store state so views update without a manual refetch.
                await store.syncAfterPurchase(user: resp.user)
                return .success(applied: resp.applied)
            case .unverified(_, let error):
                return .unverified(reason: error.localizedDescription)
            }
        case .userCancelled:
            return .userCancelled
        case .pending:
            return .pending
        @unknown default:
            return .userCancelled
        }
    }
}

// ----------------------------------------------------------------------
// MARK: - PurchaseResult
// ----------------------------------------------------------------------

/// Outcome of `SalesCentral.purchase(_:)`.
public enum PurchaseResult: Sendable {

    /// Receipt accepted by your backend; effects (premium, credits,
    /// entitlements, feature unlocks) have been applied to the user.
    /// `applied` is the per-receipt summary so UI can describe what
    /// changed.
    case success(applied: [AppliedReceipt])

    /// User dismissed the StoreKit purchase dialog. Show nothing — this
    /// isn't an error.
    case userCancelled

    /// Apple's "Ask to Buy" / strong customer authentication is awaiting
    /// approval. The transaction observer started by `bootstrap()` will
    /// upload the receipt automatically once Apple resolves it; you can
    /// show a "pending approval" hint in the meantime.
    case pending

    /// StoreKit's local signature verification failed for the returned
    /// transaction. This is rare and signals tampering or a corrupted
    /// StoreKit response — **do not unlock the purchase**.
    case unverified(reason: String)

    /// Convenience: was the purchase fully completed (effects applied)?
    public var didSucceed: Bool {
        if case .success = self { return true }
        return false
    }
}
