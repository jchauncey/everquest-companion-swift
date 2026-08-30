// fold/src/spells_us.rs — the client's spell table, parsed.
//
// Pure over the file's bytes, exactly as the TypeScript is: no file, no thread, no state. The format
// is fold vocabulary and the IO belongs to whoever owns a directory (`ClientSpells`).
//
// The table is never served in bulk: a parsed table measures ~48k entries and 6.13 MiB of JSON
// against an 8 MiB frame ceiling. This process parses the file internally for its own joins, and
// consumers ask per-spell questions.
//
// The field map is transcribed from an app-side verification rather than re-derived, including the
// two traps: field 10 is the recast and field 9 is not, and an effect slot is
// `slot | effectId | base | limit | calc | max` rather than `… | max | calc`.
//
// The JavaScript semantics are the hard part. Every scalar goes through `Number(x)` or
// `Number(x) || 0`, and the row filter is `f.length < 172` — not 173, so a row with exactly 172
// fields passes and then reads `undefined` for its slots. See `jsNumber`.
//
// The scan is over BYTES rather than over a `String`: the file is 38 MB and Swift's `Character`
// grapheme scanning over it costs seconds. `Decode` is how the two callers differ — the file is
// latin-1 and a hand-authored test row is already text — and nothing else in the parser knows which.
import Foundation
import EQLog

public enum SpellsUs {
    // The field map, `spellsUsParse.ts` index for index.

    public static let F_ID = 0
    public static let F_NAME = 1
    public static let F_CAST_MS = 8
    public static let F_RECAST_MS = 10
    public static let F_DURATION_FORMULA = 11
    public static let F_DURATION = 12
    public static let F_MANA = 14
    public static let F_RESIST_TYPE = 29
    public static let F_TARGET_TYPE = 30
    public static let F_CLASS_FIRST = 36
    public static let F_CLASS_COUNT = 16
    /// The bard's index among the sixteen class-level fields (WAR CLR PAL RNG SHD DRU MNK BRD …).
    public static let CLASS_BARD = 7
    /// The spell's category id — `Taps`, `Direct Damage`, `Heals` — as the in-game Actions/Spells
    /// window's Category column prints it. The word lives in `dbstr_us.txt`; this column is only
    /// ever the number.
    public static let F_CATEGORY = 86
    /// The spell's subcategory id. Independent of the category rather than nested under it: some
    /// rows carry a subcategory with no category. Column 88 is a third such column and is
    /// deliberately not read — the game's own window prints two.
    public static let F_SUBCATEGORY = 87
    public static let F_RESIST_ADJ = 78
    public static let F_AE_MAX_TARGETS = 143
    public static let F_SLOTS = 172

    static let EFFECT_HITPOINTS = 0.0
    static let EFFECT_CHARM = 22.0
    static let EFFECT_MEZ = 31.0
    static let EFFECT_ALL_RESISTS = 111.0

    /// A resist-debuff slot has to be worth something to count: opening an 11-minute debuff window
    /// for a one-point rider would file every later observation under a condition that never
    /// mattered. Five sits below the weakest real member of the family (Tashani, 23) and above every
    /// rider in the file.
    static let MIN_DEBUFF_MAGNITUDE = 5.0

    // MARK: - The shapes, `shared/resistTypes.ts`

    /// The five axes the game prints, plus the `all` a tash/malo debuff slot carries — which is a
    /// slot's axis and never a spell's, so the two are one enum with an extra member.
    public enum Axis: String, Sendable, Hashable, CaseIterable {
        case magic, fire, cold, poison, disease
        /// Only a debuff slot is ever this — the tash and malo family, effect 111.
        case all

        /// The word every surface prints. No acronyms anywhere.
        public var word: String { rawValue }
    }

    /// `axisFromResistType`. Everything unlisted — 0 unresistable, 6 chromatic, 7 prismatic, 8
    /// physical, 9 corruption — is `nil` rather than guessed at.
    public static func axisFromResistType(_ resistType: Double) -> Axis? {
        switch asI64(resistType) {
        case 1: return .magic
        case 2: return .fire
        case 3: return .cold
        case 4: return .poison
        case 5: return .disease
        default: return nil
        }
    }

    /// `ResistDebuffSlot`.
    public struct DebuffSlot: Sendable, Hashable {
        public var axis: Axis
        public var base: Double
        public var calc: Double
        public var max: Double
        public init(axis: Axis, base: Double, calc: Double, max: Double) {
            self.axis = axis; self.base = base; self.calc = calc; self.max = max
        }
    }

