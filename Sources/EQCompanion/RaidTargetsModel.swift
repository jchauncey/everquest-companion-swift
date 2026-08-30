// The pure half of the Raid Targets tab: the defeat fold, the weekly loot lockout, the tier
// palette, and the class-loadout sectioning. Ported from the Electron renderer —
// `features/bosses/bossStatus.ts`, `lockout.ts`, `rosterFilter.ts`, `loadoutGroups.ts`,
// `lib/tierChip.ts`, `src/shared/comboIndex.ts` — so both clients say the same thing about the
// same kill record.
import Foundation
import SwiftUI
import EQCompanionCore

// MARK: - The roster

/// One row of `bosses.json`: the name, its progression category, the log spellings that count as
/// a kill of it, its zone and its wiki portrait URL.
struct RaidTarget: Identifiable {
    var name: String
    var category: String
    var match: [String]
    var zone: String
    var image: String?

    var id: String { name }

    static func parse(_ v: JSONValue) -> RaidTarget {
        RaidTarget(name: v["name"].string ?? "",
                   category: v["category"].string ?? "",
                   match: (v["match"].array ?? []).compactMap(\.string),
                   zone: v["zone"].string ?? "",
                   image: v["image"].string)
    }

    /// The tile drawn when there is no portrait: the first letter of the first two words.
    var initials: String {
        name.filter { $0.isLetter || $0 == " " }
            .split(separator: " ").prefix(2)
            .compactMap { $0.first.map(String.init) }
            .joined()
    }
}

/// EQL raid progression order.
let raidCategoryOrder = ["Open World", "Plane of Fear", "Plane of Hate", "Plane of Sky"]

// MARK: - Defeat status (bossStatus.ts)

/// One target folded against the kill record: whether it has ever died, how often, when, and the
/// per-instance-tier breakdown behind every one of those scalars.
struct TargetStatus: Identifiable {
    var target: RaidTarget
    var killed: Bool
    var count: Int
    var bestTier: Int
    var firstTs: Int64
    var lastTs: Int64
    var credited: Int
    var tiers: [Int: KillTierRun]

    var id: String { target.name }
}

enum BossStatus {
    /// Canonical match key: lower-case plus a stripped leading article. EQ writes the same mob
    /// with a capitalized article at sentence start ("A thunder spirit princess" on slain-by
    /// lines) and lower-case mid-sentence, and roster `match` names carry no article at all — so
    /// both sides must be article-insensitive or a princess killed by a charmed pet reads as
    /// undefeated.
    static func matchKey(_ name: String) -> String {
        var s = name.lowercased()
        for article in ["a ", "an ", "the "] where s.hasPrefix(article) {
            s = String(s.dropFirst(article.count))
            break
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Re-key a kill map by the article-insensitive match key; on a collision the higher-count
    /// entry wins.
    static func lowerKillMap(_ kills: [String: KillInfo]) -> [String: KillInfo] {
        var out: [String: KillInfo] = [:]
        for (name, info) in kills {
            let k = matchKey(name)
            if let prev = out[k], prev.count >= info.count { continue }
            out[k] = info
        }
        return out
    }

    /// Fold a target's roster `match` names against the article-insensitive kill map.
    static func statusFor(_ target: RaidTarget, _ killByLower: [String: KillInfo]) -> TargetStatus {
        var tiers: [Int: KillTierRun] = [:]
        var killed = false
        for name in target.match {
            guard let info = killByLower[matchKey(name)] else { continue }
            killed = true
            for (tier, run) in info.tiers { KillRecord.add(&tiers, tier, run) }
        }
        return projected(target, killed: killed, tiers: tiers)
    }

    /// The same target seen through ONE of its tier runs — the card a loadout section draws.
    /// Every scalar is re-derived from the given runs, so the badge, the dates and the count all
    /// describe the same kills.
    static func projected(_ target: RaidTarget, killed: Bool, tiers: [Int: KillTierRun]) -> TargetStatus {
        let t = KillRecord.totals(tiers)
        return TargetStatus(target: target, killed: killed, count: t.count, bestTier: t.bestTier,
                            firstTs: t.firstTs, lastTs: t.lastTs, credited: t.credited, tiers: tiers)
    }

    @MainActor
    static func all(_ killsState: JSONValue) -> [TargetStatus] {
        let lower = lowerKillMap(KillRecord.parse(killsState))
        return GameData.shared.raidTargets.map { statusFor(RaidTarget.parse($0), lower) }
    }
}

// MARK: - The weekly loot lockout (lockout.ts)

/// The lockout week containing `now`.
struct LockoutWindow {
    /// the most recent reset instant at or before `now` (ms)
    var start: Int64
    /// the instant this window was computed for (ms)
    var now: Int64
    /// the next reset instant after `now` (ms)
    var next: Int64
}

/// One difficulty this target is locked at, and the credited kill that locked it.
struct TierLock {
    var tier: Int
    var ts: Int64
}

enum Lockout {
    /// The reset is a PACIFIC WALL-CLOCK event, so the zone is the fact and the offset is
    /// derived. A fixed -7h/-8h is wrong for half the year.
    static let timeZone = "America/Los_Angeles"
    /// SINGLE-SOURCED: weekly reset day, as `Date`'s weekday index (0 = Sunday). 2 = Tuesday.
    static let resetWeekday = 2
    /// DOUBLE-SOURCED: the reset hour, on the Pacific wall clock.
    static let resetHour = 8

    private static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: timeZone) ?? .current
        return c
    }()

