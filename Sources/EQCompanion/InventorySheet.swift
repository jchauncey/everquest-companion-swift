// The ARMORY LAYOUT and the GEAR SUM — a port of `src/shared/characterSheet.ts`.
//
// THE GRID IS A HAND-AUTHORED TABLE and it reads the CLIENT's tokens, not the wiki's. The planner's
// join maps `Any Slot` and `Held` to nothing because there is no wiki slot to name; that is right
// for the planner and wrong here, because the real dump has items equipped in both.
//
// PAIRED SLOTS ARE ORDINAL, AND THAT IS ALL THEY ARE. `Ear`, `Wrist`, `Fingers` and `Any Slot` each
// occur twice at top level and the file has NO column saying which is left. So a cell claims an
// OCCURRENCE and both cells of a pair carry the SAME label; the sheet never prints "left"/"right".
//
// THE SUM STATES WHAT THE ITEM PAGES STATE AND NOTHING ELSE. No `/outputfile` variant exports
// character stats, so the only honest total is a sum over the WORN items' wiki stat blocks — which
// is why the panel is headed "from gear" and why it counts the items it could NOT find rather than
// quietly totalling 19 of 20. Each item is read at the ` +N` its own name states, through the same
// scaler the Gear tab uses. Percentages are STATED, NEVER ADDED: whether worn haste stacks is a
// game rule no source here states.
import Foundation

enum SheetColumn: String { case left, right, bottom }

struct SheetSlotDef {
    /// stable cell id — `ear1`/`ear2` disambiguate the OCCURRENCE, never a side
    var id: String
    /// the client Location token this cell reads
    var token: String
    /// which occurrence of that token, 0-based, in the order the client wrote them
    var nth: Int
    /// what the cell is called on screen — identical for both cells of a pair
    var label: String
    var column: SheetColumn
}

/// The twenty-four equipment cells, in render order per column. The column split is the game's own
/// inventory window: eight down the left, eight down the right, and what is left over along the
/// bottom.
let sheetSlots: [SheetSlotDef] = [
    .init(id: "ear1", token: "Ear", nth: 0, label: "Ear", column: .left),
    .init(id: "head", token: "Head", nth: 0, label: "Head", column: .left),
    .init(id: "face", token: "Face", nth: 0, label: "Face", column: .left),
    .init(id: "ear2", token: "Ear", nth: 1, label: "Ear", column: .left),
    .init(id: "neck", token: "Neck", nth: 0, label: "Neck", column: .left),
    .init(id: "shoulders", token: "Shoulders", nth: 0, label: "Shoulders", column: .left),
    .init(id: "arms", token: "Arms", nth: 0, label: "Arms", column: .left),
    .init(id: "back", token: "Back", nth: 0, label: "Back", column: .left),

    .init(id: "wrist1", token: "Wrist", nth: 0, label: "Wrist", column: .right),
    .init(id: "wrist2", token: "Wrist", nth: 1, label: "Wrist", column: .right),
    .init(id: "range", token: "Range", nth: 0, label: "Range", column: .right),
    .init(id: "hands", token: "Hands", nth: 0, label: "Hands", column: .right),
    .init(id: "chest", token: "Chest", nth: 0, label: "Chest", column: .right),
    .init(id: "legs", token: "Legs", nth: 0, label: "Legs", column: .right),
    .init(id: "feet", token: "Feet", nth: 0, label: "Feet", column: .right),
    .init(id: "waist", token: "Waist", nth: 0, label: "Waist", column: .right),

    .init(id: "primary", token: "Primary", nth: 0, label: "Primary", column: .bottom),
    .init(id: "secondary", token: "Secondary", nth: 0, label: "Secondary", column: .bottom),
    .init(id: "finger1", token: "Fingers", nth: 0, label: "Fingers", column: .bottom),
    .init(id: "finger2", token: "Fingers", nth: 1, label: "Fingers", column: .bottom),
    .init(id: "ammo", token: "Ammo", nth: 0, label: "Ammo", column: .bottom),
    .init(id: "held", token: "Held", nth: 0, label: "Held", column: .bottom),
    .init(id: "any1", token: "Any Slot", nth: 0, label: "Any Slot", column: .bottom),
    .init(id: "any2", token: "Any Slot", nth: 1, label: "Any Slot", column: .bottom)
]

/// One worn item, as the dump states it.
struct SheetItem: Equatable {
    /// the Name column verbatim — keeps ` +N`, `*` and ` (Exaltation)`
    var name: String
    /// the ` +N`/`*`-stripped base name: the join key for the committed item DB
    var baseName: String
    /// nil means the name carried no suffix, NOT tier 0
    var tier: Int?
    var itemId: Int
    /// the names of the exaltations socketed into this item, as the client spelled them
    var exaltations: [String]
}

/// One cell of the grid: a place, and what is in it.
struct SheetCell: Identifiable, Equatable {
    var id: String
    var label: String
    var column: SheetColumn
    /// the client Location token, verbatim — what the file called this place
    var location: String
    /// nil when the row said `Empty`, or when the dump had no row for this cell at all
    var item: SheetItem?
}

private func sheetItem(_ e: InventoryEntry) -> SheetItem {
    SheetItem(name: e.name, baseName: e.parsedName.base, tier: e.parsedName.tier, itemId: e.itemId,
              exaltations: e.children.filter { !$0.empty && $0.parsedName.exaltation }.map { $0.parsedName.base })
}

