import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Context payload sent up with `ensureUser` / `restorePurchases` /
/// `updateContext`. Every field is optional — the SDK collects what it can
/// from the device and the caller fills in the rest (notably `marketing`
/// and `consent`, which involve user prompts the SDK can't make on the
/// caller's behalf).
public struct UserContext: Encodable, Sendable {
    public var device: DeviceContext?
    public var app: AppContext?
    public var locale: LocaleContext?
    public var network: NetworkContext?
    public var marketing: MarketingContext?
    public var consent: ConsentContext?
    public var push: PushContext?
    public var metadata: [String: AnyEncodable]?
    /// SDK-managed stable client id (UUID), injected by `SalesClient` on
    /// createOrFetch so a tokenless retry resolves to the same server user.
    /// Callers don't set this — it has a default and is filled in internally.
    public var clientId: String? = nil

    public init(
        device: DeviceContext? = nil,
        app: AppContext? = nil,
        locale: LocaleContext? = nil,
        network: NetworkContext? = nil,
        marketing: MarketingContext? = nil,
        consent: ConsentContext? = nil,
        push: PushContext? = nil,
        metadata: [String: AnyEncodable]? = nil
    ) {
        self.device = device
        self.app = app
        self.locale = locale
        self.network = network
        self.marketing = marketing
        self.consent = consent
        self.push = push
        self.metadata = metadata
    }

    /// Build a context populated from the current device + locale. Caller
    /// can then `.merge(...)` marketing / consent overrides.
    public static func current() -> UserContext {
        UserContext(
            device: .current(),
            app:    .current(),
            locale: .current()
        )
    }

    /// Merge another context onto this one, preferring the other side's
    /// values when present. Useful for ATT-prompt completion:
    ///
    ///     var ctx = UserContext.current()
    ///     ctx.merge(UserContext(marketing: .init(attStatus: "authorized")))
    public mutating func merge(_ other: UserContext) {
        if let v = other.device    { device    = v }
        if let v = other.app       { app       = v }
        if let v = other.locale    { locale    = v }
        if let v = other.network   { network   = v }
        if let v = other.marketing { marketing = v }
        if let v = other.consent   { consent   = v }
        if let v = other.push      { push      = v }
        if let v = other.metadata  { metadata  = v }
    }
}

/// Push notification context — APNs device token + current
/// authorization status. Sent up via `SalesCentral.registerPushToken(_:)`
/// or attached to any `UserContext` you push through `updateContext`.
public struct PushContext: Encodable, Sendable {
    public var token: String?         // APNs device token, lowercased hex
    public var environment: String?   // "production" or "sandbox"
    public var authStatus: String?    // "authorized" / "denied" / "notDetermined" / ...
    public var appVersion: String?
    public var bundleId: String?

    public init(
        token: String? = nil,
        environment: String? = nil,
        authStatus: String? = nil,
        appVersion: String? = nil,
        bundleId: String? = nil
    ) {
        self.token = token
        self.environment = environment
        self.authStatus = authStatus
        self.appVersion = appVersion
        self.bundleId = bundleId
    }
}

public struct DeviceContext: Encodable, Sendable {
    public var model: String?
    public var family: String?
    public var osName: String?
    public var osVersion: String?
    public var screenWidth: Int?
    public var screenHeight: Int?
    public var screenScale: Double?
    public var totalMemoryMB: Int?
    public var isLowPowerMode: Bool?
    public var isSimulator: Bool?

    public init(
        model: String? = nil, family: String? = nil,
        osName: String? = nil, osVersion: String? = nil,
        screenWidth: Int? = nil, screenHeight: Int? = nil,
        screenScale: Double? = nil, totalMemoryMB: Int? = nil,
        isLowPowerMode: Bool? = nil, isSimulator: Bool? = nil
    ) {
        self.model = model; self.family = family
        self.osName = osName; self.osVersion = osVersion
        self.screenWidth = screenWidth; self.screenHeight = screenHeight
        self.screenScale = screenScale; self.totalMemoryMB = totalMemoryMB
        self.isLowPowerMode = isLowPowerMode; self.isSimulator = isSimulator
    }

    public static func current() -> DeviceContext {
        let model = Self.modelIdentifier()
        var ctx = DeviceContext(
            model: model,
            family: Self.family(from: model),
            isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            isSimulator: Self.isSimulator()
        )
        ctx.totalMemoryMB = Int(ProcessInfo.processInfo.physicalMemory / 1024 / 1024)

        #if canImport(UIKit)
        ctx.osName    = UIDevice.current.systemName
        ctx.osVersion = UIDevice.current.systemVersion
        let s = UIScreen.main
        ctx.screenWidth  = Int(s.nativeBounds.width)
        ctx.screenHeight = Int(s.nativeBounds.height)
        ctx.screenScale  = Double(s.nativeScale)
        #endif

        return ctx
    }

