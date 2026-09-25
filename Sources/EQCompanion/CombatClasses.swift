// Your damage by class. EQ Legends runs up to three classes at once, and this says which one each
// ability belongs to — so the meter's drill colours your abilities by class, and the dashboard
// adds up how much damage each class did per second.
//
// Which classes can land a lane is the engine's answer (`combat.laneClasses`, the combo module's
// own spell and skill tables). It is narrowed here to the classes you were playing when the fight
// started (the `combo` module's loadout at that instant):
//
// - A lane only one class of your loadout can land is that class's.
// - A melee lane (`Melee`, `Kick`, `Cleave` …) that none or several of them can land goes to the
//   most melee class of the loadout (`meleePriority`).
// - Your pet's damage goes to its summoner: the loadout's pet class (`petPriority`). The log does
//   not say which spell made the pet, so this is the class that has pets, most-pet first.
// - A spell two or three of your classes share goes to the one that gets it at the lowest level
//   (the spell data lists each class's level): that is the class that can have been casting it.
// - Anything else (an item click, a proc of no spell page, a skill none of them has) is "Other".
import SwiftUI
import EQCompanionCore

let otherClass = "Other"

/// Most melee first: where a swing could be any class's, it is this list's first one you play.
let meleePriority = ["WAR", "MNK", "ROG", "BER", "PAL", "SHD", "RNG", "BST", "BRD",
                     "CLR", "SHM", "DRU", "NEC", "WIZ", "MAG", "ENC"]
/// Classes with pets, most-pet first.
let petPriority = ["NEC", "MAG", "BST", "ENC", "SHD", "SHM", "DRU", "CLR", "WIZ"]

enum ClassColor {
    static func of(_ cls: String) -> Color {
        switch cls {
        case "WAR": return Color(hex: 0xc9744f)
        case "PAL": return Color(hex: 0xf0b8cf)
        case "SHD": return Color(hex: 0x7c6fc0)
        case "BER": return Color(hex: 0xd65454)
        case "MNK": return Color(hex: 0x7fbf5f)
        case "ROG": return Color(hex: 0xe6d35a)
        case "RNG": return Color(hex: 0xa9d46f)
        case "BST": return Color(hex: 0xb58a5a)
        case "BRD": return Color(hex: 0xe89ad9)
        case "CLR": return Color(hex: 0xf2ead0)
        case "DRU": return Color(hex: 0xe08a3c)
        case "SHM": return Color(hex: 0x45b8a8)
        case "NEC": return Color(hex: 0xa678e0)
        case "WIZ": return Color(hex: 0x5b8fe0)
        case "MAG": return Color(hex: 0x5fc7e0)
        case "ENC": return Color(hex: 0xd76fb4)
        default: return Color(hex: 0x7d7d7d)
        }
    }
}

/// The classes you were playing at `ts`: the combo interval covering it (else the current one), its
/// slots that are settled on one class, in slot order.
func loadoutClasses(_ combo: JSONValue, at ts: Int64?) -> [String] {
    var pick = combo["current"]
    if let ts {
        for iv in combo["intervals"].array ?? [] {
            let start = iv["startTs"].int64 ?? 0
            let end = iv["endTs"].int64 ?? .max
            if ts >= start && ts < end { pick = iv }
        }
    }
    return (pick["slots"].array ?? []).compactMap { slot in
        let c = (slot["candidates"].array ?? []).compactMap(\.string)
        return c.count == 1 ? c[0] : nil
    }
}

struct ClassResolver: Equatable {
    var loadout: [String]
    /// "category|lane" → the classes that can land it (the engine's answer).
    var lanes: [String: [String]]
    /// "category|lane" → the level each class gets it at, where the spell data says.
    var levels: [String: [String: Int]] = [:]

    static func key(_ lane: String, _ category: String) -> String { "\(category)|\(lane)" }

    var meleeClass: String { meleePriority.first { loadout.contains($0) } ?? otherClass }
    var petClass: String { petPriority.first { loadout.contains($0) } ?? otherClass }