    /// `SpellHpSlot`. `perTick` is a question of the ROW rather than of the slot — does this spell
    /// have a duration at all — written onto each slot because that is where the reader needs it.
    public struct HpSlot: Sendable, Hashable {
        public var base: Double
        public var max: Double
        public var calc: Double
        public var perTick: Bool
        public init(base: Double, max: Double, calc: Double, perTick: Bool) {
            self.base = base; self.max = max; self.calc = calc; self.perTick = perTick
        }
    }

    /// The `hpSlot` the resist estimator reads — effect 0 alone. Neither a heal-over-time nor a bard
    /// pulse is a spell the estimator fits a resist from.
    public struct DamageSlot: Sendable, Hashable {
        public var base: Double
        public var max: Double
        public var calc: Double
        public init(base: Double, max: Double, calc: Double) {
            self.base = base; self.max = max; self.calc = calc
        }
    }

    /// `hpDuration` — the buff-duration formula and its cap, present only on a spell that has one.
    public struct HpDuration: Sendable, Hashable {
        public var formula: Double
        public var value: Double
        public init(formula: Double, value: Double) { self.formula = formula; self.value = value }
    }

    /// One row's sixteen class levels, in the file's own column order. `0` means the class cannot
    /// use the spell at all.
    public typealias ClassLevels = [UInt8]

    /// `SpellResistInfo` — one row of the parsed table. The optionals are absent-means-nothing: a 0
    /// recast is the file saying there is no re-use timer, and a 0 mana is what every bard song says.
    public struct SpellInfo: Sendable, Hashable {
        /// The row's own spelling of the name, kept because the table is keyed by `spellCanonKey`
        /// and a folded key is not something a surface may print.
        public var name: String
        /// The category id, or `nil` when the row files itself under none. A zero is the file saying
        /// "uncategorised" rather than naming category zero: the string table's ids start at 1.
        public var category: UInt32?
        /// The subcategory id, or `nil`. Independent of `category` rather than nested under it.
        public var subcategory: UInt32?
        /// The level each of the sixteen classes learns this at, `0` meaning the class cannot use it.
        /// The valid window is `1...254` — `255` is the file's "cannot use", `0` is nothing.
        public var classLevels: ClassLevels
        public var axis: Axis?
        public var resistAdj: Double
        public var castMs: Double
        public var recastMs: Double?
        public var aeMaxTargets: Double?
        public var mana: Double?
        public var targetType: Double
        public var damageSlot: DamageSlot?
        public var hp: [HpSlot]
        public var hpDuration: HpDuration?
        public var debuffSlots: [DebuffSlot]
        public var levelCap: Double?
        public var song: Bool
    }

    /// The whole parsed table, keyed by `spellCanonKey(name)`.
    public typealias SpellTable = [String: SpellInfo]

    /// The sixteen class columns, in the file's order, spelled the way the app spells a class.
    ///
    /// The app's own list is sorted alphabetically and this one is not — this is the client's column
    /// order and nothing may re-sort it.
    public static let CLASS_ORDER: [String] = [
        "WAR", "CLR", "PAL", "RNG", "SHD", "DRU", "MNK", "BRD", "ROG", "SHM", "NEC", "WIZ", "MAG",
        "ENC", "BST", "BER"
    ]

    /// The column a class code names, or `nil` for a code this file has no column for.
    public static func classColumn(_ abbr: String) -> Int? { CLASS_ORDER.firstIndex(of: abbr) }

    // MARK: - The JavaScript arithmetic this parser is written in

    /// Rust's `as i64` on a `f64`: truncating toward zero, saturating at the ends, and `0` for NaN.
    /// The axis and effect tables are matched on this, so `1.9` is resist type 1 exactly as it is
    /// over there.
    static func asI64(_ v: Double) -> Int64 {
        if v.isNaN { return 0 }
        if v >= 9.223372036854775e18 { return Int64.max }
        if v <= -9.223372036854775e18 { return Int64.min }
        return Int64(v)
    }

    /// `Number(x)` for a string, which is not Swift's `Double(_:)` with a different name. The four
    /// differences that matter: the empty string is `0`; whitespace is the ECMA set, trimmed first;
    /// `Infinity` is a literal spelled exactly and takes an optional sign; radix prefixes are
    /// numbers and take no sign. Anything else is `NaN`.
    public static func jsNumber(_ text: String) -> Double { number(JS.trim(text)) }

