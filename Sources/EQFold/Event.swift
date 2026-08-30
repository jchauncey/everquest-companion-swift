// `Event` — one canonical log event, as the fold reads it (fold/src/event.rs).
//
// A primary event borrows the parser's typed payload (valid for exactly one delivery — a module that
// keeps one copies what it needs); a derived event (`epoch`, `offlineGap`, `buffExpired`, the
// early-warning probes) is a JSON body. Absent is not null and neither is zero: `str`/`int` answer
// nil for a key the writer omitted AND for one written as null; `has` tells them apart.
import Foundation
import EQLog
import EQCompanionCore

public typealias Kind = EQLog.Kind
public typealias Key = EQLog.Key

public struct Event {
    enum Body {
        case typed(Payload)
        case json(JSONValue)
    }

    public let kindOf: Kind
    let body: Body

    /// A primary event, straight off the parser. Borrowed: valid for exactly this delivery.
    public static func typed(_ p: Payload) -> Event { Event(kindOf: p.kind, body: .typed(p)) }

    /// A derived event the fold built itself, or a golden NDJSON line.
    public static func fromValue(_ v: JSONValue) -> Event {
        Event(kindOf: Kind.parse(v["kind"].string ?? ""), body: .json(v))
    }

    public static func fromJSON(_ line: String) -> Event? {
        guard let v = try? JSONValue.parse(line), v.object != nil else { return nil }
        return fromValue(v)
    }

    /// The kind as text — a JSON body whose kind this build does not know keeps its own text.
    public var kind: String {
        if case .json(let v) = body, kindOf == .other { return v["kind"].string ?? "" }
        return kindOf.rawValue
    }

    public var seq: Int64 {
        switch body {
        case .typed(let p): return p.seq
        case .json(let v): return v["seq"].int64 ?? 0
        }
    }

    public var ts: Int64 {
        switch body {
        case .typed(let p): return p.ts
        case .json(let v): return v["ts"].int64 ?? 0
        }
    }

    public var raw: String {
        switch body {
        case .typed(let p): return p.raw
        case .json(let v): return v["raw"].string ?? ""
        }
    }

    public func str(_ k: Key) -> String? {
        switch body {
        case .typed(let p):
            switch k {
            case .raw: return p.raw
            case .kind: return p.kind.rawValue
            default: return p.str(k)
            }
        case .json(let v): return v[k.rawValue].string
        }
    }

    public func str(_ name: String) -> String? { Key.parse(name).flatMap { str($0) } }

    public func int(_ k: Key) -> Int64? {
        switch body {
        case .typed(let p):
            switch k {
            case .seq: return p.seq
            case .ts: return p.ts
            default: return p.int(k)
            }
        case .json(let v): return v[k.rawValue].int64
        }
    }

    public func int(_ name: String) -> Int64? { Key.parse(name).flatMap { int($0) } }

    public func double(_ k: Key) -> Double? {
        switch body {
        case .typed(let p): return p.double(k)
        case .json(let v): return v[k.rawValue].double
        }
    }

    public func double(_ name: String) -> Double? { Key.parse(name).flatMap { double($0) } }

    public func bool(_ k: Key) -> Bool {
        switch body {
        case .typed(let p): return p.bool(k) ?? false
        case .json(let v): return v[k.rawValue].bool ?? false
        }
    }

    public func bool(_ name: String) -> Bool { Key.parse(name).map { bool($0) } ?? false }

    public func arrStr(_ k: Key) -> [String] {
        switch body {
        case .typed(let p): return p.strs(k) ?? []
        case .json(let v): return (v[k.rawValue].array ?? []).compactMap(\.string)
        }
    }

    public func arrStr(_ name: String) -> [String] { Key.parse(name).map { arrStr($0) } ?? [] }

    public func arrLen(_ k: Key) -> Int {
        switch body {
        case .typed(let p):
            switch p.slot(k) {
            case .strs(_, let len)?, .cands(_, let len)?: return len
            default: return 0
            }
        case .json(let v): return v[k.rawValue].array?.count ?? 0
        }
    }

    /// `candidates` names from the OBJECT shape only.
    public func candidateNames(_ k: Key) -> [String] {
        switch body {
        case .typed(let p): return (p.cands(k) ?? []).map(\.name)
        case .json(let v): return (v[k.rawValue].array ?? []).compactMap { $0["name"].string }
        }
    }

