import Foundation
import StoreKit

/// Top-level entry point. The SDK reads its configuration from the app's
/// `Info.plist` (under the `SalesCentral` dictionary key — see the admin's
/// "SDK config" card for the exact XML to paste). You then make exactly
/// **one** call from your app launch path:
///
/// ```swift
/// // SwiftUI:
/// @main
/// struct MyApp: App {
///     var body: some Scene {
///         WindowGroup {
///             RootView()
///                 .environmentObject(SalesCentral.store)
///                 .task { await SalesCentral.start() }
///         }
///     }
/// }
///
/// // UIKit:
/// func application(_ application: UIApplication, didFinishLaunchingWithOptions ...) -> Bool {
///     Task { await SalesCentral.start() }
///     return true
/// }
/// ```
///
/// That's it — no separate config file, no `configure(_:)` call, no
/// `@StateObject` to wire up.
///
/// Everywhere else in your app:
///
/// ```swift
/// try await SalesCentral.purchase(product)
/// try await SalesCentral.shared.spendCredits(50, reason: "image_gen")
/// ```
///
/// ## Lazy configuration
/// `SalesCentral.store` and `SalesCentral.shared` are safe to reference
/// **before** `start()` is awaited — first access reads `Info.plist`
/// synchronously and creates the client. `start()` then layers the
/// async bootstrap (ensure user, observe transactions, start session
/// tracker) on top. Both are idempotent.
///
/// ## Custom bundle (tests, app extensions)
/// If you need to load config from a non-`.main` bundle, call
/// `SalesCentral.configure(.fromInfoPlist(bundle: myBundle))` before any
/// access. Tests that want a fully fake config can pass any `SalesConfig`
/// to `configure(_:)`.
@MainActor
public enum SalesCentral {

    // ------------------------------------------------------------------
    // MARK: - Storage
    // ------------------------------------------------------------------

    private static var _client: SalesClient?
    private static var _store: SalesStore?
    private static var _bootstrapped = false

    // ------------------------------------------------------------------
    // MARK: - Lifecycle
    // ------------------------------------------------------------------

    /// Configure + bootstrap the SDK in one shot. Reads `Info.plist` if it
    /// hasn't been configured yet, then ensures a user, fetches their
    /// current subscription, starts the StoreKit transaction observer,
    /// and starts the session tracker.
    ///
    /// Safe to call multiple times — the bootstrap half is gated by an
    /// internal `_bootstrapped` flag and subsequent calls are no-ops.
    public static func start() async {
        ensureConfigured()
        if _bootstrapped { return }
        _bootstrapped = true
        await store.bootstrap()
    }

    /// Inject an explicit `SalesConfig` instead of reading `Info.plist`.
    /// Useful in unit tests, app extensions, and apps that resolve config
    /// from a remote service.
    ///
    /// First call wins; later calls are ignored. Use `reset()` first to
    /// re-configure mid-process.
    public static func configure(_ config: SalesConfig) {
        guard _client == nil else { return }
        let c = SalesClient(config)
        _client = c
        _store = SalesStore(client: c)
    }

    /// Drop the configured client (test hook). After `reset()`, the next
    /// access to `store` / `shared` / `start()` re-reads `Info.plist`.
    public static func reset() {
        _client = nil
        _store = nil
        _bootstrapped = false
    }

    // ------------------------------------------------------------------
    // MARK: - Shared instances (lazy-configured)
    // ------------------------------------------------------------------

    /// The shared `SalesClient` actor. Triggers lazy `Info.plist`
    /// configuration on first access so SwiftUI views can reference it
    /// before `start()` has been awaited.
    public static var shared: SalesClient {
        ensureConfigured()
        return _client!
    }

    /// The shared `SalesStore`. Pass to `.environmentObject(...)` on your
    /// root view; the store's `@Published` properties drive re-renders
    /// when user / subscription state changes.
    public static var store: SalesStore {
        ensureConfigured()
        return _store!
    }

    /// Has the SDK been configured (lazily or via `configure(_:)`)?
    public static var isConfigured: Bool { _client != nil }

    // ------------------------------------------------------------------
    // MARK: - Purchase (end-to-end)
    // ------------------------------------------------------------------

    /// Drive StoreKit's purchase dialog, validate the verified transaction,
    /// upload the signed JWS receipt to your SalesCentral backend, apply
    /// effects on the user, finish the transaction so it doesn't re-emit
    /// on next launch, and refresh the shared `SalesStore` so SwiftUI
    /// views see the new state immediately.
    ///
    /// Throws on network errors or backend rejection
    /// (e.g. `product_not_registered`). UI should branch on the returned
    /// `PurchaseResult` for normal flow outcomes and `catch` for retryable
    /// failures.
    @discardableResult
    public static func purchase(_ product: Product) async throws -> PurchaseResult {
        ensureConfigured()
        let result = try await product.purchase()
        switch result {
        case .success(let verification):
            switch verification {
            case .verified(let txn):
                let jws = String(decoding: txn.jsonRepresentation, as: UTF8.self)
                let resp = try await shared.applyReceipt(jws)
                await txn.finish()
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

    // ------------------------------------------------------------------
    // MARK: - Private
    // ------------------------------------------------------------------

    /// Lazily configure from `Info.plist` if no explicit `configure(_:)`
    /// has been called yet.
    private static func ensureConfigured() {
        guard _client == nil else { return }
        configure(.fromInfoPlist())
    }
}

// ----------------------------------------------------------------------
// MARK: - PurchaseResult
// ----------------------------------------------------------------------

/// Outcome of `SalesCentral.purchase(_:)`.
public enum PurchaseResult: Sendable {

    /// Receipt accepted by your backend; effects (premium, credits,
    /// entitlements, feature unlocks) have been applied to the user.
    /// `applied` is the per-receipt summary if you want to inspect what
    /// changed.
    case success(applied: [AppliedReceipt])

    /// User dismissed the StoreKit purchase dialog. Not an error.
    case userCancelled

    /// Apple's "Ask to Buy" / strong customer authentication is awaiting
    /// approval. The transaction observer started by `start()` will
    /// upload the receipt automatically once Apple resolves it; you can
    /// show a "pending approval" hint in the meantime.
    case pending

    /// StoreKit's local signature verification failed for the returned
    /// transaction. Rare; signals tampering or a corrupted StoreKit
    /// response — **do not unlock the purchase**.
    case unverified(reason: String)

    /// Convenience: was the purchase fully completed (effects applied)?
    public var didSucceed: Bool {
        if case .success = self { return true }
        return false
    }
}