    /// `Number(x)` over an already-trimmed body.
    static func number(_ t: String) -> Double {
        if t.isEmpty { return 0.0 }
        // The radix literals, which take no sign.
        if let rest = strip(t, "0x") ?? strip(t, "0X") { return radix(rest, 16) }
        if let rest = strip(t, "0o") ?? strip(t, "0O") { return radix(rest, 8) }
        if let rest = strip(t, "0b") ?? strip(t, "0B") { return radix(rest, 2) }
        // `Infinity`, with an optional sign. Spelled exactly: JS accepts no `inf` or `INFINITY`.
        var sign = 1.0
        var body = Substring(t)
        if body.hasPrefix("-") { sign = -1.0; body = body.dropFirst() } else if body.hasPrefix("+") { body = body.dropFirst() }
        if body == "Infinity" { return sign * Double.infinity }
        // The decimal arm is guarded rather than delegated: Swift's parser accepts spellings JS does
        // not (`inf`, `nan`, hex floats), so the body must look like a JS decimal literal first.
        if !isJSDecimal(body) { return Double.nan }
        guard let v = Double(body) else { return Double.nan }
        return sign * v
    }

    private static func strip(_ s: String, _ p: String) -> String? {
        s.hasPrefix(p) ? String(s.dropFirst(p.count)) : nil
    }

    /// Does this look like a JS `StrDecimalLiteral` body (no sign — the caller took it)? Requires at
    /// least one digit, allows at most one `.`, and allows one `e`/`E` exponent with an optional
    /// sign and at least one digit after it.
    static func isJSDecimal(_ body: Substring) -> Bool {
        var mantissa = body
        var exponent: Substring?
        if let e = body.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            mantissa = body[body.startIndex..<e]
            exponent = body[body.index(after: e)...]
        }
        var digits = 0
        var dots = 0
        for c in mantissa {
            if c.isASCII && c.isNumber { digits += 1 } else if c == "." { dots += 1 } else { return false }
        }
        if digits == 0 || dots > 1 { return false }
        guard var e = exponent else { return true }
        if e.hasPrefix("-") || e.hasPrefix("+") { e = e.dropFirst() }
        return !e.isEmpty && e.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// One radix literal's digits, or `NaN` when it has none or has a bad one — `Number`'s answer.
    static func radix(_ digits: String, _ base: UInt32) -> Double {
        if digits.isEmpty { return Double.nan }
        var out = 0.0
        for c in digits.unicodeScalars {
            guard let d = digitValue(c), d < base else { return Double.nan }
            out = out * Double(base) + Double(d)
        }
        return out
    }

    /// `char::to_digit` — ASCII digits and letters only, which is the set JS accepts too.
    private static func digitValue(_ c: Unicode.Scalar) -> UInt32? {
        switch c.value {
        case 0x30...0x39: return c.value - 0x30
        case 0x61...0x7A: return c.value - 0x61 + 10
        case 0x41...0x5A: return c.value - 0x41 + 10
        default: return nil
        }
    }

    /// `Number(x) || 0` — the idiom `rowInfo` uses for every scalar it stores. Not a default: JS `||`
    /// is falsiness, so `NaN`, `0` and `-0` all become a POSITIVE `0`.
    public static func orZero(_ v: Double) -> Double { (v == 0.0 || v.isNaN) ? 0.0 : v }

    // MARK: - Text out of the client's bytes

    /// How a field's bytes become text.
    public typealias Decode = (ArraySlice<UInt8>) -> String

    /// The latin-1 read, which is the one the client files get: latin1 never throws and never
    /// replaces a byte, and every field this parser reads numerically is ASCII. A UTF-8 read of a
    /// file with one stray high byte in a spell name would substitute a replacement character, which
    /// changes a NAME and therefore a join key — so the bytes are widened one at a time.
    public static let latin1: Decode = { s in
        var v = String.UnicodeScalarView()
        v.reserveCapacity(s.count)
        for b in s { v.append(Unicode.Scalar(b)) }
        return String(v)
    }

    /// The decode for bytes that came from a Swift `String` in the first place (a hand-authored test
    /// row), so the round trip is the identity.
    public static let utf8: Decode = { s in String(decoding: s, as: UTF8.self) }

