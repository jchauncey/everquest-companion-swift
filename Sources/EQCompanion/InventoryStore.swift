// The transport for the `/outputfile inventory` dump: find it, read it, parse it, and hand the
// three views of it (the armory grid, the gear sum, the carry-all ledger) to the surfaces.
//
// Nothing is cached across a reload. The dump is a file the player rewrites mid-session ON PURPOSE
// — that is the whole point of the command — so the store re-reads whenever the engine's
// `outputFiles` module moves, and a Refresh button does the same thing by hand. The freshness the
// surfaces draw is the FILE's mtime: when the player dumped, never when we read it.
import Foundation
import Observation
import EQCompanionCore

/// Where a copy of an item sits, in the words the Owned column uses.
enum OwnedPlace: String, CaseIterable {
    case equipped, inventory, bank, sharedBank, personalDepot, keyring, unknown

    var label: String {
        switch self {
        case .equipped: return "Equipped"
        case .inventory: return "Inventory"
        case .bank: return "Bank"
        case .sharedBank: return "Shared bank"
        case .personalDepot: return "Depot"
        case .keyring: return "Keyring"
        case .unknown: return "Unfiled"
        }
    }
}

/// One statement the dump makes about owning an item: a place, a ` +N`, and how many rows said it.
/// EACH ` +N` IS ITS OWN COPY, never a total — `Boots +1` twice is two boots.
struct OwnedFact: Hashable {
    var place: OwnedPlace
    var tier: Int?
    var count: Int

    var label: String {
        var s = place.label
        if let t = tier { s += " +\(t)" }
        if count > 1 { s += " x\(count)" }
        return s
    }
}

/// What the dump and the loot ledger together say about one item key.
struct ItemOwnership {
    var facts: [OwnedFact] = []
    /// exaltation-socket rows naming this item — it is a donor you hold, not a thing you can wear
    var exaltations = 0
    var looted = false

    var owned: Bool { !facts.isEmpty }

    /// The Owned cell, in precedence order.
    var cellText: String {
        if !facts.isEmpty { return facts.map(\.label).joined(separator: " · ") }
        if exaltations > 0 { return "Exaltation only" }
        if looted { return "Looted" }
        return ""
    }
}

@MainActor
@Observable
final class InventoryStore {
    static let shared = InventoryStore()

    /// The dump file that was read, or nil when this character has never written one.
    private(set) var path: String?
    /// the file's mtime in ms: WHEN THE PLAYER DUMPED
    private(set) var updatedAt: Int64?
    /// when THIS app last read it — the two diverge exactly when something went wrong
    private(set) var readAt: Int64?
    private(set) var ready = false
    private(set) var error: String?

    private(set) var cells: [SheetCell] = []
    private(set) var unplaced: [SheetCell] = []
    private(set) var totals = GearTotals()
    private(set) var carry = CarryAll()
    /// `GameData.nameKey(baseName)` → what the dump says about owning it
    private(set) var ownership: [String: ItemOwnership] = [:]
    /// raw lowercased name → how many, the flat held-counts view
    private(set) var held: [String: Int] = [:]

    private var lastKey = ""

    /// The command this surface is fed by, as the registry states it.
    static let command = "/outputfile inventory"
    static let why = "Re-type it in game whenever your gear changes - this sheet follows the dump."
    static let steps = [
        "Stand at a banker and open your Bank.",
        "Open Dragon\u{2019}s Hoard too - it only dumps while its window is open.",
        "Open your Tradeskill Depot once if you keep anything in it.",
        "Type /outputfile inventory.",
        "Wind Runes and other currency-tab items are never in the dump - the game leaves them out."
    ]

