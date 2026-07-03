import Foundation

// Decodable models that mirror the SalesCentral response shapes.
// Everything is Sendable so an actor can hand it back to the main thread.

public struct SalesUser: Decodable, Sendable, Equatable {
    public let id: String
    public let premium: PremiumState
    public let credits: Credits
    public let entitlements: [String: Entitlement]
    public let features: [String]
    /// Caller-defined user properties — see `SalesClient.setUserProperty`.
    /// Values are scalar (string / number / bool). Empty when the user
    /// has none set.
    public let properties: [String: SalesPropertyValue]
    public let stats: Stats?

    public init(
        id: String,
        premium: PremiumState,
        credits: Credits,
        entitlements: [String: Entitlement] = [:],
        features: [String] = [],
        properties: [String: SalesPropertyValue] = [:],
        stats: Stats? = nil
    ) {
        self.id = id
        self.premium = premium
        self.credits = credits
        self.entitlements = entitlements
        self.features = features
        self.properties = properties
        self.stats = stats
    }

    private enum CodingKeys: String, CodingKey {
        case id, premium, credits, entitlements, features, properties, stats
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.premium = try c.decode(PremiumState.self, forKey: .premium)
        self.credits = try c.decode(Credits.self, forKey: .credits)
        // Tolerate older / leaner server responses that omit any of
        // these — the SDK still works with empty defaults.
        self.entitlements = (try? c.decode([String: Entitlement].self, forKey: .entitlements)) ?? [:]
        self.features     = (try? c.decode([String].self,             forKey: .features))     ?? []
        self.properties   = (try? c.decode([String: SalesPropertyValue].self, forKey: .properties)) ?? [:]
        self.stats        = try? c.decode(Stats.self, forKey: .stats)
    }

    /// Convenience: is the user on any paid tier right now?
    public var isPaid: Bool { premium.isPaid }

    /// Convenience: is the user currently in a free trial? (respects expiry)
    public var isInTrial: Bool { premium.isInTrial }
}

// MARK: - SalesPropertyValue Decodable

extension SalesPropertyValue: Decodable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let b = try? c.decode(Bool.self)   { self = .bool(b);   return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        throw DecodingError.dataCorruptedError(
            in: c,
            debugDescription: "SalesPropertyValue must be a string, number, or boolean"
        )
    }
}

public struct PremiumState: Decodable, Sendable, Equatable {
    public let tier: String
    public let expiresAt: Date?
    public let source: String?
    public let isTrial: Bool?
    public let trialEndsAt: Date?

    /// True when the user currently has paid (non-free) access. Respects
    /// `expiresAt`: a lapsed premium reports `false` immediately — no server
    /// round-trip — so a long-running app reflects expiry the moment it passes.
    /// A `nil` `expiresAt` means no expiry (e.g. lifetime / non-expiring grant).
    public var isPaid: Bool {
        guard tier != "free" else { return false }
        if let expiresAt { return expiresAt > Date() }
        return true
    }

    /// The effective tier accounting for expiry: the raw `tier` while active,
    /// otherwise `"free"`. Use this for tier-gated UI instead of raw `tier`.
    public var effectiveTier: String { isPaid ? tier : "free" }

    /// True while a free trial is currently running (respects `trialEndsAt`).
    public var isInTrial: Bool {
        guard isTrial == true else { return false }
        if let trialEndsAt { return trialEndsAt > Date() }
        return true
    }
}

public struct Credits: Decodable, Sendable, Equatable {
    /// Spendable right now.
    public let balance: Int
    /// Purchased but still locked — released on the product's drip schedule
    /// (e.g. 100/day). 0 when the product grants everything at once.
    public let locked: Int
    /// When the next locked tranche becomes spendable. nil when nothing is
    /// locked.
    public let nextUnlockAt: Date?
    /// Ledger row id of the debit. Present only on `spendCredits` responses.
    public let transactionId: String?
    /// Signed proof of the debit (compact HS256 JWS, ~10-minute expiry).
    /// Present only on `spendCredits` responses. For server-delivered work,
    /// forward it to YOUR backend, which verifies it offline with the
    /// receipt signing secret from the admin panel — see the README's
    /// "Charge credits" section.
    public let receipt: String?

    public init(balance: Int, locked: Int = 0, nextUnlockAt: Date? = nil,
                transactionId: String? = nil, receipt: String? = nil) {
        self.balance = balance
        self.locked = locked
        self.nextUnlockAt = nextUnlockAt
        self.transactionId = transactionId
        self.receipt = receipt
    }

