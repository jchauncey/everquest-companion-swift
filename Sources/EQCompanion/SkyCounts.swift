// What the app counts you as HOLDING, and from which witness. Ports of
// `features/posky/heldCounts.ts`, `shared/outputs/inventory.ts` + `main/outputs/inventoryParse.ts`,
// `features/inventory/reconcile.ts` and `features/inventory/countSource.ts`.
import Foundation
import EQCompanionCore

// MARK: - Loot events

struct SkyLootEvent {
    var ts: Int64
    var item: String
    var disposition: String?
    var count: Int

    var isDestroyed: Bool { disposition == "destroyed" }

    static func parse(_ v: JSONValue) -> [SkyLootEvent] {
        (v.array ?? []).map { e in
            SkyLootEvent(ts: e["ts"].int64 ?? 0,
                         item: e["item"].string ?? "",
                         disposition: e["disposition"].string,
                         count: e["count"].int ?? 1)
        }
    }
}

/// A completed NPC trade the log witnessed.
struct SkyTurnInEvent {
    var ts: Int64
    var npc: String
    var items: [String]

    static func parse(_ v: JSONValue) -> [SkyTurnInEvent] {
        (v.array ?? []).map { e in
            SkyTurnInEvent(ts: e["ts"].int64 ?? 0,
                           npc: e["npc"].string ?? "",
                           items: (e["items"].array ?? []).compactMap(\.string))
        }
    }
}

enum SkyHeld {
    /// Fold loot history into held counts on the counting key. `sold` and `combined` are skipped
    /// (gone, and net-zero respectively); a `destroyed` row SUBTRACTS where it sits and the running
    /// count floors at 0 per row, so `loot 1, destroy 3, loot 2` reads 2 rather than 0.
    static func counts(_ history: [SkyLootEvent],
                       keep: (SkyLootEvent, String) -> Bool = { _, _ in true }) -> [String: Int] {
        var c: [String: Int] = [:]
        for e in history {
            if e.disposition == "sold" || e.disposition == "combined" { continue }
            let k = SkyName.countKey(e.item)
            guard keep(e, k) else { continue }
            let n = max(1, e.count)
            c[k] = e.isDestroyed ? max(0, (c[k] ?? 0) - n) : (c[k] ?? 0) + n
        }
        return c
    }

    /// Drops recorded strictly after an instant — the forward half of a dump baseline. GROSS:
    /// destroys are discounted from the witness itself, once, by `destroyedAfter`.
    static func countsAfter(_ history: [SkyLootEvent], after: Int64) -> [String: Int] {
        counts(history) { e, _ in !e.isDestroyed && e.ts > after }
    }

    static func countsAfterPerKey(_ history: [SkyLootEvent], after: [String: Int64]) -> [String: Int] {
        counts(history) { e, k in !e.isDestroyed && e.ts > (after[k] ?? Int64.max) }
    }

    /// The discount a witness that spoke at an instant owes — a separate walk, because a windowed
    /// held fold floors at zero and would swallow a destroy with no loot beside it.
    static func destroyedAfter(_ history: [SkyLootEvent], after: Int64) -> [String: Int] {
        destroyed(history) { e, _ in e.ts > after }
    }

    static func destroyedAfterPerKey(_ history: [SkyLootEvent], after: [String: Int64]) -> [String: Int] {
        destroyed(history) { e, k in e.ts > (after[k] ?? Int64.max) }
    }

    private static func destroyed(_ history: [SkyLootEvent],
                                  keep: (SkyLootEvent, String) -> Bool) -> [String: Int] {
        var c: [String: Int] = [:]
        for e in history where e.isDestroyed {
            let k = SkyName.countKey(e.item)
            guard keep(e, k) else { continue }
            c[k] = (c[k] ?? 0) + max(1, e.count)
        }
        return c
    }

