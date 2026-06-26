import Foundation
// Re-export StoreKit so consumers of this SDK don't have to `import StoreKit`
// themselves. `Product`, `Transaction`, `StoreKit.Product.PurchaseResult`,
// etc. are all in scope after `import SalesCentral` — which is the whole
// point of the SDK: the iOS app never speaks to StoreKit directly.
@_exported import StoreKit
#if canImport(UserNotifications)
import UserNotifications
#endif

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

    /// Watches for network reconnection to retry a bootstrap that failed
    /// offline. Created lazily on failure, stopped once bootstrap succeeds.
    private static var _reconnectMonitor: NetworkMonitor?

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
        if _bootstrapped {
            SalesLog.debug(.sdk, "start() called again — bootstrap already complete, no-op")
            return
        }
        SalesLog.info(.sdk, "start() — bootstrapping…")
        // Single-flight: concurrent start()/loadProducts triggers share ONE
        // attempt (no duplicate user creation), and a failed attempt leaves the
        // store un-bootstrapped so we can retry.
        await store.ensureBootstrapped()
        guard await store.didBootstrap else {
            // No user established (e.g. offline first launch). Do NOT mark
            // _bootstrapped — leave it retryable — and watch for reconnect so
            // we recover automatically once the network returns.
            SalesLog.warn(.sdk, "start() — bootstrap failed (no user; likely offline). Watching for reconnect to retry.")
            startReconnectMonitor()
            return
        }
        _bootstrapped = true
        _reconnectMonitor?.stop(); _reconnectMonitor = nil
        SalesLog.info(.sdk, "start() — bootstrap complete; prefetching StoreKit products")
        // Right after bootstrap, the SalesClient knows which Apple SKUs the
        // admin has registered for this app (returned from createOrFetchUser).
        // Kick off the StoreKit lookup in the background — `loadProducts()`
        // awaits the same task. Don't await it here so first paint isn't
        // blocked by the StoreKit network call.
        if _productsTask == nil {
            _productsTask = Task { try await fetchProductsFromStoreKit() }
        }
    }

    /// Watch for network reconnection and retry `start()` once we're online,
    /// so a first launch with no internet recovers without the user relaunching
    /// the app. No-op once a second time (idempotent); `start()` itself is a
    /// no-op after bootstrap succeeds. Stopped once bootstrap completes.
    private static func startReconnectMonitor() {
        guard _reconnectMonitor == nil else { return }
        let m = NetworkMonitor()
        m.onReconnect = { Task { await start() } }
        _reconnectMonitor = m
        m.start()
    }

    /// Inject an explicit `SalesConfig` instead of reading the bundle.
    /// Useful in unit tests, app extensions, and apps that resolve config
    /// from a remote service.
    ///
    /// First call wins; later calls are ignored. Use `reset()` first to
    /// re-configure mid-process.
    public static func configure(_ config: SalesConfig) {
        guard _client == nil else {
            SalesLog.debug(.sdk, "configure(_:) ignored — already configured")
            return
        }
        let c = SalesClient(config)
        _client = c
        _store = SalesStore(client: c)
        SalesLog.info(.sdk, "configured for baseURL=\(config.baseURL.absoluteString)")
    }

    /// Drop the configured client (test hook). After `reset()`, the next
    /// access to `store` / `shared` / `start()` re-reads the bundle.
    public static func reset() {
        SalesLog.debug(.sdk, "reset() — clearing configuration")
        _productsTask?.cancel()
        _productsTask = nil
        _reconnectMonitor?.stop()
        _reconnectMonitor = nil
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
    // MARK: - Logging
    // ------------------------------------------------------------------

    /// Toggle SDK logging. Verbose by default in DEBUG; silent in release.
    /// Lines route through `os.Logger` under the subsystem
    /// `com.salescentral.sdk` — open Console.app and filter on that
    /// subsystem to see the full SDK conversation.
    public static var loggingEnabled: Bool {
        get { SalesLog.isEnabled }
        set { SalesLog.isEnabled = newValue }
    }

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
            SalesLog.debug(.store, "loadProducts() — no prefetch in flight, bootstrapping on demand")
            if !_bootstrapped { await start() }                 // populates _productsTask
            if _productsTask == nil {
                _productsTask = Task { try await fetchProductsFromStoreKit() }
            }
        } else {
            SalesLog.debug(.store, "loadProducts() — joining the prefetch task")
        }
        do {
            let products = try await _productsTask!.value
            SalesLog.info(.store, "loadProducts() returned \(products.count) product(s)")
            return products
        } catch {
            SalesLog.error(.store, "loadProducts() failed: \(error.localizedDescription)")
            throw error
        }
    }

    /// Force a refetch of the registered SKUs + StoreKit lookup. Use
    /// after an admin-panel change you want to pick up without restarting
    /// the app. Otherwise `start()` does this once per launch.
    @discardableResult
    public static func reloadProducts() async throws -> [Product] {
        ensureConfigured()
        SalesLog.info(.store, "reloadProducts() — refetching SKUs + StoreKit lookup")
        let task = Task { try await fetchProductsFromStoreKit(forceRefreshIDs: true) }
        _productsTask = task
        do {
            let products = try await task.value
            SalesLog.info(.store, "reloadProducts() returned \(products.count) product(s)")
            return products
        } catch {
            SalesLog.error(.store, "reloadProducts() failed: \(error.localizedDescription)")
            throw error
        }
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
        SalesLog.info(.store, "purchase(\(product.id)) — opening StoreKit dialog")
        // Stamp the purchase with our user id as Apple's `appAccountToken`.
        // Apple echoes it on the original transaction AND every renewal, so the
        // server can tie webhooks to this user even if the client never uploads
        // a receipt (e.g. after a keychain reset). Requires a UUID; our user ids
        // are UUIDs, so this is set whenever a user is known.
        let accountToken: UUID? = await MainActor.run {
            guard let uid = store.user?.id else { return nil }
            return UUID(uuidString: uid)
        }
        let purchaseOptions: Set<Product.PurchaseOption> =
            accountToken.map { [.appAccountToken($0)] } ?? []
        let result = try await product.purchase(options: purchaseOptions)
        switch result {
        case .success(let verification):
            switch verification {
            case .verified(let txn):
                SalesLog.info(.store, "purchase(\(product.id)) — verified txn=\(txn.id), uploading receipt")
                // Claim this txn so the StoreKit observer doesn't ALSO upload it
                // concurrently (which would race on the server). purchase() is the
                // authoritative uploader here — it needs the response.
                _ = await shared.claimTransaction(String(txn.id))
                // Upload the signed JWS (has x5c), not the decoded txn JSON.
                let jws = verification.jwsRepresentation
                let resp = try await shared.applyReceipt(jws)
                await txn.finish()
                await store.syncAfterPurchase(user: resp.user)
                SalesLog.info(.store, "purchase(\(product.id)) — applied \(resp.applied.count) effect(s)")
                return .success(applied: resp.applied)
            case .unverified(_, let error):
                SalesLog.warn(.store, "purchase(\(product.id)) — UNVERIFIED: \(error.localizedDescription)")
                return .unverified(reason: error.localizedDescription)
            }
        case .userCancelled:
            SalesLog.info(.store, "purchase(\(product.id)) — user cancelled")
            return .userCancelled
        case .pending:
            SalesLog.info(.store, "purchase(\(product.id)) — pending (Ask to Buy / SCA)")
            return .pending
        @unknown default:
            SalesLog.warn(.store, "purchase(\(product.id)) — unknown StoreKit result, treating as cancelled")
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
    // MARK: - Push notifications
    // ------------------------------------------------------------------

    /// Register the APNs device token your `AppDelegate` received in
    /// `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`.
    /// The SDK converts the raw bytes to lowercase hex, captures the
    /// current `UNUserNotificationCenter` auth status, and ships both up
    /// to the backend via `updateContext`. Re-registering the same token
    /// is cheap — the backend dedupes and just bumps `lastUsedAt`.
    ///
    /// ```swift
    /// func application(
    ///     _ application: UIApplication,
    ///     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    /// ) {
    ///     Task { try? await SalesCentral.registerPushToken(deviceToken) }
    /// }
    /// ```
    public static func registerPushToken(_ deviceToken: Data) async throws {
        ensureConfigured()
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        let env = SalesCentral.pushEnvironment()
        let auth = await SalesCentral.pushAuthStatusString()
        let info = Bundle.main.infoDictionary ?? [:]
        let push = PushContext(
            token: hex,
            environment: env,
            authStatus: auth,
            appVersion: info["CFBundleShortVersionString"] as? String,
            bundleId: Bundle.main.bundleIdentifier
        )
        SalesLog.info(.push, "registerPushToken — env=\(env) auth=\(auth ?? "nil") token=\(hex.prefix(8))…")
        try await shared.updateContext(UserContext(push: push))
    }

    /// Tell the backend this device no longer wants to receive pushes.
    /// Marks the most recent token inactive on the user record. The token
    /// itself is left in the array so we can resurrect it if the user
    /// opts back in.
    public static func unregisterPushToken() async throws {
        ensureConfigured()
        SalesLog.info(.push, "unregisterPushToken")
        let push = PushContext(
            authStatus: await SalesCentral.pushAuthStatusString()
        )
        try await shared.updateContext(UserContext(push: push))
    }

    /// "production" in a release build, "sandbox" in DEBUG. The host APNs
    /// uses depends on the provisioning profile, and the two are mutually
    /// incompatible — sending a sandbox token to the production host
    /// returns BadDeviceToken.
    private static func pushEnvironment() -> String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }

    /// Read the current UNUserNotificationCenter authorization status as
    /// the string the backend stores ("authorized" / "denied" / etc.).
    /// Returns `nil` on platforms without UserNotifications (rare).
    private static func pushAuthStatusString() async -> String? {
        #if canImport(UserNotifications)
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized:    return "authorized"
        case .denied:        return "denied"
        case .notDetermined: return "notDetermined"
        case .provisional:   return "provisional"
        case .ephemeral:     return "ephemeral"
        @unknown default:    return "notDetermined"
        }
        #else
        return nil
        #endif
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
            SalesLog.debug(.store, "fetchProductsFromStoreKit — forcing ensureUser to refresh SKU list")
            _ = try await shared.ensureUser()
        }
        let ids = await shared.configuredProductIDs
        SalesLog.debug(.store, "fetchProductsFromStoreKit — asking StoreKit for \(ids.count) SKU(s): \(ids.joined(separator: ", "))")
        guard !ids.isEmpty else {
            SalesLog.warn(.store, "fetchProductsFromStoreKit — no SKUs registered for this app in the admin")
            return []
        }
        let products = try await Product.products(for: ids)
        if products.count < ids.count {
            let missing = Set(ids).subtracting(products.map { $0.id })
            SalesLog.warn(.store, "fetchProductsFromStoreKit — Apple did not return: \(missing.sorted().joined(separator: ", "))")
        }
        return products
    }
}

