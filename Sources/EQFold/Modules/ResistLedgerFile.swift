// `<userData>/resist-ledger.json` — the app's own file, read and written verbatim
// (fold/src/modules/resist/ledger_file.rs). The pure half: this file knows the shape and the rules
// and touches no disk.
//
// The format is inherited, not negotiated: `{"version":3,"sources":[{"key":…,"rows":[…]}]}`. Both
// implementations must be able to hold the same file. Two consequences:
//
//   * `version` is written first. The app's truncation salvage reads the version off the head of a
//     file with no parseable JSON left, so a serializer that put `sources` first would disable it.
//   * Rows carry the app's `camelCase` spelling, with the same three fields written as `null` rather
//     than omitted and the same six omitted rather than `null`.
//
// Key order within a row is not claimed by the app either; this file writes one fixed order so that
// an unchanged ledger fingerprints to the same bytes twice.
//
// Named residual: the app's three read tiers past "it parsed" — whole-object salvage, truncation
// salvage, and a quarantine that renames the unreadable bytes — are not ported. A file that will not
// parse reads as empty and the bytes are left where they are.
import Foundation
import EQLog
import EQCompanionCore

/// A file of any other version reads as empty: discarded, not migrated, because the honest upgrade is
/// the re-fold the app performs from the log on every launch anyway.
public let RESIST_LEDGER_VERSION: Int64 = 3

/// The bucket the shipped baseline is filed under. Rejected on read and dropped on write both.
public let BASELINE_SOURCE_KEY = "baseline"

/// One pooled cell, in the app's spelling. The absent-versus-null rule is the module header's, field
/// by field.
public struct ResistRowFile {
    public var mobKey: String
    /// Omitted when absent.
    public var zone: String?
    public var spellKey: String
    public var family: ResistFamily
    public var casterKind: ResistCasterKind
    /// `number | null` — written as `null`, never omitted.
    public var casterLevel: Int64?
    /// `number | null` — written as `null`, never omitted.
    public var mobLevel: Int64?
    public var mobLevelLo: Int64?
    public var mobLevelHi: Int64?
    public var debuffs: String
    public var rank: Int64
    /// `boolean | null` — written as `null`, never omitted. `null` is "not known" and is never assumed
    /// to be `false`; the row key spells the three states apart.
    public var overchannel: Bool?
    public var casterClasses: Int64?
    public var week: String?
    public var resist: Int64
    public var land: Int64
    public var dmg: [String: Int64]
    /// Present only when the row gave up on the histogram; `false` is not a shape either
    /// implementation writes.
    public var variable: Bool?
    public var firstTs: Int64
    public var lastTs: Int64

    /// One in-memory row, as it goes on disk.
    public static func of(_ row: ResistRow) -> ResistRowFile {
        let spec = row.spec
        return ResistRowFile(
            mobKey: spec.mobKey,
            zone: spec.zone,
            spellKey: spec.spellKey,
            family: spec.family,
            casterKind: spec.casterKind,
            casterLevel: spec.casterLevel,
            mobLevel: spec.mobLevel,
            mobLevelLo: spec.mobLevelLo,
            mobLevelHi: spec.mobLevelHi,
            debuffs: spec.debuffs,
            rank: spec.rank,
            overchannel: spec.overchannel,
            casterClasses: spec.casterClasses,
            week: spec.week,
            resist: row.resist,
            land: row.land,
            dmg: row.dmg,
            variable: row.variable ? true : nil,
            firstTs: row.firstTs,
            lastTs: row.lastTs)
    }

    /// …and back. Total, with no failure case: every field is either required by the reader or
    /// optional in the app's own type, so a row that parsed is a row that folds.
    public func intoRow() -> ResistRow {
        ResistRow(
            spec: ResistRowSpec(mobKey: mobKey, zone: zone, spellKey: spellKey, family: family,
                                casterKind: casterKind, casterLevel: casterLevel, mobLevel: mobLevel,
                                mobLevelLo: mobLevelLo, mobLevelHi: mobLevelHi, debuffs: debuffs,
                                rank: rank, overchannel: overchannel, casterClasses: casterClasses,
                                week: week),
            resist: resist, land: land, dmg: dmg, variable: variable == true,
            firstTs: firstTs, lastTs: lastTs)
    }