    /// The lockout week `now` falls in. Timezone-independent by construction: every field is
    /// read through the Pacific calendar, so a player in Tokyo and one in Denver get the same
    /// two instants. Out-of-range day numbers are normalized by `Calendar`, which is also what
    /// makes the week containing a DST transition come out 167 or 169 hours rather than 168.
    static func window(now: Int64) -> LockoutWindow {
        let date = Date(timeIntervalSince1970: Double(now) / 1000)
        let p = calendar.dateComponents([.year, .month, .day, .hour, .weekday], from: date)
        let weekday = (p.weekday ?? 1) - 1  // Calendar counts from 1 = Sunday
        var back = (weekday - resetWeekday + 7) % 7
        // Reset day, but the hour has not come round yet: this week began a full seven days ago.
        if back == 0, (p.hour ?? 0) < resetHour { back = 7 }
        func wall(_ dayOffset: Int) -> Int64 {
            var c = DateComponents()
            c.year = p.year
            c.month = p.month
            c.day = (p.day ?? 1) + dayOffset
            c.hour = resetHour
            guard let d = calendar.date(from: c) else { return 0 }
            return Int64(d.timeIntervalSince1970 * 1000)
        }
        return LockoutWindow(start: wall(-back), now: now, next: wall(-back + 7))
    }

    /// The difficulties a target is locked at this week, lowest tier first.
    ///
    /// CREDITED, NOT MERELY OBSERVED — a boss a stranger killed across an open-world zone pays
    /// you nothing, so it cannot put you on lockout. A DIFFICULTY, NOT MERELY A KILL — the two
    /// off-ladder tier keys are skipped here, which is the one place that decision is made, so
    /// no rung anywhere can be greened by a kill that took no lockout.
    static func tierLocks(_ tiers: [Int: KillTierRun], _ w: LockoutWindow) -> [TierLock] {
        var out: [TierLock] = []
        for (tier, run) in tiers where KillRecord.isDifficulty(tier) {
            let ts = run.lastCreditedTs
            if ts == 0 || ts < w.start || ts >= w.next { continue }
            out.append(TierLock(tier: tier, ts: ts))
        }
        return out.sorted { $0.tier < $1.tier }
    }

    /// One difficulty of one boss, in the current lockout week.
    struct Rung: Identifiable {
        var tier: Int
        var cleared: Bool
        var ts: Int64
        var id: Int { tier }
    }

    /// The five rungs, lowest difficulty first. A grey rung means "this app has no credited kill
    /// of yours here this week", never "this difficulty exists and you may go".
    static func ladder(_ locks: [TierLock]) -> [Rung] {
        let byTier = Dictionary(locks.map { ($0.tier, $0.ts) }, uniquingKeysWith: { a, _ in a })
        return KillRecord.difficultyTiers.map { Rung(tier: $0, cleared: byTier[$0] != nil, ts: byTier[$0] ?? 0) }
    }

