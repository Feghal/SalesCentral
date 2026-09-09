//
//  AdServicesAttribution.swift
//  Apple Search Ads attribution via Apple's AdServices framework.
//
//  WHAT THIS IS FOR. AdServices is the ONLY Apple API that attributes an
//  install to a specific ad campaign at the level of an individual user. It
//  covers Apple Search Ads and nothing else — every other network on iOS
//  reports through SKAdNetwork / AdAttributionKit, which is anonymous by
//  design and cannot be joined to a user. Apps that need those networks
//  forward an MMP's answer through `updateContext` instead.
//
//  It does NOT require ATT. The attribution token is available whatever the
//  user answered (or was never asked), because it identifies the ad, not the
//  person. So this runs unconditionally at bootstrap — no prompt, no gate.
//
//  WHERE THE EXCHANGE HAPPENS. On the device. That is a deliberate departure
//  from how this SDK treats receipts, which are uploaded verbatim and verified
//  server-side because a forged receipt would manufacture an entitlement.
//  Attribution buys nothing: a tampered client could only pollute its own
//  operator's analytics, exactly as it already can by sending any
//  `MarketingContext` it likes. Doing it here keeps Apple's latency and its
//  retry loop off the server's hot path and needs no new endpoint.
//
import Foundation
#if canImport(AdServices)
import AdServices
#endif

/// Resolves Apple Search Ads attribution for this install.
///
/// Internal: it is wired into `SalesCentral.start()` and runs on its own, so
/// there is nothing for a host app to call and no reason to freeze its shape
/// as public API.
enum AdServicesAttribution {

    /// Apple's attribution lookup service.
    static let endpointURL = URL(string: "https://api-adservices.apple.com/api/v1/")!

    /// Apple returns 404 while the token is still propagating, for a few
    /// seconds after a fresh install. Their guidance is to retry rather than
    /// treat it as "no attribution" — giving up early is how an install gets
    /// permanently mislabelled, which first-touch protection then makes final.
    static let maxAttempts = 3
    static let retryDelay: Duration = .seconds(5)

    /// Apple's response body. Every field but `attribution` is absent when
    /// `attribution` is false, and `keywordId` / `adId` are absent for
    /// campaign types that have no such concept.
    struct Response: Decodable, Equatable {
        var attribution: Bool
        var orgId: Int?
        var campaignId: Int?
        var conversionType: String?
        var adGroupId: Int?
        var countryOrRegion: String?
        var keywordId: Int?
        var adId: Int?
    }

    /// What one resolution attempt concluded.
    enum Outcome: Equatable {
        /// Apple Search Ads produced this install; send these fields.
        case attributed(MarketingContext)
        /// Apple answered definitively that this install did NOT come from
        /// Apple Search Ads. Nothing to send, and nothing to retry.
        case notAppleSearchAds
        /// No answer — token unavailable, offline, or Apple still 404ing.
        /// Retry on a later launch.
        case unavailable
    }

    // MARK: - Mapping

    /// Translate Apple's payload into the marketing fields the backend stores.
    ///
    /// `attribution == false` returns nil, and it is important that it does NOT
    /// return `"organic"`. False means "not Apple Search Ads" — the install may
    /// well have come from Google or Meta. Recording it as organic would
    /// misfile every paid non-Apple install, and because acquisition fields are
    /// write-once on the server, that mistake could never be corrected.
    static func marketingContext(from response: Response) -> MarketingContext? {
        guard response.attribution else { return nil }

        let campaign = response.campaignId.map(String.init)
        return MarketingContext(
            // Matches the vocabulary the backend already documents for this
            // field (see models/User.js) and the label the admin renders.
            attributionSource: "asa",
            campaign: campaign,
            // Apple gives numeric ids, not names — the human-readable campaign
            // name lives only in the Search Ads Campaign Management API.
            utmSource: "apple_search_ads",
            // "Download" or "Redownload": whether this was a new customer.
            utmMedium: response.conversionType,
            utmCampaign: campaign,
            utmTerm: response.keywordId.map(String.init),
            // The ad is narrower than the ad group; prefer it when present.
            utmContent: (response.adId ?? response.adGroupId).map(String.init)
        )
    }

    // MARK: - Token

    /// The device's attribution token, or nil where AdServices cannot produce
    /// one — watchOS (no framework), the simulator, and builds that are not
    /// App Store installs. All of those are ordinary, not errors.
    static func attributionToken() -> String? {
        #if canImport(AdServices)
        do {
            return try AAAttribution.attributionToken()
        } catch {
            SalesLog.debug(.attribution, "no attribution token: \(error.localizedDescription)")
            return nil
        }
        #else
        return nil
        #endif
    }

    // MARK: - Exchange

    private struct RetryableError: Error {}

    /// POST the token to Apple and decode the reply. The body is the raw token
    /// as `text/plain` — not JSON, which is easy to get wrong and answers 400.
    static func exchange(token: String, session: URLSession) async throws -> Response {
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(token.utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RetryableError() }
        switch http.statusCode {
        case 200:
            return try JSONDecoder().decode(Response.self, from: data)
        case 404:
            // Token not yet queryable — the expected state moments after install.
            throw RetryableError()
        default:
            SalesLog.warn(.attribution, "AdServices exchange failed: HTTP \(http.statusCode)")
            throw RetryableError()
        }
    }

    /// Fetch the token, exchange it, and map the result — retrying only the
    /// part of that which Apple asks us to retry.
    ///
    /// `token` is injectable because reading it is the one step with no seam:
    /// AdServices only issues a token to a real App Store install, so under
    /// `swift test` (and on the simulator) it is always nil. Without the
    /// parameter every test below would short-circuit before making a request
    /// and would assert nothing about the retry contract.
    static func resolve(
        token: String? = Self.attributionToken(),
        session: URLSession = .shared,
        retryDelay: Duration = Self.retryDelay
    ) async -> Outcome {
        guard let token else { return .unavailable }

        for attempt in 1...maxAttempts {
            do {
                let response = try await exchange(token: token, session: session)
                if let marketing = marketingContext(from: response) {
                    SalesLog.info(.attribution, "Apple Search Ads install (campaign \(response.campaignId.map(String.init) ?? "?"))")
                    return .attributed(marketing)
                }
                SalesLog.debug(.attribution, "not an Apple Search Ads install")
                return .notAppleSearchAds
            } catch {
                guard attempt < maxAttempts else { break }
                try? await Task.sleep(for: retryDelay)
            }
        }
        SalesLog.debug(.attribution, "AdServices attribution unavailable after \(maxAttempts) attempts")
        return .unavailable
    }
}
