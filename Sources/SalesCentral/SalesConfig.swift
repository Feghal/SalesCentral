import Foundation

/// Configuration for a single registered app.
///
/// Every operation in this SDK lives behind its own unguessable URL. The
/// admin generates a unique 12-char hex token per (app, operation) when the
/// app is registered. Paste those tokens into `Tokens` below — the SDK
/// composes the URLs from `baseUrl + "/" + token` at call time.
///
/// You don't have to type these by hand: open your app's detail page in the
/// admin and copy the prebuilt Swift snippet from the "SDK config" card.
public struct SalesConfig: Sendable {
    /// The public origin where the central-sales-rest service is reachable,
    /// e.g. `https://sales.yourdomain.com`. No trailing slash.
    public let baseURL: URL

    /// API key for this app — sent as the `x-app-key` header on every
    /// request. Treat it as a secret. Store in your Info.plist / a secrets
    /// file / a remote config, not in source control.
    public let apiKey: String

    /// Per-operation tokens. Each is a 12-char hex string.
    public let tokens: Tokens

    /// Optional override for the user-token storage backend. Defaults to
    /// the system Keychain.
    public let tokenStore: TokenStore

    public init(baseURL: URL, apiKey: String, tokens: Tokens, tokenStore: TokenStore? = nil) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.tokens = tokens
        self.tokenStore = tokenStore ?? KeychainTokenStore.shared
    }

    /// Map an operation to its full URL.
    public func url(for endpoint: Endpoint) -> URL {
        let token: String
        switch endpoint {
        case .createOrFetchUser:   token = tokens.createOrFetchUser
        case .restoreUser:         token = tokens.restoreUser
        case .applyPurchases:      token = tokens.applyPurchases
        case .currentSubscription: token = tokens.currentSubscription
        case .spendCredits:        token = tokens.spendCredits
        case .recordSession:       token = tokens.recordSession
        case .recordEvent:         token = tokens.recordEvent
        }
        return baseURL.appendingPathComponent(token)
    }

    /// Operations the SDK can talk to. Mirrors `EndpointRoute.ENDPOINT_TYPES`
    /// on the server, minus the Apple webhook (which doesn't involve the SDK).
    public enum Endpoint: Sendable, CaseIterable {
        case createOrFetchUser
        case restoreUser
        case applyPurchases
        case currentSubscription
        case spendCredits
        case recordSession
        case recordEvent
    }

    /// The per-operation tokens for one app. The admin's "SDK config" card
    /// outputs an initializer literal with these prefilled.
    public struct Tokens: Sendable, Codable, Equatable {
        public let createOrFetchUser: String
        public let restoreUser: String
        public let applyPurchases: String
        public let currentSubscription: String
        public let spendCredits: String
        public let recordSession: String
        public let recordEvent: String

        public init(
            createOrFetchUser: String,
            restoreUser: String,
            applyPurchases: String,
            currentSubscription: String,
            spendCredits: String,
            recordSession: String,
            recordEvent: String
        ) {
            self.createOrFetchUser   = createOrFetchUser
            self.restoreUser         = restoreUser
            self.applyPurchases      = applyPurchases
            self.currentSubscription = currentSubscription
            self.spendCredits        = spendCredits
            self.recordSession       = recordSession
            self.recordEvent         = recordEvent
        }
    }
}