    /// Coarse time remaining in the window: `3d 4h` / `4h 12m` / `12m`.
    static func untilReset(_ w: LockoutWindow) -> String {
        let mins = Int(max(0, w.next - w.now) / 60_000)
        let days = mins / 1440
        let hours = (mins % 1440) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(mins % 60)m" }
        return "\(mins)m"
    }
}

// MARK: - The tier palette (lib/tierChip.ts)

/// The chip colours for the five difficulties plus the two off-ladder answers. The dark
/// foreground is deliberate: white on these saturated mids failed WCAG AA on every tier.
struct TierStyle {
    var bg: Color
    var fg: Color
    /// short label, e.g. `D2`
    var label: String
    /// long label, e.g. `D2 · Adaptive`
    var long: String
}

enum RaidTier {
    private static let ink = Color(hex: 0x10131a)
    private static let offLadderInk = Color(hex: 0xf3f5f8)

    static let styles: [TierStyle] = [
        TierStyle(bg: Color(hex: 0x9aa0a6), fg: ink, label: "D0", long: "D0 · base"),
        TierStyle(bg: Color(hex: 0x5fbf72), fg: ink, label: "D1", long: "D1 · Awakened"),
        TierStyle(bg: Color(hex: 0x6fb3d2), fg: ink, label: "D2", long: "D2 · Adaptive"),
        TierStyle(bg: Color(hex: 0xb07fd0), fg: ink, label: "D3", long: "D3 · Fused"),
        TierStyle(bg: Color(hex: 0xe0a94a), fg: ink, label: "D4", long: "D4 · Refined")
    ]

    /// No instance at all: a bare zone name. There is no lockout to be on.
    static let openWorld = TierStyle(bg: Color(hex: 0x4b5563), fg: offLadderInk,
                                     label: "OW", long: "Open world · no lockout")
    /// The log never said where: no zone line yet, or an adjective this app cannot decode.
    static let unknown = TierStyle(bg: Color(hex: 0x3a3f4a), fg: offLadderInk,
                                   label: "?", long: "Difficulty not stated")

    static func style(_ tier: Int) -> TierStyle {
        if tier == KillRecord.openWorld { return openWorld }
        if tier < KillRecord.openWorld { return unknown }
        return styles[min(styles.count - 1, tier)]
    }

    /// The badge text a roster card wears: `T0`…`T4` for the five difficulties, and the two
    /// off-ladder labels unchanged. (The Electron chip spells the same tier `D2`; this surface
    /// says `T2` per its own spec. Same number, same ladder — only the letter differs.)
    static func badge(_ tier: Int) -> String {
        KillRecord.isDifficulty(tier) ? "T\(tier)" : style(tier).label
    }
}

// MARK: - What "defeated" means, per view (rosterFilter.ts)

enum RosterFilter {
    /// OVERALL: a kill of this target is on the record — no window, no difficulty, no credit test.
    static func everDefeated(_ s: TargetStatus) -> Bool { s.killed }

    /// THIS WEEK: a credited kill of this target, at a real instance difficulty, inside `w`.
    /// It is `tierLocks` and nothing else, so a card is kept exactly when one of its rungs is green.
    static func defeatedThisWeek(_ w: LockoutWindow) -> (TargetStatus) -> Bool {
        { !Lockout.tierLocks($0.tiers, w).isEmpty }
    }

    /// The search box then the defeated switch, in that order of narrowing.
    static func apply(_ list: [TargetStatus], query: String, defeatedOnly: Bool,
                      defeated: (TargetStatus) -> Bool) -> [TargetStatus] {
        var out = list
        if defeatedOnly { out = out.filter(defeated) }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty { out = out.filter { $0.target.name.lowercased().contains(q) } }
        return out
    }
}

// MARK: - The class-loadout sectioning (loadoutGroups.ts + shared/comboIndex.ts)

/// One class-combo interval from the `combo` module: a contiguous stretch of one believed loadout.
struct ComboInterval {
    var id: String
    var startTs: Int64
    /// null ⇒ still running now
    var endTs: Int64?
    var levelLo: Int?
    var levelHi: Int?
    var slots: [Slot]
    var startAlso: [String]
    var levelRegressed: Bool

    struct Slot {
        var candidates: [String]
        var provenance: String
        var label: String { candidates.count == 1 ? candidates[0] : (candidates.count > 8 ? "?" : candidates.joined(separator: "/")) }
    }