    /// The deserializer, spelled out: a required field of the wrong type or absent is a refusal, which
    /// is what drops a whole bucket on read.
    public static func from(_ v: JSONValue) -> ResistRowFile? {
        guard case .object = v else { return nil }
        guard let mobKey = v["mobKey"].string,
              let spellKey = v["spellKey"].string,
              let familyText = v["family"].string, let family = ResistFamily(rawValue: familyText),
              let kindText = v["casterKind"].string, let kind = ResistCasterKind(rawValue: kindText),
              let debuffs = v["debuffs"].string,
              let rank = intField(v["rank"]),
              let resist = intField(v["resist"]),
              let land = intField(v["land"]),
              let firstTs = intField(v["firstTs"]),
              let lastTs = intField(v["lastTs"])
        else { return nil }
        guard let zone = optString(v["zone"]),
              let casterLevel = optInt(v["casterLevel"]),
              let mobLevel = optInt(v["mobLevel"]),
              let mobLevelLo = optInt(v["mobLevelLo"]),
              let mobLevelHi = optInt(v["mobLevelHi"]),
              let overchannel = optBool(v["overchannel"]),
              let casterClasses = optInt(v["casterClasses"]),
              let week = optString(v["week"]),
              let variable = optBool(v["variable"])
        else { return nil }
        guard let dmg = histogram(v["dmg"]) else { return nil }
        return ResistRowFile(
            mobKey: mobKey, zone: zone, spellKey: spellKey, family: family, casterKind: kind,
            casterLevel: casterLevel, mobLevel: mobLevel, mobLevelLo: mobLevelLo,
            mobLevelHi: mobLevelHi, debuffs: debuffs, rank: rank, overchannel: overchannel,
            casterClasses: casterClasses, week: week, resist: resist, land: land, dmg: dmg,
            variable: variable, firstTs: firstTs, lastTs: lastTs)
    }

    /// An integer field. A JSON number that is not integral is not an `i64`.
    private static func intField(_ v: JSONValue) -> Int64? {
        if case .int(let i) = v { return i }
        if case .double(let d) = v, d == d.rounded(), let i = Int64(exactly: d) { return i }
        return nil
    }

    /// The optional readers answer a double optional: outer nil is "wrong type, refuse the row",
    /// inner nil is "absent or explicitly null".
    private static func optInt(_ v: JSONValue) -> Int64?? {
        if v.isNull { return .some(nil) }
        return intField(v).map { Optional($0) }
    }

    private static func optString(_ v: JSONValue) -> String?? {
        if v.isNull { return .some(nil) }
        return v.string.map { Optional($0) }
    }

    private static func optBool(_ v: JSONValue) -> Bool?? {
        if v.isNull { return .some(nil) }
        return v.bool.map { Optional($0) }
    }

    private static func histogram(_ v: JSONValue) -> [String: Int64]? {
        guard let o = v.object else { return nil }
        var out: [String: Int64] = [:]
        for (k, n) in o {
            guard let i = intField(n) else { return nil }
            out[k] = i
        }
        return out
    }

    /// The fixed field order, as the app writes it.
    func write(_ out: inout String) {
        out.append("{")
        var first = true
        func sep() { if first { first = false } else { out.append(",") } }
        func key(_ k: String) { sep(); JS.writeJSONString(&out, k); out.append(":") }
        func str(_ k: String, _ s: String) { key(k); JS.writeJSONString(&out, s) }
        func num(_ k: String, _ n: Int64) { key(k); out.append(String(n)) }

        str("mobKey", mobKey)
        if let zone { str("zone", zone) }
        str("spellKey", spellKey)
        str("family", family.rawValue)
        str("casterKind", casterKind.rawValue)
        key("casterLevel"); out.append(casterLevel.map(String.init) ?? "null")
        key("mobLevel"); out.append(mobLevel.map(String.init) ?? "null")
        if let mobLevelLo { num("mobLevelLo", mobLevelLo) }
        if let mobLevelHi { num("mobLevelHi", mobLevelHi) }
        str("debuffs", debuffs)
        num("rank", rank)
        key("overchannel"); out.append(overchannel.map { $0 ? "true" : "false" } ?? "null")
        if let casterClasses { num("casterClasses", casterClasses) }
        if let week { str("week", week) }
        num("resist", resist)
        num("land", land)
        key("dmg"); ResistHistogram.write(&out, dmg)
        if let variable { key("variable"); out.append(variable ? "true" : "false") }
        num("firstTs", firstTs)
        num("lastTs", lastTs)
        out.append("}")
    }

