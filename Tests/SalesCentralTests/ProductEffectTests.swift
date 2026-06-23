// sdk/swift/Tests/SalesCentralTests/ProductEffectTests.swift
import XCTest
@testable import SalesCentral

final class ProductEffectTests: XCTestCase {
    func testDecodeCatalogWithAllEffectCases() throws {
        let json = """
        [
          {
            "productId": "com.app.pro", "type": "auto_renewable_subscription",
            "displayName": "Pro", "description": "All access", "subscriptionPeriod": "P1M",
            "effects": [
              { "type": "set_premium", "tier": "pro", "durationDays": 30 },
              { "type": "grant_credits", "amount": 1000, "trialAmount": 100, "unlockAmount": 50, "unlockPeriod": "week" },
              { "type": "grant_entitlement", "entitlement": "voice", "durationDays": 30 },
              { "type": "unlock_feature", "feature": "remove_ads" },
              { "type": "future_thing", "amount": 5 }
            ]
          },
          { "productId": "com.app.coins", "type": "consumable", "effects": [] }
        ]
        """.data(using: .utf8)!

        let products = try JSONDecoder().decode([SalesProduct].self, from: json)
        XCTAssertEqual(products.count, 2)

        let pro = products[0]
        XCTAssertEqual(pro.productId, "com.app.pro")
        XCTAssertEqual(pro.subscriptionPeriod, "P1M")
        XCTAssertEqual(pro.effects.count, 5)
        XCTAssertEqual(pro.effects[0], .setPremium(tier: "pro", durationDays: 30, trialDurationDays: nil))
        XCTAssertEqual(pro.effects[1], .grantCredits(amount: 1000, trialAmount: 100, unlockAmount: 50, unlockPeriod: "week"))
        XCTAssertEqual(pro.effects[2], .grantEntitlement(entitlement: "voice", durationDays: 30, trialDurationDays: nil))
        XCTAssertEqual(pro.effects[3], .unlockFeature(feature: "remove_ads"))
        XCTAssertEqual(pro.effects[4], .unknown(type: "future_thing"))

        // Lean product: missing displayName/description/subscriptionPeriod tolerated.
        let coins = products[1]
        XCTAssertEqual(coins.displayName, "")
        XCTAssertEqual(coins.description, "")
        XCTAssertNil(coins.subscriptionPeriod)
        XCTAssertTrue(coins.effects.isEmpty)
    }

    func testRestoreResultDecodesRichProducts() throws {
        let json = """
        { "token": "t", "user": { "id": "u", "premium": { "tier": "free" }, "credits": { "balance": 0 } },
          "restored": false, "applied": [],
          "products": [ { "productId": "com.app.pro", "type": "consumable",
                          "effects": [ { "type": "grant_credits", "amount": 500 } ] } ] }
        """.data(using: .utf8)!
        let r = try JSONDecoder().decode(RestoreResult.self, from: json)
        XCTAssertEqual(r.products?.count, 1)
        XCTAssertEqual(r.products?.first?.productId, "com.app.pro")
        XCTAssertEqual(r.products?.first?.effects.first, .grantCredits(amount: 500, trialAmount: nil, unlockAmount: nil, unlockPeriod: nil))
    }
}
