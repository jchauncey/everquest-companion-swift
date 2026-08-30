// "Of everything this loadout already owns, what is best at the level I am looking at."
//
// Ported from src/shared/{bestSpells,bestSpellsSearch,spellMetrics,spellScale,spellLevels,
// aoeSpells,spellRanks}.ts. The corpus is the committed `spells.json` beside the app (the same
// file the Electron main process folds into `LevelUnlockData`), read ONCE off the main thread and
// kept for the life of the process.
//
// WHAT THIS PORT DOES NOT HAVE. The Electron fold also reads the game client's own spell table
// (`clientSpellHp`) for spells whose wiki page states no hit-point line and for the handful whose
// magnitude follows a client formula rather than the page's breakpoints. That table lives in the
// player's EverQuest install, not in this repo, so rows are built from the PAGE alone here: a
// spell with no stated hit-point line simply has no reading and does not appear. On the owner's
// snapshot the two agree exactly (DD 26, DoT 25, AOE 6, Heal 8, HoT 8, +1 out of era).
import Foundation
import EQCompanionCore

// MARK: - Rank scaling (shared/spellScale.ts)

enum LvSpellScale {
    static let maxRank = 10
    private static let damageRankPercent = 6
    private static let healRankPercent = 3

    /// A name with no roman suffix is rank 1, and rank 1 is no bonus at all — so `0` is the
    /// "nothing to add" rank every caller normalizes to.
    static func normalize(_ rank: Int?) -> Int {
        guard let rank, rank > 1 else { return 0 }
        return min(maxRank, rank)
    }

    static func damage(_ amount: Double, _ rank: Int) -> Double {
        guard rank > 0, amount > 0 else { return amount }
        return amount + (amount * Double(damageRankPercent) * Double(rank) / 100).rounded(.down)
    }

    static func heal(_ amount: Double, _ rank: Int) -> Double {
        guard rank > 0, amount > 0 else { return amount }
        return amount + (amount * Double(healRankPercent) * Double(rank) / 100).rounded(.down)
    }

    /// The higher of the rank you have been observed casting and the one being simulated, so a
    /// spell you already own at a better rank is never pulled down by the slider.
    static func effective(observed: Int, simulated: Int) -> Int {
        max(normalize(observed), normalize(simulated))
    }

    private static let romans = ["", "I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X"]

    static func roman(_ rank: Int) -> String {
        rank >= 1 && rank <= maxRank ? romans[rank] : String(rank)
    }
}

// MARK: - Observed ranks (shared/spellLines.ts, shared/spellRanks.ts)

enum LvSpellLines {
    private static let rankTail = try! NSRegularExpression(pattern: " (I|II|III|IV|V|VI|VII|VIII|IX|X)$", options: [.caseInsensitive])

    /// The rank-folded key: the display name with its roman suffix stripped, case-folded.
    static func lineKey(_ name: String) -> String {
        let t = name.trimmingCharacters(in: .whitespaces)
        let stripped = rankTail.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "")
        return stripped.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// `yours: IV` — the highest rank of this spell the log has watched you merge or cast. Null
    /// where the log has seen only rank one, because that is what everyone starts with.
    static func observedLabel(_ snap: [String: Int], _ name: String) -> String? {
        guard let rank = snap[lineKey(name)], rank > 1 else { return nil }
        return "yours: \(LvSpellScale.roman(rank))"
    }

    static func observedRank(_ snap: [String: Int], _ name: String) -> Int {
        LvSpellScale.normalize(snap[lineKey(name)])
    }

    /// `observedSpellRanks` folded to key → rank.
    static func snapshot(_ v: JSONValue) -> [String: Int] {
        var out: [String: Int] = [:]
        for (k, row) in v.object ?? [:] { out[k] = row["rank"].int ?? 0 }
        return out
    }
}

// MARK: - AoE (shared/aoeSpells.ts)

enum LvAoeSpells {
    static let targetTypes: Set<String> = ["targeted ae", "pb ae", "pbaoe", "ae"]
    static let defaultMaxTargets = 4

    static func isAe(_ targetType: String) -> Bool {
        targetTypes.contains(targetType.trimmingCharacters(in: .whitespaces).lowercased())
    }

    static func hits(waves: Int, targets: Int, cap: Int) -> Int {
        max(1, min(max(1, waves) * max(1, targets), max(1, cap)))
    }

