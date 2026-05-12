import Foundation
// Re-export StoreKit so consumers of this SDK don't have to `import StoreKit`
// themselves. `Product`, `Transaction`, `StoreKit.Product.PurchaseResult`,
// etc. are all in scope after `import SalesCentral` — which is the whole
// point of the SDK: the iOS app never speaks to StoreKit directly.
@_exported import StoreKit

/// Top-level entry point. The SDK reads its configuration from a
/// `SalesCentral.plist` file in your app bundle (or, for legacy projects,
/// a `SalesCentral` dictionary entry inside `Info.plist`). Generate the
/// file from the admin's "SDK config" card. You then make exactly **one**
/// call from your app launch path:
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

    /// In-flight (or already-resolved) task for loading the app's
    /// configured StoreKit products. `start()` kicks this off right after
    /// `bootstrap()`. Concurrent `loadProducts()` callers await the same
    /// task and get the same `[Product]`.
    private static var _productsTask: Task<[Product], Error>?

    // ------------------------------------------------------------------
    // MARK: - Lifecycle
    // ------------------------------------------------------------------

    /// Configure + bootstrap the SDK in one shot. Reads `SalesCentral.plist`
    /// (or the `SalesCentral` key in Info.plist as a fallback) if no
    /// explicit `configure(_:)` was called, then ensures a user, fetches
    /// their current subscription, starts the StoreKit transaction
    /// observer, and starts the session tracker.
    ///
    /// Safe to call multiple times — the bootstrap half is gated by an
    /// internal `_bootstrapped` flag and subsequent calls are no-ops.
    public static func start() async {
        ensureConfigured()
        if _bootstrapped { return }
        _bootstrapped = true
        await store.bootstrap()
        // Right after bootstrap, the SalesClient knows which Apple SKUs the
        // admin has registered for this app (returned from createOrFetchUser).
        // Kick off the StoreKit lookup in the background — `loadProducts()`
        // awaits the same task. Don't await it here so first paint isn't
        // blocked by the StoreKit network call.
        _productsTask = Task { try await fetchProductsFromStoreKit() }
    }

    /// Inject an explicit `SalesConfig` instead of reading the bundle.
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
    /// access to `store` / `shared` / `start()` re-reads the bundle.
    public static func reset() {
        _productsTask?.cancel()
        _productsTask = nil
        _client = nil
        _store = nil
        _bootstrapped = false
    }

    // ------------------------------------------------------------------
    // MARK: - Shared instances (lazy-configured)
    // ------------------------------------------------------------------

    /// The shared `SalesClient` actor. Triggers lazy bundle
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
    // MARK: - Products
    // ------------------------------------------------------------------

    /// Fetch the StoreKit products the admin registered for this app.
    ///
    /// **You don't pass identifiers.** The SDK already knows them — the
    /// configured SKUs come down with `start()`'s `ensureUser` round-trip,
    /// so the iOS app can stay product-list-agnostic. Add / remove
    /// products from the admin panel and they appear / disappear here on
    /// the next launch, without an app update.
    ///
    /// Behavior:
    ///   - If `start()` already kicked off the load and it finished:
    ///     returns the cached array immediately.
    ///   - If `start()` kicked it off but it's still running: awaits.
    ///   - If `start()` hasn't been called yet: starts the SDK and the
    ///     product load now, then awaits.
    ///
    /// Concurrent callers all share the same in-flight task and get the
    /// same `[Product]`. Use `reloadProducts()` to force a fresh fetch
    /// (e.g. after the operator just added a new product).
    public static func loadProducts() async throws -> [Product] {
        ensureConfigured()
        // If start() hasn't kicked off the prefetch yet, do it on demand.
        // This makes the call usable even from app delegates that haven't
        // awaited start() yet.
        if _productsTask == nil {
            if !_bootstrapped { await start() }                 // populates _productsTask
            if _productsTask == nil {
                _productsTask = Task { try await fetchProductsFromStoreKit() }
            }
        }
        return try await _productsTask!.value
    }

    /// Force a refetch of the registered SKUs + StoreKit lookup. Use
    /// after an admin-panel change you want to pick up without restarting
    /// the app. Otherwise `start()` does this once per launch.
    @discardableResult
    public static func reloadProducts() async throws -> [Product] {
        ensureConfigured()
        let task = Task { try await fetchProductsFromStoreKit(forceRefreshIDs: true) }
        _productsTask = task
        return try await task.value
    }

    /// Convenience: look up a single registered product by SKU. Returns
    /// `nil` if the admin hasn't configured this id (or Apple doesn't
    /// recognize it).
    public static func loadProduct(_ identifier: String) async throws -> Product? {
        try await loadProducts().first(where: { $0.id == identifier })
    }

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

    /// Convenience: look up the product by id and purchase it in one
    /// call. The lookup hits the SDK's product cache (populated by
    /// `start()`), so it's free after first launch.
    ///
    /// Throws `SalesError.invalidState("product_not_found:<id>")` when:
    ///   - the admin hasn't registered this SKU, OR
    ///   - Apple doesn't recognize it (typo, missing in App Store Connect).
    @discardableResult
    public static func purchase(productID: String) async throws -> PurchaseResult {
        guard let product = try await loadProduct(productID) else {
            throw SalesError.invalidState("product_not_found:\(productID)")
        }
        return try await purchase(product)
    }

    // ------------------------------------------------------------------
    // MARK: - Private
    // ------------------------------------------------------------------

    /// Lazily configure from the bundle (`SalesCentral.plist` if present,
    /// otherwise the `SalesCentral` key inside Info.plist) if no explicit
    /// `configure(_:)` has been called yet.
    private static func ensureConfigured() {
        guard _client == nil else { return }
        configure(.fromBundle())
    }

    /// Ask the client for the registered SKUs, then resolve them with
    /// StoreKit. Optionally re-runs `ensureUser` first so a freshly added
    /// product in the admin shows up without a relaunch.
    private static func fetchProductsFromStoreKit(forceRefreshIDs: Bool = false) async throws -> [Product] {
        if forceRefreshIDs {
            _ = try await shared.ensureUser()
        }
        let ids = await shared.configuredProductIDs
        guard !ids.isEmpty else { return [] }
        return try await Product.products(for: ids)
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
