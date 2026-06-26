import Foundation
import Security

/// Pluggable storage for the user JWT issued by the service.
///
/// The SDK defaults to `KeychainTokenStore`, which combines the system
/// Keychain (primary) with a UserDefaults shadow (fallback). See that
/// type's docs for the disruption matrix. Apps that want test-only storage
/// can implement this protocol and pass it in via `SalesConfig`.
public protocol TokenStore: Sendable {
    func read() -> String?
    func write(_ token: String)
    func clear()

    /// Read/persist the SDK's stable client id (a UUID) used for idempotent
    /// user creation. Default implementations are no-ops so existing custom
    /// `TokenStore`s keep compiling — they just don't get cross-launch
    /// idempotency until they implement these. The built-in stores do.
    func readClientId() -> String?
    func writeClientId(_ id: String)
    /// Wipe the stored client id so the next create starts a brand-new guest
    /// user (a genuine identity reset). Default is a no-op.
    func clearClientId()
}

public extension TokenStore {
    func readClientId() -> String? { nil }
    func writeClientId(_ id: String) {}
    func clearClientId() {}
}

/// Default token store — system Keychain with a UserDefaults shadow.
///
/// Service / account labels are namespaced to the bundle id so multiple
/// apps using the SDK on the same device don't collide.
///
/// Two stores, primary + shadow, because each survives a different
/// disruption:
///
/// * **Keychain (primary)** survives uninstall + reinstall, but the default
///   access group is `<TeamID>.<BundleID>` — after an App Store Connect app
///   transfer the Team ID changes and the new build can't read the old
///   entries. The user looks "new" to the server.
/// * **UserDefaults (shadow)** is keyed only by bundle id, so it survives an
///   app transfer. It does NOT survive uninstall.
///
/// `read()` prefers the Keychain; if it misses, it falls back to the shadow
/// and self-heals (writes the recovered value back into the Keychain) so
/// subsequent reads hit the primary path. Free guest users that have never
/// purchased anything benefit the most — for paying users, StoreKit
/// `Transaction.all` + `restorePurchases()` is the authoritative recovery
/// path, since the original transaction ids re-link on the server.
public final class KeychainTokenStore: TokenStore, @unchecked Sendable {
    public static let shared = KeychainTokenStore()

    private let service: String
    private let account: String
    private let defaultsKey: String
    private let defaults: UserDefaults

    public init(
        service: String? = nil,
        account: String = "user_token",
        defaults: UserDefaults = .standard
    ) {
        let bundle = Bundle.main.bundleIdentifier ?? "central.sales"
        self.service = service ?? "\(bundle).centralSales"
        self.account = account
        self.defaultsKey = "\(self.service).\(account)"
        self.defaults = defaults
    }

    private var query: [String: Any] {
        [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func read() -> String? {
        if let s = readKeychain() { return s }
        // Keychain miss — try the UserDefaults shadow. Most likely cause is
        // an App Store Connect app transfer (new Team ID can't read the old
        // keychain entries). Self-heal by writing the recovered value back
        // into the keychain so the next read hits the primary path.
        guard let s = defaults.string(forKey: defaultsKey) else { return nil }
        writeKeychain(s)
        return s
    }

    public func write(_ token: String) {
        writeKeychain(token)
        defaults.set(token, forKey: defaultsKey)
    }

    public func clear() {
        SecItemDelete(query as CFDictionary)
        defaults.removeObject(forKey: defaultsKey)
    }

    // MARK: - Client id (stable idempotent-create key)

    private var clientIdQuery: [String: Any] {
        [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "client_id",
        ]
    }
    private var clientIdDefaultsKey: String { "\(service).client_id" }

    public func readClientId() -> String? {
        var q = clientIdQuery
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data, let s = String(data: data, encoding: .utf8) {
            return s
        }
        // Keychain miss — fall back to the UserDefaults shadow and self-heal,
        // mirroring read()'s app-transfer recovery.
        guard let s = defaults.string(forKey: clientIdDefaultsKey) else { return nil }
        writeClientId(s)
        return s
    }

    public func writeClientId(_ id: String) {
        SecItemDelete(clientIdQuery as CFDictionary)
        var add = clientIdQuery
        add[kSecValueData as String]      = Data(id.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
        defaults.set(id, forKey: clientIdDefaultsKey)
    }

    public func clearClientId() {
        SecItemDelete(clientIdQuery as CFDictionary)
        defaults.removeObject(forKey: clientIdDefaultsKey)
    }

    // ------------------------------------------------------------------

    private func readKeychain() -> String? {
        var q = query
        q[kSecReturnData as String]  = true
        q[kSecMatchLimit as String]  = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    private func writeKeychain(_ token: String) {
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String]      = Data(token.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// In-memory store — useful for unit tests.
public final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?
    public init(initial: String? = nil) { self.token = initial }
    private var clientId_: String?
    public func read() -> String? { lock.lock(); defer { lock.unlock() }; return token }
    public func write(_ token: String) { lock.lock(); defer { lock.unlock() }; self.token = token }
    public func clear() { lock.lock(); defer { lock.unlock() }; self.token = nil }
    public func readClientId() -> String? { lock.lock(); defer { lock.unlock() }; return clientId_ }
    public func writeClientId(_ id: String) { lock.lock(); defer { lock.unlock() }; clientId_ = id }
    public func clearClientId() { lock.lock(); defer { lock.unlock() }; clientId_ = nil }
}