    /// The ASCII half of the ECMA whitespace set — the whole set on every real field.
    @inline(__always) private static func isASCIISpace(_ b: UInt8) -> Bool {
        b == 0x09 || b == 0x0A || b == 0x0B || b == 0x0C || b == 0x0D || b == 0x20
    }

    /// `Number(x)` over a field's bytes. Pure ASCII takes the fast path — the trim and the spelling
    /// are then byte work — and anything else is handed to the `String` definition through the same
    /// decoder the names use, so the two never disagree about what U+00A0 is.
    static func jsNumber(_ s: ArraySlice<UInt8>, _ decode: Decode) -> Double {
        var lo = s.startIndex, hi = s.endIndex
        while lo < hi, isASCIISpace(s[lo]) { lo += 1 }
        while hi > lo, isASCIISpace(s[hi - 1]) { hi -= 1 }
        if lo == hi { return 0.0 }
        var i = lo
        while i < hi {
            if s[i] >= 0x80 { return jsNumber(decode(s)) }
            i += 1
        }
        return number(String(decoding: s[lo..<hi], as: UTF8.self))
    }

    /// `Number(x) || 0` over a field that may be absent — `undefined` past the end of the row, which
    /// `Number` reads as `NaN` and `|| 0` reads as 0.
    static func jsNumberOrZero(_ s: ArraySlice<UInt8>?, _ decode: Decode) -> Double {
        guard let s else { return 0.0 }
        return orZero(jsNumber(s, decode))
    }

    // MARK: - Slots

    /// One effect slot, as the row spells it.
    struct Slot {
        var effect: Double
        var base: Double
        var calc: Double
        var max: Double
    }

    /// `parseSlots`. Note the missing `|| 0`: a slot's numbers are read with a bare `Number(...)`, so
    /// a malformed slot yields `NaN` and that NaN flows into the comparisons below — `NaN >= 0` and
    /// `NaN < 5` are both false, and between them they decide whether a slot becomes a debuff window.
    static func parseSlots(_ field: String?) -> [Slot] {
        // An absent field, which a 172-field row really has, and also an empty one, because `''` is
        // falsy over there.
        guard let field, !field.isEmpty else { return [] }
        var out: [Slot] = []
        // The trim before the split absorbs a CRLF file's trailing `\r`: nothing else in this parser
        // strips one, and on a CRLF row the `\r` lands on the last field, which is this one.
        for chunk in JS.trim(field).split(separator: "$", omittingEmptySubsequences: false) {
            if chunk.isEmpty { continue }
            let p = chunk.split(separator: "|", omittingEmptySubsequences: false)
            if p.count < 6 { continue }
            out.append(Slot(effect: jsNumber(String(p[1])),
                            base: jsNumber(String(p[2])),
                            calc: jsNumber(String(p[4])),
                            max: jsNumber(String(p[5]))))
        }
        return out
    }

    /// `RESIST_EFFECTS` plus the `all` arm — a slot's axis, or `nil` when the slot is not a resist
    /// debuff at all.
    static func slotAxis(_ effect: Double) -> Axis? {
        if effect == EFFECT_ALL_RESISTS { return .all }
        switch asI64(effect) {
        case 46: return .fire
        case 47: return .cold
        case 48: return .poison
        case 49: return .disease
        case 50: return .magic
        default: return nil
        }
    }

    /// `debuffSlots`.
    static func debuffSlots(_ slots: [Slot]) -> [DebuffSlot] {
        var out: [DebuffSlot] = []
        for s in slots {
            guard let axis = slotAxis(s.effect) else { continue }
            // Only decreases; a spell that raises a resist is a buff and never opens a window here.
            if s.base >= 0.0 { continue }
            let magnitude = Swift.max(abs(s.base), abs(s.max))
            if magnitude < MIN_DEBUFF_MAGNITUDE { continue }
            out.append(DebuffSlot(axis: axis, base: s.base, calc: s.calc, max: s.max))
        }
        return out
    }

    /// `levelCapOf` — the cap the game enforces regardless of rc, and only from the primary slot. A
    /// rider's cap must never make a whole spell "always resisted": Chaos Flux carries a stun rider
    /// capped at 55, and being above it costs the stun, not the nuke.
    static func levelCapOf(_ slots: [Slot]) -> Double? {
        guard let first = slots.first else { return nil }
        if first.effect != EFFECT_CHARM && first.effect != EFFECT_MEZ { return nil }
        return first.max > 0.0 ? first.max : nil
    }

