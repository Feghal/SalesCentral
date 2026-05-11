import Foundation
import Security

/// Pluggable storage for the user JWT issued by the service.
///
/// The SDK defaults to `KeychainTokenStore` which uses the system Keychain
/// — survives reinstalls if iCloud Keychain is on (don't rely on that for
/// recovery though; use the explicit `restorePurchases` flow). Apps that
/// want test-only storage can implement this protocol and pass it in via
/// `SalesConfig`.
public protocol TokenStore: Sendable {
    func read() -> String?
    func write(_ token: String)
    func clear()
}

/// Default Keychain-backed token store.
///
/// Service / account labels are namespaced to the bundle id so multiple
/// apps using the SDK on the same device don't collide.
public final class KeychainTokenStore: TokenStore, @unchecked Sendable {
    public static let shared = KeychainTokenStore()

    private let service: String
    private let account: String

    public init(service: String? = nil, account: String = "user_token") {
        let bundle = Bundle.main.bundleIdentifier ?? "central.sales"
        self.service = service ?? "\(bundle).centralSales"
        self.account = account
    }

    private var query: [String: Any] {
        [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func read() -> String? {
        var q = query
        q[kSecReturnData as String]  = true
        q[kSecMatchLimit as String]  = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    public func write(_ token: String) {
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String]      = Data(token.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    public func clear() {
        SecItemDelete(query as CFDictionary)
    }
}

/// In-memory store — useful for unit tests.
public final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?
    public init(initial: String? = nil) { self.token = initial }
    public func read() -> String? { lock.lock(); defer { lock.unlock() }; return token }
    public func write(_ token: String) { lock.lock(); defer { lock.unlock() }; self.token = token }
    public func clear() { lock.lock(); defer { lock.unlock() }; self.token = nil }
}
