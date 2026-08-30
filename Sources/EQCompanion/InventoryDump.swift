// The deep model of an EQ `/outputfile inventory` dump — a port of
// `src/shared/outputs/inventory.ts` and `src/main/outputs/inventoryParse.ts`.
//
// It states what the FILE states and nothing more. The file is tab-separated tables separated by
// blank lines; a table starts at a header row whose SECOND column is literally `Name`, and the
// header's REMAINING columns say how to read it: `Name ID Count Slots` is an item table whatever
// it is called, `Name ID` is a keyring table, anything else is refused.
//
// LOCATION IS A PATH: `<base>` followed by zero or more `-Slot<n>` segments. The separator is
// specifically `-Slot<digits>`, NOT a bare `-` — the real file contains `Personal-Depot1`, a
// compound base token whose hyphen means nothing of the kind.
//
// DUPLICATE BASE TOKENS ARE REAL: `Ear`, `Wrist`, `Fingers` and `Any Slot` each appear TWICE at
// top level. Rows attach to the MOST RECENT row bearing the parent path.
import Foundation

// MARK: - Places

/// The top-level Location tokens that are EQUIPMENT slots — a CLOSED set measured from a real
/// dump. Anything outside it parses to `unknown` rather than being coerced into the nearest member.
let equipLocations: [String] = [
    "Any Slot", "Ammo", "Arms", "Back", "Chest", "Ear", "Face", "Feet", "Fingers", "Hands",
    "Head", "Held", "Legs", "Neck", "Primary", "Range", "Secondary", "Shoulders", "Waist", "Wrist"
]

private let equipSet = Set(equipLocations)

enum ContainerKind: String { case general, bank, sharedBank, personalDepot }

enum InventoryPlace: Equatable {
    case equip(token: String)
    case container(kind: ContainerKind, index: Int)
    case unknown(raw: String)

    var raw: String {
        switch self {
        case .equip(let t): return t
        case .container(let k, let i):
            switch k {
            case .general: return "General \(i)"
            case .bank: return "Bank\(i)"
            case .sharedBank: return "SharedBank\(i)"
            case .personalDepot: return "Personal-Depot\(i)"
            }
        case .unknown(let r): return r
        }
    }
}

private let containerPatterns: [(String, ContainerKind)] = [
    ("^General (\\d+)$", .general),
    ("^Bank(\\d+)$", .bank),
    ("^SharedBank(\\d+)$", .sharedBank),
    ("^Personal-Depot(\\d+)$", .personalDepot)
]

/// Classify a base Location token (the part before any `-Slot<n>` chain).
func parsePlace(_ base: String) -> InventoryPlace {
    if equipSet.contains(base) { return .equip(token: base) }
    for (pattern, kind) in containerPatterns {
        if let m = base.range(of: pattern, options: .regularExpression) {
            let digits = base[m].filter(\.isNumber)
            return .container(kind: kind, index: Int(digits) ?? 0)
        }
    }
    return .unknown(raw: base)
}

/// Split a Location into its base token and its `-Slot<n>` chain (outermost first). END-anchored
/// on the chain so `Personal-Depot1` keeps its hyphen and yields no sub-slots.
func splitLocationPath(_ location: String) -> (base: String, path: [Int]) {
    guard let m = location.range(of: "((?:-Slot\\d+)+)$", options: .regularExpression) else {
        return (location, [])
    }
    let chain = String(location[m])
    var path: [Int] = []
    var scan = chain[chain.startIndex...]
    while let r = scan.range(of: "-Slot(\\d+)", options: .regularExpression) {
        path.append(Int(scan[r].dropFirst(5)) ?? 0)
        scan = scan[r.upperBound...]
    }
    return (String(location[..<m.lowerBound]), path)
}

/// The `-Slot<n>`-stripped parent Location of a row, or nil when the row is top level.
func parentLocation(_ location: String) -> String? {
    guard let m = location.range(of: "-Slot\\d+$", options: .regularExpression) else { return nil }
    return String(location[..<m.lowerBound])
}

// MARK: - Names

/// A name split into the parts the client actually spells out.
struct ParsedItemName: Equatable {
    var base: String
    /// the ` +N` upgrade suffix; nil means the name carried none, NOT tier 0
    var tier: Int?
    /// the client's own `<Item> (Exaltation)` spelling for a socketed exaltation
    var exaltation: Bool
    /// a trailing `*` whose meaning the file never states
    var starred: Bool
}

private let exaltationSuffix = " (Exaltation)"

func parseItemName(_ name: String) -> ParsedItemName {
    var base = name
    let exaltation = base.hasSuffix(exaltationSuffix)
    if exaltation { base.removeLast(exaltationSuffix.count) }
    let starred = base.hasSuffix("*")
    if starred { base.removeLast() }
    var tier: Int?
    if let m = base.range(of: " \\+(\\d+)$", options: .regularExpression) {
        tier = Int(base[m].dropFirst(2))
        base = String(base[..<m.lowerBound])
    }
    return ParsedItemName(base: base, tier: tier, exaltation: exaltation, starred: starred)
}

