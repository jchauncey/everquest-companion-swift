// The combo module's shared vocabulary (fold/src/modules/combo.rs's class set +
// fold/src/modules/combo/evidence.rs's committed tables and the spell → class index).
//
// The tables are not interchangeable: `Frenzy`, `Smite` and `Feign Death` are BOTH client skill
// names AND Template:Spellpage spell names with different class sets, so a `skillUp` resolves
// against classes.json `skills` and only that, and a `castBegin` resolves against spells.json (then
// classes.json `abilities`) and only that. Unioning them would misattribute a whole family of
// skill-ups.
//
// The spell → class table involves no scrape: `spells.json` already carries a `classes` field per
// spell, straight from Template:Spellpage. It is keyed by `spellCanonKey` because casts print a
// Roman rank, and two spells canonicalizing to one key UNION their class sets — union is the
// conservative direction, so a collision can only make an inference less certain, never wrong.
import Foundation
import EQLog
import EQData
import EQCompanionCore

/// The 16 EQ Legends classes, by their `/who` three-letter code. Note SHD, not SHK: the wiki spells
/// the class both "Shadow Knight" and "Shadowknight" and both canonicalize here.
public typealias ClassAbbr = String

/// Every class code, sorted — the closed set behind `asClassAbbr` and an unknown slot's candidate
/// list.
public let classAbbrs: [ClassAbbr] = [
    "BER", "BRD", "BST", "CLR", "DRU", "ENC", "MAG", "MNK", "NEC", "PAL", "RNG", "ROG", "SHD",
    "SHM", "WAR", "WIZ",
]

private let classAbbrSet: Set<ClassAbbr> = Set(classAbbrs)

/// `shared/classCombo.ts MAX_COMBO_SLOTS` — EQ Legends runs up to three classes at once.
public let maxComboSlots: Int = 3

/// `isClassAbbr` as a narrowing rather than a predicate: an unknown code is dropped, never coerced.
public func asClassAbbr(_ v: String) -> ClassAbbr? { classAbbrSet.contains(v) ? v : nil }

/// `spellClasses.ts INDEX` — canon key → the classes that can cast it.
public typealias SpellClassIndex = [String: [ClassAbbr]]

// MARK: - classes.json

/// The committed class tables. `ready` is data availability, not health: classes.json ships as an
/// empty stub before the scrape runs, and an empty stance table would silently turn every inference
/// into an unknown slot.
struct ComboTables {
    var stances: [String: [ClassAbbr]] = [:]
    var invocations: [String: [ClassAbbr]] = [:]
    var skills: [String: [ClassAbbr]] = [:]
    /// Abilities that are NOT Template:Spellpage pages — `Lay on Hands`, `Holy Steed`, `Harm Touch`
    /// and some seventy more. Keyed by `spellCanonKey`, because casts carry a Roman rank the table
    /// does not.
    var abilities: [String: [ClassAbbr]] = [:]
    var ready: Bool = false
}

/// `classes.json` list → the closed `ClassAbbr` set. An unknown code is dropped, never coerced.
private func abbrs(_ list: JSONValue) -> [ClassAbbr] {
    (list.array ?? []).compactMap { $0.string.flatMap(asClassAbbr) }
}

private func table(_ v: JSONValue) -> [String: [ClassAbbr]] {
    var out: [String: [ClassAbbr]] = [:]
    for (k, list) in v.object ?? [:] { out[k] = abbrs(list) }
    return out
}

let comboTables: ComboTables = {
    guard let text = EQData.text("classes.json"), let raw = try? JSONValue.parse(text) else {
        fatalError("classes.json is not readable")
    }
    var abilities: [String: [ClassAbbr]] = [:]
    for (k, list) in raw["abilities"].object ?? [:] { abilities[Names.spellCanonKey(k)] = abbrs(list) }
    return ComboTables(
        stances: table(raw["stances"]),
        invocations: table(raw["invocations"]),
        skills: table(raw["skills"]),
        abilities: abilities,
        ready: !(raw["stances"].object ?? [:]).isEmpty
    )
}()

/// `TABLES_READY` — see `ComboTables.ready`.
public func comboTablesReady() -> Bool { comboTables.ready }

// MARK: - the spell → class index

/// Wiki class name → `/who` code. The wiki spells the Shadow Knight both ways across its own spell
/// pages, and both canonicalize to SHD.
private func abbrByWikiName(_ name: String) -> ClassAbbr? {
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

/// `/\*\s*([A-Za-z][A-Za-z ]*?)\s*-\s*Level\s*\d+/g`, with JS's `\s` set and ASCII `\d` spelled out.
/// Each bullet is `* <Class> - Level <n>` with an optional trailing note; anything not of that shape
/// yields an empty list rather than a guess.
private let classBullet = Re("\\*\(JS.S)*([A-Za-z][A-Za-z ]*?)\(JS.S)*-\(JS.S)*Level\(JS.S)*[0-9]+")

/// `parseSpellClassString` — one `classes` field → the classes it names, deduped and sorted.
public func parseSpellClassString(_ classes: String?) -> [ClassAbbr] {
    guard let classes else { return [] }
    var found: [ClassAbbr] = []
    for c in classBullet.allCaptures(classes) {
        let name = JS.trim(c.s(1)).lowercased()
        if let abbr = abbrByWikiName(name), !found.contains(abbr) { found.append(abbr) }
    }
    return found.sorted()
}

/// Which classes can cast each spell, off the catalog's `classes` strings — built once from the DB
/// the parser already loaded, with removals and corrections applied.
public func spellClassIndex(_ db: SpellDb) -> SpellClassIndex {
    var index: [String: Set<ClassAbbr>] = [:]
    for spell in db.spells {
        let classes = parseSpellClassString(spell.classes)
        if classes.isEmpty { continue }
        index[Names.spellCanonKey(spell.name), default: []].formUnion(classes)
    }
    // `classesForSpell` sorts on the way out, so the stored form is sorted once instead.
    return index.mapValues { $0.sorted() }
}

// MARK: - Levels (NOT A PORT)

/// `classBullet` with the level captured too: `* Shaman - Level 49` → ("SHM", 49).
private let classLevelBullet = Re("\\*\(JS.S)*([A-Za-z][A-Za-z ]*?)\(JS.S)*-\(JS.S)*Level\(JS.S)*([0-9]+)")

/// Spell canon key → the level each class gets it at (the lowest across the spell's ranks).
public typealias SpellClassLevelIndex = [String: [ClassAbbr: Int]]

/// Which class gets each spell first, so a spell two classes of a loadout share can be credited to
/// the one that has it earliest. Swift-only: the Combat tab's class colouring reads it; the combo
/// module's inference does not.
public func spellClassLevelIndex(_ db: SpellDb) -> SpellClassLevelIndex {
    var index: SpellClassLevelIndex = [:]
    for spell in db.spells {
        guard let classes = spell.classes else { continue }
        for c in classLevelBullet.allCaptures(classes) {
            guard let abbr = abbrByWikiName(JS.trim(c.s(1)).lowercased()), let level = Int(c.s(2)) else { continue }
            let key = Names.spellCanonKey(spell.name)
            index[key, default: [:]][abbr] = min(index[key]?[abbr] ?? Int.max, level)
        }
    }
    return index
}
