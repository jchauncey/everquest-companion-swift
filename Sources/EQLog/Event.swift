// The event writer and its typed payload (eqlog/src/event.rs).
//
// The JSON is built key by key in the order the classifier writes it — the bar is byte identity
// with `JSON.stringify` over the TypeScript parser's object literals, which writes insertion order.
// The same writes are recorded as `(Key, Slot)` pairs so the fold reads fields without re-parsing.
// Absent is not null: `sOpt`/`iOpt` write nothing, `sOrNull`/`iOrNull` write `null`.
import Foundation

/// Every event kind. The raw value is the exact `kind` text. The last three are the fold's own.
public enum Kind: String, CaseIterable, Sendable {
    case aaActivate = "aaActivate"
    case aaGain = "aaGain"
    case aaPotion = "aaPotion"
    case aaSpend = "aaSpend"
    case allyPetLeader = "allyPetLeader"
    case buffApply = "buffApply"
    case buffFade = "buffFade"
    case buffWearOff = "buffWearOff"
    case campAbort = "campAbort"
    case campStart = "campStart"
    case castBegin = "castBegin"
    case castFizzle = "castFizzle"
    case castInterrupted = "castInterrupted"
    case castResumed = "castResumed"
    case cc = "cc"
    case ccWake = "ccWake"
    case charm = "charm"
    case classUnlock = "classUnlock"
    case coin = "coin"
    case consider = "consider"
    case damage = "damage"
    case death = "death"
    case expGain = "expGain"
    case group = "group"
    case heal = "heal"
    case healUnstated = "healUnstated"
    case illusionFade = "illusionFade"
    case instanceCreate = "instanceCreate"
    case invocationChange = "invocationChange"
    case itemActivate = "itemActivate"
    case itemMerge = "itemMerge"
    case itemMergeFailed = "itemMergeFailed"
    case itemReceived = "itemReceived"
    case level = "level"
    case loot = "loot"
    case miss = "miss"
    case mitigation = "mitigation"
    case offer = "offer"
    case otherCastBegin = "otherCastBegin"
    case outputFile = "outputFile"
    case petClaim = "petClaim"
    case petSay = "petSay"
    case playerDeath = "playerDeath"
    case poisonCoat = "poisonCoat"
    case poisonDry = "poisonDry"
    case poisonProc = "poisonProc"
    case purchase = "purchase"
    case resist = "resist"
    case selfWho = "selfWho"
    case sessionStart = "sessionStart"
    case skillUp = "skillUp"
    case specialAttack = "specialAttack"
    case spellEmote = "spellEmote"
    case spellForget = "spellForget"
    case spellMemorize = "spellMemorize"
    case spellSet = "spellSet"
    case stanceChange = "stanceChange"
    case trade = "trade"
    case uncharm = "uncharm"
    case unknown = "unknown"
    case zone = "zone"
    case epoch = "epoch"
    case offlineGap = "offlineGap"
    case buffExpired = "buffExpired"
    /// A `kind` string this build does not know — never produced by a parse.
    case other = ""

    public static func parse(_ s: String) -> Kind { Kind(rawValue: s) ?? .other }
}

