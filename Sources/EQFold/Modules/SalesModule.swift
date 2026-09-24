// What this character sold, and for how much. NOT A PORT: upstream has no such module. It folds lines
// the parser already produces, and adds nothing to any event, so the parser oracle and every
// ported module's golden are untouched:
//
//   loot, disposition `sold` - `You looted a Rusty Short Sword from a skeleton's corpse and sold it
//                              for 2 silver and 1 copper.` The auto-sell. The price is only in the
//                              raw line (the parser records the item, the corpse and `sold`), so it
//                              is read from there: every `<n> <denomination>` after `sold it for`,
//                              or `free`.
//   coin, source `vendor`    - `You receive 2 silver 4 copper from A Shady Swashbuckler for the
//                              Rusty Short Sword(s).` A merchant sale. The coins are the parser's
//                              own `coins` object; the item is the text between `for the` and the
//                              closing `(s).`.
//   unknown, `… from Reward Chest and sold it for …` - a dungeon crawl's chest auto-sells as well,
//                              but the ported parser's pattern wants `corpse`, so the line arrives
//                              unclassified and is read whole here.
//
// Money is kept in copper (platinum 1000, gold 100, silver 10). A sale "for free" is a sale: it is
// counted, at zero, because "how much of what I loot is worthless" is a question worth answering.
import Foundation
import EQLog
import EQCompanionCore

public final class SalesModule: EqModule {
    public let id = "sales"

    /// One item's sales, summed.
    struct ItemSales: Equatable {
        var item: String
        var count: Int64 = 0
        var copper: Int64 = 0
        var lastTs: Int64 = 0

        var json: JSONValue {
            ["item": .string(item), "count": .int(count), "copper": .int(copper), "lastTs": .int(lastTs)]
        }

        static func from(_ v: JSONValue) -> ItemSales? {
            guard let item = v["item"].string, let count = v["count"].int64, let copper = v["copper"].int64,
                  let lastTs = v["lastTs"].int64 else { return nil }
            return ItemSales(item: item, count: count, copper: copper, lastTs: lastTs)
        }
    }

    /// One channel's totals: the auto-sell at loot, or a merchant.
    struct Totals: Equatable {
        var sales: Int64 = 0
        var items: Int64 = 0
        var copper: Int64 = 0
        var free: Int64 = 0

        var json: JSONValue {
            ["sales": .int(sales), "items": .int(items), "copper": .int(copper), "free": .int(free)]
        }

        static func from(_ v: JSONValue) -> Totals? {
            guard let s = v["sales"].int64, let i = v["items"].int64, let c = v["copper"].int64,
                  let f = v["free"].int64 else { return nil }
            return Totals(sales: s, items: i, copper: c, free: f)
        }
    }

    private var auto = Totals()
    private var vendor = Totals()
    /// Keyed by the item's lowercased name, first-seen order.
    private var byItem = JSMap<ItemSales>()
    private var firstTs: Int64 = 0
    private var lastTs: Int64 = 0
    private var seq: Int64 = 0
    private var announce = Announce()

    /// How many items the snapshot lists, most coin first. The totals always cover every sale.
    public static let listedItems = 50

    public init() {}

    public func reset() {
        auto = Totals(); vendor = Totals(); byItem.clear()
        firstTs = 0; lastTs = 0; seq = 0
        announce.reset()
    }

    public func onEvent(_ ev: Event, live: Bool) {
        seq = ev.seq
        switch ev.kindOf {
        case .epoch:
            // Character rebirth: the new character has sold nothing.
            auto = Totals(); vendor = Totals(); byItem.clear(); firstTs = 0; lastTs = 0
            announce.changed(seq)
        case .loot:
            guard ev.str(.disposition) == "sold", let price = Self.autoSellPrice(ev.raw) else { return }
            let count = max(1, ev.int(.count) ?? 1)
            record(&auto, ev.str(.item) ?? "", count: count, copper: price, ts: ev.ts)
        case .coin:
            guard ev.str(.source) == "vendor", let item = Self.vendorItem(ev.raw) else { return }
            let copper = Self.copper(ev.toJSON()["coins"])
            record(&vendor, item, count: 1, copper: copper, ts: ev.ts)
        case .unknown:
            // A dungeon crawl's Reward Chest auto-sells too, and the ported parser's sold pattern
            // wants `corpse`, so those lines arrive unclassified. Read here rather than in the
            // parser, whose output is held byte-identical to the Rust engine's.
            guard ev.raw.contains(" from Reward Chest and sold it for "),
                  let (item, count) = Self.chestSoldItem(ev.raw),
                  let price = Self.autoSellPrice(ev.raw) else { return }
            record(&auto, item, count: count, copper: price, ts: ev.ts)
        default:
            return
        }
    }