    static func assumptionLabel(_ counts: [Int]) -> String {
        let c = counts.filter { $0 > 0 }
        guard let lo = c.min(), let hi = c.max() else { return "x\(defaultMaxTargets) targets" }
        return lo == hi ? "x\(lo) targets" : "x\(lo) to x\(hi) targets"
    }

    static let assumptionTitle = "Figures assume every target the spell can hit. Four unless your client states the spell its own cap."
}

// MARK: - The committed catalogue

/// One hit-point line off a spell's page, parsed ONCE. The magnitude still depends on the level it
/// is read at, so what is stored is the RULE — a breakpoint ramp or a fixed number — not a value.
struct LvHpEffect: Sendable {
    enum Magnitude: Sendable {
        case ramp([(level: Int, value: Double)])
        case fixed(Double)
    }
    var magnitude: Magnitude
    /// From the head word (`increase`/`decrease`), never from the sign of the number.
    var heals: Bool
    var perTick: Bool
    var statedTicks: Int?

    func amount(at level: Int) -> Double {
        switch magnitude {
        case .fixed(let v): return abs(v)
        case .ramp(let points):
            guard let first = points.first, let last = points.last else { return 0 }
            if level <= first.level { return abs(first.value) }
            if level >= last.level { return abs(last.value) }
            for i in 1..<points.count {
                let a = points[i - 1], b = points[i]
                if level > b.level { continue }
                let span = b.level - a.level
                if span <= 0 { return abs(b.value) }
                return abs(a.value + (b.value - a.value) * Double(level - a.level) / Double(span))
            }
            return abs(last.value)
        }
    }
}

/// One class and the level it gets a spell at.
struct LvSpellClassLevel: Sendable, Identifiable {
    var cls: String
    var level: Int
    var id: String { cls }
}

struct LvCatalogSpell: Sendable {
    var name: String
    var key: String                  // lowercased name — the fold-by-name identity
    var at: [LvSpellClassLevel]        // one entry per class, at its LOWEST stated level
    var castTimeMs: Double = 0
    var recastMs: Double = 0
    var durationMs: Double = 0
    var mana: Int?
    var targetType = ""
    var spellType = ""
    var outOfEra = false
    var hp: [LvHpEffect] = []
    var searchText = ""
}

/// What one spell is worth at one level, at one rank, against one target count.
struct LvSpellMetrics: Sendable {
    var damage: Double?
    var heal: Double?
    var damagePerMana: Double?
    var healPerMana: Double?
    var dps: Double?
    var hps: Double?
    var dot = false
    var hot = false
    var overSec: Int?
}

enum LvSpellCatalogue {
    private static let tickMs = 6000.0
    private static let hpHead = try! NSRegularExpression(
        pattern: "^(increase|decrease)s?\\s+(?:current\\s+)?hit\\s?points?(?:\\s+v\\d+)?\\b", options: [.caseInsensitive])
    private static let atLevel = try! NSRegularExpression(pattern: "@\\s*l(\\d+)", options: [.caseInsensitive])
    private static let perTickWords = try! NSRegularExpression(pattern: "\\s*\\bper\\s+tick\\b", options: [.caseInsensitive])
    private static let breakpoint = try! NSRegularExpression(pattern: "(-?\\d+)\\s*\\(L(\\d+)\\)", options: [.caseInsensitive])
    private static let betweenRe = try! NSRegularExpression(pattern: "\\bbetween\\s+(-?\\d+)\\s+and\\s+(-?\\d+)", options: [.caseInsensitive])
    private static let byToRe = try! NSRegularExpression(pattern: "\\bby\\s+(-?\\d+)\\s+to\\s+(-?\\d+)", options: [.caseInsensitive])
    private static let byRe = try! NSRegularExpression(pattern: "\\bby\\s+(-?\\d+)", options: [.caseInsensitive])
    private static let ticksRe = try! NSRegularExpression(
        pattern: "\\b(?:for|after)\\s+(\\d+|one|two|three|four|five|six)\\s+(?:additional\\s+)?ticks?\\b", options: [.caseInsensitive])
    private static let perTickRe = try! NSRegularExpression(pattern: "\\bper\\s+tick\\b", options: [.caseInsensitive])
    private static let additionalTicksRe = try! NSRegularExpression(
        pattern: "\\bfor\\s+\\S+\\s+additional\\s+ticks?\\b", options: [.caseInsensitive])
    private static let classSegment = try! NSRegularExpression(pattern: "^([A-Za-z][A-Za-z ]*?)\\s*-\\s*Level\\s*(\\d+)\\b")
    private static let apostrophes = CharacterSet(charactersIn: "'\u{2018}\u{2019}\u{02BC}`")

