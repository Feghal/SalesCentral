import Foundation

// Decodable models that mirror the central_sales_rest response shapes.
// Everything is Sendable so an actor can hand it back to the main thread.

public struct SalesUser: Decodable, Sendable, Equatable {
    public let id: String
    public let premium: PremiumState
    public let credits: Credits
    public let entitlements: [String: Entitlement]
    public let features: [String]
    public let stats: Stats?

    public init(
        id: String,
        premium: PremiumState,
        credits: Credits,
        entitlements: [String: Entitlement] = [:],
        features: [String] = [],
        stats: Stats? = nil
    ) {
        self.id = id
        self.premium = premium
        self.credits = credits
        self.entitlements = entitlements
        self.features = features
        self.stats = stats
    }

    /// Convenience: is the user on any paid tier right now?
    public var isPaid: Bool { premium.isPaid }

    /// Convenience: is the user currently in a free trial?
    public var isInTrial: Bool { premium.isTrial ?? false }
}

public struct PremiumState: Decodable, Sendable, Equatable {
    public let tier: String
    public let expiresAt: Date?
    public let source: String?
    public let isTrial: Bool?
    public let trialEndsAt: Date?

    public var isPaid: Bool { tier != "free" }
}

public struct Credits: Decodable, Sendable, Equatable {
    public let balance: Int
}

public struct Entitlement: Decodable, Sendable, Equatable {
    public let active: Bool
    public let expiresAt: Date?
}

public struct Stats: Decodable, Sendable, Equatable {
    public let sessionCount: Int?
    public let totalSecondsInApp: Int?
    public let avgSessionDurationSec: Int?
    public let firstSessionAt: Date?
    public let lastSessionAt: Date?
    public let eventCount: Int?
    public let lifetimePurchaseCents: Int?
    public let lifetimeRefundedCents: Int?
}

public struct SubscriptionDetail: Decodable, Sendable, Equatable {
    public let id: String
    public let productId: String
    public let status: String
    public let isInTrial: Bool?
    public let trialEndsAt: Date?
    public let expiresAt: Date?
    public let isAutoRenewing: Bool
    public let environment: String
}

public struct CurrentSubscriptionResponse: Decodable, Sendable, Equatable {
    public let subscription: SubscriptionDetail?
    public let premium: PremiumState
}

public struct AppliedReceipt: Decodable, Sendable, Equatable {
    public let ok: Bool
    public let transactionId: String?
    public let originalTransactionId: String?
    public let productId: String?
    public let alreadyProcessed: Bool?
    public let effects: [AnyDecodable]?
    public let error: String?
}

/// Response shape for `POST /purchases`.
public struct ApplyResult: Decodable, Sendable {
    public let applied: [AppliedReceipt]
    public let user: SalesUser?
}

/// Response shape for `POST /users/restore`.
public struct RestoreResult: Decodable, Sendable {
    public let token: String
    public let user: SalesUser
    public let restored: Bool
    public let applied: [AppliedReceipt]
}

/// Response shape for `POST /users`.
public struct EnsureUserResult: Decodable, Sendable {
    public let token: String
    public let user: SalesUser
    public let created: Bool
}

// MARK: - Type-erased Decodable for free-form effect data ------------------

/// Tiny type-erased Decodable. Lets the SDK pass through `effects` arrays
/// from the server without the caller needing to know their exact shape.
public struct AnyDecodable: Decodable, Sendable, Equatable {
    public let value: Sendable

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            value = Optional<String>.none as Sendable
        } else if let v = try? c.decode(Bool.self)   { value = v
        } else if let v = try? c.decode(Int.self)    { value = v
        } else if let v = try? c.decode(Double.self) { value = v
        } else if let v = try? c.decode(String.self) { value = v
        } else if let v = try? c.decode([AnyDecodable].self) {
            value = v.map { $0.value as Any } as Sendable
        } else if let v = try? c.decode([String: AnyDecodable].self) {
            value = v.mapValues { $0.value as Any } as Sendable
        } else {
            value = "" as Sendable
        }
    }

    public static func == (lhs: AnyDecodable, rhs: AnyDecodable) -> Bool {
        String(describing: lhs.value) == String(describing: rhs.value)
    }
}