    func classOf(lane: String, category: String) -> String {
        guard !loadout.isEmpty else { return otherClass }
        let can = lanes[Self.key(lane, category)] ?? []
        let mine = loadout.filter { can.contains($0) }
        if mine.count == 1 { return mine[0] }
        if category == "melee" {
            return meleePriority.first { mine.contains($0) } ?? meleeClass
        }
        // Shared by several of your classes: the one that gets it first; a tie keeps loadout order.
        let at = levels[Self.key(lane, category)] ?? [:]
        let known = mine.filter { at[$0] != nil }
        if let first = known.min(by: { at[$0]! < at[$1]! }) { return first }
        return otherClass
    }

    /// A skill row's class; a group row (the Slay Undead roll-up) takes its first member's.
    func classOf(_ s: SkillRow) -> String {
        if let c = s.children?.first { return classOf(c) }
        return classOf(lane: s.name, category: s.category)
    }
}

/// Every lane a source row lists, group members included — what to ask the engine about.
func sourceLanes(_ source: JSONValue) -> [(lane: String, category: String)] {
    flattenSkills(source).flatMap { s in (s.children ?? [s]).map { ($0.name, $0.category) } }
}

struct ClassShare: Equatable, Identifiable {
    var cls: String
    var total: Double
    var dps: Double
    var pct: Double
    var id: String { cls }
}

/// Your damage (and your pets') by class, largest first; dps over `durationSec`, the segment's own
/// length — the headline dps's basis, so the classes add up to your and your pets' part of it.
func classBreakdown(you: JSONValue?, pets: [JSONValue], resolver: ClassResolver, durationSec: Double) -> [ClassShare] {
    var totals: [String: Double] = [:]
    if let you {
        for s in flattenSkills(you) {
            for m in s.children ?? [s] { totals[resolver.classOf(m), default: 0] += m.total }
        }
    }
    for p in pets { totals[resolver.petClass, default: 0] += p["total"].double ?? 0 }
    let all = totals.values.reduce(0, +)
    let secs = max(1, durationSec)
    return totals.filter { $0.value > 0 }
        .map { ClassShare(cls: $0.key, total: $0.value, dps: $0.value / secs, pct: all > 0 ? $0.value / all * 100 : 0) }
        .sorted { $0.total != $1.total ? $0.total > $1.total : $0.cls < $1.cls }
}

// MARK: - Loading

/// The engine's lane → classes answers, asked for once per lane and kept for the session.
@MainActor
@Observable
final class LaneClassesLoader {
    private(set) var known: [String: [String]] = [:]
    private(set) var levels: [String: [String: Int]] = [:]
    private var asked: Set<String> = []

    func ensure(_ model: AppModel, _ lanes: [(lane: String, category: String)]) async {
        var want: [(String, String)] = []
        for l in lanes {
            let k = ClassResolver.key(l.lane, l.category)
            if !asked.contains(k) { asked.insert(k); want.append((l.lane, l.category)) }
        }
        guard !want.isEmpty else { return }
        let body: [JSONValue] = want.map { ["lane": .string($0.0), "category": .string($0.1)] }
        guard let r = try? await model.client.request(Op.combatLaneClasses, ["lanes": .array(body)], deadline: 10),
              let classes = r["classes"].array, classes.count == want.count else {
            for w in want { asked.remove(ClassResolver.key(w.0, w.1)) }
            return
        }
        let lv = r["levels"].array ?? []
        for (i, (w, c)) in zip(want, classes).enumerated() {
            let k = ClassResolver.key(w.0, w.1)
            known[k] = (c.array ?? []).compactMap(\.string)
            if i < lv.count { levels[k] = (lv[i].object ?? [:]).compactMapValues { $0.int } }
        }
    }
}

// MARK: - The readout

/// One bar per class: its share of your damage and its dps.
struct ClassDpsBars: View {
    var shares: [ClassShare]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(shares) { s in
                MeterBarRow(rank: nil, color: ClassColor.of(s.cls), pct: s.pct, name: s.cls,
                            badges: [(CFmt.pct0(s.pct), Theme.textDim)],
                            right: "\(CFmt.num(s.total)) · \(CFmt.rate(s.dps))", bold: true)
            }
        }
    }
}