/// The dump → the grid, plus anything equipped that the grid has no cell for. `unplaced` exists so
/// a THIRD `Ear` row is surfaced instead of dropped; it is empty for every dump seen so far.
func sheetCells(_ dump: InventoryDump) -> (cells: [SheetCell], unplaced: [SheetCell]) {
    var seen: [String: Int] = [:]
    var byKey: [String: InventoryEntry] = [:]
    var unplaced: [SheetCell] = []

    // Top level only, and in FILE ORDER — the occurrence index is the only signal the file gives.
    // Only the `Location` table says what is WORN: another item-shaped table spelling `Head` must
    // never become the hat on the character sheet.
    for e in dump.items {
        guard e.section == primaryItemSection, e.path.isEmpty, case .equip(let token) = e.place else { continue }
        let nth = seen[token] ?? 0
        seen[token] = nth + 1
        let key = "\(token)#\(nth)"
        if sheetSlots.contains(where: { $0.token == token && $0.nth == nth }) {
            byKey[key] = e
        } else if !e.empty {
            unplaced.append(SheetCell(id: key, label: token, column: .bottom, location: token, item: sheetItem(e)))
        }
    }

    let cells = sheetSlots.map { slot -> SheetCell in
        let e = byKey["\(slot.token)#\(slot.nth)"]
        return SheetCell(id: slot.id, label: slot.label, column: slot.column, location: slot.token,
                         item: e.flatMap { $0.empty ? nil : sheetItem($0) })
    }
    return (cells, unplaced)
}

// MARK: - The gear sum

/// One summed stat: an integer total over the items that stated an integer for it.
struct GearStatTotal: Identifiable, Equatable {
    var label: String
    var total: Int
    /// how many worn items contributed
    var from: Int
    var id: String { label }
}

/// A stat whose values are NOT addable (percentages): the individual values, never a total.
struct GearUnsummed: Identifiable, Equatable {
    var label: String
    var values: [String]
    var id: String { label }
}

struct GearTotals: Equatable {
    var ac = 0
    var stats: [GearStatTotal] = []
    var saves: [GearStatTotal] = []
    var unsummed: [GearUnsummed] = []
    /// worn items whose stat block we had
    var counted = 0
    /// worn items the committed DB knew nothing about; their stats are in NO total above
    var unknown = 0
}

/// Display order for the summed rows. Anything unlisted keeps source order, after these.
private let statOrder = [
    "Strength", "Stamina", "Agility", "Dexterity", "Wisdom", "Intelligence", "Charisma",
    "HP", "Mana", "Endurance", "Attack", "Regen", "Mana Regen"
]

/// The stat rows the committed DB states for one item, read out of its `stats` object once.
struct WornStatBlock {
    var stats: [(key: String, value: String)] = []
    var saves: [(key: String, value: String)] = []
    var ac: Int?
}

/// One worn item as the sum needs to read it: the tier its NAME stated, and the DB's block behind
/// it. The tier is part of the argument on purpose — a caller cannot state a worn item without
/// stating what state it is worn at.
struct WornItemBlock {
    var tier: Int?
    /// nil is an item the committed DB had nothing for
    var block: WornStatBlock?
}

/// Sum the worn items' stat blocks, each read at its own ` +N`. A nil block is an item the
/// committed DB had nothing for — counted as `unknown` and contributing to nothing, so the panel
/// can say so out loud.
func sumGear(_ worn: [WornItemBlock]) -> GearTotals {
    var stats: [String: GearStatTotal] = [:]
    var saves: [String: GearStatTotal] = [:]
    var unsummed: [String: GearUnsummed] = [:]
    var totals = GearTotals()

    func fold(_ rows: [(key: String, value: String)], into sums: inout [String: GearStatTotal],
              state: ItemUpgradeState) {
        for row in rows {
            let label = GearUpgrade.statLabel(row.key)
            let cls = GearUpgrade.statClass(row.key)
            // Scale first, in the item's own spelling, then decide whether the result adds up.
            var value = row.value
            if cls == .primary || cls == .flat, let base = GearUpgrade.statNumber(row.value) {
                let scaled = cls == .primary
                    ? GearUpgrade.scalePrimary(Int(base), state)
                    : GearUpgrade.scaleFlat(Int(base), state)
                value = GearUpgrade.renderStatValue(source: row.value, scaled: scaled)
            }
            guard let n = GearUpgrade.statInteger(value) else {
                unsummed[label, default: GearUnsummed(label: label, values: [])].values.append(value)
                continue
            }
            var held = sums[label] ?? GearStatTotal(label: label, total: 0, from: 0)
            held.total += n
            held.from += 1
            sums[label] = held
        }
    }

    for item in worn {
        guard let block = item.block else { totals.unknown += 1; continue }
        totals.counted += 1
        let state = GearUpgrade.state(forTier: item.tier)
        if let ac = block.ac { totals.ac += GearUpgrade.scalePrimary(ac, state) }
        fold(block.stats, into: &stats, state: state)
        fold(block.saves, into: &saves, state: state)
        // The synthetic SV VOID line an upgraded item gains is part of what the item READS, not a
        // decoration of the item window, so it belongs in these totals too.
        if GearUpgrade.synthesizesVoidSave(statKeys: block.stats.map(\.key),
                                           saveKeys: block.saves.map(\.key), state: state) {
            let label = GearUpgrade.statLabel("SV VOID")
            var held = saves[label] ?? GearStatTotal(label: label, total: 0, from: 0)
            held.total += state.normalized.full
            held.from += 1
            saves[label] = held
        }
    }

    func orderKey(_ label: String) -> Int { statOrder.firstIndex(of: label) ?? statOrder.count }
    totals.stats = stats.values.sorted {
        orderKey($0.label) != orderKey($1.label) ? orderKey($0.label) < orderKey($1.label) : $0.label < $1.label
    }
    totals.saves = saves.values.sorted { $0.label < $1.label }
    totals.unsummed = unsummed.values.sorted { $0.label < $1.label }
    return totals
}