// ----------------------------------------------------------------------
// MARK: - SalesPaywall extensions
// ----------------------------------------------------------------------

extension SalesPaywall {

    /// Load the StoreKit `Product`s for this paywall in one call.
    ///
    /// Equivalent to `SalesCentral.loadProducts().filter` + a reorder, but
    /// folded into one ergonomic call. The SDK already prefetched every
    /// registered product during `start()` (or on first `loadProducts()`
    /// access), so this is just an in-memory filter most of the time — no
    /// extra StoreKit round-trip per paywall.
    ///
    /// The returned array preserves `paywall.productIds` order so the
    /// operator's chosen display order is honoured. SKUs the admin lists
    /// that Apple doesn't recognise are silently dropped from the result;
    /// inspect `paywall.productIds.count` vs `products.count` if that
    /// mismatch matters to you.
    ///
    /// ```swift
    /// let paywall  = try await SalesCentral.shared.paywall(key: "main")
    /// let products = try await paywall.loadProducts()    // [Product]
    /// ```
    @MainActor
    public func loadProducts() async throws -> [Product] {
        SalesLog.debug(.paywall, "paywall.loadProducts() — \(key) wants \(productIds.count) SKU(s)")
        let all = try await SalesCentral.loadProducts()
        let byId = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        let products = productIds.compactMap { byId[$0] }
        if products.count < productIds.count {
            let missing = productIds.filter { byId[$0] == nil }
            SalesLog.warn(.paywall, "paywall.loadProducts() — \(key) missing \(missing.count) SKU(s): \(missing.joined(separator: ", "))")
        }
        SalesLog.info(.paywall, "paywall.loadProducts() — \(key) resolved \(products.count) product(s)")
        return products
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
