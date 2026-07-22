import Foundation
#if canImport(StoreKit)
import StoreKit
#endif

/// Abstraction over StoreKit 2's `AppTransaction` so tests can inject a mock.
///
/// This backs the "App Store install proof" fallback trust tier: on
/// platforms where App Attest is unavailable (e.g. Mac Catalyst on
/// macOS <= 26), the SDK can present the App Store's own signed install
/// receipt instead, letting an opted-in app admit the device as a
/// production identity rather than sandbox.
public protocol AppTransactionProviding: Sendable {
    /// Returns the JWS representation of a verified, non-Xcode
    /// `AppTransaction`, or `nil` when none is available (unsupported
    /// platform, unverified result, or running under Xcode).
    func installProofJWS() async -> String?
}

#if canImport(StoreKit)
/// Production implementation backed by StoreKit 2's cached `AppTransaction`.
///
/// Deliberately reads only the cached `AppTransaction.shared` value — it
/// NEVER calls `AppTransaction.refresh()`, which can prompt the user for an
/// App Store sign-in. That would turn a silent background fallback into an
/// intrusive UI interruption, so this service simply returns `nil` when no
/// cached proof is available rather than forcing a refresh.
struct LiveAppTransactionService: AppTransactionProviding {
    func installProofJWS() async -> String? {
        do {
            let result = try await StoreKit.AppTransaction.shared
            guard case .verified(let t) = result, t.environment != .xcode else { return nil }
            return result.jwsRepresentation
        } catch {
            return nil
        }
    }
}
#else
/// No StoreKit on this platform — no install proof is ever available.
struct LiveAppTransactionService: AppTransactionProviding {
    func installProofJWS() async -> String? { nil }
}
#endif