    private enum CodingKeys: String, CodingKey {
        case balance, locked, nextUnlockAt, transactionId, receipt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.balance = try c.decode(Int.self, forKey: .balance)
        // Tolerate older servers that only send `balance`.
        self.locked = (try? c.decode(Int.self, forKey: .locked)) ?? 0
        self.nextUnlockAt = try? c.decode(Date.self, forKey: .nextUnlockAt)
        self.transactionId = try? c.decode(String.self, forKey: .transactionId)
        self.receipt = try? c.decode(String.self, forKey: .receipt)
    }
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

/// Retention-reward claim status — configured per app in the admin
/// (App settings → Retention rewards) and refreshed on every `ensureUser`
/// / restore round-trip plus every `claimReward()` call.
public struct RetentionStatus: Decodable, Sendable, Equatable {
    /// Feature switched on for this app at all.
    public let enabled: Bool
    /// Whether `claimReward()` would succeed right now.
    public let available: Bool
    /// Why not, when `available == false`:
    /// `"disabled"` / `"audience"` / `"already_claimed"`.
    public let reason: String?
    /// `"daily"` or `"streak"`.
    public let mode: String?
    /// Credits granted per successful claim.
    public let dailyAmount: Int?
    /// Streak mode only — days in a full cycle.
    public let streakLength: Int?
    /// Streak mode only — extra credits on the cycle's final day.
    public let streakBonusAmount: Int?
    /// Consecutive days claimed (includes today once claimed).
    public let streak: Int?
    /// 1-based day the NEXT claim lands on ("Day 3 of 7").
    public let nextStreakDay: Int?
    /// What the next claim grants, excluding any bonus.
    public let nextAmount: Int?
    /// Bonus included in the next claim (0 when none).
    public let nextBonus: Int?
    public let claimedToday: Bool?
    /// When the user can claim again. nil = claimable now.
    public let nextClaimAt: Date?

    private enum CodingKeys: String, CodingKey {
        case enabled, available, reason, mode, dailyAmount, streakLength,
             streakBonusAmount, streak, nextStreakDay, nextAmount, nextBonus,
             claimedToday, nextClaimAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Tolerant decoding — servers may omit fields per mode/state.
        self.enabled           = (try? c.decode(Bool.self,   forKey: .enabled)) ?? false
        self.available         = (try? c.decode(Bool.self,   forKey: .available)) ?? false
        self.reason            = try? c.decode(String.self,  forKey: .reason)
        self.mode              = try? c.decode(String.self,  forKey: .mode)
        self.dailyAmount       = try? c.decode(Int.self,     forKey: .dailyAmount)
        self.streakLength      = try? c.decode(Int.self,     forKey: .streakLength)
        self.streakBonusAmount = try? c.decode(Int.self,     forKey: .streakBonusAmount)
        self.streak            = try? c.decode(Int.self,     forKey: .streak)
        self.nextStreakDay     = try? c.decode(Int.self,     forKey: .nextStreakDay)
        self.nextAmount        = try? c.decode(Int.self,     forKey: .nextAmount)
        self.nextBonus         = try? c.decode(Int.self,     forKey: .nextBonus)
        self.claimedToday      = try? c.decode(Bool.self,    forKey: .claimedToday)
        self.nextClaimAt       = try? c.decode(Date.self,    forKey: .nextClaimAt)
    }
}

/// Result of a successful `claimReward()` call.
public struct RetentionClaimResult: Decodable, Sendable, Equatable {
    public struct Granted: Decodable, Sendable, Equatable {
        /// The daily reward portion.
        public let amount: Int
        /// Streak-completion bonus included in this claim (0 when none).
        public let bonus: Int
        /// amount + bonus — what actually landed on the balance.
        public let total: Int
        /// 1-based streak position this claim landed on.
        public let streakDay: Int
    }

    public let granted: Granted
    /// Post-claim status — `available` will be false until the next UTC day.
    public let retention: RetentionStatus?
    /// Post-claim credit state (balance + any drip-locked pool).
    public let credits: Credits

    private enum CodingKeys: String, CodingKey { case granted, retention }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.granted = try c.decode(Granted.self, forKey: .granted)
        self.retention = try? c.decode(RetentionStatus.self, forKey: .retention)
        // The claim response carries balance / locked / nextUnlockAt flat at
        // the top level — same shape spendCredits returns.
        self.credits = try Credits(from: decoder)
    }
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
    /// Apple SKUs registered for this app in the admin. May be `nil` on
    /// older servers that don't ship the product-prefetch feature.
    public let products: [SalesProduct]?
    /// Bundled paywalls / remote config / variant assignments. May be
    /// `nil` on older servers; the SDK then falls back to whatever it
    /// already had cached.
    public let paywalls: [SalesPaywall]?
    public let remoteConfig: [String: SalesAnyValue]?
    public let experimentAssignments: [String: String]?

    /// Explicit memberwise init so the SDK's local fallback paths
    /// (no-receipts restore, tests) don't have to spell out `products: nil`.
    public init(
        token: String,
        user: SalesUser,
        restored: Bool,
        applied: [AppliedReceipt],
        products: [SalesProduct]? = nil,
        paywalls: [SalesPaywall]? = nil,
        remoteConfig: [String: SalesAnyValue]? = nil,
        experimentAssignments: [String: String]? = nil
    ) {
        self.token = token
        self.user = user
        self.restored = restored
        self.applied = applied
        self.paywalls = paywalls
        self.remoteConfig = remoteConfig
        self.experimentAssignments = experimentAssignments
        self.products = products
    }
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
