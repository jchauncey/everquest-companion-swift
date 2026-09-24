// The Combat dashboard's stats strip: the one mob on screen (or the fight) in a row of numbers —
// dps, your damage with your pet's, the damage it did to you, the experience it gave and what came
// off its corpse.
//
// The damage numbers are the segment's own. Kills, experience, ability points, loot and corpse coin
// come from the log (`combat.rewards`, read unattributed from a window running past the fight's
// last swing) and are handed to the mob that earned them here (`fightPayout`), where the pull's
// mobs are known.
import SwiftUI
import EQCompanionCore

// MARK: - What a fight paid

struct FightPayout: Equatable {
    struct Drop: Equatable, Identifiable {
        var item: String
        var count: Int64
        /// Auto-sold at loot rather than kept.
        var sold: Bool
        var id: String { item }
    }

    var kills = 0
    /// Experience messages credited to the kills, and the percent they stated (nil when none did).
    var expGains = 0
    var expPct: Double?
    var aa: Int64 = 0
    var loot: [Drop] = []
    var copper: Int64 = 0
}

/// A kill's experience and ability points are logged in the same instant as the kill, or a moment
/// after it.
let payoutKillLagMs: Int64 = 3_000
/// A kill logged this long past the fight's last swing still belongs to it (a DoT, a pet's finish).
let payoutEndSlackMs: Int64 = 5_000

/// The share of `combat.rewards` that `mobs` earned in a fight that ended at `fightEnd`.
///
/// - A kill is a death of one of `mobs` logged by the fight's end.
/// - Experience and ability points go to the nearest death (at most `payoutKillLagMs` before them,
///   or in the same second after), whoever died: in a pull each kill pays in turn.
/// - Loot is the lines naming one of `mobs` as the corpse, from its kill on, and only until the
///   same name dies again after the fight (the next camp of that mob).
/// - Corpse coin names no mob, so it is counted only when `coin` is set (a one-mob fight): from the
///   kill until the next death after the fight.
func fightPayout(_ raw: JSONValue, mobs: [String], fightEnd: Int64, coin: Bool) -> FightPayout {
    let names = Set(mobs.map { $0.lowercased() })
    let deaths = (raw["deaths"].array ?? [])
        .map { (ts: $0["ts"].int64 ?? 0, name: ($0["name"].string ?? "").lowercased()) }
        .sorted { $0.ts < $1.ts }
    let lastIn = fightEnd + payoutEndSlackMs
    let ours = deaths.filter { names.contains($0.name) && $0.ts <= lastIn }
    var out = FightPayout(kills: ours.count)
    guard let firstKill = ours.first?.ts else { return out }

    // The nearest death: the game can log the experience a line before the kill, in the same second.
    func earned(_ ts: Int64) -> Bool {
        let near = deaths.filter { $0.ts >= ts - payoutKillLagMs && $0.ts <= ts + 1_000 }
        guard let d = near.min(by: { abs($0.ts - ts) < abs($1.ts - ts) }) else { return false }
        return names.contains(d.name) && d.ts <= lastIn
    }
    for e in raw["exp"].array ?? [] where earned(e["ts"].int64 ?? 0) {
        out.expGains += 1
        if let p = e["pct"].double { out.expPct = (out.expPct ?? 0) + p }
    }
    for a in raw["aa"].array ?? [] where earned(a["ts"].int64 ?? 0) {
        out.aa += a["amount"].int64 ?? 0
    }

    var drops: [FightPayout.Drop] = []
    for l in raw["loot"].array ?? [] {
        let ts = l["ts"].int64 ?? 0
        let source = (l["source"].string ?? "").lowercased()
        guard names.contains(source), ts >= firstKill - 1_000 else { continue }
        if deaths.contains(where: { $0.name == source && $0.ts > lastIn && $0.ts <= ts }) { continue }
        let item = l["item"].string ?? ""
        let sold = l["disposition"].string == "sold"
        let n = max(1, l["count"].int64 ?? 1)
        if let i = drops.firstIndex(where: { $0.item == item && $0.sold == sold }) { drops[i].count += n }
        else { drops.append(FightPayout.Drop(item: item, count: n, sold: sold)) }
    }
    out.loot = drops

    if coin {
        let until = deaths.first { $0.ts > lastIn }?.ts ?? .max
        for c in raw["coin"].array ?? [] {
            let ts = c["ts"].int64 ?? 0
            if ts >= firstKill, ts < until { out.copper += c["copper"].int64 ?? 0 }
        }
    }
    return out
}