    /// The two spells the EQ Legends data set removes outright (src/main/data/spellRemovalsList.ts).
    private static let removed: Set<String> = ["Invigor", "Invisibility Versus Undead"]

    private static let classByDisplayName: [String: String] = [
        "bard": "BRD", "beastlord": "BST", "berserker": "BER", "cleric": "CLR", "druid": "DRU",
        "enchanter": "ENC", "magician": "MAG", "monk": "MNK", "necromancer": "NEC",
        "paladin": "PAL", "ranger": "RNG", "rogue": "ROG", "shadow knight": "SHD",
        "shadowknight": "SHD", "shaman": "SHM", "warrior": "WAR", "wizard": "WIZ"
    ]

    static func foldApostrophes(_ s: String) -> String {
        String(s.unicodeScalars.filter { !apostrophes.contains($0) })
    }

    private static func matches(_ re: NSRegularExpression, _ s: String) -> [[String?]] {
        re.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { m in
            (0..<m.numberOfRanges).map { i in
                guard let r = Range(m.range(at: i), in: s) else { return nil }
                return String(s[r])
            }
        }
    }

    private static func first(_ re: NSRegularExpression, _ s: String) -> [String?]? {
        matches(re, s).first
    }

    /// `* Necromancer - Level 9 * Shadow Knight - Level 22` → one entry per class, lowest level.
    static func parseClasses(_ text: String) -> [LvSpellClassLevel] {
        var lowest: [String: Int] = [:]
        for raw in text.split(separator: "*", omittingEmptySubsequences: false).dropFirst() {
            let segment = raw.trimmingCharacters(in: .whitespaces)
            if segment.isEmpty { continue }
            guard let m = first(classSegment, segment), let name = m[1], let lvl = m[2].flatMap({ Int($0) }),
                  let cls = classByDisplayName[name.trimmingCharacters(in: .whitespaces).lowercased()] else { continue }
            if let prior = lowest[cls], prior <= lvl { continue }
            lowest[cls] = lvl
        }
        return lowest.map { LvSpellClassLevel(cls: $0.key, level: $0.value) }.sorted { $0.cls < $1.cls }
    }

