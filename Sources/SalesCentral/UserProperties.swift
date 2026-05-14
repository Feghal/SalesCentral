import Foundation

/// A single user property value.
///
/// Properties are caller-defined attributes (name, email, plan_intent, …)
/// the SDK attaches to the current user via `SalesClient.setUserProperty`
/// or `setUserProperties`. The admin renders + searches across these in
/// the Users list.
///
/// The value space is intentionally narrow — string / number / bool — so
/// the admin can display them in a table and the backend's wildcard text
/// index stays cheap. Pass `nil` (Swift `nil`, not a `SalesPropertyValue`
/// case) to delete a key from the user's bag.
public enum SalesPropertyValue: Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
}

extension SalesPropertyValue: ExpressibleByStringLiteral,
                              ExpressibleByIntegerLiteral,
                              ExpressibleByFloatLiteral,
                              ExpressibleByBooleanLiteral {
    public init(stringLiteral value: String)  { self = .string(value) }
    public init(integerLiteral value: Int)    { self = .number(Double(value)) }
    public init(floatLiteral value: Double)   { self = .number(value) }
    public init(booleanLiteral value: Bool)   { self = .bool(value) }
}

/// On-the-wire envelope for a property delta. Carries the additional
/// `null` case for "delete this key" so the JSON encoder emits a real
/// JSON null instead of omitting the field (which the server would read
/// as "leave this key alone").
///
/// `internal` because callers should never construct these directly —
/// `SalesClient.setUserProperty(_:_:)` translates the public optional
/// API into this wire shape.
internal enum PropertyDelta: Encodable {
    case value(SalesPropertyValue)
    case delete

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .value(.string(let s)): try c.encode(s)
        case .value(.number(let n)):
            // Round-trip integer-valued doubles as integers so the
            // backend stores 42 rather than 42.0 (cosmetic, but the
            // admin displays raw numbers and the difference is visible).
            if n.truncatingRemainder(dividingBy: 1) == 0,
               n >= Double(Int.min), n <= Double(Int.max) {
                try c.encode(Int(n))
            } else {
                try c.encode(n)
            }
        case .value(.bool(let b)): try c.encode(b)
        case .delete: try c.encodeNil()
        }
    }
}

/// Body wrapper for property-only updates posted via the
/// `createOrFetchUser` route. Matches the server-side ingest shape
/// (`utils/userIngest.js:pickProperties`).
internal struct PropertiesUpdateBody: Encodable {
    let properties: [String: PropertyDelta]
}
