import Foundation

/// The single entry point for talking to the SalesCentral backend.
///
/// `SalesClient` is an actor — call it from anywhere with `await`. It owns
/// the user JWT (read/written through the configured `TokenStore`) and
/// transparently re-issues it on calls that return one.
///
/// Typical lifecycle:
///
///     let client = SalesClient(config)
///     let user = try await client.ensureUser()         // first launch
///     client.startObservingTransactions()              // auto-upload purchases
///
///     // On the user tapping "Restore Purchases":
///     try await client.restorePurchases()
public actor SalesClient {

    private let config: SalesConfig
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private(set) public var currentUser: SalesUser?

    /// Apple SKU strings registered for this app in the SalesCentral admin.
    /// Populated by the most recent ensureUser / restorePurchases response
    /// so the SDK can ask StoreKit for products without the integrator
    /// hard-coding identifiers.
    private(set) public var configuredProductIDs: [String] = []
    /// Full registered catalog (incl. effects), refreshed from every config bundle.
    private(set) public var configuredProducts: [SalesProduct] = []

    /// Effects configured for a given StoreKit product id (empty if unknown).
    public func effects(forProductID id: String) -> [ProductEffect] {
        configuredProducts.first(where: { $0.productId == id })?.effects ?? []
    }

    /// Server-defined paywalls, keyed by `key`. Refreshed on every
    /// ensureUser / updateContext / restorePurchases call.
    private(set) public var paywallsByKey: [String: SalesPaywall] = [:]

    /// Server-defined remote config, keyed by config key. Same refresh
    /// cadence as `paywallsByKey`.
    private(set) public var remoteConfigCache: [String: SalesAnyValue] = [:]

    /// User's current experiment assignments, keyed by experiment.key.
    /// Stable for the lifetime of each experiment.
    private(set) public var experimentAssignments: [String: String] = [:]

    /// Retention-reward claim status (daily login credits / streaks).
    /// Refreshed on every ensureUser / restorePurchases / claimReward call.
    /// nil until the first round-trip, or on servers without the feature.
    private(set) public var retentionStatus: RetentionStatus?

    private var observer: StoreKitObserver?

    public init(_ config: SalesConfig, urlSession: URLSession = .shared) {
        self.config = config
        self.session = urlSession

        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc

        let dec = JSONDecoder()
        // The server serializes dates via JSON.stringify, which emits
        // fractional seconds ("2026-06-11T08:15:30.123Z"). Plain `.iso8601`
        // rejects those, so try fractional first, then fall back.
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        dec.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            if let d = fractional.date(from: s) ?? plain.date(from: s) { return d }
            throw DecodingError.dataCorruptedError(
                in: c, debugDescription: "Unrecognized ISO8601 date: \(s)"
            )
        }
        self.decoder = dec
    }

    // ------------------------------------------------------------------
    // MARK: - User lifecycle
    // ------------------------------------------------------------------

    /// "Ensure I have a user." On first launch this creates a guest user
    /// and saves the returned JWT to the token store. On subsequent launches
    /// (with the JWT present) it fetches the existing user and merges any
    /// context you passed in.
    @discardableResult
    public func ensureUser(context: UserContext = .current()) async throws -> SalesUser {
        let resp: ConfigBundleResponse = try await request(
            .createOrFetchUser,
            method: "POST",
            body: context,
            attachUserToken: config.tokenStore.read() != nil
        )
        absorbBundle(resp)
        return resp.user
    }

    /// Decoded shape of every server response that carries a user state
    /// bundle (createOrFetchUser, restoreUser). Older servers omit the
    /// paywall / remote-config / experiment blocks; we default them to
    /// empty so the SDK doesn't fail to decode.
    fileprivate struct ConfigBundleResponse: Decodable {
        let token: String
        let user: SalesUser
        let created: Bool?
        let products: [SalesProduct]?
        let paywalls: [SalesPaywall]?
        let remoteConfig: [String: SalesAnyValue]?
        let experimentAssignments: [String: String]?
        let retention: RetentionStatus?
    }

    /// Common path for every endpoint that returns a config bundle.
    /// Persists the rotated token, refreshes the in-memory caches.
    fileprivate func absorbBundle(_ resp: ConfigBundleResponse) {
        config.tokenStore.write(resp.token)
        currentUser = resp.user
        configuredProducts = resp.products ?? []
        configuredProductIDs = configuredProducts.map(\.productId)
        var pwMap: [String: SalesPaywall] = [:]
        for pw in resp.paywalls ?? [] { pwMap[pw.key] = pw }
        paywallsByKey = pwMap
        remoteConfigCache = resp.remoteConfig ?? [:]
        experimentAssignments = resp.experimentAssignments ?? [:]
        if let retention = resp.retention { retentionStatus = retention }
        SalesLog.debug(.sdk, "absorbed bundle — user=\(resp.user.id) products=\(configuredProductIDs.count) paywalls=\(pwMap.count) remoteConfig=\(remoteConfigCache.count) experiments=\(experimentAssignments.count) rewardAvailable=\(retentionStatus?.available ?? false)")
    }

    /// Update context on the current user — locale change, ATT prompt
    /// completion, consent flip, etc. Same wire format as `ensureUser`,
    /// always behaves as a fetch since the token is required.
    @discardableResult
    public func updateContext(_ context: UserContext) async throws -> SalesUser {
        guard config.tokenStore.read() != nil else {
            throw SalesError.invalidState("no user token — call ensureUser first")
        }
        return try await ensureUser(context: context)
    }

    /// Set a single user property — caller-defined attributes like name,
    /// email, plan_intent, etc. that the admin can search and display.
    /// Pass `nil` to delete the key.
    ///
    /// Keys must match `[A-Za-z0-9_.-]{1,64}`; values must be strings
    /// (≤1024 chars), finite numbers, or booleans. Out-of-spec entries
    /// are silently dropped server-side — the SDK doesn't pre-validate
    /// so that future server-side relaxations don't require a new SDK.
    @discardableResult
    public func setUserProperty(
        _ key: String,
        _ value: SalesPropertyValue?
    ) async throws -> SalesUser {
        try await setUserProperties([key: value])
    }

    /// Set multiple user properties in one round-trip. `nil` values
    /// delete their key; non-nil values upsert.
    @discardableResult
    public func setUserProperties(
        _ properties: [String: SalesPropertyValue?]
    ) async throws -> SalesUser {
        guard config.tokenStore.read() != nil else {
            throw SalesError.invalidState("no user token — call ensureUser first")
        }
        guard !properties.isEmpty else {
            // Nothing to update — surface the current user without a
            // round-trip. Mirrors the no-op behaviour callers expect.
            if let u = currentUser { return u }
            return try await ensureUser()
        }
        let wire = properties.mapValues { v -> PropertyDelta in
            if let v = v { return .value(v) }
            return .delete
        }
        let resp: ConfigBundleResponse = try await request(
            .createOrFetchUser,
            method: "POST",
            body: PropertiesUpdateBody(properties: wire),
            attachUserToken: true
        )
        absorbBundle(resp)
        return resp.user
    }

    /// Recover the user that owns the given Apple receipt(s). Pulls the
    /// current StoreKit entitlements automatically when `receipts` is omitted.
    @discardableResult
    public func restorePurchases(
        receipts: [String]? = nil,
        context: UserContext = .current()
    ) async throws -> RestoreResult {
        let jws = if let receipts { receipts } else { await Self.currentEntitlementJWSStrings() }
        guard !jws.isEmpty else {
            // No prior purchases on this device — fall back to a plain
            // create-or-fetch so the caller always ends up with a usable
            // user record.
            let user = try await ensureUser(context: context)
            return RestoreResult(token: config.tokenStore.read() ?? "", user: user, restored: false, applied: [])
        }
        struct Body: Encodable {
            let receipts: [String]
            let device: DeviceContext?
            let app: AppContext?
            let locale: LocaleContext?
            let network: NetworkContext?
            let marketing: MarketingContext?
            let consent: ConsentContext?
        }
        let body = Body(
            receipts: jws,
            device: context.device, app: context.app,
            locale: context.locale, network: context.network,
            marketing: context.marketing, consent: context.consent
        )
        let resp: RestoreResult = try await request(.restoreUser, method: "POST", body: body, attachUserToken: false)
        config.tokenStore.write(resp.token)
        currentUser = resp.user
        if let prods = resp.products {
            configuredProducts = prods
            configuredProductIDs = prods.map(\.productId)
        }
        if let p = resp.paywalls {
            var map: [String: SalesPaywall] = [:]
            for pw in p { map[pw.key] = pw }
            paywallsByKey = map
        }
        if let rc = resp.remoteConfig { remoteConfigCache = rc }
        if let ea = resp.experimentAssignments { experimentAssignments = ea }
        return resp
    }

    /// Sign the user out locally. Doesn't invalidate the server-side JWT
    /// (it'll just naturally expire); call this when the user explicitly
    /// signs out or when you want to start fresh.
    public func clearUser() {
        config.tokenStore.clear()
        currentUser = nil
        paywallsByKey = [:]
        remoteConfigCache = [:]
        experimentAssignments = [:]
    }

    // ------------------------------------------------------------------
    // MARK: - Paywalls / remote config / experiments
    // ------------------------------------------------------------------

    /// Fetch a server-defined paywall by key.
    ///
    /// Reads from the cache populated by the most recent `ensureUser` /
    /// `updateContext` / `restorePurchases`. If the key isn't cached the
    /// SDK refreshes the bundle (single round-trip via `updateContext`)
    /// and tries again — that way a paywall added in the admin reaches
    /// the app without a relaunch.
    public func paywall(key: String) async throws -> SalesPaywall {
        if let pw = paywallsByKey[key] {
            SalesLog.debug(.paywall, "paywall(\(key)) — cache hit, \(pw.productIds.count) product(s)")
            return pw
        }
        SalesLog.info(.paywall, "paywall(\(key)) — cache miss, refreshing bundle")
        try await refreshConfig()
        guard let pw = paywallsByKey[key] else {
            SalesLog.warn(.paywall, "paywall(\(key)) — still not found after refresh")
            throw SalesError.invalidState("paywall not found: \(key)")
        }
        SalesLog.info(.paywall, "paywall(\(key)) — found after refresh, \(pw.productIds.count) product(s)")
        return pw
    }

    /// Look up a remote-config value, falling back to `fallback` if the
    /// key is missing or the value can't be coerced to the same type.
    /// Synchronous — reads from the in-memory cache.
    ///
    /// Supported `T`: `String`, `Int`, `Double`, `Bool`. For richer
    /// shapes (arrays / nested objects), read `remoteConfigCache`
    /// directly and pattern-match on `SalesAnyValue`.
    public func remoteConfig<T>(_ key: String, default fallback: T) -> T {
        guard let v = remoteConfigCache[key] else { return fallback }
        return v.coerced(matching: fallback)
    }

    /// Currently-active experiment assignments, keyed by experiment key.
    /// Useful when you want to log the user's variant alongside your own
    /// analytics events.
    public func activeExperiments() -> [String: String] {
        experimentAssignments
    }

    /// Refresh the paywall / remote-config / experiment cache from the
    /// server. No-op against a logged-out user.
    public func refreshConfig() async throws {
        guard config.tokenStore.read() != nil else { return }
        _ = try await ensureUser()
    }

    // ------------------------------------------------------------------
    // MARK: - Purchases
    // ------------------------------------------------------------------

    /// Upload one or more signed StoreKit 2 receipts. Idempotent on
    /// `transactionId` — re-uploading the same JWS is safe.
    @discardableResult
    public func applyReceipts(_ jwsList: [String]) async throws -> ApplyResult {
        guard !jwsList.isEmpty else {
            throw SalesError.invalidState("applyReceipts called with empty receipts")
        }
        struct Body: Encodable { let receipts: [String] }
        let resp: ApplyResult = try await request(
            .applyPurchases, method: "POST",
            body: Body(receipts: jwsList), attachUserToken: true
        )
        if let u = resp.user { currentUser = u }
        return resp
    }

    /// Convenience for the common single-receipt case.
    @discardableResult
    public func applyReceipt(_ jws: String) async throws -> ApplyResult {
        try await applyReceipts([jws])
    }

    /// Fetch the current subscription state. Cheap source of truth for
    /// "is this user paid right now?" — performs lazy server-side expiry.
    public func currentSubscription() async throws -> CurrentSubscriptionResponse {
        try await request(.currentSubscription, method: "GET", body: Empty(), attachUserToken: true)
    }

    // ------------------------------------------------------------------
    // MARK: - Credits
    // ------------------------------------------------------------------

    /// Debit `amount` credits. Throws `SalesError.http(status: 402, …)`
    /// with `code == "insufficient_credits"` when the spendable balance is
    /// too low — surface a paywall in that branch. Note the user may still
    /// have `locked` credits on a drip schedule; re-fetch the user (or check
    /// `credits.nextUnlockAt`) to show "more credits unlock at <time>"
    /// instead of a bare paywall.
    ///
    /// Returns the full post-spend `Credits` state (spendable balance plus
    /// any locked drip pool).
    @discardableResult
    public func spendCredits(_ amount: Int, reason: String) async throws -> Credits {
        struct Body: Encodable { let amount: Int; let reason: String }
        let credits: Credits = try await request(
            .spendCredits, method: "POST",
            body: Body(amount: amount, reason: reason), attachUserToken: true
        )
        return credits
    }

    // ------------------------------------------------------------------
    // MARK: - Retention rewards
    // ------------------------------------------------------------------

    /// Claim today's retention reward (daily login credits / streak),
    /// as configured in the admin's App settings → Retention rewards.
    ///
    /// Call it wherever fits your UX — on app open for an automatic
    /// grant, or behind a "Claim" button. The server enforces one claim
    /// per UTC day, audience eligibility, and the streak rules, so
    /// calling it repeatedly is safe.
    ///
    /// Check `retentionStatus` (refreshed on every `ensureUser`) to badge
    /// your claim UI before calling.
    ///
    /// Errors (`SalesError.http`, branch on `.code`):
    ///   - `"already_claimed"` (409) — claimed today; `retentionStatus.nextClaimAt` says when.
    ///   - `"not_eligible"`    (403) — user outside the configured audience.
    ///   - `"rewards_disabled"`(404) — feature off for this app.
    @discardableResult
    public func claimReward() async throws -> RetentionClaimResult {
        guard let token = config.tokens.claimReward, !token.isEmpty else {
            throw SalesError.invalidState(
                "claimReward token not configured — regenerate SalesCentral.plist from the admin's SDK config card"
            )
        }
        let result: RetentionClaimResult = try await request(
            .claimReward, method: "POST",
            body: Empty(), attachUserToken: true
        )
        if let retention = result.retention { retentionStatus = retention }
        if let u = currentUser {
            currentUser = SalesUser(
                id: u.id, premium: u.premium,
                credits: result.credits,
                entitlements: u.entitlements, features: u.features,
                properties: u.properties, stats: u.stats
            )
        }
        SalesLog.info(.sdk, "claimReward — +\(result.granted.total) credits (day \(result.granted.streakDay))")
        return result
    }

    // ------------------------------------------------------------------
    // MARK: - Engagement
    // ------------------------------------------------------------------

    /// Record a finished foreground session. The SDK's `SessionTracker`
    /// can call this for you on app lifecycle notifications.
    public func recordSession(start: Date, end: Date, durationSec: Int? = nil) async throws {
        struct Body: Encodable {
            let startedAt: Date; let endedAt: Date; let durationSec: Int?
        }
        let _: EmptyOK = try await request(
            .recordSession, method: "POST",
            body: Body(startedAt: start, endedAt: end, durationSec: durationSec),
            attachUserToken: true
        )
    }

    /// Log a single custom event. Failures are swallowed silently — events
    /// are analytics-grade signals, not application state, so they should
    /// never break the caller.
    public func track(_ name: String, properties: [String: AnyEncodable] = [:]) async {
        struct Body: Encodable {
            let name: String
            let properties: [String: AnyEncodable]
            let occurredAt: Date
        }
        let body = Body(name: name, properties: properties, occurredAt: Date())
        _ = try? await request(.recordEvent, method: "POST", body: body, attachUserToken: true) as EmptyOK
    }

    /// Log multiple events at once. Useful when you've buffered events
    /// while offline. Max 50 events per call, 16KB per event's properties.
    public func trackBatch(_ events: [(name: String, properties: [String: AnyEncodable])]) async {
        struct EventBody: Encodable {
            let name: String
            let properties: [String: AnyEncodable]
            let occurredAt: Date
        }
        struct Body: Encodable { let events: [EventBody] }
        let body = Body(events: events.map { EventBody(name: $0.name, properties: $0.properties, occurredAt: Date()) })
        _ = try? await request(.recordEvent, method: "POST", body: body, attachUserToken: true) as EmptyOK
    }

    // ------------------------------------------------------------------
    // MARK: - StoreKit observer wiring
    // ------------------------------------------------------------------

    /// Start watching `Transaction.updates` for new purchases / renewals
    /// and auto-upload them. Call once on app boot. Idempotent.
    public func startObservingTransactions() {
        guard observer == nil else {
            SalesLog.debug(.observer, "startObservingTransactions() — already running, no-op")
            return
        }
        SalesLog.info(.observer, "startObservingTransactions() — listening on Transaction.updates")
        observer = StoreKitObserver(client: self)
        observer?.start()
    }

    /// Stop the auto-uploader. Rarely needed.
    public func stopObservingTransactions() {
        SalesLog.debug(.observer, "stopObservingTransactions()")
        observer?.stop()
        observer = nil
    }

    // ==================================================================
    // MARK: - HTTP plumbing (private)
    // ==================================================================

    private struct Empty: Encodable {}
    private struct EmptyOK: Decodable { let ok: Bool? }
    private struct APIError: Decodable { let error: String; let message: String? }

    private func request<B: Encodable, T: Decodable>(
        _ endpoint: SalesConfig.Endpoint,
        method: String,
        body: B?,
        attachUserToken: Bool
    ) async throws -> T {
        let url = config.url(for: endpoint)
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(config.apiKey, forHTTPHeaderField: "x-app-key")
        if attachUserToken, let token = config.tokenStore.read() {
            req.setValue(token, forHTTPHeaderField: "x-user-token")
        }
        if let body = body, !(body is Empty) {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try encoder.encode(body)
        }

        SalesLog.debug(.http, "→ \(method) \(endpoint) \(url.path)")
        let start = Date()
        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            SalesLog.error(.http, "✗ \(method) \(endpoint) network: \(error.localizedDescription)")
            throw SalesError.network(error.localizedDescription)
        }
        guard let http = resp as? HTTPURLResponse else {
            SalesLog.error(.http, "✗ \(method) \(endpoint) no HTTP response")
            throw SalesError.network("no HTTP response")
        }
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        if !(200..<300 ~= http.statusCode) {
            let err = (try? decoder.decode(APIError.self, from: data))
                ?? APIError(error: "http_\(http.statusCode)", message: nil)
            SalesLog.warn(.http, "← \(http.statusCode) \(endpoint) (\(ms)ms) error=\(err.error)\(err.message.map { " message=\($0)" } ?? "")")
            // 401 → user token is invalid. Wipe it so the next call starts
            // fresh via /users instead of looping on bad credentials.
            if http.statusCode == 401 { config.tokenStore.clear() }
            throw SalesError.http(status: http.statusCode, code: err.error, message: err.message)
        }
        SalesLog.debug(.http, "← \(http.statusCode) \(endpoint) (\(ms)ms, \(data.count) bytes)")
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            SalesLog.error(.http, "✗ \(method) \(endpoint) decode: \(error.localizedDescription)")
            throw SalesError.decoding(error.localizedDescription)
        }
    }

    // ------------------------------------------------------------------
    // MARK: - StoreKit helpers
    // ------------------------------------------------------------------

    /// Pull every verified `Transaction` currently entitled to the user and
    /// return their raw JWS strings. The SDK never parses receipts — these
    /// strings go straight to the server.
    public static func currentEntitlementJWSStrings() async -> [String] {
        #if canImport(StoreKit)
        var out: [String] = []
        for await result in StoreKit.Transaction.currentEntitlements {
            if case .verified = result {
                // Send the signed JWS (carries the x5c chain), not the decoded
                // Transaction.jsonRepresentation which the server can't verify.
                out.append(result.jwsRepresentation)
            }
        }
        return out
        #else
        return []
        #endif
    }
}

#if canImport(StoreKit)
import StoreKit
#endif