/// Every field name any event can carry. Closed in both directions.
public enum Key: String, CaseIterable, Sendable {
    case ability = "ability"
    case action = "action"
    case amount = "amount"
    case attacker = "attacker"
    case autoAttack = "autoAttack"
    case by = "by"
    case bySelf = "bySelf"
    case camped = "camped"
    case candidates = "candidates"
    case caster = "caster"
    case category = "category"
    case change = "change"
    case classes = "classes"
    case className = "className"
    case coins = "coins"
    case component = "component"
    case cost = "cost"
    case count = "count"
    case created = "created"
    case crit = "crit"
    case dclass = "dclass"
    case difficulty = "difficulty"
    case disposition = "disposition"
    case done = "done"
    case dtype = "dtype"
    case durationMs = "durationMs"
    case effect = "effect"
    case faction = "faction"
    case file = "file"
    case fromTs = "fromTs"
    case group = "group"
    case healer = "healer"
    case illusion = "illusion"
    case incoming = "incoming"
    case instance = "instance"
    case invocation = "invocation"
    case item = "item"
    case killer = "killer"
    case kind = "kind"
    case level = "level"
    case mob = "mob"
    case modifier = "modifier"
    case modifiers = "modifiers"
    case mtype = "mtype"
    case name = "name"
    case nowHave = "nowHave"
    case npc = "npc"
    case overTime = "overTime"
    case owner = "owner"
    case party = "party"
    case pct = "pct"
    case pet = "pet"
    case player = "player"
    case poison = "poison"
    case price = "price"
    case race = "race"
    case rank = "rank"
    case rare = "rare"
    case raw = "raw"
    case rawAmount = "rawAmount"
    case reason = "reason"
    case refresh = "refresh"
    case replaces = "replaces"
    case say = "say"
    case seq = "seq"
    case set = "set"
    case skill = "skill"
    case source = "source"
    case spell = "spell"
    case stance = "stance"
    case strike = "strike"
    case subject = "subject"
    case sung = "sung"
    case target = "target"
    case text = "text"
    case tier = "tier"
    case toTs = "toTs"
    case ts = "ts"
    case value = "value"
    case verb = "verb"
    case via = "via"
    case who = "who"
    case zone = "zone"

    public static func parse(_ s: String) -> Key? { Key(rawValue: s) }
}

/// One field's value: strings and lists are indices into the payload's text and list tables.
public enum Slot: Equatable, Sendable {
    case str(at: Int, len: Int)
    case int(Int64)
    case float(Double)
    case bool(Bool)
    case null
    case strs(at: Int, len: Int)
    case cands(at: Int, len: Int)
    case coins(at: Int, len: Int)
}

public struct CandSlot: Sendable {
    public var name: (Int, Int)
    public var durationMs: Int64?
    public var illusion: Bool
}

/// One event, typed. Reused across events; `begin` clears it.
public final class Payload {
    public private(set) var kind: Kind = .unknown
    public private(set) var seq: Int64 = 0
    public private(set) var ts: Int64 = 0
    private var rawRange: (Int, Int) = (0, 0)
    public private(set) var envelopeAfter: Int = 0
    // Every text the writer handed over, kept as the String it was. A text range is (index, 0) into
    // it: the fold reads a damage line's names a dozen times or more, and a read is then one retain
    // rather than a String rebuilt scalar by scalar.
    fileprivate var texts: [String] = []
    public private(set) var fields: [(Key, Slot)] = []
    fileprivate var strs: [(Int, Int)] = []
    fileprivate var cands: [CandSlot] = []
    fileprivate var coinsTable: [(String, Int64)] = []

    public init() {
        texts.reserveCapacity(16)
        fields.reserveCapacity(16)
    }

    public var raw: String { text(rawRange) }

    public func text(_ r: (Int, Int)) -> String { texts[r.0] }

    public func slot(_ key: Key) -> Slot? {
        for (k, s) in fields where k == key { return s }
        return nil
    }

    public func str(_ key: Key) -> String? {
        if case .str(let at, let len)? = slot(key) { return text((at, len)) }
        return nil
    }

    public func int(_ key: Key) -> Int64? {
        switch slot(key) {
        case .int(let v)?: return v
        case .float(let v)? where v == v.rounded(.towardZero): return Int64(v)
        default: return nil
        }
    }

    public func double(_ key: Key) -> Double? {
        switch slot(key) {
        case .float(let v)?: return v
        case .int(let v)?: return Double(v)
        default: return nil
        }
    }

    public func bool(_ key: Key) -> Bool? {
        if case .bool(let v)? = slot(key) { return v }
        return nil
    }

    public func strs(_ key: Key) -> [String]? {
        guard case .strs(let at, let len)? = slot(key) else { return nil }
        return strs[at..<at + len].map { text($0) }
    }

    public func cands(_ key: Key) -> [(name: String, durationMs: Int64?, illusion: Bool)]? {
        guard case .cands(let at, let len)? = slot(key) else { return nil }
        return cands[at..<at + len].map { (text($0.name), $0.durationMs, $0.illusion) }
    }