    /// One `Decrease Hit Points by 100 (L20) to 200 (L50)` line, as a rule. Nil when the line is
    /// not a hit-point line at all, or states no magnitude this app can read.
    static func parseHpLine(_ line: String) -> LvHpEffect? {
        let s = line.trimmingCharacters(in: .whitespaces)
        guard let head = hpHead.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let headRange = Range(head.range, in: s), let wordRange = Range(head.range(at: 1), in: s) else { return nil }
        let raw = String(s[headRange.upperBound...])
        // Breakpoints are read off a tail with `@L20` normalized and `per tick` removed; `perTick`
        // itself is read off the RAW tail, which is why the two are separate strings.
        var tail = atLevel.stringByReplacingMatches(in: raw, range: NSRange(raw.startIndex..., in: raw), withTemplate: "(L$1)")
        tail = perTickWords.stringByReplacingMatches(in: tail, range: NSRange(tail.startIndex..., in: tail), withTemplate: "")
        var magnitude: LvHpEffect.Magnitude?
        let points = matches(breakpoint, tail).compactMap { m -> (level: Int, value: Double)? in
            guard let v = m[1].flatMap({ Double($0) }), let l = m[2].flatMap({ Int($0) }) else { return nil }
            return (level: l, value: v)
        }.sorted { $0.level < $1.level }
        if !points.isEmpty {
            magnitude = .ramp(points)
        } else if let m = first(betweenRe, tail), let a = m[1].flatMap({ Double($0) }), let b = m[2].flatMap({ Double($0) }) {
            magnitude = .fixed((a + b) / 2)
        } else if let m = first(byToRe, tail), let a = m[1].flatMap({ Double($0) }), let b = m[2].flatMap({ Double($0) }) {
            magnitude = .fixed((a + b) / 2)
        } else if let m = first(byRe, tail), let a = m[1].flatMap({ Double($0) }) {
            magnitude = .fixed(a)
        }
        guard let magnitude else { return nil }
        var statedTicks: Int?
        if let m = first(ticksRe, tail), let word = m[1]?.lowercased() {
            let words = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6]
            let n = words[word] ?? Int(word) ?? 0
            if n > 0 { statedTicks = n }
        }
        let perTick = perTickRe.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)) != nil
            || additionalTicksRe.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)) != nil
        return LvHpEffect(magnitude: magnitude, heals: s[wordRange].lowercased() == "increase",
                        perTick: perTick, statedTicks: statedTicks)
    }

    /// Read `spells.json` and the committed era verdicts. Pure file work; call it off the main
    /// thread — the file is ~1 MB and this is the only pass over it.
    static func load(dataRoot: URL) -> [LvCatalogSpell] {
        guard let data = try? Data(contentsOf: dataRoot.appendingPathComponent("spells.json")),
              let json = try? JSONValue.parse(data), let rows = json["spells"].array else { return [] }
        var era: [String: Bool] = [:]
        if let eraData = try? Data(contentsOf: dataRoot.appendingPathComponent("pageEra.json")),
           let eraJson = try? JSONValue.parse(eraData) {
            for (k, v) in eraJson["spells"].object ?? [:] { era[k] = v.bool ?? false }
        }
        var out: [LvCatalogSpell] = []
        out.reserveCapacity(rows.count)
        for r in rows {
            guard let name = r["name"].string, !removed.contains(name) else { continue }
            let at = parseClasses(r["classes"].string ?? "")
            if at.isEmpty { continue }
            let key = name.lowercased()
            var s = LvCatalogSpell(name: name, key: key, at: at)
            s.castTimeMs = r["castTimeMs"].double ?? 0
            s.recastMs = r["recastMs"].double ?? 0
            s.durationMs = r["durationMs"].double ?? 0
            if let m = r["mana"].int, m > 0 { s.mana = m }
            s.targetType = r["targetType"].string ?? ""
            s.spellType = r["spellType"].string ?? ""
            s.outOfEra = era[key] == true
            s.hp = (r["effects"].array ?? []).compactMap { $0.string.flatMap(parseHpLine) }
            let parts = [name, r["msgCastOnYou"].string, r["msgCastOnOther"].string, r["msgWearsOff"].string]
            s.searchText = foldApostrophes(parts.compactMap { $0 }.joined(separator: " ").lowercased())
            out.append(s)
        }
        return out.sorted { $0.name < $1.name }
    }

    private static func r1(_ n: Double) -> Double { (n * 10).rounded() / 10 }

    /// Total damage/healing at a level, and the per-second and per-mana readings over ONE casting
    /// cycle: the cast, plus the longer of the duration and the re-use timer.
    static func metrics(_ s: LvCatalogSpell, level: Int, rank: Int, hits: Int) -> LvSpellMetrics? {
        guard !s.hp.isEmpty else { return nil }
        let lifetap = s.targetType == "Lifetap"
        let durationTicks = s.durationMs > 0 ? Int((s.durationMs / tickMs).rounded()) : 0
        var dmg = 0.0, heal = 0.0
        var dmgOverTime = false, healOverTime = false
        var any = false
        for line in s.hp {
            // A Lifetap's healing half is the caster's return, not the spell's output.
            if lifetap, line.heals { continue }
            any = true
            let base = line.amount(at: level)
            if line.heals {
                let amount = LvSpellScale.heal(base, rank)
                if line.perTick {
                    let ticks = line.statedTicks ?? durationTicks
                    if ticks > 0 { heal += amount * Double(ticks); healOverTime = true }
                } else {
                    heal += amount
                }
            } else {
                let amount = LvSpellScale.damage(base, rank) * Double(max(1, hits))
                if line.perTick {
                    let ticks = line.statedTicks ?? durationTicks
                    if ticks > 0 { dmg += amount * Double(ticks); dmgOverTime = true }
                } else {
                    dmg += amount
                }
            }
        }
        guard any, dmg > 0 || heal > 0 else { return nil }
        let mana = s.mana.map(Double.init)
        let castSec = s.castTimeMs / 1000
        let overSec = Double(durationTicks) * (tickMs / 1000)
        let recastSec = s.recastMs > 0 ? s.recastMs / 1000 : 0
        var out = LvSpellMetrics()
        if dmg > 0 {
            let cycle = castSec + max(dmgOverTime ? overSec : 0, recastSec)
            out.damage = r1(dmg)
            if let mana, mana > 0 { out.damagePerMana = r1(dmg / mana) }
            if cycle > 0 { out.dps = r1(dmg / cycle) }
            out.dot = dmgOverTime
        }
        if heal > 0 {
            let cycle = castSec + max(healOverTime ? overSec : 0, recastSec)
            out.heal = r1(heal)
            if let mana, mana > 0 { out.healPerMana = r1(heal / mana) }
            if cycle > 0 { out.hps = r1(heal / cycle) }
            out.hot = healOverTime
        }
        if dmgOverTime || healOverTime, overSec > 0 { out.overSec = Int(overSec.rounded()) }
        return out
    }
}

