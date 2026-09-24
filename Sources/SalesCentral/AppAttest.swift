import Foundation
import CryptoKit
#if canImport(DeviceCheck)
import DeviceCheck
#endif

/// Abstraction over DCAppAttestService so tests can inject a mock.
public protocol AppAttestServicing: Sendable {
    var isSupported: Bool { get }
    func generateKey() async throws -> String
    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data
    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data
}

#if canImport(DeviceCheck)
/// Production implementation backed by the system App Attest service.
struct LiveAppAttestService: AppAttestServicing {
    var isSupported: Bool { DCAppAttestService.shared.isSupported }
    func generateKey() async throws -> String {
        try await DCAppAttestService.shared.generateKey()
    }
    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data {
        try await DCAppAttestService.shared.attestKey(keyId, clientDataHash: clientDataHash)
    }
    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data {
        try await DCAppAttestService.shared.generateAssertion(keyId, clientDataHash: clientDataHash)
    }
}
#else
struct LiveAppAttestService: AppAttestServicing {
    var isSupported: Bool { false }
    func generateKey() async throws -> String { throw SalesError.attestUnsupported }
    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data { throw SalesError.attestUnsupported }
    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data { throw SalesError.attestUnsupported }
}
#endif

/// How the SDK treats a DeviceCheck failure on a key it already holds.
/// Apple documents a retry only for `serverUnavailable` from `attestKey`;
/// the rest follows field reports (Apple developer forum threads 785346 and
/// 838933, firebase-ios-sdk#12629 and #16256, google/app-check#96).
enum AttestFailure: Equatable {
    /// The Secure Enclave no longer has the key — app reinstall, device
    /// restore or migration. `invalidKey`, plus `invalidInput`, which iCloud
    /// restores report for a key from a previous install.
    case keyRejected
    /// `unknownSystemFailure`. Usually passes; one that never clears is a
    /// stuck key only a new key fixes (google/app-check#96).
    case systemFailure
    /// `serverUnavailable`: Apple's side is busy or throttling. The key is fine.
    case serviceUnavailable
    /// Anything else. Keep the key and surface the error.
    case other

    init(_ error: Error) {
        #if canImport(DeviceCheck)
        if let dc = error as? DCError {
            switch dc.code {
            case .invalidKey, .invalidInput:
                self = .keyRejected
                return
            case .unknownSystemFailure:
                self = .systemFailure
                return
            case .serverUnavailable:
                self = .serviceUnavailable
                return
            default:
                break
            }
        }
        #endif
        self = .other
    }

    /// Worth another attempt on the same key after a pause.
    var isTransient: Bool { self == .systemFailure || self == .serviceUnavailable }

    /// Replace the key when this failure outlasts the same-key retries.
    var retiresKey: Bool { self == .keyRejected || self == .systemFailure }
}

/// Pauses between App Attest attempts on the same key, in nanoseconds.
struct AttestRetrySchedule: Sendable {
    /// Before re-checking a key DeviceCheck rejected once.
    var recheckRejectedKey: UInt64
    /// Between attempts after a system or service failure; each entry buys
    /// one more attempt.
    var transient: [UInt64]

    static let standard = AttestRetrySchedule(
        recheckRejectedKey: 250_000_000,
        transient: [500_000_000, 1_500_000_000]
    )
}

extension Data {
    /// The server issues challenges base64url-encoded (header-safe).
    init?(base64urlEncoded s: String) {
        var b64 = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64.append("=") }
        self.init(base64Encoded: b64)
    }
}