// MARK: - Entries

/// The item table the game writes FIRST, and the only one that states what you are WEARING.
let primaryItemSection = "Location"

enum SectionShape { case items, keyRing, unknown }

/// One row of an item-shaped table, with the rows nested under it attached.
final class InventoryEntry {
    var section: String
    var location: String
    var place: InventoryPlace
    var path: [Int]
    /// the Name column, verbatim (keeps ` +N`, `*` and `(Exaltation)`)
    var name: String
    var parsedName: ParsedItemName
    var itemId: Int
    var count: Int
    /// how many child slots THIS row's item provides (the file does not distinguish a bag's
    /// capacity from an item's socket capacity)
    var slots: Int
    /// `Empty` (or a blank name) — the slot exists and holds nothing
    var empty: Bool
    var children: [InventoryEntry] = []
    /// true when this row's parent Location was never seen; kept at top level, never re-parented
    var orphan = false
    var line: Int

    init(section: String, location: String, place: InventoryPlace, path: [Int], name: String,
         parsedName: ParsedItemName, itemId: Int, count: Int, slots: Int, empty: Bool, line: Int) {
        self.section = section; self.location = location; self.place = place; self.path = path
        self.name = name; self.parsedName = parsedName; self.itemId = itemId; self.count = count
        self.slots = slots; self.empty = empty; self.line = line
    }
}

/// One row of a keyring-shaped table (3 columns: category, name, id).
struct KeyRingEntry {
    var section: String
    var category: String
    var name: String
    var parsedName: ParsedItemName
    var itemId: Int
    var line: Int
}

struct InventoryDump {
    var items: [InventoryEntry] = []
    var keyRing: [KeyRingEntry] = []
    /// rows belonging to a section whose header SHAPE we do not recognize — retained, never interpreted
    var unknownSections: [[String]] = []
    /// rows of a shaped section that did not have that shape's column count
    var malformed: [[String]] = []
    var sections: [String] = []

    /// Depth-first walk over every entry (parents before children).
    func walk() -> [InventoryEntry] {
        var out: [InventoryEntry] = []
        func rec(_ es: [InventoryEntry]) {
            for e in es { out.append(e); rec(e.children) }
        }
        rec(items)
        return out
    }
}

// MARK: - The parser

private let itemColumns = ["Name", "ID", "Count", "Slots"]
private let keyRingColumns = ["Name", "ID"]

private func headerSpells(_ cols: [String], _ want: [String]) -> Bool {
    var declared = cols.dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }
    // The real `KeyRing` header is `KeyRing \t Name \t ID \t` — the trailing empty column is the
    // client's tab, not a column.
    while let last = declared.last, last.isEmpty { declared.removeLast() }
    return declared == want
}

/// Parse a `/outputfile inventory` dump. Rows before any header read as the item table — both the
/// original parser's behaviour and the only sane default for a file whose first line IS the item
/// header. A malformed row is COUNTED, never thrown on.
func parseInventoryDump(_ text: String) -> InventoryDump {
    var dump = InventoryDump()
    var section = primaryItemSection
    var shape = SectionShape.items
    var byPath: [String: InventoryEntry] = [:]

    func int(_ s: String?) -> Int { Int((s ?? "").trimmingCharacters(in: .whitespaces)) ?? 0 }

    let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    for (i, line) in lines.enumerated() {
        if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
        let cols = line.components(separatedBy: "\t")
        if cols.count >= 2 && cols[1].trimmingCharacters(in: .whitespaces) == "Name" {
            section = cols[0].trimmingCharacters(in: .whitespaces)
            shape = headerSpells(cols, itemColumns) ? .items
                : headerSpells(cols, keyRingColumns) ? .keyRing : .unknown
            dump.sections.append(section)
            byPath.removeAll()   // a new section starts a new path space; nothing nests across tables
            continue
        }
        switch shape {
        case .items:
            guard cols.count >= 4 else { dump.malformed.append(cols); continue }
            let location = cols[0].trimmingCharacters(in: .whitespaces)
            let name = cols[1].trimmingCharacters(in: .whitespaces)
            let split = splitLocationPath(location)
            let entry = InventoryEntry(
                section: section, location: location, place: parsePlace(split.base), path: split.path,
                name: name, parsedName: parseItemName(name), itemId: int(cols[2]), count: int(cols[3]),
                slots: cols.count > 4 ? int(cols[4]) : 0,
                empty: name.isEmpty || name == "Empty", line: i + 1)
            let parentKey = parentLocation(entry.location)
            if let parentKey, let parent = byPath[parentKey] {
                parent.children.append(entry)
            } else {
                entry.orphan = parentKey != nil
                dump.items.append(entry)
            }
            byPath[entry.location] = entry
        case .keyRing:
            guard cols.count >= 3 else { dump.malformed.append(cols); continue }
            let name = cols[1].trimmingCharacters(in: .whitespaces)
            dump.keyRing.append(KeyRingEntry(
                section: section, category: cols[0].trimmingCharacters(in: .whitespaces),
                name: name, parsedName: parseItemName(name), itemId: int(cols[2]), line: i + 1))
        case .unknown:
            dump.unknownSections.append(cols)
        }
    }
    return dump
}

