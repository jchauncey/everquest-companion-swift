// The three committed catalogs the resist fold consults, and the fourth it refuses
// (fold/src/modules/resist/catalog.rs).
//
// It never reads the client's `spells_us.txt`: everything a row records is something the log
// printed, so the ledger means something without a file this project may not redistribute, and a
// patch that retunes a spell costs a re-estimate rather than a re-fold. What it does consult:
//
//   * `mobs.json` — a creature's level when no `/con` has stated one, and, as a side effect, "the
//     catalog has heard of this name", which admits a proper-named NPC as caster and as target.
//   * `bosses.json` — the one place this tree states that two spellings are one creature.
//   * the wiki spell catalog (`SpellDb`) — three facts and no more: is the spell a song, is a
//     landing sentence known for it, is it a resist debuff.
//
// The lazy statics memoize no fold answer: each table is a pure function of committed bytes, so a
// second `Fold` in the process cannot observe one as different.
import Foundation
import EQLog
import EQData

/// One row of `mobs.json`, cut down to what the resist fold reads. The scrape carries `zones`,
/// `drops` and `loc` too; naming only these three is the claim that none of them is consulted.
private struct MobRow: Decodable {
    var page: String
    var name: String
    var level: String?
}

private struct MobFile: Decodable {
    var mobs: [MobRow]?
}

private struct BossTarget: Decodable {
    var name: String
    var match: [String]?
}

private struct BossFile: Decodable {
    var targets: [BossTarget]?
}

/// One creature and every spelling the roster states for it.
public struct MobIdentity: Sendable {
    /// The name to ask the catalog with: the roster's own `name`, never what a surface displays.
    public var canonical: String
    /// Every `mobKey` the creature answers to, canonical key first.
    public var keys: [String]
    /// The roster stated more than one spelling for this creature.
    public var aliased: Bool
}

/// The three facts the fold projects out of the wiki spell catalog.
public struct ResistSpellFacts: Sendable {
    /// The Bard is the only class the catalog says can learn it. "Only" is load-bearing: a handful of
    /// lines are shared with other classes and those roll once per cast like anything else.
    public var song: Bool = false
    /// The catalog knows a cast-on-other sentence, so every pulse that lands prints one and the
    /// denominator is exact — lands plus resists, with nothing reconstructed.
    public var landing: Bool = false
    /// The level the catalog says a bard learns this at, or nil when it names no class.
    public var learnedAt: Int64? = nil
    /// An effect line that opens with `Decrease <axis> Resist`. Anchored, because a stem match would
    /// find "Resist" inside a spell name.
    public var resistDebuff: Bool = false
}

public enum ResistCatalog {
    // MARK: - The mob-name fold

    /// `consider.rs mob_key`, which this tree keeps in one place: the resist fold keys every row and
    /// every catalog lookup through the same fold a `/con` is filed under.
    public static func mobKey(_ name: String) -> String { EQFold.mobKey(name) }

    // MARK: - mobs.json

    /// Keyed by the page's `|name` (the in-game spelling a `/con` prints) first, then by the wiki page
    /// title, which only fills gaps — so a real mob's own name can never be displaced by another
    /// page's title. Both passes key through `mobKey`.
    ///
    /// The stored value is the `level` free text and nothing else: the inner optional answers "what
    /// level", the outer one answers "have you heard of this name".
    private static let mobLevels: [String: String?] = {
        guard let text = EQData.text("mobs.json"),
              let file = try? JSONDecoder().decode(MobFile.self, from: Data(text.utf8)) else {
            fatalError("mobs.json is not readable")
        }
        let mobs = file.mobs ?? []
        var byName: [String: String?] = [:]
        for m in mobs {
            let key = mobKey(m.name)
            if !key.isEmpty && byName.index(forKey: key) == nil { byName.updateValue(m.level, forKey: key) }
        }
        for m in mobs {
            let key = mobKey(m.page)
            if !key.isEmpty && byName.index(forKey: key) == nil { byName.updateValue(m.level, forKey: key) }
        }
        return byName
    }()

    /// The catalog's row for a mob, or nil when it has none. The inner optional is the row's
    /// free-text `level`, which is itself frequently absent.
    public static func localMobEntry(_ name: String) -> String?? { mobLevels[mobKey(name)] }

    /// True when the committed catalog has heard of this name at all.
    public static func catalogKnows(_ name: String) -> Bool { mobLevels.index(forKey: mobKey(name)) != nil }

    // MARK: - bosses.json

    /// A target whose `name` and every `match` collapse to one key is not indexed at all, so every
    /// unaliased name gets the trivial identity and runs the ordinary path.
    private static let aliasIndex: [String: MobIdentity] = {
        guard let text = EQData.text("bosses.json"),
              let file = try? JSONDecoder().decode(BossFile.self, from: Data(text.utf8)) else {
            fatalError("bosses.json is not readable")
        }
        var out: [String: MobIdentity] = [:]
        for t in file.targets ?? [] {
            var keys: [String] = []
            for spelling in [t.name] + (t.match ?? []) {
                let k = mobKey(spelling)
                if !k.isEmpty && !keys.contains(k) { keys.append(k) }
            }
            if keys.count < 2 { continue }
            let id = MobIdentity(canonical: t.name, keys: keys, aliased: true)
            // A key claimed by two targets keeps the first.
            for k in keys where out.index(forKey: k) == nil { out[k] = id }
        }
        return out
    }()