    /// Re-read if anything moved. `seq` is the `outputFiles` module's sequence; `force` is the
    /// Refresh button, which re-reads even when nothing appeared to change.
    func refresh(_ model: AppModel, seq: Int, force: Bool = false) async {
        let root = model.install?.root
        let name = model.attached?.name
        let server = model.attached?.server
        let key = "\(root?.path ?? "")|\(name ?? "")|\(server ?? "")|\(seq)"
        if !force && key == lastKey && ready { return }
        lastKey = key

        guard let root else {
            path = nil; updatedAt = nil; cells = []; unplaced = []; totals = GearTotals()
            carry = CarryAll(); ownership = [:]; held = [:]
            error = "No EverQuest install found."
            ready = true
            return
        }

        // The file names EQ writes, MOST SPECIFIC FIRST. Matching is case-insensitive because the
        // client's own casing is not something this app gets to assume.
        var wanted: [String] = []
        if let name, let server { wanted.append("\(name)_\(server)-Inventory.txt") }
        if let name { wanted.append("\(name)-Inventory.txt") }

        let found: (URL, Int64)? = await Task.detached(priority: .userInitiated) { () -> (URL, Int64)? in
            let fm = FileManager.default
            guard let entries = try? fm.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
            let candidates = entries.filter { $0.lastPathComponent.lowercased().hasSuffix("-inventory.txt") }
            func mtime(_ u: URL) -> Int64 {
                let d = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                return Int64((d ?? .distantPast).timeIntervalSince1970 * 1000)
            }
            for want in wanted {
                if let m = candidates.first(where: { $0.lastPathComponent.lowercased() == want.lowercased() }) {
                    return (m, mtime(m))
                }
            }
            // Failing every preferred name, the newest matching file — what a one-character
            // machine always lands on.
            guard let newest = candidates.max(by: { mtime($0) < mtime($1) }) else { return nil }
            return (newest, mtime(newest))
        }.value

        guard let (url, mtime) = found else {
            path = nil; updatedAt = nil; cells = []; unplaced = []; totals = GearTotals()
            carry = CarryAll(); ownership = [:]; held = [:]
            error = nil
            ready = true
            return
        }

        let parsed: InventoryDump? = await Task.detached(priority: .userInitiated) { () -> InventoryDump? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            // The dump is what the Windows client wrote; UTF-8 first, then the code page it falls
            // back to, so an accented mob name cannot blank the whole sheet.
            let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
                ?? ""
            return parseInventoryDump(text)
        }.value

        guard let dump = parsed else {
            error = "Could not read \(url.lastPathComponent)."
            ready = true
            return
        }

        path = url.path
        updatedAt = mtime
        readAt = nowMs()
        error = nil

        let split = sheetCells(dump)
        cells = split.cells
        unplaced = split.unplaced
        carry = carryAll(dump)
        held = heldCounts(dump)
        totals = Self.sumWorn(split.cells + split.unplaced)
        ownership = Self.ownershipOf(dump)
        ready = true
    }

    /// The worn items joined to the committed item DB and summed at each item's own ` +N`.
    /// Twenty items, so this runs inline; `GameData` is main-actor anyway.
    private static func sumWorn(_ cells: [SheetCell]) -> GearTotals {
        let worn: [WornItemBlock] = cells.compactMap { cell in
            guard let item = cell.item else { return nil }
            guard let record = GameData.shared.item(named: item.baseName) else {
                return WornItemBlock(tier: item.tier, block: nil)
            }
            func rows(_ v: JSONValue) -> [(key: String, value: String)] {
                (v.array ?? []).compactMap { r in
                    guard let k = r["key"].string, let val = r["value"].string else { return nil }
                    return (k, val)
                }
            }
            return WornItemBlock(tier: item.tier, block: WornStatBlock(
                stats: rows(record.stats["stats"]),
                saves: rows(record.stats["saves"]),
                ac: record.stats["ac"].int))
        }
        return sumGear(worn)
    }

    /// What the dump says about owning each item, folded onto the item-name key the gear corpus
    /// joins on. An `(Exaltation)` row is counted separately: it is a donor you hold, not a copy
    /// you can wear.
    private static func ownershipOf(_ dump: InventoryDump) -> [String: ItemOwnership] {
        var out: [String: ItemOwnership] = [:]
        var buckets: [String: [OwnedFact: Int]] = [:]

        for e in dump.walk() where !e.empty {
            let key = GameData.nameKey(e.parsedName.base)
            if key.isEmpty { continue }
            if e.parsedName.exaltation {
                out[key, default: ItemOwnership()].exaltations += 1
                continue
            }
            let place: OwnedPlace
            if e.section != primaryItemSection {
                place = .unknown
            } else {
                switch e.place {
                case .equip: place = e.path.isEmpty ? .equipped : .inventory
                case .container(let kind, _):
                    switch kind {
                    case .general: place = .inventory
                    case .bank: place = .bank
                    case .sharedBank: place = .sharedBank
                    case .personalDepot: place = .personalDepot
                    }
                case .unknown: place = .unknown
                }
            }
            let fact = OwnedFact(place: place, tier: e.parsedName.tier, count: 1)
            buckets[key, default: [:]][fact, default: 0] += max(1, e.count)
        }

        for k in dump.keyRing where heldKeyRingCategories.contains(k.category)
            && !k.name.isEmpty && k.name != "Empty" {
            let key = GameData.nameKey(k.parsedName.base)
            if key.isEmpty { continue }
            let fact = OwnedFact(place: .keyring, tier: k.parsedName.tier, count: 1)
            buckets[key, default: [:]][fact, default: 0] += 1
        }

        let order = OwnedPlace.allCases
        for (key, facts) in buckets {
            var rows = facts.map { OwnedFact(place: $0.key.place, tier: $0.key.tier, count: $0.value) }
            rows.sort {
                let a = order.firstIndex(of: $0.place) ?? 0, b = order.firstIndex(of: $1.place) ?? 0
                if a != b { return a < b }
                return ($0.tier ?? -1) < ($1.tier ?? -1)   // "no tier" first
            }
            out[key, default: ItemOwnership()].facts = rows
        }
        return out
    }
}