/// A cache of the parsed corpus. One load per process; every readout below reads this.
actor LvSpellCatalogueStore {
    static let shared = LvSpellCatalogueStore()
    private var spells: [LvCatalogSpell]?

    func spells(dataRoot: URL) -> [LvCatalogSpell] {
        if let spells { return spells }
        let loaded = LvSpellCatalogue.load(dataRoot: dataRoot)
        spells = loaded
        return loaded
    }
}

// MARK: - The readout (shared/bestSpells.ts)

enum LvBestSpellTab: String, CaseIterable, Sendable, Identifiable {
    case dd, dot, aoe, heal, hot
    var id: String { rawValue }
    var label: String {
        switch self {
        case .dd: return "DD"
        case .dot: return "DoT"
        case .aoe: return "AOE"
        case .heal: return "Heal"
        case .hot: return "HoT"
        }
    }
    var healSide: Bool { self == .heal || self == .hot }
    var columns: [LvBestSpellColumn] {
        switch self {
        case .aoe: return [.dps, .damage, .hits, .mana, .damagePerMana]
        case .heal, .hot: return [.hps, .heal, .mana, .healPerMana]
        default: return [.dps, .damage, .mana, .damagePerMana]
        }
    }
    var rankColumn: LvBestSpellColumn { healSide ? .hps : .dps }

    func admits(_ m: LvSpellMetrics) -> Bool {
        switch self {
        case .dd: return m.damage != nil && !m.dot
        case .dot: return m.damage != nil && m.dot
        case .aoe: return m.damage != nil
        case .heal: return m.heal != nil && !m.hot
        case .hot: return m.heal != nil && m.hot
        }
    }
}

enum LvBestSpellColumn: String, Sendable, Identifiable {
    case dps, damage, damagePerMana, hps, heal, healPerMana, mana, hits
    var id: String { rawValue }
    var label: String {
        switch self {
        case .dps: return "dps"
        case .damage: return "dmg"
        case .damagePerMana: return "dmg/mana"
        case .hps: return "hps"
        case .heal: return "heal"
        case .healPerMana: return "heal/mana"
        case .mana: return "mana"
        case .hits: return "hits"
        }
    }
    var title: String {
        switch self {
        case .dps: return "sustained damage per second over one casting cycle: the cast plus the longer of the duration and the re-use timer"
        case .damage: return "total base damage at this level, every tick included"
        case .damagePerMana: return "total damage divided by the mana it costs"
        case .hps: return "sustained healing per second over one casting cycle: the cast plus the longer of the duration and the re-use timer"
        case .heal: return "total base healing at this level, every tick included"
        case .healPerMana: return "total healing divided by the mana it costs"
        case .mana: return "what the spell costs to cast"
        case .hits: return "how many times one cast lands at the assumed target count: the number the damage total was multiplied by"
        }
    }
}

struct LvBestSpellRow: Sendable, Identifiable {
    var name: String
    /// the LOWEST level any class in the loadout gets it at — the level chip.
    var gainedAt: Int
    var classes: [String]
    var mana: Int?
    var metrics: LvSpellMetrics
    var outOfEra: Bool
    var rank: Int
    var observedRank: Int
    var hits: Int
    /// class levels for a search result the loadout does not own yet.
    var levels: [LvSpellClassLevel] = []
    var owned = true
    var id: String { name }