    /// `hpSlotOf` — the first effect-0 slot.
    static func damageSlotOf(_ slots: [Slot]) -> DamageSlot? {
        guard let s = slots.first(where: { $0.effect == EFFECT_HITPOINTS }) else { return nil }
        return DamageSlot(base: s.base, max: s.max, calc: s.calc)
    }

    /// `hpSlotsOf` — every hitpoint slot in file order. The effect set is 0 (the damage slot), 100
    /// (heal over time) and 334 (the bard's pulsing hitpoint effect).
    static func hpSlotsOf(_ slots: [Slot], _ perTick: Bool) -> [HpSlot] {
        slots.filter { $0.effect == EFFECT_HITPOINTS || $0.effect == 100.0 || $0.effect == 334.0 }
            .map { HpSlot(base: $0.base, max: $0.max, calc: $0.calc, perTick: perTick) }
    }

    // MARK: - Rows

    /// A category or subcategory id — `Number(x) || 0`, then absent-means-nothing. A zero is an
    /// absence and not an id: the string table's namespace starts at 1. The cast saturates rather
    /// than wrapping for an absurd value, which resolves to no word and reads as no category.
    static func categoryID(_ v: Double) -> UInt32? {
        guard v > 0.0 else { return nil }
        if v >= 4_294_967_295.0 { return UInt32.max }
        return UInt32(v)
    }

    /// `classLevels` — the level each of the sixteen classes learns this at, `0` for "cannot use".
    /// A valid level is `1...254`: `>= 255` is the file's "cannot use" and `<= 0` is nothing. The
    /// bound is on the number rather than on an integer, exactly as the TypeScript's is.
    static func classLevels(_ fields: [Range<Int>], _ bytes: [UInt8], _ decode: Decode) -> ClassLevels {
        var levels = ClassLevels(repeating: 0, count: F_CLASS_COUNT)
        for i in 0..<F_CLASS_COUNT {
            let idx = F_CLASS_FIRST + i
            let v = idx < fields.count ? jsNumber(bytes[fields[idx]], decode) : jsNumber("")
            if !v.isFinite || v >= 255.0 || v <= 0.0 { continue }
            // Bounded to `0 < v < 255` by the guard above; a fractional level floors, which is the
            // reading a player would give it.
            levels[i] = UInt8(v)
        }
        return levels
    }

    /// Can any class cast this? A row nobody can learn is a mob's or an item's copy, which is the one
    /// override on the table's first-wins dedupe.
    static func anyClass(_ levels: ClassLevels) -> Bool { levels.contains { $0 > 0 } }

    /// Can only the bard cast this? That is what makes a row a song rather than a cast.
    static func bardOnly(_ levels: ClassLevels) -> Bool {
        levels[CLASS_BARD] > 0 && levels.enumerated().allSatisfy { $0.offset == CLASS_BARD || $0.element == 0 }
    }

    /// `rowInfo` — one row's whole answer. The name and the class levels arrive from the caller
    /// rather than being re-read: both are needed before the row wins its key, and reading them
    /// twice would be two chances to disagree about what a valid level is.
    static func rowInfo(_ fields: [Range<Int>], _ bytes: [UInt8], _ decode: Decode,
                        name: String, classLevels levels: ClassLevels) -> SpellInfo {
        func fld(_ i: Int) -> ArraySlice<UInt8>? { i < fields.count ? bytes[fields[i]] : nil }
        func num(_ i: Int) -> Double { jsNumberOrZero(fld(i), decode) }

        let slots = parseSlots(fld(F_SLOTS).map(decode))
        let recastMs = num(F_RECAST_MS)
        let ae = num(F_AE_MAX_TARGETS)
        let mana = num(F_MANA)
        // `Number(f[11]) || 0`, and the whole `hpDuration` branch turns on it being non-zero.
        let formula = num(F_DURATION_FORMULA)
        let hp = hpSlotsOf(slots, formula != 0.0)
        return SpellInfo(
            name: name,
            category: categoryID(num(F_CATEGORY)),
            subcategory: categoryID(num(F_SUBCATEGORY)),
            classLevels: levels,
            // Not `|| 0`: the resist type goes in as `Number(...)` alone, and an unparseable one is
            // NaN, which matches no arm — the same answer a chromatic spell gets.
            axis: axisFromResistType(fld(F_RESIST_TYPE).map { jsNumber($0, decode) } ?? jsNumber("")),
            resistAdj: num(F_RESIST_ADJ),
            castMs: num(F_CAST_MS),
            recastMs: recastMs > 0.0 ? recastMs : nil,
            aeMaxTargets: ae > 0.0 ? ae : nil,
            mana: mana > 0.0 ? mana : nil,
            targetType: num(F_TARGET_TYPE),
            damageSlot: damageSlotOf(slots),
            hp: hp,
            // `hpDuration` is written only when BOTH hold: at least one hitpoint slot, and a duration
            // formula. The TypeScript nests the second test inside the first, so a formula on a row
            // with no hitpoint slot writes nothing.
            hpDuration: (!hp.isEmpty && formula != 0.0) ? HpDuration(formula: formula, value: num(F_DURATION)) : nil,
            debuffSlots: debuffSlots(slots),
            levelCap: levelCapOf(slots),
            song: bardOnly(levels))
    }