    private func record(_ t: inout Totals, _ item: String, count: Int64, copper: Int64, ts: Int64) {
        t.sales += 1
        t.items += count
        t.copper += copper
        if copper == 0 { t.free += 1 }
        let key = item.lowercased()
        var s = byItem[key] ?? ItemSales(item: item)
        s.count += count; s.copper += copper; s.lastTs = max(s.lastTs, ts)
        byItem.insert(key, s)
        if firstTs == 0 || ts < firstTs { firstTs = ts }
        lastTs = max(lastTs, ts)
        announce.changed(seq)
    }

    public var publishedSeq: Int64? { announce.cursor }

    public func snapshot() -> JSONValue {
        let top = Rust.stableSorted(byItem.values) { a, b in a.copper != b.copper ? a.copper > b.copper : a.count > b.count }
            .prefix(Self.listedItems)
        return ["seq": .int(seq), "state": [
            "auto": auto.json,
            "vendor": vendor.json,
            "copper": .int(auto.copper + vendor.copper),
            "distinctItems": .int(Int64(byItem.count)),
            "firstTs": .int(firstTs),
            "lastTs": .int(lastTs),
            "items": .array(top.map(\.json)),
        ]]
    }

    // MARK: - Reading the lines

    /// Copper per denomination.
    static let denominations: [String: Int64] = ["platinum": 1000, "gold": 100, "silver": 10, "copper": 1]

    /// The price an auto-sell line states, in copper: `free` is 0, and nil for a line that states
    /// no price at all (not a sale this module understands).
    static func autoSellPrice(_ raw: String) -> Int64? {
        guard let at = raw.range(of: "sold it for ") else { return nil }
        let tail = raw[at.upperBound...]
        if tail.hasPrefix("free") { return 0 }
        var total: Int64 = 0
        var found = false
        var number: Int64? = nil
        // Words split on spaces only: a comma is both the list separator (`1 gold, 4 silver`) and a
        // thousands separator (`1,204 platinum`), so it is trimmed off a word's end, not split on.
        for word in tail.split(separator: " ") {
            let w = word.trimmingCharacters(in: CharacterSet(charactersIn: ",."))
            if let n = Int64(w.replacingOccurrences(of: ",", with: "")) {
                number = n
            } else if let n = number, let per = denominations[w] {
                total += n * per
                found = true
                number = nil
            } else {
                number = nil
            }
        }
        return found ? total : nil
    }

    /// The item a merchant sale names: the text after `for the ` up to the trailing `(s).`.
    static func vendorItem(_ raw: String) -> String? {
        guard let at = raw.range(of: " for the ", options: .backwards) else { return nil }
        var item = String(raw[at.upperBound...])
        if item.hasSuffix(".") { item.removeLast() }
        if item.hasSuffix("(s)") { item.removeLast(3) }
        item = item.trimmingCharacters(in: .whitespaces)
        return item.isEmpty ? nil : item
    }

    /// `You looted 3 Undead Froglok Tongue from Reward Chest and sold it for …` → (item, count).
    static func chestSoldItem(_ raw: String) -> (String, Int64)? {
        guard let start = raw.range(of: "] You looted "),
              let end = raw.range(of: " from Reward Chest and sold it for ", range: start.upperBound..<raw.endIndex)
        else { return nil }
        let text = String(raw[start.upperBound..<end.lowerBound])
        let words = text.split(separator: " ", maxSplits: 1).map(String.init)
        guard words.count == 2 else { return text.isEmpty ? nil : (text, 1) }
        if words[0] == "a" || words[0] == "an" { return (words[1], 1) }
        if let n = Int64(words[0]) { return (words[1], n) }
        return (text, 1)
    }

    /// A `coins` object (`{"gold": 1, "silver": 6}`) in copper.
    static func copper(_ coins: JSONValue) -> Int64 {
        var total: Int64 = 0
        for (den, per) in denominations { total += (coins[den].int64 ?? 0) * per }
        return total
    }
}

// MARK: - Checkpoint

extension SalesModule: FoldCheckpointable {
    public func checkpointState() -> JSONValue {
        .object([
            "auto": auto.json,
            "vendor": vendor.json,
            "byItem": byItem.checkpoint(\.json),
            "firstTs": .int(firstTs),
            "lastTs": .int(lastTs),
            "seq": .int(seq),
            "announce": .int(announce.cursor),
        ])
    }

    public func restoreCheckpoint(_ state: JSONValue) -> Bool {
        reset()
        guard let a = Totals.from(state["auto"]), let v = Totals.from(state["vendor"]),
              let items = JSMap<ItemSales>.fromCheckpoint(state["byItem"], ItemSales.from),
              let first = state["firstTs"].int64, let last = state["lastTs"].int64,
              let savedSeq = state["seq"].int64, let cursor = state["announce"].int64 else { return false }
        auto = a; vendor = v; byItem = items; firstTs = first; lastTs = last; seq = savedSeq
        announce.restore(cursor: cursor)
        return true
    }
}
