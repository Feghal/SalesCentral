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

    private var observer: StoreKitObserver?

    public init(_ config: SalesConfig, urlSession: URLSession = .shared) {
        self.config = config
        self.session = urlSession

        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
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
        struct Resp: Decodable {
            let token: String
            let user: SalesUser
            let created: Bool
            // Apple SKUs registered for this app in the admin. Present on
            // servers that ship the product-prefetch feature; older servers
            // omit it and we just keep an empty list.
            let products: [String]?
        }
        let resp: Resp = try await request(
            .createOrFetchUser,
            method: "POST",
            body: context,
            attachUserToken: config.tokenStore.read() != nil
        )
        config.tokenStore.write(resp.token)
        currentUser = resp.user
        configuredProductIDs = resp.products ?? []
        return resp.user
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
        struct Resp: Decodable {
            let token: String
            let user: SalesUser
            let products: [String]?
        }
        let resp: Resp = try await request(
            .createOrFetchUser,
            method: "POST",
            body: PropertiesUpdateBody(properties: wire),
            attachUserToken: true
        )
        config.tokenStore.write(resp.token)
        currentUser = resp.user
        if let p = resp.products { configuredProductIDs = p }
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
        if let ids = resp.products { configuredProductIDs = ids }
        return resp
    }

    /// Sign the user out locally. Doesn't invalidate the server-side JWT
    /// (it'll just naturally expire); call this when the user explicitly
    /// signs out or when you want to start fresh.
    public func clearUser() {
        config.tokenStore.clear()
        currentUser = nil
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
    /// with `code == "insufficient_credits"` when the balance is too low —
    /// surface a paywall in that branch.
    @discardableResult
    public func spendCredits(_ amount: Int, reason: String) async throws -> Int {
        struct Body: Encodable { let amount: Int; let reason: String }
        struct Resp: Decodable { let balance: Int }
        let resp: Resp = try await request(
            .spendCredits, method: "POST",
            body: Body(amount: amount, reason: reason), attachUserToken: true
        )
        return resp.balance
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
        guard observer == nil else { return }
        observer = StoreKitObserver(client: self)
        observer?.start()
    }

    /// Stop the auto-uploader. Rarely needed.
    public func stopObservingTransactions() {
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
        var req = URLRequest(url: config.url(for: endpoint))
        req.httpMethod = method
        req.setValue(config.apiKey, forHTTPHeaderField: "x-app-key")
        if attachUserToken, let token = config.tokenStore.read() {
            req.setValue(token, forHTTPHeaderField: "x-user-token")
        }
        if let body = body, !(body is Empty) {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try encoder.encode(body)
        }

        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw SalesError.network(error.localizedDescription)
        }
        guard let http = resp as? HTTPURLResponse else {
            throw SalesError.network("no HTTP response")
        }
        if !(200..<300 ~= http.statusCode) {
            let err = (try? decoder.decode(APIError.self, from: data))
                ?? APIError(error: "http_\(http.statusCode)", message: nil)
            // 401 → user token is invalid. Wipe it so the next call starts
            // fresh via /users instead of looping on bad credentials.
            if http.statusCode == 401 { config.tokenStore.clear() }
            throw SalesError.http(status: http.statusCode, code: err.error, message: err.message)
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
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
            if case .verified(let txn) = result {
                out.append(String(decoding: txn.jsonRepresentation, as: UTF8.self))
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