    static func parse(_ v: JSONValue) -> ComboInterval {
        ComboInterval(id: v["id"].string ?? "",
                      startTs: v["startTs"].int64 ?? 0,
                      endTs: v["endTs"].int64,
                      levelLo: v["levelLo"].int,
                      levelHi: v["levelHi"].int,
                      slots: (v["slots"].array ?? []).map {
                          Slot(candidates: ($0["candidates"].array ?? []).compactMap(\.string),
                               provenance: $0["provenance"].string ?? "inferred")
                      },
                      startAlso: (v["startAlso"].array ?? []).compactMap(\.string),
                      levelRegressed: v["levelRegressed"].bool ?? false)
    }

    /// Authority over the whole interval: the strongest statement any slot carries.
    var provenance: String {
        if slots.contains(where: { $0.provenance == "user" }) { return "user" }
        if slots.contains(where: { $0.provenance == "who" }) { return "who" }
        return "inferred"
    }

    var provenanceLabel: String {
        switch provenance {
        case "user": return "you set this"
        case "who": return "stated by /who"
        default: return "inferred"
        }
    }

    /// THE CONFIDENCE GATE: may this interval's loadout be read as FACT, or has the model already
    /// said it cannot explain the span? Applies only to pure INFERENCE — a `/who` row is the game
    /// naming the loadout outright and a user correction is the owner naming it.
    var uncertain: Bool {
        if slots.contains(where: { $0.provenance != "inferred" }) { return false }
        return startAlso.contains("overDetermined") || levelRegressed
    }

    /// THE SECTION IDENTITY: every slot's candidate SET, order-insensitive across the slots. Two
    /// intervals share a section exactly when this matches.
    var loadoutKey: String {
        slots.map { $0.candidates.sorted().joined(separator: "|") }.sorted().joined(separator: "/")
    }
}

/// One card: what it draws (a tier run of the target) and the whole target behind it.
struct LoadoutCard: Identifiable {
    var s: TargetStatus
    var whole: TargetStatus
    var id: String { s.target.name }
}

/// One loadout section: the loadout its cards were killed under, and the cards.
struct LoadoutGrouping: Identifiable {
    var key: String
    /// True ⇒ the members are spans the model has said it cannot explain, so this section states
    /// NO loadout: `interval` is null even though `intervals` is not.
    var uncertain: Bool
    /// The member that SPEAKS for the section — the WEAKEST provenance, so the chips cannot
    /// upgrade a section that is partly inference. Null when the section states no loadout.
    var interval: ComboInterval?
    /// Every interval merged into this section, earliest first.
    var intervals: [ComboInterval]
    var rows: [LoadoutCard]

    var id: String { key }
}

enum LoadoutGroups {
    private static let unknownKey = "unknown"
    private static let uncertainKey = "uncertain"
    private static let provenanceRank = ["inferred": 0, "who": 1, "user": 2]

    static func intervals(_ comboState: JSONValue) -> [ComboInterval] {
        (comboState["intervals"].array ?? []).map(ComboInterval.parse).sorted { $0.startTs < $1.startTs }
    }

    /// The interval whose ESTIMATE covers `ts`, or nil. Keyed on `[startTs, endTs)` so a
    /// timestamp lands in exactly one interval and grouping is a partition.
    static func comboAt(_ intervals: [ComboInterval], _ ts: Int64) -> ComboInterval? {
        for interval in intervals.reversed() {
            if ts < interval.startTs { continue }
            if let end = interval.endTs { return ts < end ? interval : nil }
            return interval
        }
        return nil
    }

    private struct RunRow {
        var ts: Int64
        var status: TargetStatus
        var tier: Int
        var run: KillTierRun
    }

    /// A card is a TIER RUN, not a target: each run joins the intervals at ITS OWN most recent
    /// kill and is badged with ITS OWN tier, so a section header is true of every card beneath it.
    private static func runRows(_ list: [TargetStatus]) -> [RunRow] {
        var rows: [RunRow] = []
        for status in list where status.killed {
            for r in KillRecord.runs(status.tiers) where r.run.lastTs > 0 {
                rows.append(RunRow(ts: r.run.lastTs, status: status, tier: r.tier, run: r.run))
            }
        }
        return rows
    }

