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

extension Data {
    /// The server issues challenges base64url-encoded (header-safe).
    init?(base64urlEncoded s: String) {
        var b64 = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64.append("=") }
        self.init(base64Encoded: b64)
    }
}
