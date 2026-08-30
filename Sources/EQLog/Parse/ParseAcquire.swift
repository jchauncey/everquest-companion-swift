// Port of eqlog/src/parse/acquire.rs — every sentence in which an item or a coin reaches the player
// without a corpse in it: coin, itemReceived, purchase.
import Foundation

/// The chat marker: the guard on the one shape here that starts with free text.
private let CHAT_QUOTE_MARKER = ", '"

final class AcquireRes {
    let coinToken: Re
    let coinSeparators: Re
    let coinCorpse: Re
    let coinItem: Re
    let coinVendor: Re
    let coinBare: Re
    let purchase: Re
    let itemInventory: Re
    let itemOverflow: Re
    let itemFashioned: Re

    init() {
        let s = JS.S
        coinToken = Re("([0-9][0-9,]*) (platinum|gold|silver|copper)")
        coinSeparators = Re("^[\(JS.S_INNER),]*(?:and[\(JS.S_INNER),]*)*$")
        coinCorpse = Re("^You receive (.+?) from the corpse\\.$")
        coinItem = Re("^You received (.+?) from that item\\.$")
        coinVendor = Re("^You receive (.+?) from (.+?) for the (.+)\\(s\\)\\.$")
        coinBare = Re("^You received? (.+?)\(s)*\\.$")
        purchase = Re("^You purchased ([0-9]+) (.+?) from (.+?) for (.*)\\.$")
        itemInventory = Re("^(.+?) has been placed in your inventory!$")
        itemOverflow = Re("^Your inventory is full\\. (.+?) has been added to your overflow items!")
        itemFashioned = Re("^You have fashioned the items together to create something new: (.+?)\\.$")
    }
}

/// Take every `<digits> <denomination>` pair in order, then prove the clause held nothing else.
/// That proof is what lets the callers anchor loosely.
private func parseCoins(_ r: AcquireRes, _ clause: String) -> [(String, Int64)]? {
    var coins: [(String, Int64)] = []
    var rest = ""
    var last = clause.startIndex
    var found = 0
    for m in r.coinToken.allCaptures(clause) {
        rest += clause[last..<m.start]
        last = m.end
        guard let amount = Int64(m.s(1).replacingOccurrences(of: ",", with: "")) else { return nil }
        let denom: String
        switch m.s(2) {
        case "platinum": denom = "platinum"
        case "gold": denom = "gold"
        case "silver": denom = "silver"
        default: denom = "copper"
        }
        // A denomination stated twice would be a shape nobody has seen; refuse rather than pick.
        if coins.contains(where: { $0.0 == denom }) { return nil }
        coins.append((denom, amount))
        found += 1
    }
    if found == 0 { return nil }
    rest += clause[last...]
    return r.coinSeparators.isMatch(rest) ? coins : nil
}

/// The four coin sentences, tried in the order their anchors get looser.
private func classifyCoin(_ r: AcquireRes, _ c: Ctx, _ out: Ev) -> Bool {
    if let m = r.coinCorpse.captures(c.text) {
        if let coins = parseCoins(r, m.s(1)) {
            out.begin(.coin)
            out.envelope(c.seq, c.ts, c.raw)
            out.s(.source, "corpse")
            out.coins(.coins, coins)
            return true
        }
    }
    if let m = r.coinItem.captures(c.text) {
        if let coins = parseCoins(r, m.s(1)) {
            out.begin(.coin)
            out.envelope(c.seq, c.ts, c.raw)
            out.s(.source, "item")
            out.coins(.coins, coins)
            return true
        }
    }
    if let m = r.coinVendor.captures(c.text) {
        if let coins = parseCoins(r, m.s(1)) {
            out.begin(.coin)
            out.envelope(c.seq, c.ts, c.raw)
            out.s(.source, "vendor")
            out.coins(.coins, coins)
            out.s(.npc, JS.trim(m.s(2)))
            out.s(.item, JS.trim(m.s(3)))
            return true
        }
    }
    if let m = r.coinBare.captures(c.text) {
        if let coins = parseCoins(r, m.s(1)) {
            out.begin(.coin)
            out.envelope(c.seq, c.ts, c.raw)
            out.s(.source, "unstated")
            out.coins(.coins, coins)
            return true
        }
    }
    return false
}

/// The merchant buy. An empty price clause is the free form and is honest as `{}`.
private func classifyPurchase(_ r: AcquireRes, _ c: Ctx, _ out: Ev) -> Bool {
    guard let m = r.purchase.captures(c.text) else {
        return false
    }
    let clause = JS.trim(m.s(4))
    let price: [(String, Int64)]? = clause.isEmpty ? [] : parseCoins(r, clause)
    guard let price else { return false }
    out.begin(.purchase)
    out.envelope(c.seq, c.ts, c.raw)
    out.s(.item, JS.trim(m.s(2)))
    out.i(.count, Int64(m.s(1)) ?? 0)
    out.s(.npc, JS.trim(m.s(3)))
    out.coins(.price, price)
    return true
}

/// The three corpse-less item arrivals.
private func classifyItemArrival(_ r: AcquireRes, _ c: Ctx, _ out: Ev) -> Bool {
    let text = c.text
    if text.hasPrefix("You have fashioned ") {
        guard let m = r.itemFashioned.captures(text) else {
            return false
        }
        itemReceived(c, out, JS.trim(m.s(1)), "fashioned")
        return true
    }
    if text.hasPrefix("Your inventory is full. ") {
        guard let m = r.itemOverflow.captures(text) else {
            return false
        }
        itemReceived(c, out, JS.trim(m.s(1)), "overflow")
        return true
    }
    if text.hasSuffix(" has been placed in your inventory!") && !text.contains(CHAT_QUOTE_MARKER) {
        guard let m = r.itemInventory.captures(text) else {
            return false
        }
        itemReceived(c, out, JS.trim(m.s(1)), "inventory")
        return true
    }
    return false
}

private func itemReceived(_ c: Ctx, _ out: Ev, _ item: String, _ via: String) {
    out.begin(.itemReceived)
    out.envelope(c.seq, c.ts, c.raw)
    out.s(.item, item)
    out.s(.via, via)
}

/// Every way an item or a coin reaches you that does not name a corpse. One cheap gate per family.
func classifyAcquire(_ r: AcquireRes, _ c: Ctx, _ out: Ev) -> Bool {
    if c.text.hasPrefix("You rece") {
        return classifyCoin(r, c, out)
    }
    if c.text.hasPrefix("You purchased ") {
        return classifyPurchase(r, c, out)
    }
    return classifyItemArrival(r, c, out)
}
