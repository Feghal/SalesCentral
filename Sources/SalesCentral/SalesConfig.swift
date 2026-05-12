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
    /// The public origin where the SalesCentral service is reachable,
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

    /// Load configuration from the app bundle. Two sources are tried, in
    /// order:
    ///
    /// 1. A standalone **`SalesCentral.plist`** resource at the bundle
    ///    root. Modern Xcode iOS projects don't have a top-level
    ///    `Info.plist` file anymore, so a dedicated plist is the cleanest
    ///    way to ship SDK config — drop it into the target, no further
    ///    setup. The file is a dictionary at top level:
    ///
    ///    ```xml
    ///    <plist version="1.0">
    ///    <dict>
    ///        <key>baseURL</key> <string>https://sales.yourdomain.com</string>
    ///        <key>apiKey</key>  <string>csk_...</string>
    ///        <key>tokens</key>
    ///        <dict>
    ///            <key>createOrFetchUser</key> <string>917a5d766e03</string>
    ///            <key>restoreUser</key>       <string>917a5d766e04</string>
    ///            ...
    ///        </dict>
    ///    </dict>
    ///    </plist>
    ///    ```
    ///
    /// 2. A `SalesCentral` dictionary entry inside the app's `Info.plist`
    ///    (legacy / projects that still ship a manual `Info.plist`).
    ///
    /// The admin's App Detail → SDK config card generates both shapes —
    /// pick whichever fits the project layout.
    ///
    /// `bundle` defaults to `.main`; pass a different bundle for unit
    /// tests, app extensions, or framework targets.
    public static func fromBundle(_ bundle: Bundle = .main) -> SalesConfig {
        // Source 1: standalone SalesCentral.plist at bundle root.
        if let url = bundle.url(forResource: "SalesCentral", withExtension: "plist"),
           let data = try? Data(contentsOf: url),
           let raw = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] {
            return parse(raw, source: "SalesCentral.plist")
        }

        // Source 2: SalesCentral key inside Info.plist.
        if let raw = bundle.object(forInfoDictionaryKey: "SalesCentral") as? [String: Any] {
            return parse(raw, source: "Info.plist → SalesCentral")
        }

        preconditionFailure("""
        SalesCentral SDK could not find its configuration. Add one of:

          • A SalesCentral.plist file to your app target (recommended for
            modern Xcode projects). Generate the XML from the admin's
            App Detail → SDK config card → "SalesCentral.plist" tab.

          • A 'SalesCentral' dictionary key in your Info.plist (legacy).
        """)
    }

    /// Back-compat alias for `fromBundle()`. Prefer `fromBundle()` going
    /// forward — the loader looks at `SalesCentral.plist` *and* Info.plist.
    @available(*, deprecated, renamed: "fromBundle", message: "Renamed to fromBundle() — now also reads a standalone SalesCentral.plist file.")
    public static func fromInfoPlist(bundle: Bundle = .main) -> SalesConfig {
        fromBundle(bundle)
    }

    // ------------------------------------------------------------------
    // MARK: - Plist parsing
    // ------------------------------------------------------------------

    private static func parse(_ raw: [String: Any], source: String) -> SalesConfig {
        guard let urlString = raw["baseURL"] as? String, !urlString.isEmpty,
              let url = URL(string: urlString) else {
            preconditionFailure("\(source): 'baseURL' is missing or not a valid URL.")
        }
        guard let apiKey = (raw["apiKey"] as? String), !apiKey.isEmpty else {
            preconditionFailure("\(source): 'apiKey' is missing.")
        }
        guard let t = raw["tokens"] as? [String: String] else {
            preconditionFailure("\(source): 'tokens' must be a Dictionary of String → String.")
        }
        func need(_ key: String) -> String {
            guard let v = t[key], !v.isEmpty else {
                preconditionFailure("\(source): 'tokens.\(key)' is missing.")
            }
            return v
        }
        return SalesConfig(
            baseURL: url,
            apiKey: apiKey,
            tokens: Tokens(
                createOrFetchUser:   need("createOrFetchUser"),
                restoreUser:         need("restoreUser"),
                applyPurchases:      need("applyPurchases"),
                currentSubscription: need("currentSubscription"),
                spendCredits:        need("spendCredits"),
                recordSession:       need("recordSession"),
                recordEvent:         need("recordEvent")
            )
        )
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