    func value(_ column: LvBestSpellColumn) -> Double? {
        switch column {
        case .mana: return mana.map(Double.init)
        case .hits: return Double(hits)
        case .dps: return metrics.dps
        case .damage: return metrics.damage
        case .damagePerMana: return metrics.damagePerMana
        case .hps: return metrics.hps
        case .heal: return metrics.heal
        case .healPerMana: return metrics.healPerMana
        }
    }

    func text(_ column: LvBestSpellColumn) -> String {
        guard let v = value(column) else { return LevelingFormat.none }
        if column == .damagePerMana || column == .healPerMana { return LevelingFormat.small(v) }
        return String(Int(v.rounded()))
    }
}

struct LvBestSpellSort: Sendable, Equatable {
    var column: LvBestSpellColumn
    var desc: Bool
}

struct LvBestSpellsTable: Sendable {
    var shown: [LvBestSpellRow] = []
    var outOfEra: [LvBestSpellRow] = []
}

struct LvBestSpells: Sendable {
    var level = 0
    var classes: [String] = []
    var tabs: [LvBestSpellTab: LvBestSpellsTable] = [:]
    var aoeTargets = "x4 targets"

    static let empty = LvBestSpells()
}

enum LvBestSpellsReadout {
    static func sort(_ rows: [LvBestSpellRow], _ s: LvBestSpellSort) -> [LvBestSpellRow] {
        rows.sorted { a, b in
            let av = a.value(s.column), bv = b.value(s.column)
            if av == nil || bv == nil {
                if (av == nil) != (bv == nil) { return bv == nil }
            } else if av != bv {
                return s.desc ? bv! < av! : av! < bv!
            }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// Every spell at least one class in the loadout has by `level`, folded by name.
    private static func rows(_ spells: [LvCatalogSpell], want: Set<String>, level: Int,
                             observed: [String: Int], simulate: Int, area: Bool) -> [LvBestSpellRow] {
        var byName: [String: LvBestSpellRow] = [:]
        var order: [String] = []
        for spell in spells {
            if area, !LvAoeSpells.isAe(spell.targetType) { continue }
            let owned = spell.at.filter { $0.level <= level && want.contains($0.cls) }
            if owned.isEmpty { continue }
            let classes = Set(owned.map(\.cls)).sorted()
            let gainedAt = owned.map(\.level).min() ?? level
            if var seen = byName[spell.key] {
                seen.classes = Array(Set(seen.classes).union(classes)).sorted()
                seen.gainedAt = min(seen.gainedAt, gainedAt)
                byName[spell.key] = seen
                continue
            }
            let observedRank = LvSpellLines.observedRank(observed, spell.name)
            let rank = LvSpellScale.effective(observed: observedRank, simulated: simulate)
            let targets = area ? LvAoeSpells.defaultMaxTargets : 1
            let hits = LvAoeSpells.hits(waves: 1, targets: targets, cap: LvAoeSpells.defaultMaxTargets)
            guard let m = LvSpellCatalogue.metrics(spell, level: level, rank: rank, hits: area ? hits : 1) else { continue }
            byName[spell.key] = LvBestSpellRow(name: spell.name, gainedAt: gainedAt, classes: classes,
                                             mana: spell.mana, metrics: m, outOfEra: spell.outOfEra,
                                             rank: rank, observedRank: observedRank,
                                             hits: area ? hits : 1)
            order.append(spell.key)
        }
        return order.compactMap { byName[$0] }
    }

    static func build(spells: [LvCatalogSpell], classes: [String], level: Int,
                      observed: [String: Int], simulate: Int,
                      sorts: [LvBestSpellTab: LvBestSpellSort]) -> LvBestSpells {
        var out = LvBestSpells(level: level, classes: classes)
        guard !classes.isEmpty, level > 0 else { return out }
        let want = Set(classes)
        let plain = rows(spells, want: want, level: level, observed: observed, simulate: simulate, area: false)
        let area = rows(spells, want: want, level: level, observed: observed, simulate: simulate, area: true)
        for tab in LvBestSpellTab.allCases {
            let source = tab == .aoe ? area : plain
            let s = sorts[tab] ?? LvBestSpellSort(column: tab.rankColumn, desc: true)
            var table = LvBestSpellsTable()
            for row in source where tab.admits(row.metrics) {
                if row.outOfEra { table.outOfEra.append(row) } else { table.shown.append(row) }
            }
            table.shown = sort(table.shown, s)
            table.outOfEra = sort(table.outOfEra, s)
            out.tabs[tab] = table
        }
        let aoe = out.tabs[.aoe] ?? LvBestSpellsTable()
        out.aoeTargets = LvAoeSpells.assumptionLabel((aoe.shown + aoe.outOfEra).map(\.hits))
        return out
    }

    static let searchCap = 50

    /// The whole corpus, not just the loadout's — a search answers the question the player typed.
    /// Rows the loadout does not own carry their class levels instead of a level chip.
    static func search(spells: [LvCatalogSpell], query: String, classes: [String], level: Int,
                       tab: LvBestSpellTab, sort s: LvBestSpellSort,
                       observed: [String: Int], simulate: Int)
    -> (rows: [LvBestSpellRow], matched: Int, hidden: Int, elsewhere: Int) {
        let tokens = LvSpellCatalogue.foldApostrophes(query.lowercased())
            .split(whereSeparator: { $0 == " " }).map(String.init).filter { !$0.isEmpty }
        if tokens.isEmpty { return ([], 0, 0, 0) }
        let want = Set(classes)
        var out: [LvBestSpellRow] = []
        var elsewhere = 0
        var seen = Set<String>()
        for spell in spells {
            guard !seen.contains(spell.key) else { continue }
            guard tokens.allSatisfy({ matches(spell, token: $0) }) else { continue }
            seen.insert(spell.key)
            if tab == .aoe, !LvAoeSpells.isAe(spell.targetType) { elsewhere += 1; continue }
            let owned = spell.at.filter { $0.level <= level && want.contains($0.cls) }
            let gainedAt = owned.map(\.level).min() ?? spell.at.map(\.level).min() ?? 0
            let observedRank = LvSpellLines.observedRank(observed, spell.name)
            let rank = LvSpellScale.effective(observed: observedRank, simulated: simulate)
            let hits = tab == .aoe
                ? LvAoeSpells.hits(waves: 1, targets: LvAoeSpells.defaultMaxTargets, cap: LvAoeSpells.defaultMaxTargets) : 1
            guard let m = LvSpellCatalogue.metrics(spell, level: level, rank: rank, hits: hits),
                  tab.admits(m) else { elsewhere += 1; continue }
            out.append(LvBestSpellRow(name: spell.name, gainedAt: gainedAt,
                                    classes: Set(owned.map(\.cls)).sorted(), mana: spell.mana,
                                    metrics: m, outOfEra: spell.outOfEra, rank: rank,
                                    observedRank: observedRank, hits: hits,
                                    levels: spell.at, owned: !owned.isEmpty))
        }
        let sorted = sort(out, s)
        return (Array(sorted.prefix(searchCap)), sorted.count, max(0, sorted.count - searchCap), elsewhere)
    }

    /// One token: a class code or display name matches the spell's class list, `level:N` or a bare
    /// range matches its levels, anything else is a substring of the search surface.
    private static func matches(_ spell: LvCatalogSpell, token: String) -> Bool {
        if token.hasPrefix("class:") {
            let want = String(token.dropFirst(6)).uppercased()
            return spell.at.contains { $0.cls == want }
        }
        if token.hasPrefix("level:") || token.hasPrefix("lvl:") {
            let value = String(token.drop(while: { $0 != ":" }).dropFirst())
            if let n = Int(value) { return spell.at.contains { $0.level == n } }
        }
        if let dash = token.firstIndex(where: { $0 == "-" }), dash != token.startIndex,
           let lo = Int(token[token.startIndex..<dash]), let hi = Int(token[token.index(after: dash)...]) {
            return spell.at.contains { $0.level >= min(lo, hi) && $0.level <= max(lo, hi) }
        }
        if let n = Int(token) { return spell.at.contains { $0.level == n } || spell.searchText.contains(token) }
        if token.count == 3, spell.at.contains(where: { $0.cls.lowercased() == token }) { return true }
        return spell.searchText.contains(token)
    }
}

/// `+1 out of era` — the wiki's verdict on a spell's page, as the disclosure's own label.
func lvOutOfEraLabel(_ count: Int) -> String { "+\(count) out of era" }
