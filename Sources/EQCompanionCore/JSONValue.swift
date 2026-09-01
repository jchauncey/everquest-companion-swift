// JSONValue — the one JSON type the whole client speaks.
//
// The protocol deliberately leaves most payload shapes OPEN (`Cells`, `ModuleState`, `CombatState`,
// `KnowledgeRecord`): the field set belongs to the source, not to the wire. A closed Codable struct
// per shape would drift the day the engine adds a column, so the client holds JSON as JSON and reads
// it by key. Ints and doubles are kept apart: the engine's `serde` refuses `50.0` where an `i64`
// is expected, so a window limit must encode as `50`.
import Foundation

public enum JSONValue: Sendable, Equatable, Hashable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

// MARK: - Accessors

public extension JSONValue {
    subscript(key: String) -> JSONValue {
        if case .object(let o) = self { return o[key] ?? .null }
        return .null
    }

    subscript(index: Int) -> JSONValue {
        if case .array(let a) = self, index >= 0, index < a.count { return a[index] }
        return .null
    }

    var isNull: Bool { if case .null = self { return true }; return false }

    /// This value as a Swift optional: `.null` — which is also what subscripting an absent key
    /// returns — reads as `nil`. THE TRAP THIS EXISTS FOR: `cond ? nil : someValue` does not mean
    /// what it says, because JSONValue is ExpressibleByNilLiteral, so that `nil` resolves to
    /// `.null` and an optional destination wraps it `.some(.null)` — present-but-null, a key the
    /// original object never had. Spell absence with this accessor, never with a nil literal.
    /// Spelled with an explicit `Optional.none`, not a ternary: `isNull ? nil : self` resolves the
    /// `nil` through JSONValue's own nil-literal conformance and yields `.some(.null)` — the exact
    /// wrong answer this accessor exists to prevent, produced by its own first draft.
    var presentValue: JSONValue? {
        if case .null = self { return Optional<JSONValue>.none }
        return self
    }

    var string: String? { if case .string(let s) = self { return s }; return nil }

    var bool: Bool? { if case .bool(let b) = self { return b }; return nil }

    var int: Int? {
        switch self {
        case .int(let i): return Int(exactly: i)
        case .double(let d): return d.isFinite ? Int(exactly: d.rounded()) : nil
        default: return nil
        }
    }

    var int64: Int64? {
        switch self {
        case .int(let i): return i
        case .double(let d): return d.isFinite ? Int64(exactly: d.rounded()) : nil
        default: return nil
        }
    }

    var double: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        default: return nil
        }
    }

    var array: [JSONValue]? { if case .array(let a) = self { return a }; return nil }

    var object: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }

    /// The cell as the pixel says it: a string for text, a plain number for numbers, empty for null.
    var display: String {
        switch self {
        case .null: return ""
        case .bool(let b): return b ? "yes" : "no"
        case .int(let i): return String(i)
        case .double(let d):
            if d == d.rounded(), abs(d) < 1e15 { return String(Int64(d)) }
            return String(format: "%.1f", d)
        case .string(let s): return s
        case .array(let a): return "[\(a.count)]"
        case .object(let o): return "{\(o.count)}"
        }
    }
}

// MARK: - Codable

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int64.self) { self = .int(i); return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "not a JSON value")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

// MARK: - Bytes in, bytes out

public extension JSONValue {
    /// Parse one JSON document. Uses `JSONSerialization` (measurably faster than `JSONDecoder` on
    /// the engine's larger payloads) and converts once.
    static func parse(_ data: Data) throws -> JSONValue {
        let any = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return JSONValue(any: any)
    }

    static func parse(_ text: String) throws -> JSONValue {
        try parse(Data(text.utf8))
    }

    init(any: Any) {
        switch any {
        case is NSNull: self = .null
        case let n as NSNumber:
            // CFBoolean is an NSNumber; tell a real boolean apart from 0/1 by its Objective-C type.
            if CFGetTypeID(n) == CFBooleanGetTypeID() { self = .bool(n.boolValue); return }
            let t = String(cString: n.objCType)
            switch t {
            case "d", "f": self = .double(n.doubleValue)
            default:
                let i = n.int64Value
                if Double(i) == n.doubleValue { self = .int(i) } else { self = .double(n.doubleValue) }
            }
        case let s as String: self = .string(s)
        case let a as [Any]: self = .array(a.map(JSONValue.init(any:)))
        case let o as [String: Any]:
            var out: [String: JSONValue] = [:]
            out.reserveCapacity(o.count)
            for (k, v) in o { out[k] = JSONValue(any: v) }
            self = .object(out)
        default: self = .null
        }
    }

    var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .int(let i): return i
        case .double(let d): return d
        case .string(let s): return s
        case .array(let a): return a.map(\.anyValue)
        case .object(let o): return o.mapValues(\.anyValue)
        }
    }

    /// One line, no trailing newline. Keys are sorted so the bytes are stable for tests and logs.
    func serialized() -> Data {
        (try? JSONSerialization.data(withJSONObject: anyValue, options: [.sortedKeys, .fragmentsAllowed])) ?? Data("null".utf8)
    }

    func serializedString() -> String {
        String(decoding: serialized(), as: UTF8.self)
    }

    func pretty() -> String {
        let d = (try? JSONSerialization.data(withJSONObject: anyValue, options: [.sortedKeys, .prettyPrinted, .fragmentsAllowed])) ?? Data()
        return String(decoding: d, as: UTF8.self)
    }
}

// MARK: - Literals, so descriptors and params read like JSON at the call site

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(Int64(value)) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        var o: [String: JSONValue] = [:]
        for (k, v) in elements { o[k] = v }
        self = .object(o)
    }
    public init(nilLiteral: ()) { self = .null }
}