    /// The same row as `JSONValue` — key order is lost, which is exactly what a deep-equality reader
    /// wants and what the byte-stable `write` above is for.
    public var json: JSONValue {
        var o: [String: JSONValue] = [
            "mobKey": .string(mobKey),
            "spellKey": .string(spellKey),
            "family": .string(family.rawValue),
            "casterKind": .string(casterKind.rawValue),
            "casterLevel": casterLevel.map { JSONValue.int($0) } ?? .null,
            "mobLevel": mobLevel.map { JSONValue.int($0) } ?? .null,
            "debuffs": .string(debuffs),
            "rank": .int(rank),
            "overchannel": overchannel.map { JSONValue.bool($0) } ?? .null,
            "resist": .int(resist),
            "land": .int(land),
            "dmg": .object(dmg.mapValues { JSONValue.int($0) }),
            "firstTs": .int(firstTs),
            "lastTs": .int(lastTs)
        ]
        if let zone { o["zone"] = .string(zone) }
        if let mobLevelLo { o["mobLevelLo"] = .int(mobLevelLo) }
        if let mobLevelHi { o["mobLevelHi"] = .int(mobLevelHi) }
        if let casterClasses { o["casterClasses"] = .int(casterClasses) }
        if let week { o["week"] = .string(week) }
        if let variable { o["variable"] = .bool(variable) }
        return .object(o)
    }
}

/// The damage histogram, keyed by the decimal number the log printed.
///
/// It serializes in numeric-ascending key order, which is what a JavaScript object does with
/// canonical array-index keys and what a sorted-string map gets wrong the moment a ledger holds both
/// `"9"` and `"10"`. The order must be a function of the histogram's content rather than of a hash
/// iteration order, because the coalescing fingerprint is taken over it.
///
/// A key that is not a canonical index sorts after every key that is, by its string.
public enum ResistHistogram {
    public static func write(_ out: inout String, _ dmg: [String: Int64]) {
        let keys = dmg.keys.sorted { a, b in
            let ia = indexOf(a), ib = indexOf(b)
            if ia != ib {
                switch (ia, ib) {
                case (.some(let x), .some(let y)): return x < y
                case (.some, .none): return true
                case (.none, .some): return false
                case (.none, .none): break
                }
            }
            return Rust.bytesLess(a, b)
        }
        out.append("{")
        var first = true
        for k in keys {
            if first { first = false } else { out.append(",") }
            JS.writeJSONString(&out, k)
            out.append(":")
            out.append(String(dmg[k]!))
        }
        out.append("}")
    }

    /// A JS "array index" key as a sortable value: a number for a canonical non-negative decimal, nil
    /// for everything else, and nil sorts last.
    static func indexOf(_ key: String) -> UInt64? {
        // "007" is not the canonical spelling of 7, so JS files it as an ordinary string key.
        if key.count > 1 && key.hasPrefix("0") { return nil }
        return UInt64(key)
    }
}

/// One character's bucket as it goes on disk.
public struct ResistLedgerFileSource {
    public var key: String
    public var rows: [ResistRowFile]
}

/// The file itself. `version` first — see the header for why that is load-bearing.
public struct UserLedgerFile {
    public var version: Int64
    public var sources: [ResistLedgerFileSource]

    /// The bytes, in the app's field order.
    public func serializedString() -> String {
        var out = "{\"version\":" + String(version) + ",\"sources\":["
        for (i, source) in sources.enumerated() {
            if i > 0 { out.append(",") }
            out.append("{\"key\":")
            JS.writeJSONString(&out, source.key)
            out.append(",\"rows\":[")
            for (j, row) in source.rows.enumerated() {
                if j > 0 { out.append(",") }
                row.write(&out)
            }
            out.append("]}")
        }
        out.append("]}")
        return out
    }

