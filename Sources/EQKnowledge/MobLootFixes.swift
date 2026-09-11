// Corrections to the wiki's stated mob loot.
//
// `mobs.json` carries what each wiki page's drop table says, verbatim - and the wiki sometimes
// files one creature under two pages. Plane of Hate has three: the game's `a revultant rat` has a
// second page as `a repulsive rat`, `a loathling lich` one as `a loathing lich`, and
// ``Innoruuk`s Chosen`` one under a straight apostrophe. The tables are DISJOINT, so whichever
// page the card reaches shows half the creature's loot - and for the rat the missing half is all
// fifteen of its warrior pieces.
//
// A split table is worse than a thin one: the card's promise is that it says what the thing drops,
// and a player reads its silence as "this mob does not drop that".
//
// So `mobLootFixes.json` corrects those rows under the two rules `mobLocFixes.json` states for
// positions, kept deliberately identical:
//
//   1. EVERY FIX IS GUARDED, and the guard is the error itself rather than a copy of the data.
//      An ALIAS applies only while the corpus still carries the alias as its own entry: when a
//      re-scrape merges the two pages, the alias resolves to nothing and the fix retires. A stated
//      DROP applies only while the page still lacks it. Neither can outlive what it corrects, and
//      neither can fire twice.
//   2. EVERY FIX IS CITED. `why` names the evidence - which spelling the game actually writes, and
//      which drops were seen under it.
//
// Merging is a UNION IN THE CANONICAL PAGE'S ORDER: the mob's own drops first, in the order the
// wiki states them, then the alias's own, so a card's familiar rows do not move when a fix lands.
// The alias entry is then dropped from the catalog entirely - it is not a mob, and leaving it in
// would put a second creature in the zone's list and offer a name the game never prints to search.
//
// Applied in TWO readers of `mobs.json`, on the raw array each time: `MobIndex.build` (the
// engine's `knowledge.mob`) and the app's `GameData.mobs` (the map's pins, zone list and mob
// card). Both must see one creature, or the map would still show two rats.
//
// This corrects the CATALOG, not your history: `dropsSeen` is gathered from your own log by
// identity and is untouched here.
import Foundation
import EQCompanionCore
import EQData

public enum MobLootFixes {
    /// One "these two pages are one creature" statement.
    public struct Alias {
        /// The page that survives - the spelling the game writes, and the display name that stays.
        public var mob: String
        /// The page folded into it and then removed from the catalog.
        public var alias: String
        /// The zone both pages must still state, so a fix can never merge two creatures that merely
        /// share a name across zones.
        public var zone: String
        public var why: String
        public init(mob: String, alias: String, zone: String, why: String) {
            self.mob = mob; self.alias = alias; self.zone = zone; self.why = why
        }
    }

    /// One "this page is missing a drop it plainly has" statement.
    public struct Drops {
        public var mob: String
        public var add: [String]
        public var why: String
        public init(mob: String, add: [String], why: String) { self.mob = mob; self.add = add; self.why = why }
    }

    public struct Fixes {
        public var aliases: [Alias] = []
        public var drops: [Drops] = []
        public init(aliases: [Alias] = [], drops: [Drops] = []) { self.aliases = aliases; self.drops = drops }
    }

    /// The committed corrections, parsed once. An unreadable or absent file is NOT fatal: the
    /// catalog is the thing that must load, and a lost correction costs a partial card, not a crash.
    public static let shipped: Fixes = {
        guard let text = EQData.text("mobLootFixes.json"),
              let file = try? JSONValue.parse(text) else { return Fixes() }
        return parse(file)
    }()

    public static func parse(_ file: JSONValue) -> Fixes {
        var out = Fixes()
        for a in file["aliases"].array ?? [] {
            guard let mob = a["mob"].string, let alias = a["alias"].string, let zone = a["zone"].string
            else { continue }
            out.aliases.append(Alias(mob: mob, alias: alias, zone: zone, why: a["why"].string ?? ""))
        }
        for d in file["drops"].array ?? [] {
            guard let mob = d["mob"].string else { continue }
            let add = (d["add"].array ?? []).compactMap(\.string)
            if add.isEmpty { continue }
            out.drops.append(Drops(mob: mob, add: add, why: d["why"].string ?? ""))
        }
        return out
    }

    /// Apply every fix whose guard holds to the raw `mobs` array, before it is indexed.
    ///
    /// Works on the ARRAY rather than the built index because the `Innoruuk`s Chosen` pair folds to
    /// one `mobKey`: by the time `byName` exists one of the two is already gone. Matching here is
    /// by EXACT NAME, which is what makes a fix say precisely which page it means.
    public static func apply(_ mobs: [JSONValue], _ fixes: Fixes = shipped) -> [JSONValue] {
        var out = mobs
        for a in fixes.aliases {
            guard let m = index(of: a.mob, in: out, zone: a.zone),
                  let x = index(of: a.alias, in: out, zone: a.zone),
                  m != x
            else { continue }                     // the guard: both pages still there, still split
            out[m].set("drops", .array(union(out[m]["drops"].array ?? [], out[x]["drops"].array ?? [])))
            out.remove(at: x)
        }
        for d in fixes.drops {
            guard let m = index(of: d.mob, in: out, zone: nil) else { continue }
            let have = out[m]["drops"].array ?? []
            let keys = Set(have.compactMap { $0.string?.lowercased() })
            // The guard: only what the page still lacks. A re-scrape that adds it makes this inert.
            let missing = d.add.filter { !keys.contains($0.lowercased()) }
            if missing.isEmpty { continue }
            out[m].set("drops", .array(have + missing.map { .string($0) }))
        }
        return out
    }

    /// The first entry with this exact name, optionally required to state this zone.
    private static func index(of name: String, in mobs: [JSONValue], zone: String?) -> Int? {
        mobs.firstIndex { m in
            guard m["name"].string == name else { return false }
            guard let zone else { return true }
            return (m["zones"].array ?? []).contains { $0.string == zone }
        }
    }

    /// Canonical order first, then the alias's own, de-duped case-insensitively.
    private static func union(_ mine: [JSONValue], _ theirs: [JSONValue]) -> [JSONValue] {
        var seen = Set(mine.compactMap { $0.string?.lowercased() })
        var out = mine
        for d in theirs {
            guard let s = d.string, seen.insert(s.lowercased()).inserted else { continue }
            out.append(d)
        }
        return out
    }
}
