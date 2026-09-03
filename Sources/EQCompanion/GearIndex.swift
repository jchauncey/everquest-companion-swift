// The gear corpus, indexed once off the main thread — a port of `src/main/planner/gearIndex.ts`
// and `src/shared/planner/{gear,era,weaponType,normalize}.ts`.
//
// THE LOAD-BEARING RULE (the Electron index's, kept): every sort and filter key must be computable
// AT ANY PLUS-STATE by a pure map over the rows, never by rebuilding the index. So a row carries a
// NUMERIC BASE VECTOR keyed the way `GearUpgrade.normalizeStatKey` spells things, and the upgrade
// slider is `rows.map { $0.scaled(state) }`.
//
// 11.5k pages come off disk as JSON, so the whole build runs in a detached task and hands the
// finished value type back to the main actor. Nothing here touches `GameData`, which is
// MainActor-isolated; the roots are captured before the hop.
import Foundation
import Observation
import EQCompanionCore

// MARK: - Vocabulary

/// The wiki's equip slots, in the order the pickers list them.
let equipSlots: [String] = [
    "HEAD", "FACE", "EAR", "NECK", "SHOULDERS", "BACK", "CHEST", "ARMS", "WRIST", "HANDS",
    "FINGER", "WAIST", "LEGS", "FEET", "PRIMARY", "SECONDARY", "RANGE", "AMMO"
]

/// The sixteen class abbreviations, in the order the pickers list them.
let classAbbrs: [String] = [
    "BER", "BRD", "BST", "CLR", "DRU", "ENC", "MAG", "MNK",
    "NEC", "PAL", "RNG", "ROG", "SHD", "SHM", "WAR", "WIZ"
]

/// The comparison stats, in the order a table draws its columns.
let gearStatKeys: [String] = [
    "AC", "STR", "STA", "AGI", "DEX", "WIS", "INT", "CHA", "HP", "MP", "END",
    "HP_REGEN", "MANA_REGEN", "END_REGEN", "ATTACK", "HASTE",
    "SV_FIRE", "SV_COLD", "SV_MAGIC", "SV_DISEASE", "SV_POISON", "SV_VOID",
    "SV_CORRUPTION", "SV_CHROMATIC", "SV_PRISMATIC", "SV_ALL",
    "DMG", "DELAY", "DMG_BONUS", "BACKSTAB", "RANGE", "WEIGHT"
]

private let gearStatKeySet = Set(gearStatKeys)

/// Keys the table may draw as a numeric column: the corpus's own stats, plus the ratio it computes.
/// A sort key outside this set names a TEXT column and must never be mistaken for a stat.
let gearNumericColumnKeys: Set<String> = gearStatKeySet.union(["RATIO"])

/// The columns only a weapon fills in. Measured against the corpus: 86% of PRIMARY, 79% of AMMO,
/// 69% of RANGE and 64% of SECONDARY pages state a damage, against 0% of every armour slot — so on
/// an armour-only filter these three are a screenful of blank cells and a ratio that sorts nothing.
let gearWeaponColumnKeys: [String] = ["DMG", "DELAY", "RATIO"]

/// The slots whose pages state those columns.
let weaponEquipSlots: Set<String> = ["PRIMARY", "SECONDARY", "RANGE", "AMMO"]

/// Percent-valued keys — a display concern, and the reason a cell can read `41%`.
let gearPercentStatKeys: Set<String> = ["HASTE"]

// MARK: - Slot / class normalization (shared/planner/normalize.ts)

private let slotRenames: [String: String] = ["SHOULDER": "SHOULDERS", "FINGERS": "FINGER", "SECONDAY": "SECONDARY"]
private let slotNoise: Set<String> = ["/", "-", "&", "OR", "AND"]
private let slotSet = Set(equipSlots)

private func cleanToken(_ raw: String) -> String {
    var t = raw.trimmingCharacters(in: .whitespaces).uppercased()
    while let last = t.last, ",.;:".contains(last) { t.removeLast() }
    return t
}

