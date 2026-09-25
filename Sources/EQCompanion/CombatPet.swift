// The Combat dashboard's pet card: your pet's fight on its own. What it hit with (its source row's
// lanes, from the engine) beside what it cast (`combat.petLog`, read from the log by its name), and
// the damage it took, the heals it got and the buffs on it.
//
// A cast line names no target, so the casts are the whole pull's even when one mob is on screen;
// the damage it took is kept to that mob.
import SwiftUI
import EQCompanionCore

// MARK: - The pet's fight

struct PetBreakdown: Equatable {
    struct Ability: Equatable, Identifiable {
        var name: String
        /// Damage it landed under this name (the engine's lane), and how.
        var total: Double = 0
        var hits = 0
        var crits = 0
        /// Casts begun under this name, and how many of them were resisted (from the log).
        var casts = 0
        var resisted = 0
        var id: String { name.lowercased() }
    }

    struct Attacker: Equatable, Identifiable {
        var name: String
        var total: Double
        var hits: Int
        var misses: Int
        var id: String { name.lowercased() }
    }

    var name: String
    var total: Double
    var dps: Double
    var abilities: [Ability] = []
    var taken: [Attacker] = []
    var takenTotal: Double { taken.reduce(0) { $0 + $1.total } }
    /// Healing that landed on it: its own (a lifetap) and everyone else's.
    var selfHealed: Double = 0
    var healedByOthers: Double = 0
    var buffs: [String] = []
}

/// Your pet in a segment: the `pet` source that did the most. nil when you had none.
func segmentPet(_ seg: JSONValue) -> JSONValue? {
    (seg["entities"].array ?? []).filter { $0["kind"].string == "pet" }
        .max { ($0["total"].double ?? 0) < ($1["total"].double ?? 0) }
}

/// The pet card's content: the pet's source row (its lanes) joined by name with its casts from the
/// log, its damage taken (from `mob` only, when one mob of a pull is on screen), heals and buffs.
func petBreakdown(_ pet: JSONValue, log: JSONValue, mob: String?) -> PetBreakdown {
    var out = PetBreakdown(name: pet["name"].string ?? "Pet", total: pet["total"].double ?? 0,
                           dps: pet["dps"].double ?? 0)
    var abilities: [PetBreakdown.Ability] = []
    func index(_ name: String) -> Int {
        if let i = abilities.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) { return i }
        abilities.append(.init(name: name))
        return abilities.count - 1
    }
    for s in pet["skills"].array ?? [] {
        let i = index(s["name"].string ?? "")
        abilities[i].total += s["total"].double ?? 0
        abilities[i].hits += s["hits"].int ?? 0
        abilities[i].crits += s["crits"].int ?? 0
    }
    for c in log["casts"].array ?? [] {
        let i = index(c["spell"].string ?? "")
        abilities[i].casts += c["casts"].int ?? 0
        abilities[i].resisted += c["resisted"].int ?? 0
    }
    out.abilities = abilities.sorted {
        $0.total != $1.total ? $0.total > $1.total : $0.casts > $1.casts
    }
    out.taken = (log["taken"].array ?? [])
        .map { PetBreakdown.Attacker(name: $0["attacker"].string ?? "", total: $0["total"].double ?? 0,
                                     hits: $0["hits"].int ?? 0, misses: $0["misses"].int ?? 0) }
        .filter { a in mob.map { mobKey(a.name) == mobKey($0) } ?? true }
        .sorted { $0.total > $1.total }
    for h in log["healed"].array ?? [] {
        if h["healer"].string == "itself" { out.selfHealed += h["total"].double ?? 0 }
        else { out.healedByOthers += h["total"].double ?? 0 }
    }
    out.buffs = (log["buffs"].array ?? []).compactMap(\.string)
    return out
}

// MARK: - Loading

/// `combat.petLog` for the pet in the fight on screen, read once per window, and again every few
/// seconds while the fight is still open.
@MainActor
@Observable
final class PetLogLoader {
    var raw: JSONValue = .null
    private var key = ""

    static func key(pet: String, startTs: Int64, endTs: Int64, live: Bool, now: Int64) -> String {
        "\(pet)|\(startTs)|\(endTs)" + (live ? "|\(now / 5_000)" : "")
    }