    /// Parse the whole file, from a `String` — the hand-authored-row entry point.
    public static func parseSpellsUs(_ text: String) -> SpellTable {
        parse(Array(text.utf8), utf8)
    }

    /// Parse the whole file, from the client's own latin-1 bytes.
    public static func parseSpellsUs(latin1 bytes: [UInt8]) -> SpellTable {
        parse(bytes, latin1)
    }

    /// The four filters, in order:
    ///
    ///   * an empty line only — a blank-looking line of spaces falls out at the field-count test.
    ///   * `f.length < 172`, not 173: a row with exactly 172 fields passes and then reads
    ///     `undefined` for its slots. Tightening this drops rows the app keeps.
    ///   * an empty name only — a whitespace-only name survives here and dies at the key test.
    ///   * an id that is not a number. `''` is `0`, which is finite, so an empty id is kept.
    ///
    /// Ranked spells and NPC copies of a player spell fold onto one key, so file order decides, with
    /// one override: a row no class can cast is a mob's or an item's copy and loses to a row a player
    /// can learn. First-wins otherwise.
    static func parse(_ bytes: [UInt8], _ decode: Decode) -> SpellTable {
        var table = SpellTable()
        // `playable` per key, beside the table — the TypeScript's `seen` map, whose only extra
        // content is that flag.
        var playableByKey: [String: Bool] = [:]
        var fields: [Range<Int>] = []
        fields.reserveCapacity(200)
        let n = bytes.count
        var lineStart = 0
        // `text.split('\n')`, which yields the trailing empty piece a file ending in a newline has.
        while true {
            var lineEnd = lineStart
            while lineEnd < n, bytes[lineEnd] != 0x0A { lineEnd += 1 }
            if lineEnd > lineStart {
                fields.removeAll(keepingCapacity: true)
                var fieldStart = lineStart
                var i = lineStart
                while i < lineEnd {
                    if bytes[i] == 0x5E { // '^'
                        fields.append(fieldStart..<i)
                        fieldStart = i + 1
                    }
                    i += 1
                }
                fields.append(fieldStart..<lineEnd)
                row(fields, bytes, decode, &table, &playableByKey)
            }
            if lineEnd >= n { break }
            lineStart = lineEnd + 1
        }
        return table
    }

    private static func row(_ fields: [Range<Int>], _ bytes: [UInt8], _ decode: Decode,
                            _ table: inout SpellTable, _ playableByKey: inout [String: Bool]) {
        if fields.count < F_SLOTS { return }
        let name = decode(bytes[fields[F_NAME]])
        if name.isEmpty { return }
        if !jsNumber(bytes[fields[F_ID]], decode).isFinite { return }
        let key = Names.spellCanonKey(name)
        if key.isEmpty { return }
        let levels = classLevels(fields, bytes, decode)
        let playable = anyClass(levels)
        if let held = playableByKey[key] {
            // Replace only when the incumbent is unplayable and the newcomer is not.
            if held || !playable { return }
        }
        table[key] = rowInfo(fields, bytes, decode, name: name, classLevels: levels)
        playableByKey[key] = playable
    }
}

/// The two names the rest of the engine spells without the module in front of them.
public typealias SpellInfo = SpellsUs.SpellInfo
public typealias SpellTable = SpellsUs.SpellTable