    /// Any spelling to the one identity the roster states, or to itself when the roster has never
    /// heard of it.
    public static func resolveMobIdentity(_ name: String) -> MobIdentity {
        let key = mobKey(name)
        if let known = aliasIndex[key] { return known }
        return MobIdentity(canonical: name, keys: key.isEmpty ? [] : [key], aliased: false)
    }

    // MARK: - The wiki spell catalog

    private static let resistDebuffLine =
        Re("(?i)^Decrease\(JS.S)+(?:Magic|Fire|Cold|Poison|Disease|All)\(JS.S)+Resists?(?-u:\\b)")

    private static let spellFactsTable: [String: ResistSpellFacts] = {
        var out: [String: ResistSpellFacts] = [:]
        for (key, entry) in SpellDb.shared().byKeyEntries() {
            let levels = parseSpellClassLevels(entry.classes)
            let resistDebuff = (entry.effects ?? []).contains { resistDebuffLine.isMatch(JS.trim($0)) }
            out[key] = ResistSpellFacts(
                song: !levels.isEmpty && levels.allSatisfy { $0.0 == "BRD" },
                landing: entry.msgCastOnOther.map { !$0.isEmpty } ?? false,
                // Levels are lowest-per-class and sorted ascending, so the first row is the level a
                // bard gets the line at.
                learnedAt: levels.first.map { $0.1 },
                resistDebuff: resistDebuff)
        }
        return out
    }()

    /// The facts for a spell name.
    ///
    /// The two key spellings are deliberately different: the table is built under the spell db's own
    /// canon key (case-insensitive rank tail) and the query uses `spellCanonKey` (case-sensitive).
    public static func factsForKey(_ spellKey: String) -> ResistSpellFacts {
        spellFactsTable[spellKey] ?? ResistSpellFacts()
    }

    /// Asked with a display name, so it canonicalizes first.
    public static func isResistDebuff(_ display: String) -> Bool {
        factsForKey(Names.spellCanonKey(display)).resistDebuff
    }

    private static let classLevelRe =
        Re("\\*\(JS.S)*([A-Za-z][A-Za-z ]*?)\(JS.S)*-\(JS.S)*Level\(JS.S)*([0-9]+)")

    /// The per-class entry levels off a wiki `classes` blob: lowest per class, sorted by level then
    /// class code. Neither caller can see the tie order; the sort is kept so this stays the same
    /// function as the app's rather than a subset of it.
    static func parseSpellClassLevels(_ classes: String?) -> [(String, Int64)] {
        guard let classes else { return [] }
        var best: [(String, Int64)] = []
        for m in classLevelRe.allCaptures(classes) {
            guard let cls = abbrByName(JS.trim(m.s(1)).lowercased()) else { continue }
            guard let level = Int64(m.s(2)) else { continue }
            if let i = best.firstIndex(where: { $0.0 == cls }) {
                if level < best[i].1 { best[i].1 = level }
            } else {
                best.append((cls, level))
            }
        }
        best.sort { a, b in a.1 != b.1 ? a.1 < b.1 : rustLess(a.0, b.0) }
        return best
    }

    /// The wiki class name to the `/who` code, both spellings of Shadow Knight included.
    static func abbrByName(_ name: String) -> String? {
        switch name {
        case "bard": return "BRD"
        case "beastlord": return "BST"
        case "berserker": return "BER"
        case "cleric": return "CLR"
        case "druid": return "DRU"
        case "enchanter": return "ENC"
        case "magician": return "MAG"
        case "monk": return "MNK"
        case "necromancer": return "NEC"
        case "paladin": return "PAL"
        case "ranger": return "RNG"
        case "rogue": return "ROG"
        case "shadow knight", "shadowknight": return "SHD"
        case "shaman": return "SHM"
        case "warrior": return "WAR"
        case "wizard": return "WIZ"
        default: return nil
        }
    }

    /// How many of a `/who` row's class codes are non-hybrid casters: the `-15`-each half of the
    /// overchannel adjust. An unknown loadout answers 0, the honest floor.
    ///
    /// The seven are the game's own "pure caster" grouping, spelled out rather than read out of a
    /// data file so a catalog change cannot silently move what a resist estimate means.
    public static func casterClassCount(_ classes: [String]) -> Int64 {
        Int64(classes.filter { c in
            switch JS.trim(c).uppercased() {
            case "CLR", "DRU", "ENC", "MAG", "NEC", "SHM", "WIZ": return true
            default: return false
            }
        }.count)
    }

    private static let digitsRe = Re("[0-9]+")

    /// The catalog's `level` is free text scraped off a wiki page: "39", "39 - 43", "45-50". Two
    /// numbers is a range, one is a level, anything else says nothing and is refused rather than
    /// guessed at.
    public static func parseCatalogLevel(_ text: String?) -> (Int64, Int64)? {
        guard let text else { return nil }
        let nums = digitsRe.allCaptures(text).prefix(2).map { String($0.whole) }
        if nums.isEmpty { return nil }
        // A digit run too long for an `Int64` would fail the `hi > 200` test anyway; refusing it here
        // is the same verdict by a shorter road.
        guard let lo = Int64(nums[0]) else { return nil }
        let hi: Int64
        if nums.count > 1 {
            guard let h = Int64(nums[1]) else { return nil }
            hi = h
        } else {
            hi = lo
        }
        if lo <= 0 || hi < lo || hi > 200 { return nil }
        return (lo, hi)
    }
}