    public func coins(_ key: Key) -> [(String, Int64)]? {
        guard case .coins(let at, let len)? = slot(key) else { return nil }
        return Array(coinsTable[at..<at + len])
    }

    fileprivate func begin(_ kind: Kind) {
        self.kind = kind
        seq = 0; ts = 0; rawRange = (0, 0); envelopeAfter = 0
        texts.removeAll(keepingCapacity: true)
        fields.removeAll(keepingCapacity: true)
        strs.removeAll(keepingCapacity: true)
        cands.removeAll(keepingCapacity: true)
        coinsTable.removeAll(keepingCapacity: true)
    }

    fileprivate func pushText(_ v: String) -> (Int, Int) {
        texts.append(v)
        return (texts.count - 1, 0)
    }

    fileprivate func setEnvelope(seq: Int64, ts: Int64, raw: String) {
        envelopeAfter = fields.count
        self.seq = seq
        self.ts = ts
        rawRange = pushText(raw)
    }

    fileprivate func note(_ k: Key, _ s: Slot) {
        assert(!fields.contains { $0.0 == k }, "\(k.rawValue) written twice on a \(kind.rawValue) event")
        fields.append((k, s))
    }

    fileprivate func pushStrs(_ v: [String]) -> (Int, Int) {
        let at = strs.count
        for s in v { strs.append(pushText(s)) }
        return (at, v.count)
    }

    fileprivate func pushCand(_ c: CandSlot) { cands.append(c) }
    fileprivate var candsCount: Int { cands.count }
    fileprivate func pushCoins(_ v: [(String, Int64)]) -> (Int, Int) {
        let at = coinsTable.count
        coinsTable.append(contentsOf: v)
        return (at, v.count)
    }
}

/// The writer: JSON text and the payload, built in one pass.
///
/// `json: false` builds the payload alone. The fold reads only the payload, and serializing every
/// field of every event it will never look at was a fifth of a parse; the parser oracle, the
/// counting sinks and `eqtool events` keep the default and get the byte-identical line.
public final class Ev {
    private var buf = ""
    private var first = true
    private var closed = false
    public let payload = Payload()
    public let writesJSON: Bool

    public init(json: Bool = true) {
        writesJSON = json
        if json { buf.reserveCapacity(1024) }
    }

    public func begin(_ kind: Kind) {
        payload.begin(kind)
        guard writesJSON else { return }
        buf.removeAll(keepingCapacity: true)
        buf.append("{")
        first = true
        closed = false
        jsonKey(.kind)
        JS.writeJSONString(&buf, kind.rawValue)
    }

    public func envelope(_ seq: Int64, _ ts: Int64, _ raw: String) {
        payload.setEnvelope(seq: seq, ts: ts, raw: raw)
        guard writesJSON else { return }
        jsonKey(.seq); buf.append(String(seq))
        jsonKey(.ts); buf.append(String(ts))
        jsonKey(.raw); JS.writeJSONString(&buf, raw)
    }

    /// Convenience: `envelope(c.seq, c.ts, c.raw)`.
    public func envelope(_ c: Ctx) { envelope(c.seq, c.ts, c.raw) }

    /// The finished JSON line (no trailing newline). Closes the object in place — no copy per
    /// event — and is idempotent. Empty for a writer built with `json: false`.
    public func finish() -> String {
        guard writesJSON else { return "" }
        if !closed { buf.append("}"); closed = true }
        return buf
    }

    private func jsonKey(_ k: Key) {
        if !first { buf.append(",") }
        first = false
        buf.append("\"")
        buf.append(k.rawValue)
        buf.append("\":")
    }

    public func s(_ k: Key, _ v: String) {
        if writesJSON {
            jsonKey(k)
            JS.writeJSONString(&buf, v)
        }
        let r = payload.pushText(v)
        payload.note(k, .str(at: r.0, len: r.1))
    }

    public func s(_ k: Key, _ v: Substring) { s(k, String(v)) }