// MARK: - Everything you carry (shared/carryAll.ts)

let carrySectionLanePrefix = "section:"

/// The lanes that exist whatever the dump holds, in chip order.
let carryFixedLanes = ["worn", "bags", "bank", "depot", "keyring", "elsewhere"]

let carryLaneLabels: [String: String] = [
    "worn": "Worn", "bags": "Bags", "bank": "Bank",
    "depot": "Depot", "keyring": "Key rings", "elsewhere": "Elsewhere"
]

private let containerLanes: [ContainerKind: String] = [
    .general: "bags", .bank: "bank", .sharedBank: "bank", .personalDepot: "depot"
]

func carryLaneLabel(_ id: String) -> String {
    if id.hasPrefix(carrySectionLanePrefix) { return String(id.dropFirst(carrySectionLanePrefix.count)) }
    return carryLaneLabels[id] ?? id
}

/// One thing the dump says this character has, and where the dump says it is.
struct CarryRow: Identifiable {
    var name: String
    /// `name` lowercased once. THE NAME ONLY: folding the location in makes `ring` match every
    /// `KeyRing` row, which is not what anybody typing `ring` wants.
    var searchKey: String
    var location: String
    /// the Count column, except that a 0 or nonsense count reads as 1
    var count: Int
    var lane: String
    var line: Int
    var id: Int { line }
}

struct CarryLane: Identifiable, Hashable {
    var id: String
    var label: String
    var count: Int
}

struct CarryAll {
    var rows: [CarryRow] = []
    var lanes: [CarryLane] = []
}

private func laneOfEntry(_ e: InventoryEntry) -> String {
    if e.section != primaryItemSection { return carrySectionLanePrefix + e.section }
    switch e.place {
    case .equip: return "worn"
    case .container(let kind, _): return containerLanes[kind] ?? "elsewhere"
    case .unknown: return "elsewhere"
    }
}

/// The dump → one flat ledger, in FILE ORDER. An `Empty` row is evidence that the client
/// ENUMERATED that slot, not that it holds something: a ledger of what you carry is a ledger of
/// things, and a slot is not a thing.
func carryAll(_ dump: InventoryDump) -> CarryAll {
    var rows: [CarryRow] = []
    for e in dump.walk() where !e.empty && !e.name.isEmpty && e.name != "Empty" {
        let location = e.section == primaryItemSection ? e.location : "\(e.section) / \(e.location)"
        rows.append(CarryRow(name: e.name, searchKey: e.name.lowercased(), location: location,
                             count: e.count > 0 ? e.count : 1, lane: laneOfEntry(e), line: e.line))
    }
    for k in dump.keyRing where !k.name.isEmpty && k.name != "Empty" {
        // The category is the only "where" a keyring row has, so it IS the location path here.
        rows.append(CarryRow(name: k.name, searchKey: k.name.lowercased(),
                             location: "\(k.section) / \(k.category)", count: 1,
                             lane: "keyring", line: k.line))
    }
    rows.sort { $0.line < $1.line }

    var counts: [String: Int] = [:]
    for r in rows { counts[r.lane, default: 0] += 1 }
    var order = carryFixedLanes
        + dump.sections.filter { $0 != primaryItemSection }.map { carrySectionLanePrefix + $0 }
    for id in counts.keys where !order.contains(id) { order.append(id) }
    let lanes = order.compactMap { id -> CarryLane? in
        guard let c = counts[id] else { return nil }
        return CarryLane(id: id, label: carryLaneLabel(id), count: c)
    }
    return CarryAll(rows: rows, lanes: lanes)
}

// MARK: - Held counts

/// The KeyRing categories whose rows are HELD ITEMS — a closed set, and today it holds one member.
/// `Activated` stays OUT: one observed member is no evidence about whether the category holds a
/// copy or a receipt.
let heldKeyRingCategories: Set<String> = ["Equipment"]

/// The flat held-counts view of a dump: the RAW name lowercased → how many. `+N` variants stay
/// separate here. A Count of 0 or nonsense counts as 1.
func heldCounts(_ dump: InventoryDump) -> [String: Int] {
    var counts: [String: Int] = [:]
    for e in dump.walk() where !e.empty {
        counts[e.name.lowercased(), default: 0] += e.count > 0 ? e.count : 1
    }
    for k in dump.keyRing where heldKeyRingCategories.contains(k.category) && !k.name.isEmpty && k.name != "Empty" {
        counts[k.name.lowercased(), default: 0] += 1
    }
    return counts
}