    /// When each item last DROPPED. `combined` counts (a real drop still held on this key), `sold`
    /// and `destroyed` do not — a destroy is the opposite event and must never stamp a recency.
    static func lastLootedAt(_ history: [SkyLootEvent]) -> [String: Int64] {
        var t: [String: Int64] = [:]
        for e in history {
            if e.disposition == "sold" || e.isDestroyed { continue }
            let k = SkyName.countKey(e.item)
            if let prev = t[k], prev >= e.ts { continue }
            t[k] = e.ts
        }
        return t
    }

    /// The best display spelling the log knows for each counting key (`deriveLootNames`).
    static func names(_ history: [SkyLootEvent]) -> [String: String] {
        var m: [String: String] = [:]
        for e in history {
            let k = SkyName.countKey(e.item)
            let base = SkyName.normalize(e.item)
            if m[k] == nil || (m[k] != base && base == e.item) { m[k] = base }
        }
        return m
    }
}

// MARK: - The `/outputfile inventory` dump

/// A parsed dump, flattened. `heldCountsFromDump` walks every item row depth-first anyway, so the
/// nesting the deep model builds changes no count; what IS load-bearing is which rows are read at
/// all, and that is decided by a section header's COLUMNS, never by its name (JOS-185).
struct SkyInventoryDump {
    struct ItemRow { var name: String; var count: Int; var empty: Bool }
    struct KeyRingRow { var category: String; var name: String }

    var items: [ItemRow] = []
    var keyRing: [KeyRingRow] = []
    var sections: [String] = []

    /// `Equipment` is a storage bin, not a claimed appearance: a reporter's Sky quest items sat
    /// there and nowhere else. `Activated` stays out until a dump proves which it is.
    static let heldKeyRingCategories: Set<String> = ["Equipment"]

    /// The flat held view: every row of every item-shaped table, keyed by the RAW name lowercased
    /// (`+N` variants stay separate here and fold onto the counting key downstream). A count of 0
    /// or nonsense counts as 1; `Empty` never counts; a held keyring row counts ONE.
    var heldCounts: [String: Int] {
        var counts: [String: Int] = [:]
        for e in items where !e.empty {
            let key = e.name.lowercased()
            counts[key] = (counts[key] ?? 0) + (e.count > 0 ? e.count : 1)
        }
        for k in keyRing {
            guard Self.heldKeyRingCategories.contains(k.category), k.name != "", k.name != "Empty" else { continue }
            let key = k.name.lowercased()
            counts[key] = (counts[key] ?? 0) + 1
        }
        return counts
    }

    /// text → dump. Rows before any header read as the item table (the file's first line IS the
    /// item header). A header is any row whose second column is literally `Name`; its remaining
    /// columns say how to read the section, and a shape we have never seen is retained, never
    /// interpreted.
    static func parse(_ text: String) -> SkyInventoryDump {
        var dump = SkyInventoryDump()
        var section = "Location"
        var shape = "items"
        for raw in text.components(separatedBy: CharacterSet.newlines) {
            if raw.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let cols = raw.components(separatedBy: "\t")
            if cols.count >= 2, cols[1].trimmingCharacters(in: .whitespaces) == "Name" {
                section = cols[0].trimmingCharacters(in: .whitespaces)
                var declared = cols.dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }
                while let last = declared.last, last.isEmpty { declared.removeLast() }
                if declared == ["Name", "ID", "Count", "Slots"] { shape = "items" }
                else if declared == ["Name", "ID"] { shape = "keyRing" }
                else { shape = "unknown" }
                dump.sections.append(section)
                continue
            }
            switch shape {
            case "items":
                guard cols.count >= 4 else { continue }
                let name = cols[1].trimmingCharacters(in: .whitespaces)
                dump.items.append(ItemRow(name: name,
                                          count: Int(cols[3].trimmingCharacters(in: .whitespaces)) ?? 0,
                                          empty: name.isEmpty || name == "Empty"))
            case "keyRing":
                guard cols.count >= 3 else { continue }
                dump.keyRing.append(KeyRingRow(category: cols[0].trimmingCharacters(in: .whitespaces),
                                               name: cols[1].trimmingCharacters(in: .whitespaces)))
            default:
                continue
            }
        }
        return dump
    }
}

