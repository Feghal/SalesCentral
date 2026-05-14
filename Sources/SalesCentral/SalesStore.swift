import Foundation
import Combine

/// Optional convenience wrapper for SwiftUI apps.
///
/// `SalesStore` is an `ObservableObject` that mirrors the `SalesClient`
/// state into `@Published` properties so SwiftUI views can react to
/// premium / credits / subscription changes without manually awaiting.
///
/// You don't have to use it — `SalesClient` is fully usable on its own.
@MainActor
public final class SalesStore: ObservableObject {

    @Published public private(set) var user: SalesUser?
    @Published public private(set) var subscription: CurrentSubscriptionResponse?
    @Published public private(set) var lastError: SalesError?

    public let client: SalesClient
    private let sessionTracker: SessionTracker

    /// Convenience: build a fresh `SalesClient` from a `SalesConfig` and
    /// delegate to the designated initializer below.
    public convenience init(_ config: SalesConfig) {
        self.init(client: SalesClient(config))
    }

    /// Designated initializer. Used by `SalesCentral.configure(_:)` so the
    /// singleton facade and `SalesStore` share a single `SalesClient`
    /// actor — in-memory caches and the Keychain JWT stay consistent.
    public init(client: SalesClient) {
        self.client = client
        self.sessionTracker = SessionTracker(client: client)
    }

    /// Sync the store's user + subscription state after an out-of-band
    /// purchase / receipt upload (e.g. `SalesCentral.purchase(_:)`). Views
    /// re-render immediately without waiting for the next refresh.
    public func syncAfterPurchase(user: SalesUser?) async {
        if let u = user { self.user = u }
        self.subscription = try? await client.currentSubscription()
    }

    // ------------------------------------------------------------------

    /// Call once on app launch. Ensures a user exists, refreshes their
    /// subscription state, and wires up the StoreKit + session observers.
    public func bootstrap(_ context: UserContext = .current()) async {
        do {
            user = try await client.ensureUser(context: context)
            subscription = try? await client.currentSubscription()
            await client.startObservingTransactions()
            sessionTracker.start()
        } catch let err as SalesError {
            lastError = err
        } catch {
            lastError = .network(error.localizedDescription)
        }
    }

    public func restorePurchases() async {
        do {
            let r = try await client.restorePurchases()
            user = r.user
            subscription = try? await client.currentSubscription()
        } catch let err as SalesError {
            lastError = err
        } catch {
            lastError = .network(error.localizedDescription)
        }
    }

    /// Upload a single JWS receipt — for the post-purchase flow.
    public func applyReceipt(_ jws: String) async {
        do {
            let r = try await client.applyReceipt(jws)
            if let u = r.user { user = u }
            subscription = try? await client.currentSubscription()
        } catch let err as SalesError {
            lastError = err
        } catch {
            lastError = .network(error.localizedDescription)
        }
    }

    @discardableResult
    public func spendCredits(_ amount: Int, reason: String) async throws -> Int {
        let balance = try await client.spendCredits(amount, reason: reason)
        // Mutate `user` so views update without a re-fetch.
        if var u = user {
            u = SalesUser(
                id: u.id, premium: u.premium,
                credits: Credits(balance: balance),
                entitlements: u.entitlements, features: u.features,
                properties: u.properties, stats: u.stats
            )
            user = u
        }
        return balance
    }

    /// Set a single user property. See `SalesClient.setUserProperty`.
    public func setUserProperty(_ key: String, _ value: SalesPropertyValue?) async {
        do {
            user = try await client.setUserProperty(key, value)
        } catch let err as SalesError {
            lastError = err
        } catch {
            lastError = .network(error.localizedDescription)
        }
    }

    /// Set multiple user properties in one round-trip. See
    /// `SalesClient.setUserProperties`.
    public func setUserProperties(_ properties: [String: SalesPropertyValue?]) async {
        do {
            user = try await client.setUserProperties(properties)
        } catch let err as SalesError {
            lastError = err
        } catch {
            lastError = .network(error.localizedDescription)
        }
    }

    public func track(_ name: String, properties: [String: AnyEncodable] = [:]) async {
        await client.track(name, properties: properties)
    }

    // ------------------------------------------------------------------
    // MARK: - Convenience accessors
    // ------------------------------------------------------------------

    public var isPaid: Bool      { user?.isPaid ?? false }
    public var isInTrial: Bool   { user?.isInTrial ?? false }
    public var creditBalance: Int { user?.credits.balance ?? 0 }
    public var tier: String      { user?.premium.tier ?? "free" }
}