    func clear() { key = ""; raw = .null }

    func load(_ model: AppModel, pet: String, startTs: Int64, endTs: Int64, live: Bool, now: Int64) async {
        let k = Self.key(pet: pet, startTs: startTs, endTs: endTs, live: live, now: now)
        guard k != key else { return }
        if !key.hasPrefix("\(pet)|\(startTs)|") { raw = .null }
        key = k
        guard let r = try? await model.client.request(Op.combatPetLog,
                                                      ["from": .int(startTs - 1_000), "to": .int(endTs + 2_000),
                                                       "pet": .string(pet)], deadline: 15),
              key == k else { return }
        raw = r
    }
}

// MARK: - The card

struct CombatPetCard: View {
    var pet: PetBreakdown
    /// The log has been read (casts, damage taken and heals are known).
    var logRead: Bool

    var body: some View {
        CombatCard(title: "Pet · \(pet.name)", caps: false, trailing: {
            Text("\(CFmt.num(pet.total)) · \(CFmt.rate(pet.dps))")
                .font(.caption).foregroundStyle(CombatColor.pet).monospacedDigit()
        }) {
            HStack(alignment: .top, spacing: 14) {
                abilities.frame(maxWidth: .infinity)
                facts.frame(width: 170, alignment: .leading)
            }
        }
    }

    private var abilities: some View {
        let top = max(1, pet.abilities.map(\.total).max() ?? 1)
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("ABILITY").frame(maxWidth: .infinity, alignment: .leading)
                Text("CASTS").frame(width: 50, alignment: .trailing)
            }
            .font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.textFaint)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(pet.abilities) { a in
                        HStack(spacing: 6) {
                            MeterBarRow(rank: nil, color: CombatColor.pet, pct: a.total / top * 100, name: a.name,
                                        badges: a.crits > 0 ? [("\(a.crits) crit", Theme.textDim)] : [],
                                        right: a.total > 0 ? "\(CFmt.num(a.total)) · \(a.hits) hit\(a.hits == 1 ? "" : "s")" : "–")
                            Text(castText(a)).font(.system(size: 11)).monospacedDigit()
                                .foregroundStyle(a.resisted > 0 ? CombatColor.resist : Theme.textDim)
                                .frame(width: 50, alignment: .trailing)
                                .help(a.resisted > 0 ? "\(a.resisted) of \(a.casts) resisted" : "")
                        }
                    }
                    if pet.abilities.isEmpty { CombatNote("It landed nothing in this fight.") }
                }
            }
        }
    }

    private func castText(_ a: PetBreakdown.Ability) -> String {
        guard a.casts > 0 else { return logRead ? "" : "…" }
        return a.resisted > 0 ? "\(a.casts) (\(a.resisted)r)" : "\(a.casts)"
    }

    private var facts: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !logRead {
                Text("reading the log…").font(.caption).foregroundStyle(Theme.textFaint)
            } else {
                fact("TOOK", pet.takenTotal > 0 ? CFmt.num(pet.takenTotal) : "nothing",
                     pet.taken.prefix(3).map { "\($0.name) \(CFmt.num($0.total))" + ($0.misses > 0 ? " · \($0.misses) missed" : "") })
                fact("HEALED", pet.selfHealed + pet.healedByOthers > 0 ? CFmt.num(pet.selfHealed + pet.healedByOthers) : "nothing",
                     [pet.selfHealed > 0 ? "itself \(CFmt.num(pet.selfHealed))" : nil,
                      pet.healedByOthers > 0 ? "by others \(CFmt.num(pet.healedByOthers))" : nil].compactMap { $0 })
                if !pet.buffs.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("BUFFS LANDED").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.textFaint)
                        FlowLayout(spacing: 4) {
                            ForEach(pet.buffs, id: \.self) { b in
                                Text(b).font(.system(size: 10)).foregroundStyle(Theme.textDim)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Capsule().fill(Theme.paperRaised))
                            }
                        }
                    }
                }
            }
        }
    }

    private func fact(_ label: String, _ value: String, _ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(label).font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.textFaint)
                Text(value).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text).monospacedDigit()
            }
            ForEach(lines, id: \.self) { l in
                Text(l).font(.caption).foregroundStyle(Theme.textDim).lineLimit(1)
            }
        }
    }
}