/// The verbatim `Slot:` text → canonical equip slots. `"RANGE PRIMARY SECONDARY"` names three.
/// A token the table does not know is dropped rather than coerced into the nearest member.
func normalizeSlotTokens(_ slot: String?) -> [String] {
    var out: [String] = []
    for raw in (slot ?? "").split(whereSeparator: { $0.isWhitespace }) {
        let token = cleanToken(String(raw))
        if token.isEmpty || slotNoise.contains(token) { continue }
        guard let mapped = slotRenames[token] ?? (slotSet.contains(token) ? token : nil) else { continue }
        if !out.contains(mapped) { out.append(mapped) }
    }
    return out
}

private let classAbbrSet = Set(classAbbrs)

/// The `Class:` list → the classes that can actually use the item. `ALL` → all 16;
/// `ALL except NEC WIZ` → the complement; `NONE` → `[]`. An empty answer means UNKNOWN-or-nobody
/// and is never filtered out: nine pages write a bare `Class: ALL except` with the list missing.
func normalizeClasses(_ classes: [String]) -> [String] {
    var all = false, none = false, sawExcept = false
    var listed: [String] = [], excluded: [String] = []
    for token in classes {
        let t = cleanToken(token)
        if t == "EXCEPT" { sawExcept = true }
        else if t == "ALL" { all = true }
        else if t == "NONE" { none = true }
        else if classAbbrSet.contains(t) {
            if sawExcept { if !excluded.contains(t) { excluded.append(t) } }
            else if !listed.contains(t) { listed.append(t) }
        }
        // Anything else — "(35)", "(48)" — is a level annotation, not a class. Dropped.
    }
    if none { return [] }
    if sawExcept {
        if excluded.isEmpty { return [] }
        let base = all ? classAbbrs : listed
        return base.filter { !excluded.contains($0) }
    }
    if all { return classAbbrs }
    return listed
}

// MARK: - Weapon types (shared/planner/weaponType.ts)

let weaponTypes: [String] = ["1HS", "1HB", "1HP", "H2H", "2HS", "2HB", "2HP", "ARCHERY", "THROWING"]
let weaponCategories: [String] = ["ONE_HAND", "TWO_HAND", "RANGED"]
let weaponPicks: [String] = weaponCategories + weaponTypes

let weaponPickLabel: [String: String] = [
    "ONE_HAND": "One-handed", "TWO_HAND": "Two-handed", "RANGED": "Ranged",
    "1HS": "1H Slashing", "1HB": "1H Blunt", "1HP": "1H Piercing", "H2H": "Hand to Hand",
    "2HS": "2H Slashing", "2HB": "2H Blunt", "2HP": "2H Piercing",
    "ARCHERY": "Archery", "THROWING": "Throwing"
]

let weaponCategoryMembers: [String: [String]] = [
    "ONE_HAND": ["1HS", "1HB", "1HP", "H2H"],
    "TWO_HAND": ["2HS", "2HB", "2HP"],
    "RANGED": ["ARCHERY", "THROWING"]
]

/// The fold over the fifteen spellings the corpus states. Only measured spellings are here: the
/// classic piercing skill is spelled bare on 322 pages, and `Throwingv1/v2` is the wiki's own
/// template version suffix stuck to one skill.
private let skillTypes: [String: String] = [
    "1H SLASHING": "1HS", "1H SLASH": "1HS", "1H BLUNT": "1HB",
    "PIERCING": "1HP", "1H PIERCING": "1HP", "HAND TO HAND": "H2H",
    "2H SLASHING": "2HS", "2H BLUNT": "2HB", "2H PIERCING": "2HP",
    "ARCHERY": "ARCHERY", "THROWING": "THROWING", "THROWINGV1": "THROWING", "THROWINGV2": "THROWING"
]

