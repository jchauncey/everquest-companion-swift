// The Combat dashboard's stats strip — the one mob on screen (or the fight) in a row of numbers:
// dps with your stance, your damage with your pet's, dps by class, the damage it did to you and
// the experience it gave — and the loot card, what came off its corpse.
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

/// One of your combat modifiers as the dps tile shows it: numbered, with its kind in the tooltip.
struct StatModifier: Identifiable {
    var slot: Int
    /// "combat stance", "invocation", "blade coats".
    var what: String
    var value: String
    var color: Color
    var id: Int { slot }
}

/// The headline cards, spread across the width in the Leveling tab's style (`BigStat` /
/// `AccentCard`): each its own accent colour and icon, all one height.
struct CombatStatsStrip: View {
    var seg: JSONValue
    var payout: FightPayout?
    /// Your and your pet's damage by class (CombatClasses.swift); empty when the loadout is unknown.
    var classes: [ClassShare] = []
    /// Your stance, invocation and coats, shown under the dps; empty for a fight that is not the
    /// current or last one (they are what you have now, not what you had then).
    var modifiers: [StatModifier] = []
    var inCombat = false
    /// Whose numbers these are: the mob's name, for the labels.
    var subject: String?

    private static let purple = Color(hex: 0xb07fd0)

    var body: some View {
        let own = ownDamage(seg)
        let secs = max(1, seg["durationSec"].double ?? 0)
        HStack(alignment: .top, spacing: 12) {
            dpsCard
            card(CFmt.num(own.you + own.pet), own.pet > 0 ? "your damage + pet" : "your damage",
                 sub: own.pet > 0 ? "you \(CFmt.num(own.you)) · pet \(CFmt.num(own.pet))" : "no pet",
                 color: Theme.blue, icon: "person.fill")
            if !classes.isEmpty { classCard }
            card(CFmt.num(seg["inTotal"].double ?? 0), subject == nil ? "damage taken" : "it did to you",
                 sub: "\(CFmt.rate((seg["inTotal"].double ?? 0) / secs)) at you",
                 color: CombatColor.enemy, icon: "shield.lefthalf.filled")
                .help(subject.map { "Damage \($0) landed on you" } ?? "Damage this fight landed on you")
            card(expValue, "experience", sub: expSub, color: Theme.green, icon: "star.fill")
                .help(expHelp)
        }
        // One height for the row: the tallest card's, the others stretched to it.
        .fixedSize(horizontal: false, vertical: true)
    }

    private func card(_ value: String, _ label: String, sub: String?, color: Color, icon: String) -> some View {
        AccentCard(color: color, icon: icon, fill: true) {
            Text(value).font(.system(size: 26, weight: .semibold)).foregroundStyle(color).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.callout).foregroundStyle(Theme.text).lineLimit(1)
            if let sub { Text(sub).font(.caption).foregroundStyle(Theme.textDim).lineLimit(1) }
        }
    }

    private var expValue: String {
        guard let p = payout else { return "…" }
        if let pct = p.expPct { return String(format: "%.2f%%", pct) }
        return p.expGains > 0 ? "×\(p.expGains)" : "–"
    }

    /// The kills behind it, and any ability points they gave.
    private var expSub: String? {
        guard let p = payout else { return "reading the log" }
        var parts: [String] = []
        parts.append(p.kills == 0 ? "no kill logged" : "\(p.kills) kill\(p.kills == 1 ? "" : "s")")
        if p.aa > 0 { parts.append("+\(p.aa) AA") }
        return parts.joined(separator: " · ")
    }

    private var expHelp: String {
        guard let p = payout else { return "Reading the log…" }
        if p.kills == 0 { return "No kill of this mob was logged" }
        if p.expGains == 0 { return "No experience was logged for the kill" }
        return p.expPct == nil ? "The log didn't state the percent" : "Experience from the kill"
    }

    /// The headline: dps with the fight's total and length, and your modifiers under it.
    private var dpsCard: some View {
        AccentCard(color: Theme.gold, icon: "flame.fill", fill: true) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(CFmt.num(seg["outDps"].double ?? 0)).font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Theme.gold).monospacedDigit().lineLimit(1)
                if inCombat {
                    Circle().fill(Theme.green).frame(width: 7, height: 7).help("In combat")
                }
            }
            Text("total dps").font(.callout).foregroundStyle(Theme.text)
            Text("\(CFmt.num(seg["outTotal"].double ?? 0)) · \(CFmt.dur(seg["durationSec"].double ?? 0))")
                .font(.caption).foregroundStyle(Theme.textDim).monospacedDigit().lineLimit(1)
            if !modifiers.isEmpty {
                HStack(spacing: 6) {
                    ForEach(modifiers) { m in
                        Text(m.value.prefix(1).uppercased() + m.value.dropFirst())
                            .font(.caption.weight(.semibold)).foregroundStyle(m.color).lineLimit(1)
                            .help("Modifier \(m.slot) - \(m.what): \(m.value)")
                    }
                }
            }
        }
        .help("\(CFmt.num(seg["outTotal"].double ?? 0)) damage over \(CFmt.dur(seg["durationSec"].double ?? 0))")
    }

    /// Your dps split by the class that did it: a stacked bar and each class's dps.
    private var classCard: some View {
        AccentCard(color: Self.purple, icon: "chart.bar.fill", fill: true) {
            FlowLayout(spacing: 8) {
                ForEach(classes) { c in
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(c.cls).font(.caption.weight(.semibold)).foregroundStyle(ClassColor.of(c.cls))
                        Text(CFmt.num(c.dps)).font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Theme.text).monospacedDigit()
                    }
                    .help("\(c.cls): \(CFmt.num(c.total)) damage, \(CFmt.pct0(c.pct)) of yours" + (c.cls == otherClass ? " — procs, clicks and spells more than one of your classes has" : ""))
                }
            }
            Text("dps by class").font(.callout).foregroundStyle(Theme.text)
            GeometryReader { g in
                HStack(spacing: 1) {
                    ForEach(classes) { c in
                        Rectangle().fill(ClassColor.of(c.cls)).frame(width: max(2, g.size.width * c.pct / 100 - 1))
                    }
                }
            }
            .frame(height: 5).clipShape(Capsule()).padding(.top, 4)
        }
    }
}

// MARK: - The loot card

/// What came off the corpse: each drop with its count (sold ones dim and tagged), and the coin.
struct CombatLootCard: View {
    var payout: FightPayout?

    var body: some View {
        CombatCard(title: "Loot", trailing: {
            if let c = payout?.copper, c > 0 {
                Text(Coin.text(c)).font(.caption.weight(.semibold)).foregroundStyle(Theme.gold)
            }
        }) {
            if let p = payout {
                if p.loot.isEmpty {
                    CombatNote(p.kills == 0 ? "No kill of this mob was logged, so there is no corpse to read."
                                            : "Nothing was looted from this corpse.")
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(p.loot) { d in
                                HStack(spacing: 6) {
                                    Text(d.item).font(.callout).lineLimit(1)
                                        .foregroundStyle(d.sold ? Theme.textDim : Theme.text)
                                    if d.count > 1 {
                                        Text("×\(d.count)").font(.caption).foregroundStyle(Theme.textDim).monospacedDigit()
                                    }
                                    Spacer(minLength: 4)
                                    if d.sold {
                                        Text("sold").font(.system(size: 9)).foregroundStyle(Theme.textFaint)
                                            .padding(.horizontal, 5).padding(.vertical, 1)
                                            .background(Capsule().fill(Theme.paperRaised))
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                CombatNote("Reading the log…")
            }
        }
    }
}
