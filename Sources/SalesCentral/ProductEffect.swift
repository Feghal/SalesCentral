// sdk/swift/Sources/SalesCentral/ProductEffect.swift
import Foundation

/// A single effect a product applies on purchase, as configured in the admin.
/// Mirrors the server's `Product.effects` entries. `.unknown` keeps the SDK
/// forward-compatible with effect types added on the server later.
public enum ProductEffect: Decodable, Sendable, Equatable {
    case setPremium(tier: String?, durationDays: Int?, trialDurationDays: Int?)
    case grantCredits(amount: Int, trialAmount: Int?, unlockAmount: Int?, unlockPeriod: String?)
    case grantEntitlement(entitlement: String, durationDays: Int?, trialDurationDays: Int?)
    case unlockFeature(feature: String)
    case unknown(type: String)

    private enum CodingKeys: String, CodingKey {
        case type, tier, durationDays, trialDurationDays
        case amount, trialAmount, unlockAmount, unlockPeriod
        case entitlement, feature
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "set_premium":
            self = .setPremium(
                tier: try c.decodeIfPresent(String.self, forKey: .tier),
                durationDays: try c.decodeIfPresent(Int.self, forKey: .durationDays),
                trialDurationDays: try c.decodeIfPresent(Int.self, forKey: .trialDurationDays))
        case "grant_credits":
            self = .grantCredits(
                amount: try c.decodeIfPresent(Int.self, forKey: .amount) ?? 0,
                trialAmount: try c.decodeIfPresent(Int.self, forKey: .trialAmount),
                unlockAmount: try c.decodeIfPresent(Int.self, forKey: .unlockAmount),
                unlockPeriod: try c.decodeIfPresent(String.self, forKey: .unlockPeriod))
        case "grant_entitlement":
            self = .grantEntitlement(
                entitlement: try c.decodeIfPresent(String.self, forKey: .entitlement) ?? "",
                durationDays: try c.decodeIfPresent(Int.self, forKey: .durationDays),
                trialDurationDays: try c.decodeIfPresent(Int.self, forKey: .trialDurationDays))
        case "unlock_feature":
            self = .unlockFeature(feature: try c.decodeIfPresent(String.self, forKey: .feature) ?? "")
        default:
            self = .unknown(type: type)
        }
    }
}

/// A product in the app's catalog, including the effects it grants. Display
/// title/price still come from StoreKit (fetched by `productId`); this carries
/// what the product DOES so paywalls can render benefits pre-purchase.
public struct SalesProduct: Decodable, Sendable, Equatable {
    public let productId: String
    public let type: String
    public let displayName: String
    public let description: String
    public let subscriptionPeriod: String?
    public let effects: [ProductEffect]

    private enum CodingKeys: String, CodingKey {
        case productId, type, displayName, description, subscriptionPeriod, effects
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.productId = try c.decode(String.self, forKey: .productId)
        self.type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        self.displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        self.description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        self.subscriptionPeriod = try c.decodeIfPresent(String.self, forKey: .subscriptionPeriod)
        self.effects = try c.decodeIfPresent([ProductEffect].self, forKey: .effects) ?? []
    }

    public init(productId: String, type: String, displayName: String = "", description: String = "",
                subscriptionPeriod: String? = nil, effects: [ProductEffect] = []) {
        self.productId = productId
        self.type = type
        self.displayName = displayName
        self.description = description
        self.subscriptionPeriod = subscriptionPeriod
        self.effects = effects
    }
}