/// A fight's name as the picker shows it, without the level and the count of extra mobs:
/// "A revultant rat (3) +5" → "A revultant rat".
func fightMobName(_ name: String) -> String {
    var s = name
    if let r = s.range(of: #"\s*\+\d+$"#, options: .regularExpression) { s.removeSubrange(r) }
    if let r = s.range(of: #"\s*\(\d+\)$"#, options: .regularExpression) { s.removeSubrange(r) }
    return s
}

/// Your damage and your pet's in a segment: the `you` and `pet` sources.
func ownDamage(_ seg: JSONValue) -> (you: Double, pet: Double) {
    var you = 0.0, pet = 0.0
    for e in seg["entities"].array ?? [] {
        switch e["kind"].string {
        case "you": you += e["total"].double ?? 0
        case "pet": pet += e["total"].double ?? 0
        default: break
        }
    }
    return (you, pet)
}

// MARK: - Loading

/// `combat.rewards` for the fight on screen, read once per window. The window runs
/// `FightRewardsLoader.tailMs` past the fight's last swing, so a fight that just ended is read again
/// as its loot comes in (the key moves with the clock until the tail has passed).
@MainActor
@Observable
final class FightRewardsLoader {
    var raw: JSONValue = .null
    private var key = ""

    static let tailMs: Int64 = 90_000

    static func key(startTs: Int64, endTs: Int64, now: Int64) -> String {
        let settled = now > endTs + tailMs
        return "\(startTs)|\(endTs)" + (settled ? "" : "|\(now / 5_000)")
    }

    func clear() { key = ""; raw = .null }

    func load(_ model: AppModel, startTs: Int64, endTs: Int64, now: Int64) async {
        let k = Self.key(startTs: startTs, endTs: endTs, now: now)
        guard k != key else { return }
        if !key.hasPrefix("\(startTs)|") { raw = .null }
        key = k
        guard let r = try? await model.client.request(Op.combatRewards,
                                                      ["from": .int(startTs - 1_000), "to": .int(endTs + Self.tailMs)],
                                                      deadline: 15),
              key == k else { return }
        raw = r
    }
}

// MARK: - The strip

struct CombatStatsStrip: View {
    var seg: JSONValue
    var payout: FightPayout?
    /// Your and your pet's damage by class (CombatClasses.swift); empty when the loadout is unknown.
    var classes: [ClassShare] = []
    /// Whose numbers these are: the mob's name, for the labels.
    var subject: String?

    var body: some View {
        let own = ownDamage(seg)
        FlowLayout(spacing: 8) {
            tile(CFmt.num(seg["outDps"].double ?? 0), "total dps",
                 "\(CFmt.num(seg["outTotal"].double ?? 0)) damage over \(CFmt.dur(seg["durationSec"].double ?? 0))")
            tile(CFmt.num(own.you + own.pet), own.pet > 0 ? "your damage + pet" : "your damage",
                 own.pet > 0 ? "You \(CFmt.num(own.you)) · pet \(CFmt.num(own.pet))" : "Your own damage")
            if !classes.isEmpty { classTile }
            tile(CFmt.num(seg["inTotal"].double ?? 0), subject == nil ? "damage taken" : "it did to you",
                 subject.map { "Damage \($0) landed on you" } ?? "Damage this fight landed on you")
            tile(expValue, expLabel, expHelp)
            lootTile
        }
    }

    private var expValue: String {
        guard let p = payout else { return "…" }
        if let pct = p.expPct { return String(format: "%.2f%%", pct) }
        return p.expGains > 0 ? "×\(p.expGains)" : "–"
    }

    private var expLabel: String {
        guard let p = payout, p.aa > 0 else { return "experience" }
        return "experience · +\(p.aa) AA"
    }

    private var expHelp: String {
        guard let p = payout else { return "Reading the log…" }
        if p.kills == 0 { return "No kill of this mob was logged" }
        let kills = "\(p.kills) kill\(p.kills == 1 ? "" : "s")"
        if p.expGains == 0 { return "\(kills), no experience logged" }
        return p.expPct == nil ? "\(kills); the log didn't state the percent" : kills
    }

    private func tile(_ value: String, _ label: String, _ help: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.gold).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.caption).foregroundStyle(Theme.textDim).lineLimit(1).truncationMode(.middle)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(width: 132, height: 58, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.paper))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
        .help(help)
    }

    /// Your dps split by the class that did it: a stacked bar and a line per class.
    private var classTile: some View {
        VStack(alignment: .leading, spacing: 3) {
            GeometryReader { g in
                HStack(spacing: 1) {
                    ForEach(classes) { c in
                        Rectangle().fill(ClassColor.of(c.cls)).frame(width: max(2, g.size.width * c.pct / 100 - 1))
                    }
                }
            }
            .frame(height: 5).clipShape(Capsule())
            FlowLayout(spacing: 8) {
                ForEach(classes) { c in
                    HStack(spacing: 3) {
                        Text(c.cls).font(.system(size: 10, weight: .semibold)).foregroundStyle(ClassColor.of(c.cls))
                        Text(CFmt.num(c.dps)).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text).monospacedDigit()
                    }
                    .help("\(c.cls): \(CFmt.num(c.total)) damage, \(CFmt.pct0(c.pct)) of yours" + (c.cls == otherClass ? " — procs, clicks and spells more than one of your classes has" : ""))
                }
            }
            Text("dps by class").font(.caption).foregroundStyle(Theme.textDim)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .frame(width: 220, height: 58, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.paper))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
    }

    /// The corpse: each drop and its count, sold ones dim, and the coin.
    private var lootTile: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("LOOT").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.textFaint)
                if let c = payout?.copper, c > 0 {
                    Text(Coin.text(c)).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.gold)
                }
            }
            if let p = payout {
                if p.loot.isEmpty && p.copper == 0 {
                    Text(p.kills == 0 ? "no kill logged" : "nothing looted")
                        .font(.caption).foregroundStyle(Theme.textFaint)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(p.loot) { d in
                                HStack(spacing: 4) {
                                    Text(d.item).lineLimit(1)
                                        .foregroundStyle(d.sold ? Theme.textDim : Theme.text)
                                    if d.count > 1 { Text("×\(d.count)").foregroundStyle(Theme.textDim) }
                                    if d.sold { Text("sold").foregroundStyle(Theme.textFaint) }
                                }
                                .font(.caption)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                Text("reading the log…").font(.caption).foregroundStyle(Theme.textFaint)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .frame(width: 240, height: 58, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.paper))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
    }
}