    static func modelIdentifier() -> String {
        var sys = utsname()
        uname(&sys)
        let mirror = Mirror(reflecting: sys.machine)
        return mirror.children.reduce(into: "") { acc, el in
            if let v = el.value as? Int8, v != 0 {
                acc.append(Character(UnicodeScalar(UInt8(v))))
            }
        }
    }

    static func family(from model: String) -> String {
        let id = model.lowercased()
        if id.contains("iphone")   { return "iPhone" }
        if id.contains("ipad")     { return "iPad" }
        if id.contains("mac")      { return "Mac" }
        if id.contains("appletv") || id.contains("tv") { return "AppleTV" }
        if id.contains("watch")    { return "Watch" }
        if id.contains("vision") || id.contains("realitydevice") { return "Vision" }
        return "Other"
    }

    static func isSimulator() -> Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }
}

public struct AppContext: Encodable, Sendable {
    public var version: String?
    public var build: String?
    public var sdkVersion: String?
    public var firstLaunchAt: Date?
    public var storefront: String?

    public init(version: String? = nil, build: String? = nil,
                sdkVersion: String? = nil, firstLaunchAt: Date? = nil,
                storefront: String? = nil)
    {
        self.version = version; self.build = build
        self.sdkVersion = sdkVersion; self.firstLaunchAt = firstLaunchAt
        self.storefront = storefront
    }

    public static func current(sdkVersion: String = SDKMetadata.version) -> AppContext {
        let info = Bundle.main.infoDictionary ?? [:]
        return AppContext(
            version: info["CFBundleShortVersionString"] as? String,
            build:   info["CFBundleVersion"] as? String,
            sdkVersion: sdkVersion
        )
    }
}

public struct LocaleContext: Encodable, Sendable {
    public var locale: String?
    public var language: String?
    public var region: String?
    public var timezone: String?
    public var currency: String?

    public init(locale: String? = nil, language: String? = nil,
                region: String? = nil, timezone: String? = nil,
                currency: String? = nil)
    {
        self.locale = locale; self.language = language
        self.region = region; self.timezone = timezone
        self.currency = currency
    }

    public static func current() -> LocaleContext {
        let l = Locale.current
        return LocaleContext(
            locale:   l.identifier,
            language: l.language.languageCode?.identifier,
            region:   l.region?.identifier,
            timezone: TimeZone.current.identifier,
            currency: l.currency?.identifier
        )
    }
}

public struct NetworkContext: Encodable, Sendable {
    public var type: String?
    public var carrier: String?
    public init(type: String? = nil, carrier: String? = nil) {
        self.type = type; self.carrier = carrier
    }
}

public struct MarketingContext: Encodable, Sendable {
    public var idfa: String?
    public var idfv: String?
    public var attStatus: String?
    public var attributionSource: String?
    public var campaign: String?
    public var utmSource: String?
    public var utmMedium: String?
    public var utmCampaign: String?
    public var utmTerm: String?
    public var utmContent: String?
    public var referrer: String?

    public init(
        idfa: String? = nil, idfv: String? = nil, attStatus: String? = nil,
        attributionSource: String? = nil, campaign: String? = nil,
        utmSource: String? = nil, utmMedium: String? = nil,
        utmCampaign: String? = nil, utmTerm: String? = nil,
        utmContent: String? = nil, referrer: String? = nil
    ) {
        self.idfa = idfa; self.idfv = idfv; self.attStatus = attStatus
        self.attributionSource = attributionSource; self.campaign = campaign
        self.utmSource = utmSource; self.utmMedium = utmMedium
        self.utmCampaign = utmCampaign; self.utmTerm = utmTerm
        self.utmContent = utmContent; self.referrer = referrer
    }
}

public struct ConsentContext: Encodable, Sendable {
    public var analytics: Bool?
    public var marketing: Bool?
    public var timestamp: Date?
    public init(analytics: Bool? = nil, marketing: Bool? = nil, timestamp: Date? = nil) {
        self.analytics = analytics; self.marketing = marketing
        self.timestamp = timestamp ?? (analytics != nil || marketing != nil ? Date() : nil)
    }
}

/// SDK constants. Updated when the package is released.
public enum SDKMetadata {
    public static let version = "1.1.5"
}