// MARK: - Which witness counts (countSource.ts)

enum SkyCountSource: String, CaseIterable, Identifiable {
    case both, log, inventory
    var id: String { rawValue }

    /// A player who never opened the dropdown counts by `both`: the dump only covers what was OPEN
    /// when it was written, so it can never be the sole witness without hiding banked items.
    static let `default`: SkyCountSource = .both

    var label: String {
        switch self {
        case .both: return "Both (higher of the two)"
        case .log: return "Log only (ever looted)"
        case .inventory: return "Export only (as dumped)"
        }
    }

    /// The same fact as a sentence fragment, for a line that reads "counting from …".
    var phrase: String {
        switch self {
        case .both: return "the log and the inventory export, whichever holds more of each item"
        case .log: return "the looted log only - the inventory export is ignored"
        case .inventory: return "the inventory export only - the looted log is ignored"
        }
    }

    /// Is the dump in play at all? Under `log` the file could be a year old and not one number
    /// on screen would differ.
    var readsInventory: Bool { self != .log }
}

// MARK: - A count stated by hand (itemOverrides.ts)

struct SkyItemOverride: Codable, Hashable {
    var key: String
    var name: String
    var count: Int
    var setAt: Int64
}

// MARK: - Reconcile

/// The turn-in consumption of a set of quests: how many of each item those turn-ins spent, and
/// which quests to blame.
struct SkyConsumption {
    var consumed: [String: Int] = [:]
    var consumedBy: [String: [String]] = [:]

    init(quests: [SkyQuestDef], times: (String) -> Int) {
        for q in quests {
            let count = times(q.key)
            if count <= 0 { continue }
            for it in q.items {
                let k = SkyName.countKey(it.name)
                let need = it.count > 0 ? it.count : 1
                consumed[k] = (consumed[k] ?? 0) + need * count
                consumedBy[k, default: []].append(count > 1 ? "\(q.name) x\(count)" : q.name)
            }
        }
    }
}

struct SkyReconcileInput {
    var log: [String: Int]
    var inv: [String: Int]              // raw dump names lowercased
    var lootNames: [String: String]
    var countSource: SkyCountSource
    var quests: [SkyQuestDef]
    var turnInCounts: [String: Int]     // key -> how many times, all witnesses
    var detectedInstants: [String: [Int64]]
    var overrides: [String: SkyItemOverride]
    var lootSinceOverride: [String: Int]
    var destroyedSinceOverride: [String: Int]
    var allInstants: [String: [Int64]]
    var dumpAt: Int64?                  // the dump's generation instant, when we can date it
    var lootSinceDump: [String: Int]
    var destroyedSinceDump: [String: Int]
}

struct SkyInventoryRow: Identifiable {
    var key: String
    var name: String
    var log: Int
    var inv: Int
    var base: Int
    var consumed: Int
    var net: Int
    var consumedBy: [String]
    var override: SkyItemOverride?
    var id: String { key }
}

struct SkyReconcileResult {
    var net: [String: Int] = [:]
    var rows: [SkyInventoryRow] = []
}