    /// Merge the runs that landed in one SECTION back into one card per target — a target must
    /// not appear twice under one header.
    private static func cards(_ rows: [RunRow]) -> [LoadoutCard] {
        var order: [String] = []
        var byTarget: [String: (whole: TargetStatus, tiers: [Int: KillTierRun])] = [:]
        for row in rows {
            let name = row.status.target.name
            if byTarget[name] == nil { byTarget[name] = (row.status, [:]); order.append(name) }
            KillRecord.add(&byTarget[name]!.tiers, row.tier, row.run)
        }
        return order.compactMap { name in
            guard let e = byTarget[name] else { return nil }
            return LoadoutCard(s: BossStatus.projected(e.whole.target, killed: true, tiers: e.tiers), whole: e.whole)
        }
    }

    /// The member that speaks for the section: weakest provenance, earliest on a tie.
    private static func speaker(_ members: [ComboInterval]) -> ComboInterval? {
        var best: ComboInterval?
        for m in members {
            guard let b = best else { best = m; continue }
            let delta = (provenanceRank[m.provenance] ?? 0) - (provenanceRank[b.provenance] ?? 0)
            if delta < 0 || (delta == 0 && m.startTs < b.startTs) { best = m }
        }
        return best
    }

    /// Defeated targets, split into tier runs, time-joined to the combo intervals, and sectioned
    /// by LOADOUT — every interval stating the same classes is ONE section. Undefeated targets
    /// carry no timestamp to join on and are not returned; the view keeps them in a trailing
    /// section rather than dropping or attributing them.
    static func groups(_ intervals: [ComboInterval], _ list: [TargetStatus],
                       keep: ((TargetStatus) -> Bool)? = nil) -> [LoadoutGrouping] {
        struct Pending { var key: String; var members: [ComboInterval] = []; var rows: [RunRow] = [] }
        var byKey: [String: Int] = [:]
        var ordered: [Pending] = []
        for row in runRows(list).sorted(by: { $0.ts < $1.ts }) {
            let interval = comboAt(intervals, row.ts)
            let gated = interval?.uncertain == true
            let key: String
            if let i = interval { key = gated ? uncertainKey : "combo:\(i.loadoutKey)" } else { key = unknownKey }
            if byKey[key] == nil {
                byKey[key] = ordered.count
                ordered.append(Pending(key: key))
            }
            let idx = byKey[key]!
            if let i = interval, !ordered[idx].members.contains(where: { $0.id == i.id }) { ordered[idx].members.append(i) }
            ordered[idx].rows.append(row)
        }
        var out: [LoadoutGrouping] = []
        for pending in ordered {
            let members = pending.members.sorted { $0.startTs < $1.startTs }
            let all = cards(pending.rows.sorted { $0.ts < $1.ts })
            let rows = keep.map { k in all.filter { k($0.s) } } ?? all
            if rows.isEmpty { continue }
            let uncertain = pending.key == uncertainKey
            out.append(LoadoutGrouping(key: pending.key, uncertain: uncertain,
                                       // A gated section names NO loadout — the chips are exactly
                                       // what must not be drawn — but its spans are still true.
                                       interval: uncertain ? nil : speaker(members),
                                       intervals: members, rows: rows))
        }
        return out
    }

    /// `spansText`: a merged span has HOLES in it, so the count of ranges is part of the sentence
    /// rather than a tooltip's afterthought.
    static func spansText(_ intervals: [ComboInterval]) -> String {
        if intervals.isEmpty { return "" }
        func one(_ i: ComboInterval) -> String {
            "\(Format.stamp(ms: i.startTs)) → \(i.endTs.map { Format.stamp(ms: $0) } ?? "now")"
        }
        if intervals.count == 1 { return one(intervals[0]) }
        let start = intervals.map(\.startTs).min() ?? 0
        let open = intervals.contains { $0.endTs == nil }
        let end = open ? "now" : Format.stamp(ms: intervals.compactMap(\.endTs).max() ?? 0)
        return "\(Format.stamp(ms: start)) → \(end) · \(intervals.count) ranges"
    }

    static let groupRule = "Grouped by the loadout you were running for these kills."
    static let mixedRule = "More classes showed up in these stretches than a loadout holds, or your level went backwards inside one - so a swap happened in there that nothing in the log dated. These kills are yours; which loadout took them is not something this app can honestly say."
}