    public func sOpt(_ k: Key, _ v: String?) { if let v { s(k, v) } }
    public func sOpt(_ k: Key, _ v: Substring?) { if let v { s(k, String(v)) } }

    public func i(_ k: Key, _ v: Int64) {
        if writesJSON {
            jsonKey(k)
            buf.append(String(v))
        }
        payload.note(k, .int(v))
    }

    public func i(_ k: Key, _ v: Int) { i(k, Int64(v)) }

    public func iOpt(_ k: Key, _ v: Int64?) { if let v { i(k, v) } }

    public func iOrNull(_ k: Key, _ v: Int64?) {
        if let v { i(k, v) } else { null(k) }
    }

    public func sOrNull(_ k: Key, _ v: String?) {
        if let v { s(k, v) } else { null(k) }
    }

    private func null(_ k: Key) {
        if writesJSON { jsonKey(k); buf.append("null") }
        payload.note(k, .null)
    }

    public func b(_ k: Key, _ v: Bool) {
        if writesJSON {
            jsonKey(k)
            buf.append(v ? "true" : "false")
        }
        payload.note(k, .bool(v))
    }

    public func f(_ k: Key, _ v: Double) {
        if writesJSON {
            jsonKey(k)
            JS.writeNumber(&buf, v)
        }
        payload.note(k, .float(v))
    }

    public func strs(_ k: Key, _ v: [String]) {
        if writesJSON {
            jsonKey(k)
            buf.append("[")
            for (i, s) in v.enumerated() {
                if i > 0 { buf.append(",") }
                JS.writeJSONString(&buf, s)
            }
            buf.append("]")
        }
        let r = payload.pushStrs(v)
        payload.note(k, .strs(at: r.0, len: r.1))
    }

    /// `candidates` as `{name, durationMs}` objects.
    public func candsND(_ k: Key, _ v: [(String, Int64?)]) {
        if writesJSON {
            jsonKey(k)
            buf.append("[")
            for (i, (name, dur)) in v.enumerated() {
                if i > 0 { buf.append(",") }
                buf.append("{\"name\":")
                JS.writeJSONString(&buf, name)
                buf.append(",\"durationMs\":")
                buf.append(dur.map { String($0) } ?? "null")
                buf.append("}")
            }
            buf.append("]")
        }
        let at = payload.candsCount
        for (name, dur) in v {
            let r = payload.pushText(name)
            payload.pushCand(CandSlot(name: r, durationMs: dur, illusion: false))
        }
        payload.note(k, .cands(at: at, len: v.count))
    }

    /// `candidates` as `{name, durationMs, illusion}` objects.
    public func candsNDI(_ k: Key, _ v: [(String, Int64?, Bool)]) {
        if writesJSON {
            jsonKey(k)
            buf.append("[")
            for (i, (name, dur, ill)) in v.enumerated() {
                if i > 0 { buf.append(",") }
                buf.append("{\"name\":")
                JS.writeJSONString(&buf, name)
                buf.append(",\"durationMs\":")
                buf.append(dur.map { String($0) } ?? "null")
                buf.append(",\"illusion\":")
                buf.append(ill ? "true" : "false")
                buf.append("}")
            }
            buf.append("]")
        }
        let at = payload.candsCount
        for (name, dur, ill) in v {
            let r = payload.pushText(name)
            payload.pushCand(CandSlot(name: r, durationMs: dur, illusion: ill))
        }
        payload.note(k, .cands(at: at, len: v.count))
    }

    /// A coin object, denominations in clause order.
    public func coins(_ k: Key, _ v: [(String, Int64)]) {
        if writesJSON {
            jsonKey(k)
            buf.append("{")
            for (i, (denom, amount)) in v.enumerated() {
                if i > 0 { buf.append(",") }
                JS.writeJSONString(&buf, denom)
                buf.append(":")
                buf.append(String(amount))
            }
            buf.append("}")
        }
        let r = payload.pushCoins(v)
        payload.note(k, .coins(at: r.0, len: r.1))
    }
}
