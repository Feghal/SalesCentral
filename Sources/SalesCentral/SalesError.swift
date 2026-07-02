import Foundation

/// Errors surfaced by `SalesClient`.
///
/// The `http` case carries the server's machine-readable `error` code so
/// callers can branch on specific failure modes (e.g. `insufficient_credits`
/// for a paywall). The human-readable `message` is best-effort.
public enum SalesError: Error, CustomStringConvertible, Sendable {
    /// The request reached the server but returned a non-2xx response.
    case http(status: Int, code: String, message: String?)

    /// The response couldn't be decoded into the expected shape.
    case decoding(String)

    /// The transport itself failed (DNS, TLS, offline, etc.).
    case network(String)

    /// A precondition wasn't met locally (e.g. no token, invalid input).
    case invalidState(String)

    /// App Attest is unavailable on this device (e.g. the iOS Simulator).
    /// `SalesClient` no longer throws this from its request path — such
    /// platforms run as SANDBOX identities instead. Retained for API
    /// stability and for direct misuse of the attest plumbing.
    case attestUnsupported

    public var description: String {
        switch self {
        case .http(let s, let c, let m):
            return "HTTP \(s) \(c)" + (m.map { ": \($0)" } ?? "")
        case .decoding(let m):
            return "Decoding error: \(m)"
        case .network(let m):
            return "Network error: \(m)"
        case .invalidState(let m):
            return "Invalid state: \(m)"
        case .attestUnsupported:
            return "App Attest unsupported on this device"
        }
    }

    /// The server's `error` code if this is an HTTP error, otherwise nil.
    /// Handy for `switch err.code { … }` paywall / restore flows.
    public var code: String? {
        if case .http(_, let c, _) = self { return c }
        return nil
    }

    /// True for HTTP 4xx, false otherwise.
    public var isClientError: Bool {
        if case .http(let s, _, _) = self { return (400..<500).contains(s) }
        return false
    }
}
