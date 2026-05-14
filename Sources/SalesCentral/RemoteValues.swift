import Foundation

/// A decoded JSON value of unknown shape — string / number / bool /
/// array / dictionary / null. Used to expose arbitrary content in
/// `SalesPaywall.data` and `SalesClient.remoteConfig(_:default:)`.
///
/// The SDK doesn't try to be smart about schemas — the caller types
/// each lookup themselves via the `string` / `int` / `double` / `bool`
/// / `array` / `dictionary` accessors below. Missing keys / type
/// mismatches return `nil`, which is the cue to fall back to a default.
public enum SalesAnyValue: Decodable, Sendable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([SalesAnyValue])
    case dictionary([String: SalesAnyValue])
    case null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil()                                  { self = .null;                       return }
        if let v = try? c.decode(Bool.self)               { self = .bool(v);                    return }
        if let v = try? c.decode(Int.self)                { self = .int(v);                     return }
        if let v = try? c.decode(Double.self)             { self = .double(v);                  return }
        if let v = try? c.decode(String.self)             { self = .string(v);                  return }
        if let v = try? c.decode([SalesAnyValue].self)    { self = .array(v);                   return }
        if let v = try? c.decode([String: SalesAnyValue].self) { self = .dictionary(v);         return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
    }

    // MARK: - Typed accessors

    public var stringValue: String? { if case .string(let s) = self { return s } else { return nil } }
    public var intValue: Int? {
        switch self {
        case .int(let n):    return n
        case .double(let n): return Int(n)
        default:             return nil
        }
    }
    public var doubleValue: Double? {
        switch self {
        case .double(let n): return n
        case .int(let n):    return Double(n)
        default:             return nil
        }
    }
    public var boolValue: Bool? { if case .bool(let b) = self { return b } else { return nil } }
    public var arrayValue: [SalesAnyValue]? { if case .array(let a) = self { return a } else { return nil } }
    public var dictionaryValue: [String: SalesAnyValue]? { if case .dictionary(let d) = self { return d } else { return nil } }
    public var isNull: Bool { if case .null = self { return true } else { return false } }

    /// Coerce to the same concrete Swift type as `fallback`. Used by
    /// `SalesClient.remoteConfig(_:default:)`. Supports String, Int,
    /// Double, Bool. Anything else returns the fallback.
    @inlinable
    func coerced<T>(matching fallback: T) -> T {
        if T.self == String.self, let v = stringValue { return v as! T }
        if T.self == Int.self,    let v = intValue    { return v as! T }
        if T.self == Double.self, let v = doubleValue { return v as! T }
        if T.self == Bool.self,   let v = boolValue   { return v as! T }
        return fallback
    }
}

/// A server-defined paywall. Returned by `SalesClient.paywall(key:)`.
public struct SalesPaywall: Decodable, Sendable, Equatable {
    public let key: String
    public let name: String
    public let productIds: [String]
    public let data: [String: SalesAnyValue]

    public init(key: String, name: String, productIds: [String], data: [String: SalesAnyValue] = [:]) {
        self.key = key
        self.name = name
        self.productIds = productIds
        self.data = data
    }
}