    /// `candidates` names from either shape (objects or bare strings).
    public func anyCandidateNames(_ k: Key) -> [String] {
        switch body {
        case .typed(let p):
            if let c = p.cands(k) { return c.map(\.name) }
            return p.strs(k) ?? []
        case .json(let v):
            return (v[k.rawValue].array ?? []).compactMap { c in c.string ?? c["name"].string }
        }
    }

    public func candidates(_ k: Key) -> [(name: String, durationMs: Int64?, illusion: Bool)] {
        switch body {
        case .typed(let p): return p.cands(k) ?? []
        case .json(let v):
            return (v[k.rawValue].array ?? []).map { ($0["name"].string ?? "", $0["durationMs"].int64, $0["illusion"].bool ?? false) }
        }
    }

    /// Present and not null.
    public func has(_ k: Key) -> Bool {
        switch body {
        case .typed(let p):
            switch k {
            case .kind, .seq, .ts, .raw: return true
            default:
                switch p.slot(k) {
                case nil, .null?: return false
                default: return true
                }
            }
        case .json(let v):
            let x = v[k.rawValue]
            return !x.isNull
        }
    }

    public func has(_ name: String) -> Bool { Key.parse(name).map { has($0) } ?? false }

    /// The field as JS `String(value)` — what an alert matcher tests against.
    public func fieldText(_ k: Key) -> String? {
        switch body {
        case .typed(let p):
            switch k {
            case .kind: return p.kind.rawValue
            case .raw: return p.raw
            case .seq: return JS.numberText(Double(p.seq))
            case .ts: return JS.numberText(Double(p.ts))
            default:
                switch p.slot(k) {
                case nil, .null?: return nil
                case .str?: return p.str(k)
                case .int(let v)?: return JS.numberText(Double(v))
                case .float(let v)?: return JS.numberText(v)
                case .bool(let v)?: return v ? "true" : "false"
                case .strs?: return (p.strs(k) ?? []).joined(separator: ",")
                case .cands?: return (p.cands(k) ?? []).map { _ in "[object Object]" }.joined(separator: ",")
                case .coins?: return "[object Object]"
                }
            }
        case .json(let v):
            let x = v[k.rawValue]
            return x.isNull ? nil : Event.jsonFieldText(x)
        }
    }

    public func fieldText(_ name: String) -> String? { Key.parse(name).flatMap { fieldText($0) } }

    static func jsonFieldText(_ v: JSONValue) -> String {
        switch v {
        case .string(let s): return s
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return JS.numberText(Double(i))
        case .double(let d): return JS.numberText(d)
        case .null: return ""
        case .array(let a): return a.map(jsonFieldText).joined(separator: ",")
        case .object: return "[object Object]"
        }
    }

    /// The JSON body of a derived event, or nil for a typed one.
    public var jsonBody: JSONValue? {
        if case .json(let v) = body { return v }
        return nil
    }

    /// A derived event's JSON, or the typed event re-serialized — for a module that keeps events.
    public func toJSON() -> JSONValue {
        switch body {
        case .json(let v): return v
        case .typed(let p):
            var o: [String: JSONValue] = ["kind": .string(p.kind.rawValue), "seq": .int(p.seq), "ts": .int(p.ts), "raw": .string(p.raw)]
            for (k, s) in p.fields {
                switch s {
                case .str: o[k.rawValue] = .string(p.str(k) ?? "")
                case .int(let v): o[k.rawValue] = .int(v)
                case .float(let v): o[k.rawValue] = .double(v)
                case .bool(let v): o[k.rawValue] = .bool(v)
                case .null: o[k.rawValue] = .null
                case .strs: o[k.rawValue] = .array((p.strs(k) ?? []).map { .string($0) })
                case .cands:
                    o[k.rawValue] = .array((p.cands(k) ?? []).map { c in
                        var d: [String: JSONValue] = ["name": .string(c.name), "durationMs": c.durationMs.map { .int($0) } ?? .null]
                        if c.illusion { d["illusion"] = .bool(true) }
                        return .object(d)
                    })
                case .coins:
                    var d: [String: JSONValue] = [:]
                    for (den, amt) in p.coins(k) ?? [] { d[den] = .int(amt) }
                    o[k.rawValue] = .object(d)
                }
            }
            return .object(o)
        }
    }
}