func skyReconcile(_ x: SkyReconcileInput) -> SkyReconcileResult {
    // Names: the quest bundle's spelling first, the log's on top of it, the dump's for keys neither
    // knows, an override's last.
    var nameByKey: [String: String] = [:]
    for q in x.quests { for it in q.items { nameByKey[SkyName.countKey(it.name)] = nameByKey[SkyName.countKey(it.name)] ?? it.name } }
    for (k, n) in x.lootNames { nameByKey[k] = n }

    var invByKey: [String: Int] = [:]
    for (rawK, n) in x.inv {
        let k = SkyName.countKey(rawK)
        invByKey[k] = (invByKey[k] ?? 0) + n
        if nameByKey[k] == nil { nameByKey[k] = rawK }
    }
    for (k, o) in x.overrides where nameByKey[k] == nil { nameByKey[k] = o.name }

    let all = SkyConsumption(quests: x.quests, times: { x.turnInCounts[$0] ?? 0 })

    // A windowed consumption is the same fold over the turn-ins recorded after an instant.
    var windowCache: [Int64: SkyConsumption] = [:]
    func windowed(_ instants: [String: [Int64]], _ at: Int64) -> SkyConsumption {
        SkyConsumption(quests: x.quests, times: { key in (instants[key] ?? []).filter { $0 > at }.count })
    }
    func windowedAll(_ at: Int64) -> SkyConsumption {
        if let hit = windowCache[at] { return hit }
        let c = windowed(x.allInstants, at)
        windowCache[at] = c
        return c
    }

    // The dump's window uses the DETECTED (log-witnessed) turn-ins: those are the ones the dump
    // cannot have accounted for.
    let dumpAt: Int64? = x.countSource == .log ? nil : x.dumpAt
    let dumpWindow: SkyConsumption? = dumpAt.map { windowed(x.detectedInstants, $0) }
    let lootSinceDump: [String: Int] = (x.countSource == .both && dumpAt != nil) ? x.lootSinceDump : [:]

    var out = SkyReconcileResult()
    var keys = Set(x.log.keys)
    keys.formUnion(invByKey.keys)
    keys.formUnion(all.consumed.keys)
    keys.formUnion(x.overrides.keys)

    for k in keys {
        let l = x.log[k] ?? 0
        let i = invByKey[k] ?? 0
        let consumed = all.consumed[k] ?? 0
        let invDestroyed = x.destroyedSinceDump[k] ?? 0
        let invConsumed = dumpWindow?.consumed[k] ?? 0
        let invSince = lootSinceDump[k] ?? 0
        let dumpBase = max(0, i + invSince - invDestroyed)
        let dumpNet = max(0, dumpBase - invConsumed)
        let fromLog = max(0, l - consumed)

        var base: Int
        var net: Int
        var blame: [String]
        if let o = x.overrides[k] {
            // A hand-stated count is a statement about one item at one moment: loot since counts on
            // top, destroys since come off, and only turn-ins recorded since then are spent.
            let oBase = max(0, o.count + (x.lootSinceOverride[k] ?? 0) - (x.destroyedSinceOverride[k] ?? 0))
            let oWindow = windowedAll(o.setAt)
            let oConsumed = oWindow.consumed[k] ?? 0
            base = oBase
            net = max(0, oBase - oConsumed)
            blame = oWindow.consumedBy[k] ?? []
        } else {
            switch x.countSource {
            case .log: base = l; net = fromLog
            case .inventory: base = dumpBase; net = dumpNet
            case .both: base = max(l, dumpBase); net = max(dumpNet, fromLog)
            }
            let dumpAnswered = x.countSource == .inventory
                || (x.countSource == .both && dumpBase >= l && dumpNet >= fromLog)
            if let w = dumpWindow, dumpAnswered { blame = w.consumedBy[k] ?? [] }
            else { blame = all.consumedBy[k] ?? [] }
        }

        let spent = base - net
        out.net[k] = net
        if l == 0 && i == 0 && spent == 0 && x.overrides[k] == nil { continue }
        out.rows.append(SkyInventoryRow(key: k, name: nameByKey[k] ?? k, log: l, inv: i,
                                        base: base, consumed: spent, net: net,
                                        consumedBy: spent > 0 ? blame : [],
                                        override: x.overrides[k]))
    }
    out.rows.sort { a, b in a.net == b.net ? a.name < b.name : a.net > b.net }
    return out
}
