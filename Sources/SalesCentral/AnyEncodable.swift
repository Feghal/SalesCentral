import Foundation

/// Type-erased `Encodable` for free-form event properties.
///
/// Lets callers write:
///
///     try await sales.track("level_completed", properties: [
///         "level": .init(12), "score": .init(8420), "won": .init(true)
///     ])
///
/// without a per-call Codable boilerplate.
public struct AnyEncodable: Encodable, Sendable,
    ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByFloatLiteral
{
    private let _encode: @Sendable (Encoder) throws -> Void

    public init<T: Encodable & Sendable>(_ value: T) {
        _encode = { try value.encode(to: $0) }
    }

    public init(stringLiteral value: String)   { self.init(value) }
    public init(integerLiteral value: Int)     { self.init(value) }
    public init(booleanLiteral value: Bool)    { self.init(value) }
    public init(floatLiteral value: Double)    { self.init(value) }

    public func encode(to encoder: Encoder) throws { try _encode(encoder) }
}
