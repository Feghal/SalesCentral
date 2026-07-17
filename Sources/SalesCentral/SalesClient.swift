import Foundation
import CryptoKit

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

    /// True when the SDK is configured analytics-only. Nonisolated so
    /// MainActor code (`SalesStore`, `SalesCentral`) reads it synchronously.
    public nonisolated let analyticsOnly: Bool

    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let attestService: AppAttestServicing

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

    /// Test hook: is the StoreKit auto-uploader running?
    var isObservingTransactions: Bool { observer != nil }

    /// Analytics calls that couldn't be sent yet (no user, offline, 5xx).
    /// See Outbox.swift. All access is actor-isolated.
    private var outbox = Outbox()
    /// Single-flight latch for `flushOutbox()`; concurrent triggers coalesce.
    private var isFlushingOutbox = false
    /// Watches connectivity while the outbox is non-empty. Fresh instance
    /// per backlog episode — NWPathMonitor cannot restart after cancel().
    private var outboxReconnectMonitor: NetworkMonitor?

    /// Test hook: how many analytics calls are queued.
    var pendingAnalyticsCount: Int { outbox.count }

    /// First statement of every transaction API. Analytics-only integrations
    /// must never reach the transaction endpoints or StoreKit.
    private func guardTransactionsAllowed(_ operation: String) throws {
        if analyticsOnly {
            SalesLog.warn(.sdk, "\(operation) blocked — SDK is configured analyticsOnly")
            throw SalesError.invalidState("analytics_only")
        }
    }

    /// Transaction ids already claimed for upload, so the explicit purchase()
    /// upload and the StoreKit observer don't both send the SAME transaction.
    /// Actor-isolated → the check-and-insert is atomic. The Set backs the O(1)
    /// membership test; the array preserves insertion order so we can prune the
    /// OLDEST entries (not blow away everything) when we hit the cap.
    private var claimedTransactionIDs: Set<String> = []
    private var claimedTransactionOrder: [String] = []
    private let claimedTransactionCap = 512

    /// Claim a transaction id for upload. Returns true if it's newly claimed
    /// (caller should upload), false if it was already claimed (caller should
    /// skip — someone else is handling it). Bounded so it can't grow forever:
    /// when over the cap we drop only the oldest entries, keeping recent ids
    /// (a blanket wipe would make old txns re-claimable and re-uploadable).
    func claimTransaction(_ id: String) -> Bool {
        if claimedTransactionIDs.contains(id) { return false }
        claimedTransactionIDs.insert(id)
        claimedTransactionOrder.append(id)
        while claimedTransactionOrder.count > claimedTransactionCap {
            let oldest = claimedTransactionOrder.removeFirst()
            claimedTransactionIDs.remove(oldest)
        }
        return true
    }

    /// Release a previously-claimed transaction id so it can be re-claimed and
    /// re-uploaded. Call this when an upload attempt fails: otherwise the id
    /// stays claimed for the process lifetime and the StoreKit observer (the
    /// retry path) skips it forever, stranding a paid transaction until the
    /// next cold launch.
    func unclaimTransaction(_ id: String) {
        if claimedTransactionIDs.remove(id) != nil {
            claimedTransactionOrder.removeAll { $0 == id }
        }
    }

    /// Upload one observer-delivered transaction: claim → upload → unclaim on
    /// failure. Returns true when the upload succeeded and the caller should
    /// finish() the transaction. On failure the claim is released so the next
    /// StoreKit redelivery (same session or next launch) retries the upload —
    /// the server is idempotent on transactionId, so a retry can't double-apply.
    func uploadObservedTransaction(id: String, jws: String) async -> Bool {
        guard claimTransaction(id) else { return false }
        do {
            _ = try await applyReceipts([jws])
            return true
        } catch {
            unclaimTransaction(id)
            return false
        }
    }

    public init(_ config: SalesConfig, urlSession: URLSession = .shared, attestService: AppAttestServicing? = nil) {
        self.config = config
        self.analyticsOnly = config.analyticsOnly
        self.session = urlSession
        self.attestService = attestService ?? LiveAppAttestService()

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
        var ctx = context
        ctx.clientId = clientId()   // idempotent-create key (see clientId())
        let resp: ConfigBundleResponse = try await request(
            .createOrFetchUser,
            method: "POST",
            body: ctx,
            attachUserToken: config.tokenStore.read() != nil
        )
        absorbBundle(resp)
        // A token now exists — deliver anything queued pre-user. Fire and
        // forget so bootstrap latency isn't extended by the flush.
        if !outbox.isEmpty { Task { await self.flushOutbox() } }
        return resp.user
    }

    /// Stable client id (UUID) persisted in the token store, generated once
    /// per install. Sent on `createOrFetchUser` so a tokenless retry — offline
    /// first launch, or a create whose response was lost — resolves to the
    /// SAME server user instead of creating a duplicate.
    private func clientId() -> String {
        if let existing = config.tokenStore.readClientId() { return existing }
        let id = UUID().uuidString
        config.tokenStore.writeClientId(id)
        return id
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
        // Only replace each cache when the response actually carries it — a
        // lean/older response that omits a block must not WIPE the cache.
        if let paywalls = resp.paywalls {
            var pwMap: [String: SalesPaywall] = [:]
            for pw in paywalls { pwMap[pw.key] = pw }
            paywallsByKey = pwMap
        }
        if let rc = resp.remoteConfig { remoteConfigCache = rc }
        if let ea = resp.experimentAssignments { experimentAssignments = ea }
        if let retention = resp.retention { retentionStatus = retention }
        SalesLog.debug(.sdk, "absorbed bundle — user=\(resp.user.id) products=\(configuredProductIDs.count) paywalls=\(paywallsByKey.count) remoteConfig=\(remoteConfigCache.count) experiments=\(experimentAssignments.count) rewardAvailable=\(retentionStatus?.available ?? false)")
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
        try guardTransactionsAllowed("restorePurchases")
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
        if !outbox.isEmpty { Task { await self.flushOutbox() } }
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
    ///
    /// Also wipes the stable `clientId`, so the next `ensureUser()` creates a
    /// genuinely NEW guest user instead of de-duplicating back to this one —
    /// a real identity reset (useful for testing). Also clears the in-flight
    /// transaction-claim set.
    public func clearUser() {
        config.tokenStore.clear()
        config.tokenStore.clearClientId()
        claimedTransactionIDs = []
        claimedTransactionOrder = []
        currentUser = nil
        paywallsByKey = [:]
        remoteConfigCache = [:]
        experimentAssignments = [:]
        outbox.removeAll()
        stopOutboxReconnectMonitorIfDrained()
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
        try guardTransactionsAllowed("applyReceipts")
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
        try guardTransactionsAllowed("currentSubscription")
        return try await request(.currentSubscription, method: "GET", body: Empty(), attachUserToken: true)
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
    ///
    /// Pass an `idempotencyKey` unique to the intended charge to make retries
    /// safe: if a spend times out and you re-send it with the same key, the
    /// server recognizes the replay and does NOT debit again (it returns the
    /// balance from the single original debit). Without a key, every call
    /// that reaches the server debits.
    @discardableResult
    public func spendCredits(_ amount: Int, reason: String, idempotencyKey: String? = nil) async throws -> Credits {
        try guardTransactionsAllowed("spendCredits")
        struct Body: Encodable { let amount: Int; let reason: String; let idempotencyKey: String? }
        let credits: Credits = try await request(
            .spendCredits, method: "POST",
            body: Body(amount: amount, reason: reason, idempotencyKey: idempotencyKey), attachUserToken: true
        )
        if let u = currentUser {
            currentUser = SalesUser(
                id: u.id, premium: u.premium,
                credits: credits,
                entitlements: u.entitlements, features: u.features,
                properties: u.properties, stats: u.stats
            )
        }
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
        try guardTransactionsAllowed("claimReward")
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
    // MARK: - Analytics outbox
    // ------------------------------------------------------------------

    /// Shared wire shapes for direct sends AND flushes, so both paths are
    /// byte-identical on the wire. recordEvent accepts the batch form for a
    /// single event too.
    fileprivate struct EventBody: Encodable {
        let name: String
        let properties: [String: AnyEncodable]
        let occurredAt: Date
    }
    fileprivate struct EventBatchBody: Encodable { let events: [EventBody] }
    fileprivate struct SessionBody: Encodable {
        let startedAt: Date
        let endedAt: Date
        let durationSec: Int?
    }

    /// Errors worth retrying later: transport failures, server errors, and
    /// auth losses that a future ensureUser() repairs. Everything else
    /// (validation-class 4xx) is permanent — retrying can never succeed.
    private static func isRetryableForOutbox(_ error: Error) -> Bool {
        switch error {
        case SalesError.network: return true
        case SalesError.http(let status, _, _): return status >= 500 || status == 401
        default: return false
        }
    }

    /// Core path for track / trackBatch / recordSession. Returns normally
    /// when the items were sent OR queued; throws only on permanent
    /// (non-retryable) rejections of a direct send.
    private func sendOrEnqueue(_ newItems: [OutboxItem]) async throws {
        guard !newItems.isEmpty else { return }
        // FIFO guarantee: while backlogged OR mid-flush, new items go BEHIND
        // the queue (an in-flight flush pass picks them up via drainNext).
        if isFlushingOutbox || !outbox.isEmpty {
            enqueueToOutbox(newItems, reason: "backlog ahead")
            await flushOutbox()
            return
        }
        // No user yet → queue locally without a doomed 401 round-trip.
        guard config.tokenStore.read() != nil else {
            enqueueToOutbox(newItems, reason: "no user yet")
            return
        }
        do {
            try await sendBatch(batchFor(newItems))
        } catch {
            if Self.isRetryableForOutbox(error) {
                enqueueToOutbox(newItems, reason: "send failed: \(error)")
                return
            }
            throw error
        }
    }

    /// Homogeneous by construction: each public call produces either events
    /// or a single session, never a mix.
    private func batchFor(_ items: [OutboxItem]) -> OutboxBatch {
        if case .session = items[0] { return .session(items[0]) }
        return .events(items)
    }

    private func enqueueToOutbox(_ items: [OutboxItem], reason: String) {
        let dropped = outbox.append(items)
        if dropped > 0 {
            SalesLog.warn(.outbox, "outbox over cap — dropped \(dropped) oldest item(s)")
        }
        SalesLog.info(.outbox, "queued \(items.count) item(s) (\(reason)) — \(outbox.count) pending")
        startOutboxReconnectMonitorIfNeeded()
    }

    /// Send one drained unit. A 2xx whose body fails to decode is SUCCESS
    /// for queue purposes — the server recorded it; never retry it.
    private func sendBatch(_ batch: OutboxBatch) async throws {
        do {
            switch batch {
            case .events(let items):
                let events = items.compactMap { item -> EventBody? in
                    guard case let .event(name, properties, occurredAt) = item else {
                        assertionFailure("events batch holds a session")
                        return nil
                    }
                    return EventBody(name: name, properties: properties, occurredAt: occurredAt)
                }
                let _: EmptyOK = try await request(
                    .recordEvent, method: "POST",
                    body: EventBatchBody(events: events), attachUserToken: true
                )
            case .session(let item):
                guard case let .session(start, end, durationSec) = item else {
                    assertionFailure("session batch holds an event")
                    return
                }
                let _: EmptyOK = try await request(
                    .recordSession, method: "POST",
                    body: SessionBody(startedAt: start, endedAt: end, durationSec: durationSec),
                    attachUserToken: true
                )
            }
        } catch SalesError.decoding(let detail) {
            SalesLog.warn(.outbox, "2xx response failed to decode (\(detail)) — treating as sent")
        }
    }

    /// Drain the outbox in FIFO order. Single-flight; a pass stops early on
    /// a retryable failure (the failed batch requeues at the FRONT) or when
    /// no user token exists yet.
    func flushOutbox() async {
        guard !isFlushingOutbox, !outbox.isEmpty else { return }
        guard config.tokenStore.read() != nil else {
            SalesLog.debug(.outbox, "flush skipped — no user token yet")
            return
        }
        isFlushingOutbox = true
        defer { isFlushingOutbox = false }
        SalesLog.info(.outbox, "flushing \(outbox.count) queued item(s)")
        while let batch = outbox.drainNext() {
            do {
                try await sendBatch(batch)
                SalesLog.debug(.outbox, "flushed \(batch.items.count) item(s) — \(outbox.count) remaining")
            } catch where Self.isRetryableForOutbox(error) {
                // Known narrow race: clearUser() during this await wipes the
                // outbox, and this requeue can resurrect the abandoned
                // identity's batch. Distinguishing that from a mid-flight
                // 401 token-clear (whose items MUST stay queued) needs an
                // identity generation counter — accepted for analytics-grade
                // data.
                let dropped = outbox.requeue(batch)
                if dropped > 0 {
                    SalesLog.warn(.outbox, "outbox over cap during requeue — dropped \(dropped) oldest item(s)")
                }
                SalesLog.warn(.outbox, "flush stopped — retryable failure, \(outbox.count) item(s) kept: \(error)")
                break
            } catch {
                SalesLog.warn(.outbox, "dropped \(batch.items.count) item(s) — permanent rejection: \(error)")
            }
        }
        stopOutboxReconnectMonitorIfDrained()
    }

    private func startOutboxReconnectMonitorIfNeeded() {
        guard outboxReconnectMonitor == nil, !outbox.isEmpty else { return }
        let m = NetworkMonitor()
        m.onReconnect = { [weak self] in
            Task { await self?.flushOutbox() }
        }
        outboxReconnectMonitor = m
        m.start()
        SalesLog.debug(.outbox, "reconnect monitor started")
    }

    private func stopOutboxReconnectMonitorIfDrained() {
        guard outbox.isEmpty, let m = outboxReconnectMonitor else { return }
        m.stop()
        outboxReconnectMonitor = nil
        SalesLog.debug(.outbox, "reconnect monitor stopped — outbox drained")
    }

    // ------------------------------------------------------------------
    // MARK: - Engagement
    // ------------------------------------------------------------------

    /// Record a finished foreground session. The SDK's `SessionTracker`
    /// can call this for you on app lifecycle notifications.
    ///
    /// If the session can't be sent yet (no user, offline, server 5xx) it
    /// is queued in the in-memory outbox and flushed automatically — the
    /// call returns normally. Throws ONLY on permanent rejections
    /// (validation-class 4xx).
    public func recordSession(start: Date, end: Date, durationSec: Int? = nil) async throws {
        try await sendOrEnqueue([.session(start: start, end: end, durationSec: durationSec)])
    }

    /// Log a single custom event. Never throws. Events that can't be sent
    /// yet (no user, offline, server 5xx) are queued in the in-memory
    /// outbox (cap 500, oldest dropped on overflow) with their ORIGINAL
    /// `occurredAt`, and flushed automatically once sending becomes
    /// possible. Permanent rejections are dropped with a warning.
    public func track(_ name: String, properties: [String: AnyEncodable] = [:]) async {
        do {
            try await sendOrEnqueue([.event(name: name, properties: properties, occurredAt: Date())])
        } catch {
            SalesLog.warn(.outbox, "event dropped — permanent rejection: \(error)")
        }
    }

    /// Log multiple events at once. Same queueing behavior as `track`.
    /// Max 50 events per call on the DIRECT send path — the server
    /// truncates anything beyond 50. Only batches that go through the
    /// outbox (queued while unsendable) are chunked at 50 on flush.
    public func trackBatch(_ events: [(name: String, properties: [String: AnyEncodable])]) async {
        let now = Date()
        do {
            try await sendOrEnqueue(events.map { .event(name: $0.name, properties: $0.properties, occurredAt: now) })
        } catch {
            SalesLog.warn(.outbox, "event batch dropped — permanent rejection: \(error)")
        }
    }

    // ------------------------------------------------------------------
    // MARK: - StoreKit observer wiring
    // ------------------------------------------------------------------

    /// Start watching `Transaction.updates` for new purchases / renewals
    /// and auto-upload them. Call once on app boot. Idempotent.
    public func startObservingTransactions() {
        if analyticsOnly {
            SalesLog.warn(.observer, "startObservingTransactions() ignored — SDK is configured analyticsOnly")
            return
        }
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
    private struct APIError: Decodable {
        let error: String
        let message: String?
        /// Some error responses carry fresh state the app should keep — e.g.
        /// a 409 already_claimed bundles the retention status (with
        /// nextClaimAt) so the UI can say "come back at X" without another
        /// round trip.
        let retention: RetentionStatus?

        init(error: String, message: String?) {
            self.error = error
            self.message = message
            self.retention = nil
        }

        private enum CodingKeys: String, CodingKey { case error, message, retention }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.error = (try? c.decode(String.self, forKey: .error)) ?? "unknown"
            self.message = try? c.decode(String.self, forKey: .message)
            self.retention = try? c.decode(RetentionStatus.self, forKey: .retention)
        }
    }

    /// Endpoints that must carry a hardware assertion. Mirrors the server's
    /// ENDPOINT_META `assert` flags — keep the two lists in sync.
    private static let assertedEndpoints: Set<SalesConfig.Endpoint> = [
        .createOrFetchUser, .restoreUser, .applyPurchases, .spendCredits, .claimReward,
    ]

    /// 401 codes that mean "your attest proof was bad", NOT "your user
    /// token is bad" — these must not wipe the stored user session.
    private static let attestErrorCodes: Set<String> = [
        "attestation_required", "unknown_attest_key", "invalid_challenge",
        "invalid_assertion", "assertion_replay", "attest_config_missing",
    ]

    private struct ChallengeResponse: Decodable { let ok: Bool?; let challenge: String }
    private struct AttestRegisterBody: Encodable { let keyId: String; let attestation: String; let challenge: String }

    /// Coalesces concurrent first-launch attest flows: the actor suspends at
    /// awaits inside the attest round-trips, so without this two racing
    /// callers would each generate + register their own key.
    private var attestInFlight: Task<String, Error>?

    /// One-time flag so the unattested warning logs once per process, not
    /// once per call.
    private var warnedUnattested = false

    private func fetchAttestChallenge() async throws -> String {
        let resp: ChallengeResponse = try await request(.attestChallenge, method: "POST", body: Empty(), attachUserToken: false)
        return resp.challenge
    }

    /// First-launch flow: generate a Secure Enclave key, have Apple attest
    /// it, register it with the server, persist the keyId. Subsequent calls
    /// return the stored keyId without touching DeviceCheck. Concurrent
    /// first-time callers share a single in-flight attest Task so only one
    /// key is ever generated and registered.
    private func ensureAttestedKeyId() async throws -> String {
        if let existing = config.tokenStore.readAttestKeyId() { return existing }
        if let inFlight = attestInFlight { return try await inFlight.value }
        guard attestService.isSupported else { throw SalesError.attestUnsupported }
        let task = Task { try await self.performFirstAttest() }
        attestInFlight = task
        defer { attestInFlight = nil }   // clear on success AND failure so a later call can retry
        return try await task.value
    }

    /// Generate a Secure Enclave key, have Apple attest it, register it with
    /// the server, and persist the keyId.
    private func performFirstAttest() async throws -> String {
        let keyId = try await attestService.generateKey()
        let challenge = try await fetchAttestChallenge()
        guard let challengeData = Data(base64urlEncoded: challenge) else {
            throw SalesError.invalidState("server challenge was not base64url")
        }
        let attestation = try await attestService.attestKey(keyId, clientDataHash: Data(SHA256.hash(data: challengeData)))
        let _: EmptyOK = try await request(
            .attestKey, method: "POST",
            body: AttestRegisterBody(keyId: keyId, attestation: attestation.base64EncodedString(), challenge: challenge),
            attachUserToken: false
        )
        config.tokenStore.writeAttestKeyId(keyId)
        SalesLog.info(.http, "app attest key registered")
        return keyId
    }

    /// Assertion headers for one asserted call. clientDataHash =
    /// SHA256(challengeBytes ‖ SHA256(exact body bytes)) — must match the
    /// server's recipe bit-for-bit.
    private func attestHeaders(bodyData: Data) async throws -> [String: String] {
        guard attestService.isSupported else { throw SalesError.attestUnsupported }
        let keyId = try await ensureAttestedKeyId()
        let challenge = try await fetchAttestChallenge()
        guard let challengeData = Data(base64urlEncoded: challenge) else {
            throw SalesError.invalidState("server challenge was not base64url")
        }
        let bodyHash = Data(SHA256.hash(data: bodyData))
        let clientDataHash = Data(SHA256.hash(data: challengeData + bodyHash))

        var activeKeyId = keyId
        let assertion: Data
        do {
            assertion = try await attestService.generateAssertion(activeKeyId, clientDataHash: clientDataHash)
        } catch {
            // The stored key can no longer sign — its Secure Enclave key was
            // invalidated (device restore, key rotation, container reset). The
            // keyId persists in the Keychain across reinstalls, so this would
            // otherwise be a permanent wall. Discard it, attest a fresh key,
            // and sign once more. The challenge above is not consumed until the
            // asserted request reaches the server, so it stays valid here.
            SalesLog.warn(.sdk, "generateAssertion failed for stored key (\(error)) — re-attesting a fresh key")
            config.tokenStore.clearAttestKeyId()
            activeKeyId = try await ensureAttestedKeyId()
            assertion = try await attestService.generateAssertion(activeKeyId, clientDataHash: clientDataHash)
        }
        return [
            "x-attest-key-id": activeKeyId,
            "x-attest-challenge": challenge,
            "x-attest-assertion": assertion.base64EncodedString(),
        ]
    }

    private func request<B: Encodable, T: Decodable>(
        _ endpoint: SalesConfig.Endpoint,
        method: String,
        body: B?,
        attachUserToken: Bool,
        isAttestRetry: Bool = false
    ) async throws -> T {
        let url = config.url(for: endpoint)
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(config.apiKey, forHTTPHeaderField: "x-app-key")
        if attachUserToken, let token = config.tokenStore.read() {
            req.setValue(token, forHTTPHeaderField: "x-user-token")
        }
        var bodyData: Data? = nil
        if let body = body, !(body is Empty) {
            bodyData = try encoder.encode(body)
        }
        if Self.assertedEndpoints.contains(endpoint) {
            if attestService.isSupported {
                for (k, v) in try await attestHeaders(bodyData: bodyData ?? Data()) {
                    req.setValue(v, forHTTPHeaderField: k)
                }
            } else {
                // This platform (e.g. the iOS Simulator) cannot App Attest.
                // Signal it explicitly — the server quarantines the session
                // as a SANDBOX identity: play-money credits, Sandbox-only
                // receipts, excluded from production analytics.
                req.setValue("1", forHTTPHeaderField: "x-attest-unsupported")
                if !warnedUnattested {
                    warnedUnattested = true
                    SalesLog.warn(.sdk, "App Attest unavailable — running UNATTESTED. This identity is SANDBOX (excluded from production data). Use a physical device for production behavior.")
                }
            }
        }
        if let bodyData {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = bodyData
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
            // Ingest state the server attached to the error body before
            // throwing — the response is authoritative even on a 4xx.
            if let retention = err.retention { retentionStatus = retention }
            // 401 → user token is invalid. Wipe it so the next call starts
            // fresh via /users instead of looping on bad credentials. Also drop
            // the cached user + derived caches: otherwise the app keeps showing
            // the last-known (possibly premium) state the server just
            // invalidated. We keep the clientId so the next ensureUser()
            // de-dupes back to the SAME guest rather than minting a new one —
            // a 401 is an expired session, not an identity reset.
            // Attest rejections are about the DEVICE key, not the user
            // session — recover the key, don't wipe the user.
            if http.statusCode == 401, err.error == "unknown_attest_key",
               Self.assertedEndpoints.contains(endpoint), !isAttestRetry {
                config.tokenStore.clearAttestKeyId()
                return try await request(endpoint, method: method, body: body,
                                         attachUserToken: attachUserToken, isAttestRetry: true)
            }
            // 403 token_key_mismatch: the user JWT is bound to a previous
            // device key (e.g. after re-attestation) — the session is stale,
            // not the key. Re-mint the JWT against the current key, retry once.
            if http.statusCode == 403, err.error == "token_key_mismatch",
               Self.assertedEndpoints.contains(endpoint), attachUserToken, !isAttestRetry {
                config.tokenStore.clear()
                _ = try await ensureUser()
                return try await request(endpoint, method: method, body: body,
                                         attachUserToken: attachUserToken, isAttestRetry: true)
            }
            if http.statusCode == 401, !Self.attestErrorCodes.contains(err.error) {
                config.tokenStore.clear()
                currentUser = nil
                paywallsByKey = [:]
                remoteConfigCache = [:]
                experimentAssignments = [:]
            }
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