    public var json: JSONValue {
        .object(["version": .int(version),
                 "sources": .array(sources.map { s in
                     .object(["key": .string(s.key), "rows": .array(s.rows.map(\.json))])
                 })])
    }

    /// The same buckets in the engine's seam shape, so the caller can hand them straight back.
    public var seamSources: [LedgerSource] {
        sources.map { LedgerSource(key: $0.key, rows: $0.rows.map(\.json)) }
    }
}

/// What a read of the file produced, and anything about it worth a line on the diagnostics stream.
public struct ResistLedgerLoad {
    public var sources: [LedgerSource] = []
    /// One sentence for stderr. Absent means an ordinary read with nothing to say.
    public var notice: String? = nil
}

public enum ResistLedgerFile {
    /// The read rules, in order. Every one answers with buckets rather than an error: this never
    /// fails.
    ///
    ///   1. Not valid JSON: empty.
    ///   2. Wrong version: empty, and silent — a planned discard, not an incident.
    ///   3. A source is usable iff its `key` is a string that is not `baseline` and its `rows` is an
    ///      array.
    ///
    /// A source whose rows will not parse is dropped whole. A bucket is the right unit: buckets are
    /// independent and each is re-derivable by re-folding that character's log, whereas a half bucket
    /// is an under-count that looks exactly like a fact.
    public static func readLedger(_ text: String) -> ResistLedgerLoad {
        guard let doc = try? JSONValue.parse(text) else {
            return ResistLedgerLoad(sources: [],
                                    notice: "resist-ledger.json is not valid JSON; starting empty")
        }
        guard case .int(let version) = doc["version"], version == RESIST_LEDGER_VERSION else {
            return ResistLedgerLoad()
        }
        guard let raw = doc["sources"].array else { return ResistLedgerLoad() }
        var sources: [LedgerSource] = []
        var dropped = 0
        for entry in raw {
            guard let key = entry["key"].string else { continue }
            if key == BASELINE_SOURCE_KEY { continue }
            guard let rows = entry["rows"].array else { continue }
            if rows.contains(where: { ResistRowFile.from($0) == nil }) {
                dropped += 1
                continue
            }
            sources.append(LedgerSource(key: key, rows: rows))
        }
        let notice = dropped > 0
            ? "resist-ledger.json: \(dropped) character bucket(s) held rows this build cannot read and were dropped"
            : nil
        return ResistLedgerLoad(sources: sources, notice: notice)
    }

    /// The write rules:
    ///
    ///   * the shipped baseline's bucket is never written,
    ///   * a bucket with no rows is never written (an empty `{key, rows: []}` claims nothing),
    ///   * source keys ascending, rows within a bucket by pooling key ascending — byte-stable, so an
    ///     unchanged ledger serializes to the same bytes twice and the coalescing write can decline.
    public static func ledgerFileOf(_ store: ResistLedgerStore) -> UserLedgerFile {
        var sources: [ResistLedgerFileSource] = []
        for key in store.sourceKeys() {
            if key == BASELINE_SOURCE_KEY { continue }
            guard let bucket = store.bucket(key) else { continue }
            if bucket.isEmpty { continue }
            sources.append(ResistLedgerFileSource(
                key: key, rows: bucket.rowsInKeyOrder().map(ResistRowFile.of)))
        }
        return UserLedgerFile(version: RESIST_LEDGER_VERSION, sources: sources)
    }

    /// Seed a store from what a read found. `readLedger` has already rejected the baseline, so this
    /// does not re-check for it.
    ///
    /// It does not call `beginSource`: seeding puts every persisted bucket back, and the fold's own
    /// source is discarded afterwards by the one call that names it.
    public static func seedStore(_ store: ResistLedgerStore, _ sources: [LedgerSource]) {
        for source in sources {
            let bucket = store.bucketMut(source.key)
            for row in source.rows {
                guard let parsed = ResistRowFile.from(row) else { continue }
                bucket.seedRow(parsed.intoRow())
            }
        }
    }

    /// The typed overload, for a caller that already holds rows.
    public static func seedStore(_ store: ResistLedgerStore, typed sources: [ResistLedgerFileSource]) {
        for source in sources {
            let bucket = store.bucketMut(source.key)
            for row in source.rows { bucket.seedRow(row.intoRow()) }
        }
    }
}