/// What kind of weapon this skill names, or nil when the string names none — which covers the rows
/// that state no skill at all and the one page that states `SHIELD`.
func weaponTypeOf(_ skill: String?) -> String? {
    guard let skill else { return nil }
    let k = skill.uppercased()
        .replacingOccurrences(of: "[^A-Z0-9]+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
    return skillTypes[k]
}

func weaponPickCovers(_ pick: String, _ type: String) -> Bool {
    if let members = weaponCategoryMembers[pick] { return members.contains(type) }
    return pick == type
}

// MARK: - Sockets and the haste lock (shared/planner/{normalize,rules}.ts)

let socketTypes: [String] = ["focus", "click", "worn", "proc"]
let socketLabels: [String: String] = ["focus": "Focus", "click": "Click", "worn": "Worn", "proc": "Proc"]

/// The corpus spells a proc `Combat Effect:` — a planner filtering on `kind == "proc"` would show
/// an empty Proc tab. A bare `Effect:` line named no socket, so it maps to nothing and is excluded.
func socketTypeOf(kind: String) -> String? {
    switch kind {
    case "combat", "proc": return "proc"
    case "worn": return "worn"
    case "focus": return "focus"
    case "click": return "click"
    default: return nil
    }
}

/// R1: the item tier a donor must be merged to before that socket's effect can be EXTRACTED.
func extractionTier(_ socket: String) -> Int {
    switch socket {
    case "focus": return 1
    case "click": return 2
    case "worn": return 3
    default: return 4
    }
}

/// R4: what an extraction costs. `xp = 2^tier - 1` D0 merges, or one D4 drop.
func extractionCost(_ tier: Int) -> (d0: Int, d4: Int) {
    let xp = (1 << tier) - 1
    return (xp, xp <= 15 ? 1 : 0)
}

private let hasteEffects: Set<String> = [
    "haste", "brittle haste", "aanya's quickening", "alacrity", "celerity", "quickness",
    "flurry", "swift like the wind", "swift spirit", "wonderous rapidity",
    "blessing of the grove", "speed of the shissar"
]

/// The cast-time FOCUS families. Named explicitly so "contains haste" can never capture them —
/// they shorten casting time, a different mechanic from attack speed.
private let hasteFocusFamilies: Set<String> = [
    "spell haste", "affliction haste", "summoning haste", "enhancement haste", "reanimation haste"
]

private func effectFamily(_ name: String) -> String {
    name.trimmingCharacters(in: .whitespaces)
        .replacingOccurrences(of: "\\s+[IVXivx]+$", with: "", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
        .lowercased()
}

/// R3: haste cannot travel as an exaltation. Which effects ARE haste is knowledge, not a substring
/// test, so this is an exact match against a hand-authored set.
func isHasteEffect(name: String, detail: String?) -> Bool {
    for text in [name, detail ?? ""] where !text.isEmpty {
        let family = effectFamily(text)
        if hasteFocusFamilies.contains(family) { return false }
        if hasteEffects.contains(family) { return true }
    }
    return false
}

// MARK: - Era (shared/planner/era.ts)

let eraOrder: [String] = ["classic", "kunark", "velious", "luclin"]

/// What EQ Legends currently ships. Flip this one line when Kunark launches.
let currentEra = "classic"
let eraLabels: [String: String] = ["classic": "Classic", "kunark": "Kunark", "velious": "Velious", "luclin": "Luclin"]
var currentEraLabel: String { eraLabels[currentEra] ?? currentEra }

func eraRank(_ era: String) -> Int { eraOrder.firstIndex(of: era) ?? eraOrder.count }

/// The item-page banner token → an expansion. Hand-authored: the tokens are not expansion names,
/// they are the wiki's own section headings and half of them name a PLACE. A token missing here is
/// undefined, never approximate.
private let tagEra: [String: String?] = [
    "classic": "classic", "sky": "classic", "fear": "classic", "hate": "classic",
    "temple": "classic", "paineel": "classic",
    "epics": "kunark", "epicquests": "kunark", "kunark": "kunark",
    "chardok": "kunark", "chardok revamp": "kunark",
    "velious": "velious", "luclin": "luclin", "unknown": nil
]

func eraFromTag(_ tag: String) -> String? {
    tagEra[tag.trimmingCharacters(in: .whitespaces).lowercased()] ?? nil
}

/// A MIRROR of the wiki's own `Template:PageEra` switch, `#default = out` included.
private let pageEra: [String: String] = [
    "classic": "in", "kunark": "out", "velious": "out", "luclin": "out",
    "chardok": "out", "chardokrevamp": "out", "fear": "in", "hate": "in",
    "hole": "in", "holevp": "out", "sky": "in", "stonebrunt": "in", "temple": "in",
    "warrens": "in", "warrensfearhaterevamp": "out", "fearhaterevamp": "out",
    "paineel": "in", "epics": "out", "epicquests": "out", "unknown": "out"
]

private func registerKey(_ tag: String) -> String {
    tag.trimmingCharacters(in: .whitespaces).lowercased()
        .replacingOccurrences(of: "[\\s_]+", with: "", options: .regularExpression)
}

func eraBadge(_ tag: String) -> String { pageEra[registerKey(tag)] ?? "out" }

/// Does this banner's OUT claim outrank the zones? True only for an `out` badge, and then only
/// while the expansion the token names has not shipped.
func eraBadgeOverrides(tag: String?, era: String) -> Bool {
    guard let tag, !tag.isEmpty, eraBadge(tag) == "out" else { return false }
    guard let named = eraFromTag(tag) else { return true }
    return eraRank(named) > eraRank(era)
}

enum EraVerdict: String, Sendable { case inEra = "in-era", outOfEra = "out-of-era", unknown }

/// Fold a set of drop zones into one verdict. ANY reachable source makes the item farmable, so an
/// in-era zone wins over an out-of-era sibling. Nothing resolving is `unknown`, never a warning.
func eraVerdict(zoneEras: [String?], era: String) -> EraVerdict {
    let ceiling = eraRank(era)
    var resolvedAny = false
    for found in zoneEras {
        guard let found else { continue }
        resolvedAny = true
        if eraRank(found) <= ceiling { return .inEra }
    }
    return resolvedAny ? .outOfEra : .unknown
}

/// Layer 0: an explicit out-of-era badge overrules the zones (a revamp replaces a classic zone's
/// contents; an epic piece dropping in Najena still needs a Kunark turn-in). Layer 1: any zone that
/// resolves is final in both directions. Layer 2: the banner speaks into silence.
func layeredVerdict(zoneEras: [String?], tag: String?, era: String = currentEra) -> EraVerdict {
    if eraBadgeOverrides(tag: tag, era: era) { return .outOfEra }
    let byZone = eraVerdict(zoneEras: zoneEras, era: era)
    if byZone != .unknown { return byZone }
    guard let tag, !tag.isEmpty, let tagged = eraFromTag(tag) else { return .unknown }
    return eraRank(tagged) <= eraRank(era) ? .inEra : .outOfEra
}

// MARK: - The row

struct GearEffectRow: Sendable, Hashable {
    var name: String
    var detail: String?
    /// the corpus's own kind, verbatim — `combat` is what the wiki spells a proc
    var kind: String
    /// the exaltation socket; nil when the line named none (a bare `Effect:`)
    var socket: String?
    /// merge tier this effect extracts at (R1) — present exactly when `socket` is
    var tierRequired: Int?
    /// R3 — attack haste never travels as an exaltation
    var hasteLocked: Bool
}

struct GearDrop: Sendable, Hashable {
    var mob: String
    var zone: String
}

/// One equippable item, described in NUMBERS. ABSENT MEANS THE ITEM STATED NONE — never zero: an
/// item with no `HASTE:` line is not an item with 0% haste.
/// One item's focus-exaltation, mirrored onto the gear row for display and filtering. See
/// `exaltations.json` and `GameData.Exaltation`.
struct GearExaltation: Sendable, Hashable {
    var effect: String
    var decaysAfter: Int?
    var category: [String]
    var description: String?
}

struct GearRow: Sendable, Identifiable, Hashable {
    var key: String
    var name: String
    var iconId: Int?
    var slots: [String]
    /// normalized abbreviations; `[]` means the page stated no class list, and is never hidden
    var classes: [String]
    var skill: String?
    var stats: [String: Int]
    var weight: Double?
    /// the one fact the vector cannot re-derive: does an upgrade grant this item a synthetic SV VOID
    var voidSynth: Bool
    var effects: [GearEffectRow]
    var eraTag: String?
    var drops: [GearDrop]
    var quest: Bool
    var playerCrafted: Bool
    /// item name + every effect name and parenthetical, lowercased once
    var searchKey: String
    var era: EraVerdict
    /// The item's focus-exaltation, from the wiki overlay — nil for items with none.
    var exaltation: GearExaltation?
    var id: String { key }

    /// The same row at `state` — the map the gear table runs on every slider move.
    func scaled(_ state: ItemUpgradeState) -> [String: Int] {
        let s = state.normalized
        if s.full == 0 && s.fraction == 0 { return stats }
        var out: [String: Int] = [:]
        out.reserveCapacity(stats.count + 1)
        for key in gearStatKeys {
            guard let base = stats[key] else { continue }
            out[key] = GearUpgrade.scale(key: key, base: base, state: s)
        }
        if voidSynth && s.full > 0 { out["SV_VOID"] = s.full }
        return out
    }

    var weaponType: String? { weaponTypeOf(skill) }
}

/// A weapon's damage ratio. `nil` for anything that is not a weapon, which is what keeps a ratio
/// sort from ranking 6,000 non-weapons at zero.
func damageRatio(_ stats: [String: Int]) -> Double? {
    guard let dmg = stats["DMG"], dmg != 0, let delay = stats["DELAY"], delay != 0 else { return nil }
    return Double(dmg) / Double(delay)
}

/// EFFECTIVE HP — raw HP plus raw STA, no soft cap modelled (the game's cap and conversion ratio
/// are numbers this repo has no measurement for). An item stating NEITHER has none at all.
func gearEffectiveHp(_ stats: [String: Int]) -> Int? {
    let hp = stats["HP"], sta = stats["STA"]
    if hp == nil && sta == nil { return nil }
    return (hp ?? 0) + (sta ?? 0)
}

// MARK: - The build

/// The finished corpus, plus what the census can say about it.
struct GearCorpus: Sendable {
    var rows: [GearRow] = []
    var byKey: [String: GearRow] = [:]
    /// `items.json`'s own `scrapedAt`, sliced to `YYYY-MM-DD` for the caption
    var scrapedAt: String?
    /// every donor row — one per (item, effect, socket) — for the Exaltations tab
    var donors: [DonorRow] = []
    /// Every zone any item in the corpus actually drops in, ascending. The Zones picker lists these
    /// rather than the whole 128-zone catalog: a zone nothing drops in is a filter that can only
    /// ever empty the table.
    var dropZones: [String] = []
}

/// One extractable effect on one item: the Exaltations tab's unit of work.
struct DonorRow: Sendable, Identifiable, Hashable {
    var key: String
    var name: String
    var iconId: Int?
    var slots: [String]
    var classes: [String]
    var effect: String
    var detail: String?
    var socket: String
    var tierRequired: Int
    var hasteLocked: Bool
    var era: EraVerdict
    var eraTag: String?
    var drops: [GearDrop]
    var quest: Bool
    var playerCrafted: Bool
    var searchKey: String
    var id: String { "\(key)\u{0}\(effect)\u{0}\(socket)" }
}

@MainActor
@Observable
final class GearIndex {
    static let shared = GearIndex()

    private(set) var corpus = GearCorpus()
    private(set) var ready = false
    private(set) var buildMs: Int = 0
    private var started = false

    var rows: [GearRow] { corpus.rows }
    var donors: [DonorRow] { corpus.donors }

    /// Kick the build once per process. 11.5k pages, so it runs detached and the view draws
    /// "Reading the item database…" until it lands.
    func start() {
        guard !started else { return }
        started = true
        let itemsURL = GameData.shared.roots.data.appendingPathComponent("items.json")
        let zonesURL = GameData.shared.roots.generated.appendingPathComponent("zones.json")
        let researchURL = GameData.shared.roots.data.appendingPathComponent("itemsResearch.json")
        let exaltURL = GameData.shared.roots.data.appendingPathComponent("exaltations.json")
        Task.detached(priority: .userInitiated) {
            let began = Date()
            let built = GearIndex.build(itemsURL: itemsURL, zonesURL: zonesURL, researchURL: researchURL,
                                        exaltationsURL: exaltURL)
            let ms = Int(Date().timeIntervalSince(began) * 1000)
            await MainActor.run {
                self.corpus = built
                self.buildMs = ms
                self.ready = true
            }
        }
    }

    /// Pure, off-actor: JSON in, value types out.
    nonisolated static func build(itemsURL: URL, zonesURL: URL, researchURL: URL,
                                  exaltationsURL: URL? = nil) -> GearCorpus {
        var out = GearCorpus()

        // The focus-exaltation overlay (scraped from the wiki), keyed by the item's name fold so a
        // row can carry its own exaltation for display and filtering. See `exaltations.json`.
        var exaltByName: [String: GearExaltation] = [:]
        if let exaltationsURL, let d = try? Data(contentsOf: exaltationsURL), let doc = try? JSONValue.parse(d) {
            for row in doc["focus"].array ?? [] {
                guard let item = row["item"].string, let effect = row["effect"].string else { continue }
                exaltByName[GameData.nameKey(item)] = GearExaltation(
                    effect: effect,
                    decaysAfter: row["decaysAfter"].int,
                    category: (row["category"].array ?? []).compactMap(\.string),
                    description: row["description"].string)
            }
        }

        // Hand-verified corrections to the scrape. A curated `slots` list REPLACES the scraped one
        // rather than merging with it, and an item the wiki marks as a GM/event drop is not a route
        // — it is excluded from the DONOR list only, and stays in the item index.
        var curatedSlots: [String: [String]] = [:]
        var unfarmable: Set<String> = []
        if let d = try? Data(contentsOf: researchURL), let r = try? JSONValue.parse(d) {
            for (key, v) in r.object ?? [:] {
                if let sl = v["slots"].array { curatedSlots[key] = sl.compactMap(\.string) }
                if v["summoned"].bool == true || v["gmEvent"].bool == true || v["gmOnly"].bool == true {
                    unfarmable.insert(key)
                }
            }
        }

        // The zone → era table, keyed by the same fold `GameData.zoneKey` uses so
        // `Chardok (Pre-Revamp)` and `THE PLANE OF SKY` land on their rows for free.
        //
        // Every spelling is registered under BOTH article variants: the zone roster says
        // "The Plane of Fear" while the wiki's drop tables say "Plane of Fear", and that one
        // missing word left thousands of drop rows unresolvable — whole armor sets (Umbral among
        // them) verdicted `unknown` and hidden by the Current era toggle despite dropping in
        // classic zones.
        var zoneEras: [String: String] = [:]
        if let d = try? Data(contentsOf: zonesURL), let z = try? JSONValue.parse(d) {
            for row in z["zones"].array ?? [] {
                guard let era = row["era"].string else { continue }
                var spellings = [row["name"].string ?? ""]
                spellings += (row["aliases"].array ?? []).compactMap(\.string)
                spellings += (row["mobCatalogNames"].array ?? []).compactMap(\.string)
                for s in spellings {
                    let lowered = s.lowercased()
                    let k = String(lowered.filter { $0.isLetter || $0.isNumber })
                    if k.isEmpty { continue }
                    var keys = [k]
                    if lowered.split(whereSeparator: { $0.isWhitespace }).first == "the" {
                        keys.append(String(k.dropFirst(3)))
                    } else {
                        keys.append("the" + k)
                    }
                    for key in keys where !key.isEmpty && zoneEras[key] == nil {
                        zoneEras[key] = era
                    }
                }
            }
        }
        func eraOfZone(_ name: String) -> String? {
            let k = String(name.lowercased().filter { $0.isLetter || $0.isNumber })
            return k.isEmpty ? nil : zoneEras[k]
        }

        guard let d = try? Data(contentsOf: itemsURL), let doc = try? JSONValue.parse(d) else { return out }
        out.scrapedAt = doc["scrapedAt"].string.map { String($0.prefix(10)) }

        var rows: [GearRow] = []
        var donors: [DonorRow] = []
        rows.reserveCapacity(7000)

        for (key, v) in doc["items"].object ?? [:] {
            // An alias page (`|itemname`) is not an item of its own.
            if key.contains("|") { continue }
            let stats = v["stats"]
            let name = v["page"].string ?? key
            let slots = curatedSlots[key].map { $0.flatMap { normalizeSlotTokens($0) } }
                ?? normalizeSlotTokens(stats["slot"].string)

            // Effects first: a donor row exists whether or not the item is equippable.
            var effects: [GearEffectRow] = []
            for e in stats["effects"].array ?? [] {
                let ename = e["name"].string ?? ""
                if ename.isEmpty { continue }
                let detail = e["detail"].string
                let kind = e["kind"].string ?? "effect"
                let socket = socketTypeOf(kind: kind)
                effects.append(GearEffectRow(
                    name: ename, detail: detail, kind: kind, socket: socket,
                    tierRequired: socket.map(extractionTier),
                    hasteLocked: isHasteEffect(name: ename, detail: detail)))
            }

            // The numeric vector. Keys are `normalizeStatKey`'s spelling, which is the vocabulary
            // the scaler dispatches on.
            var vector: [String: Int] = [:]
            var statKeys: [String] = [], saveKeys: [String] = []
            func fold(_ rowsIn: [JSONValue], into keys: inout [String]) {
                for s in rowsIn {
                    guard let k = s["key"].string, let raw = s["value"].string else { continue }
                    keys.append(k)
                    let nk = GearUpgrade.normalizeStatKey(k)
                    guard gearStatKeySet.contains(nk) else { continue }
                    // A percent value is a number with a unit, not a disqualification here: the
                    // vector is numeric and the `%` is put back at render time.
                    if let n = GearUpgrade.statNumber(raw) { vector[nk] = Int(n) }
                }
            }
            fold(stats["stats"].array ?? [], into: &statKeys)
            fold(stats["saves"].array ?? [], into: &saveKeys)
            if let ac = stats["ac"].int { vector["AC"] = ac }
            if let dmg = stats["dmg"].int { vector["DMG"] = dmg }
            if let delay = stats["atkDelay"].int { vector["DELAY"] = delay }
            if let b = stats["dmgBonus"].int { vector["DMG_BONUS"] = b }
            if let b = stats["backstab"].int { vector["BACKSTAB"] = b }
            if let r = stats["range"].int { vector["RANGE"] = r }
            let weight = (stats["weight"].string).flatMap { Double($0) }

            let classes = normalizeClasses((stats["classes"].array ?? []).compactMap(\.string))
            let drops = (v["dropsFrom"].array ?? []).map {
                GearDrop(mob: $0["mob"].string ?? "", zone: $0["zone"].string ?? "")
            }
            let tag = v["eraTag"].string
            let verdict = layeredVerdict(zoneEras: drops.map { eraOfZone($0.zone) }, tag: tag)
            let exalt = exaltByName[GameData.nameKey(name)]
            // The exaltation's effect name joins the search corpus, so typing "Spell Haste" finds
            // the items that grant it as an exaltation, not only ones whose stats block names it.
            let searchKey = ([name] + effects.map { "\($0.name) \($0.detail ?? "")" }
                             + (exalt.map { [$0.effect] } ?? []))
                .joined(separator: " ").lowercased()

            // A page that occupies no equip slot contributes no gear row — the only exclusion.
            if !slots.isEmpty {
                rows.append(GearRow(
                    key: key, name: name, iconId: v["iconId"].int, slots: slots, classes: classes,
                    skill: stats["skill"].string, stats: vector, weight: weight,
                    voidSynth: GearUpgrade.synthesizesVoidSave(
                        statKeys: statKeys, saveKeys: saveKeys, state: ItemUpgradeState(full: 1)),
                    effects: effects, eraTag: tag, drops: drops,
                    quest: v["quest"].bool ?? false, playerCrafted: v["playerCrafted"].bool ?? false,
                    searchKey: searchKey, era: verdict, exaltation: exalt))
            }

            // Donors. A summoned item is excluded (V9): it is not farmable, so it cannot be a
            // route. A socketless `Effect:` line named no socket and is never emitted.
            if name.lowercased().hasPrefix("summoned:") || unfarmable.contains(key) { continue }
            for e in effects {
                guard let socket = e.socket else { continue }
                donors.append(DonorRow(
                    key: key, name: name, iconId: v["iconId"].int, slots: slots, classes: classes,
                    effect: e.name, detail: e.detail, socket: socket,
                    tierRequired: e.tierRequired ?? extractionTier(socket),
                    hasteLocked: e.hasteLocked, era: verdict, eraTag: tag, drops: drops,
                    quest: v["quest"].bool ?? false, playerCrafted: v["playerCrafted"].bool ?? false,
                    searchKey: "\(name) \(e.name) \(e.detail ?? "")".lowercased()))
            }
        }

        rows.sort { $0.name < $1.name }
        donors.sort { $0.name < $1.name }
        out.rows = rows
        out.donors = donors
        out.dropZones = Set(rows.flatMap { $0.drops.map(\.zone) })
            .subtracting([""]).sorted()
        out.byKey = Dictionary(rows.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        return out
    }
}
