// The Combat tab's renderer-side derivations — a faithful port of the Electron renderer's pure
// half (src/renderer/src/features/combat/dashboardData.ts, petRows.ts, procRows.ts,
// fightPickerRows.ts, meterScope.ts) plus the number/date spellings those modules read from
// src/renderer/src/lib/formatRate.ts and formatDate.ts.
//
// Everything here is a single pass over the engine's own snapshot: the authoritative totals stay
// the engine's `SourceView` bars, and only the DPS curve and the damage-by-mob grouping are
// derived — from the encounter's event ring, exactly where the Electron app derives them.
//
// HONESTY, carried over verbatim from the TS: a downsampled ring's derived numbers are scaled
// sample estimates and a truncated ring's are lower bounds, so both wear the `~` prefix
// (`isApproximate`). Observed maxima are never scaled.

import Foundation
import SwiftUI
import EQCompanionCore

// MARK: - Spellings (lib/formatRate.ts, lib/formatDate.ts, copyTable.fmtDur)

enum CFmt {
    /// `formatNum` — k/M-scaled magnitude with no unit word.
    static func num(_ n: Double) -> String {
        if n >= 1_000_000 { return String(format: "%.2fM", n / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fk", n / 1_000) }
        return String(Int(n.rounded()))
    }

    /// `formatRate` — `219 dps`, `9.6k dps`.
    static func rate(_ n: Double) -> String { "\(num(n)) dps" }

    /// `formatHealRate` — `1.2k hps`.
    static func healRate(_ n: Double) -> String { "\(num(n)) hps" }

    /// `formatSmall` — the 0–100 band the proc rates live in.
    static func small(_ n: Double) -> String {
        guard n.isFinite else { return "-" }
        let v = abs(n)
        if v >= 100 { return String(format: "%.0f", n) }
        if v >= 10 { return String(format: "%.1f", n) }
        return String(format: "%.2f", n)
    }

    static func ppm(_ n: Double) -> String { "\(small(n)) ppm" }
    static func cpm(_ n: Double) -> String { "\(small(n)) cpm" }

    /// `fmtDur` — `0:44`, `12:07`.
    static func dur(_ sec: Double) -> String {
        let s = max(0, Int(sec.rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    static func durMs(_ ms: Double) -> String { dur(ms / 1000) }

    /// A whole-percent reading, the meter's own rounding.
    static func pct0(_ p: Double) -> String { "\(Int(p.rounded()))%" }

    /// `pct` in healRows — one decimal.
    static func pct1(_ p: Double) -> String { String(format: "%.1f%%", p) }

    private static let dateOnly: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "M/d/yyyy"
        return f
    }()

    private static let clockOnly: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    /// `formatDate` — `8/28/2026`.
    static func date(_ ts: Int64) -> String {
        guard ts > 0 else { return "" }
        return dateOnly.string(from: Date(timeIntervalSince1970: Double(ts) / 1000))
    }

    /// `formatTime` — 24h `11:06:40`.
    static func clock(_ ts: Int64) -> String {
        guard ts > 0 else { return "" }
        return clockOnly.string(from: Date(timeIntervalSince1970: Double(ts) / 1000))
    }

    /// `fightPickerRows.relativeAge` — coarse on purpose, so five same-named pulls are tellable
    /// apart by start clock + age + duration.
    static func relativeAge(_ ts: Int64, now: Int64) -> String {
        guard ts > 0 else { return "" }
        let secs = max(0, Double(now - ts) / 1000)
        if secs < 45 { return "just now" }
        let mins = secs / 60
        if mins < 60 { return "\(Int(mins.rounded()))m ago" }
        let hrs = mins / 60
        if hrs < 36 { return "\(Int(hrs.rounded()))h ago" }
        return "\(Int((hrs / 24).rounded()))d ago"
    }

    /// `fightPickerRows.timingLabel` — `8/28/2026 11:06:40 · 12h ago · 0:44`.
    static func timing(startTs: Int64, durationSec: Double, now: Int64) -> String {
        var bits: [String] = []
        if startTs > 0 { bits.append("\(date(startTs)) \(clock(startTs))") }
        let age = relativeAge(startTs, now: now)
        if !age.isEmpty { bits.append(age) }
        bits.append(dur(durationSec))
        return bits.joined(separator: " · ")
    }
}

// MARK: - The palette (combatShared.KIND_COLOR / CAT_COLOR, markerStyle, ProcessingLog.ROLE_COLOR)

enum CombatColor {
    static let you = Color(hex: 0xd9b25f)
    static let pet = Color(hex: 0x6fb3d2)
    static let member = Color(hex: 0x7fbf8f)
    static let allyPet = Color(hex: 0x5b7f95)
    static let other = Color(hex: 0x5f8f74)
    static let enemy = Color(hex: 0xcf6679)
    static let resist = Color(hex: 0xe05663)
    static let heal = Color(hex: 0x7fd1a0)
    static let out = you
    static let inc = enemy

    static func kind(_ k: String) -> Color {
        switch k {
        case "you": return you
        case "pet": return pet
        case "member": return member
        case "allyPet": return allyPet
        case "other": return other
        case "enemy": return enemy
        default: return Color(hex: 0x888888)
        }
    }

    static func category(_ c: String) -> Color {
        switch c {
        case "melee": return Color(hex: 0xd9b25f)
        case "slay": return Color(hex: 0xf6f0da)
        case "spell": return Color(hex: 0xa98fe0)
        case "dot": return Color(hex: 0x6fb3d2)
        case "ds": return Color(hex: 0xcf6679)
        default: return Color(hex: 0x888888)
        }
    }

    static func marker(_ k: String) -> Color {
        switch k {
        case "stance": return Color(hex: 0xd9b25f)
        case "invocation": return Color(hex: 0xa98fe0)
        case "coat": return Color(hex: 0xc46fd2)
        case "slow": return Color(hex: 0x57e0a0)
        default: return Color(hex: 0x888888)
        }
    }

    static func origin(_ o: String) -> Color {
        switch o {
        case "poison": return Color(hex: 0xc46fd2)
        case "spell": return Color(hex: 0xa98fe0)
        case "slay": return Color(hex: 0xf6f0da)
        case "aa": return Color(hex: 0xd9b25f)
        case "click": return Color(hex: 0x6fb3d2)
        default: return Color(hex: 0x888888)
        }
    }

    static func logRole(_ r: String) -> Color {
        switch r {
        case "you": return Color(hex: 0xd9b25f)
        case "pet": return Color(hex: 0x6fb3d2)
        case "enemy": return Color(hex: 0xcf6679)
        case "info": return Color(hex: 0x9aa0aa)
        case "dropped": return Color(hex: 0xe0554f)
        default: return Theme.text
        }
    }
}

// MARK: - Scope (Fight vs Overall) and the selector rows

enum CombatScope: String, CaseIterable, Hashable { case fight, overall }

/// `dashboardData.LIVE_SELECTION` — sent to the engine as *no* `selectedId` so it re-resolves
/// every tick (open fight → that fight; none open → the most recent finalized one).
let combatLiveSelection = "__live__"

struct ScopeOption: Identifiable, Hashable {
    var value: String
    /// already carries the honest live/last wording for a head row.
    var label: String
    /// the raw name without the head-row wording.
    var name: String
    var dps: Double
    var startTs: Int64
    var durationSec: Double
    var live: Bool
    var zone: String?
    /// How many mobs the pull this row belongs to had; a row of a multi-mob pull is one of its mobs.
    var pull: Int = 1
    var id: String { value }
}

struct ScopeOptions {
    var head: ScopeOption?
    var rest: [ScopeOption]
}

/// Fight scope: the current-or-last fight, then the finalized-fight history. NO zone sessions.
func fightScopeOptions(_ segments: [JSONValue]) -> ScopeOptions {
    let open = segments.first { $0["kind"].string == "current" }
    let finalized = segments.filter { $0["kind"].string == "fight" }
    guard let headSeg = open ?? finalized.first else { return ScopeOptions(head: nil, rest: []) }
    let head = ScopeOption(
        value: combatLiveSelection,
        // State, not process: while a fight is open this row IS the current fight; between pulls
        // it is plainly the last one. It must never read "live" for a finished encounter.
        label: open != nil ? "Current fight (live)" : "Last fight - \(headSeg["name"].string ?? "")",
        name: headSeg["name"].string ?? "",
        dps: headSeg["dps"].double ?? 0,
        startTs: headSeg["startTs"].int64 ?? 0,
        durationSec: headSeg["durationSec"].double ?? 0,
        live: open != nil,
        zone: headSeg["zone"].string
    )
    let tail = open != nil ? finalized : Array(finalized.dropFirst())
    // One row per MOB: a pull that engaged several (its segment carries `targets`, when the
    // history was read with them) is listed as each of its mobs, `fightId#mob`, largest first.
    let rest = tail.flatMap { s -> [ScopeOption] in
        let id = s["id"].string ?? ""
        let dur = s["durationSec"].double ?? 0
        let one = ScopeOption(value: id, label: s["name"].string ?? "", name: s["name"].string ?? "",
                              dps: s["dps"].double ?? 0, startTs: s["startTs"].int64 ?? 0,
                              durationSec: dur, live: false, zone: s["zone"].string)
        guard let mobs = s["targets"].array, mobs.count > 1 else { return [one] }
        return mobs.compactMap { m in
            guard let name = m["name"].string else { return nil }
            var row = one
            row.value = mobSelection(id, name)
            row.label = name
            row.name = name
            row.dps = (m["total"].double ?? 0) / max(1, dur)
            row.pull = mobs.count
            return row
        }
    }
    return ScopeOptions(head: head, rest: rest)
}

/// `dashboardData.zoneSessionWord` — a stay the world ended is that zone's `overall`; one the
/// user ended with the app-wide "New session" mark is that zone's `session`.
private func zoneSessionWord(_ z: JSONValue) -> String {
    z["closedBy"].string == "mark" ? "session" : "overall"
}

/// Overall scope: the live zone session, then the finalized zone-session history. NO fights.
func overallScopeOptions(_ zoneSessions: [JSONValue]) -> ScopeOptions {
    func row(_ z: JSONValue) -> ScopeOption {
        let zone = z["zone"].string ?? ""
        let live = z["live"].bool == true
        let start = z["startTs"].int64 ?? 0
        let end = z["endTs"].int64 ?? 0
        return ScopeOption(value: z["id"].string ?? "",
                           label: "\(zone) - \(zoneSessionWord(z))",
                           name: "\(zone) - \(zoneSessionWord(z))",
                           dps: z["dps"].double ?? 0,
                           startTs: start,
                           durationSec: live ? 0 : max(1, Double(end - start) / 1000),
                           live: live,
                           zone: zone)
    }
    let liveIdx = zoneSessions.firstIndex { $0["live"].bool == true }
    var rest = zoneSessions.enumerated().filter { $0.offset != liveIdx }.map { row($0.element) }
    if let i = liveIdx { return ScopeOptions(head: row(zoneSessions[i]), rest: rest) }
    let head = rest.isEmpty ? nil : rest.removeFirst()
    return ScopeOptions(head: head, rest: rest)
}

func scopeOptions(_ scope: CombatScope, segments: [JSONValue], zoneSessions: [JSONValue]) -> ScopeOptions {
    scope == .fight ? fightScopeOptions(segments) : overallScopeOptions(zoneSessions)
}

/// The selection a scope starts on (and returns to when the user switches scopes).
func defaultSelection(_ scope: CombatScope) -> String {
    scope == .fight ? combatLiveSelection : "zone"
}

/// Is the thing on screen the LIVE one — the head row of its scope, and that row genuinely open?
/// The DPS curve's scrolling window is the one reader: a finished fight must not scroll as if
/// time were still passing in it.
func isLiveSelection(_ head: ScopeOption?, _ selection: String) -> Bool {
    guard let h = head else { return false }
    return selection == h.value && h.live
}

// MARK: - Timeline loss predicates

/// `dashboardData.sampleScale` — the unbiased estimator for a uniform-stride sample of the ring.
/// The denominator is `rawCount`, never `totalCount`: the instants the ring DROPPED are a whole
/// missing prefix, and inflating by them would be a guess.
func sampleScale(_ tl: JSONValue) -> Double {
    let events = tl["events"].array ?? []
    guard tl["downsampled"].bool == true, !events.isEmpty else { return 1 }
    return max(1, Double(tl["rawCount"].int ?? events.count) / Double(events.count))
}

/// Downsampled (scaled estimates) OR truncated (lower bounds) — one predicate, so a panel can
/// never label one loss and silently swallow the other.
func isApproximate(_ tl: JSONValue) -> Bool {
    tl["downsampled"].bool == true || tl["truncated"].bool == true
}

/// `~ 812 of 4,109 events`, or nil when the ring is exact.
func approxNote(_ tl: JSONValue) -> String? {
    guard isApproximate(tl) else { return nil }
    let shown = (tl["events"].array ?? []).count
    let of = tl["totalCount"].int ?? shown
    var why: [String] = []
    if tl["downsampled"].bool == true { why.append("sampled") }
    if tl["truncated"].bool == true { why.append("oldest dropped") }
    return "~ \(shown) of \(of) events (\(why.joined(separator: ", ")))"
}

// MARK: - DPS over time (dashboardData.buildDpsSeries)

/// Widest bucket count we ever plot.
private let dpsMaxBuckets = 360.0
/// Rolling-window width for the smoothed rate (reads as a curve, not a comb).
private let dpsSmoothMs = 5_000.0
/// How much of a LIVE fight the curve shows before it starts scrolling with `now`.
let dpsLiveWindowMs = 120_000.0

private func bucketMsFor(_ durationMs: Double, live: Bool) -> Double {
    let shown = live ? min(durationMs, dpsLiveWindowMs) : durationMs
    return max(1000, (shown / dpsMaxBuckets / 1000).rounded(.up) * 1000)
}

struct DpsSeries {
    var bucketMs: Double
    /// effective smoothing window in ms (a whole number of buckets, ≥ bucketMs).
    var smoothMs: Double
    var n: Int
    var you: [Double]
    var pet: [Double]
    /// your GROUP's contribution — every `member`/`allyPet`/`other` instant, summed. Its own band
    /// rather than folded into `you` or `inc`: a curve that filed a group-mate's damage as
    /// incoming would draw the fight upside down.
    var group: [Double]
    var inc: [Double]
    /// peak smoothed OUTGOING (you+pet+group) rate across the whole fight.
    var peakOut: Double
    var hasPet: Bool
    var hasGroup: Bool
    var hasInc: Bool
    var hasAny: Bool
    var durationMs: Double
    var estimated: Bool

    func out(_ i: Int) -> Double { you[i] + pet[i] + group[i] }
}

/// Which bucket an event at `t` milliseconds falls in, for a series of `count` buckets.
///
/// ONE FUNCTION BECAUSE THERE USED TO BE TWO. The Combat tab clamped at both ends; the Overview
/// tab's copy clamped only at the top, so an event stamped before its own encounter's start —
/// a pre-pull debuff, a clock correction, an encounter whose start was revised later — produced a
/// negative index and crashed the default tab on the next subscript. Divergent copies of a
/// bounds check are how one of them ends up wrong, so there is now nowhere for them to diverge.
///
/// The clamp is applied to the DOUBLE before the conversion: `Int(_:)` traps on a value too large
/// for `Int`, so clamping after the fact would be too late.
@inline(__always)
func dpsBucketIndex(t: Double, bucketMs: Double, count: Int) -> Int {
    guard count > 0, bucketMs > 0, t.isFinite else { return 0 }
    let raw = t / bucketMs
    guard raw.isFinite else { return 0 }
    return Int(min(Double(count - 1), max(0, raw)))
}

/// Bucket the encounter's events per `bucketMs` and smooth with a TRAILING rolling mean — the
/// same reading a live DPS meter gives ("your damage over the last 5 seconds"), so the curve's
/// height at time t is a rate you could actually have seen on screen at time t. Leading buckets
/// divide by the (shorter) elapsed window rather than the full one.
func buildDpsSeries(_ tl: JSONValue, live: Bool = false) -> DpsSeries {
    let durationMs = max(1000, tl["durationMs"].double ?? 0)
    let bucketMs = bucketMsFor(durationMs, live: live)
    let n = max(1, Int((durationMs / bucketMs).rounded(.up)))
    var rawYou = [Double](repeating: 0, count: n)
    var rawPet = rawYou, rawGroup = rawYou, rawInc = rawYou
    var hasPet = false, hasGroup = false, hasInc = false, hasAny = false
    let scale = sampleScale(tl)
    for e in tl["events"].array ?? [] {
        let amount = e["amount"].double ?? 0
        if amount <= 0 { continue }
        let i = dpsBucketIndex(t: e["t"].double ?? 0, bucketMs: bucketMs, count: n)
        hasAny = true
        switch e["kind"].string ?? "" {
        case "you": rawYou[i] += amount
        case "pet": rawPet[i] += amount; hasPet = true
        // EXPLICIT, not a default arm: "everything that is not you or your pet is incoming" is
        // exactly the assumption a fourth source kind breaks — a group-mate's nuke drawn as
        // damage taken.
        case "member", "allyPet", "other": rawGroup[i] += amount; hasGroup = true
        default: rawInc[i] += amount; hasInc = true
        }
    }
    let w = max(1, Int((dpsSmoothMs / bucketMs).rounded()))
    func smooth(_ src: [Double]) -> [Double] {
        var out = [Double](repeating: 0, count: n)
        var run = 0.0
        for i in 0..<n {
            run += src[i]
            if i >= w { run -= src[i - w] }
            let spanSec = Double(min(i + 1, w)) * bucketMs / 1000
            out[i] = run * scale / spanSec
        }
        return out
    }
    let you = smooth(rawYou), pet = smooth(rawPet), group = smooth(rawGroup), inc = smooth(rawInc)
    var peakOut = 0.0
    for i in 0..<n { peakOut = max(peakOut, you[i] + pet[i] + group[i]) }
    return DpsSeries(bucketMs: bucketMs, smoothMs: Double(w) * bucketMs, n: n,
                     you: you, pet: pet, group: group, inc: inc,
                     peakOut: peakOut, hasPet: hasPet, hasGroup: hasGroup, hasInc: hasInc,
                     hasAny: hasAny, durationMs: durationMs,
                     // A truncated ring is inexact even at scale 1, so the flag is the loss
                     // predicate, not the scale.
                     estimated: isApproximate(tl))
}

/// The visible window (dpsChart.buildDpsChart): a LIVE fight past two minutes shows only its last
/// two minutes; a finalized fight is drawn whole. Both ends land on the bucket grid.
struct DpsWindow {
    var i0: Int
    var count: Int
    var t0: Double
    var t1: Double
    var scrolling: Bool
    /// peak outgoing rate WITHIN the visible window — what the card's header quotes.
    var peakVis: Double
}

func dpsWindow(_ s: DpsSeries, live: Bool) -> DpsWindow {
    let scrolling = live && Double(s.n) * s.bucketMs > dpsLiveWindowMs
    let i0 = scrolling ? max(0, s.n - Int((dpsLiveWindowMs / s.bucketMs).rounded(.up))) : 0
    var peak = 0.0
    for i in i0..<s.n { peak = max(peak, s.out(i)) }
    return DpsWindow(i0: i0, count: s.n - i0,
                     t0: Double(i0) * s.bucketMs, t1: Double(s.n) * s.bucketMs,
                     scrolling: scrolling, peakVis: peak)
}

// MARK: - Damage by mob (dashboardData.groupByTarget)

/// Unnamed defender fallback — kept visible rather than silently dropped.
private let unknownTarget = "unknown target"

/// CASE FOLD. EQ capitalizes an article-led mob name at SENTENCE START and leaves it lowercase
/// mid-sentence, so one spawn reaches the ring under two spellings. The lowercase-INITIAL variant
/// wins the label because that is the spawn's real name — the capital is punctuation, not
/// identity; a mob only ever seen capitalized keeps its capital.
private func startsLower(_ name: String) -> Bool {
    guard let c = name.first else { return false }
    return String(c) == String(c).lowercased() && String(c) != String(c).uppercased()
}

private func preferredLabel(_ shown: String, _ next: String) -> String {
    if shown == next { return shown }
    return !startsLower(shown) && startsLower(next) ? next : shown
}

struct MobRow: Identifiable, Hashable {
    var target: String
    var total: Double
    var hits: Int
    var crits: Int
    var misses: Int
    var resists: Int
    /// pct of the LARGEST mob's total (bar fill).
    var pct: Double
    /// pct of all event-derived outgoing damage (the ranked share).
    var share: Double
    var id: String { target }
}

struct MobBreakdown {
    var rows: [MobRow]
    var total: Double
    var estimated: Bool
}

/// Group OUTGOING instants (you + pet + group) by defender. One pass; misses/resists fold into
/// the same row as damage-free counters.
func groupByTarget(_ tl: JSONValue) -> MobBreakdown {
    if let rows = tl["digestRows"].array { return groupDigestByTarget(rows, estimated: isApproximate(tl)) }
    let scale = sampleScale(tl)
    var order: [String] = []
    var byTarget: [String: MobRow] = [:]
    var total = 0.0
    for e in tl["events"].array ?? [] {
        if e["kind"].string == "enemy" { continue }
        let name = e["target"].string ?? unknownTarget
        let key = name.lowercased()
        var row = byTarget[key]
        if row == nil {
            row = MobRow(target: name, total: 0, hits: 0, crits: 0, misses: 0, resists: 0, pct: 0, share: 0)
            order.append(key)
        } else {
            row!.target = preferredLabel(row!.target, name)
        }
        switch e["outcome"].string {
        case "miss": row!.misses += 1
        case "resist": row!.resists += 1
        default:
            let amount = e["amount"].double ?? 0
            row!.total += amount
            row!.hits += 1
            if e["crit"].bool == true { row!.crits += 1 }
            total += amount
        }
        byTarget[key] = row
    }
    var rows = order.compactMap { byTarget[$0] }
    for i in rows.indices {
        rows[i].total *= scale
        rows[i].hits = Int((Double(rows[i].hits) * scale).rounded())
        rows[i].crits = Int((Double(rows[i].crits) * scale).rounded())
        rows[i].misses = Int((Double(rows[i].misses) * scale).rounded())
        rows[i].resists = Int((Double(rows[i].resists) * scale).rounded())
    }
    total *= scale
    rows.sort { a, b in
        if a.total != b.total { return a.total > b.total }
        if a.hits != b.hits { return a.hits > b.hits }
        return a.target < b.target
    }
    let maxTotal = max(1, rows.map(\.total).max() ?? 1)
    for i in rows.indices {
        rows[i].pct = rows[i].total / maxTotal * 100
        rows[i].share = total > 0 ? rows[i].total / total * 100 : 0
    }
    return MobBreakdown(rows: rows, total: total, estimated: isApproximate(tl))
}

// MARK: - Skill rows (dashboardData.flattenSkills + skillGroups)

struct SkillRow: Identifiable, Hashable {
    var name: String
    var category: String
    var total: Double
    var pct: Double
    var hits: Int
    var crits: Int
    var misses: Int
    var resists: Int
    var maxHit: Int
    var minHit: Int
    /// a GROUP row's members (the Slay Undead aggregate), ranked among themselves.
    var children: [SkillRow]?
    var id: String { "\(category)|\(name)" }
}

/// `skillGroups.rankRows` — sort by damage desc and re-base every bar width on the list maximum.
private func rankRows(_ rows: [SkillRow]) -> [SkillRow] {
    var out = rows.sorted { a, b in
        if a.total != b.total { return a.total > b.total }
        if a.hits != b.hits { return a.hits > b.hits }
        return a.name < b.name
    }
    let maxTotal = max(1, out.map(\.total).max() ?? 1)
    for i in out.indices { out[i].pct = out[i].total / maxTotal * 100 }
    return out
}

/// `skillGroups.mergeGroup` — one group row carrying its members as `children`. `max` is the
/// largest single hit across the children and `min` the smallest LANDED one (0/absent minima are
/// skipped, so a resist/miss-only lane never pulls the group minimum to nothing).
private func mergeGroup(_ members: [SkillRow], name: String, category: String) -> SkillRow {
    var children = members.sorted { a, b in
        if a.total != b.total { return a.total > b.total }
        if a.hits != b.hits { return a.hits > b.hits }
        return a.name < b.name
    }
    let childMax = max(1, children.map(\.total).max() ?? 1)
    for i in children.indices { children[i].pct = children[i].total / childMax * 100 }
    let minima = children.map(\.minHit).filter { $0 > 0 }
    return SkillRow(name: name, category: category,
                    total: children.reduce(0) { $0 + $1.total },
                    pct: 0,
                    hits: children.reduce(0) { $0 + $1.hits },
                    crits: children.reduce(0) { $0 + $1.crits },
                    misses: children.reduce(0) { $0 + $1.misses },
                    resists: children.reduce(0) { $0 + $1.resists },
                    maxHit: children.map(\.maxHit).max() ?? 0,
                    minHit: minima.min() ?? 0,
                    children: children)
}

/// Collapse every `slay`-category row into ONE "Slay Undead" aggregate. A Slay Undead proc is a
/// normal weapon swing that carries the proc, so the flatten names it after the weapon verb and
/// the flat list grows a run of near-duplicate rows that are all the same THING. A SINGLE slay
/// skill is left exactly as it is — a group of one wraps nothing.
func groupSlay(_ rows: [SkillRow]) -> [SkillRow] {
    let slay = rows.filter { $0.category == "slay" }
    if slay.count < 2 { return rows }
    let group = mergeGroup(slay, name: "Slay Undead", category: "slay")
    return rankRows(rows.filter { $0.category != "slay" } + [group])
}

private func skillRow(_ s: JSONValue, category: String) -> SkillRow {
    SkillRow(name: s["name"].string ?? "",
             category: category,
             total: s["total"].double ?? 0,
             pct: 0,
             hits: s["hits"].int ?? 0,
             crits: s["crits"].int ?? 0,
             misses: s["misses"].int ?? 0,
             resists: s["resists"].int ?? 0,
             maxHit: s["max"].int ?? 0,
             minHit: s["min"].int ?? 0,
             children: nil)
}

/// Flatten a source's per-category skill lists into ONE list ranked by damage desc, re-basing
/// each bar on the global max (the engine's `pct` is relative to the skill's own category max,
/// which would make small categories render full-width here). The slay rows then collapse.
///
/// NOT PORTED: `groupSpellComponents` (JOS-244 — the two message shapes of one spell merging into
/// one row) and the per-ability multi-attack/riposte readings, which live one level down in the
/// Electron drill's inline expansion.
func flattenSkills(_ e: JSONValue) -> [SkillRow] {
    var rows: [SkillRow] = []
    for c in e["categories"].array ?? [] {
        let category = c["category"].string ?? ""
        for s in c["skills"].array ?? [] { rows.append(skillRow(s, category: category)) }
    }
    // A source the engine served without category rollups still has its flat `skills` list.
    if rows.isEmpty {
        rows = (e["skills"].array ?? []).map { skillRow($0, category: "melee") }
    }
    return groupSlay(rankRows(rows))
}

/// `dashboardData.skillsForTarget` — the flat lane list for everything you and your allies landed
/// on ONE mob, from the event ring. You + pet are COMBINED: the panel answers "what killed this
/// mob", not "who". `max`/`min` are unscaled observations.
struct TargetDetail {
    var rows: [SkillRow]
    var total: Double
    var hits: Int
    var crits: Int
    var misses: Int
    var resists: Int
    var estimated: Bool
}

func skillsForTarget(_ tl: JSONValue, target: String) -> TargetDetail {
    if let rows = tl["digestRows"].array { return digestSkillsForTarget(rows, target: target, estimated: isApproximate(tl)) }
    let scale = sampleScale(tl)
    let want = target.lowercased()
    var order: [String] = []
    var byLane: [String: SkillRow] = [:]
    var total = 0.0, hits = 0, crits = 0, misses = 0, resists = 0
    for e in tl["events"].array ?? [] {
        if e["kind"].string == "enemy" { continue }
        if (e["target"].string ?? unknownTarget).lowercased() != want { continue }
        let category = e["category"].string ?? ""
        let lane = e["lane"].string ?? ""
        let key = "\(category)|\(lane)"
        var row = byLane[key] ?? {
            order.append(key)
            return SkillRow(name: lane, category: category, total: 0, pct: 0, hits: 0, crits: 0,
                            misses: 0, resists: 0, maxHit: 0, minHit: 0, children: nil)
        }()
        switch e["outcome"].string {
        case "miss": row.misses += 1; misses += 1
        case "resist": row.resists += 1; resists += 1
        default:
            let amount = e["amount"].double ?? 0
            row.total += amount
            row.hits += 1
            hits += 1
            if e["crit"].bool == true { row.crits += 1; crits += 1 }
            if Int(amount) > row.maxHit { row.maxHit = Int(amount) }
            if row.minHit == 0 || Int(amount) < row.minHit { row.minHit = Int(amount) }
            total += amount
        }
        byLane[key] = row
    }
    var rows = order.compactMap { byLane[$0] }
    for i in rows.indices {
        rows[i].total *= scale
        rows[i].hits = Int((Double(rows[i].hits) * scale).rounded())
        rows[i].crits = Int((Double(rows[i].crits) * scale).rounded())
        rows[i].misses = Int((Double(rows[i].misses) * scale).rounded())
        rows[i].resists = Int((Double(rows[i].resists) * scale).rounded())
    }
    return TargetDetail(rows: groupSlay(rankRows(rows)),
                        total: total * scale,
                        hits: Int((Double(hits) * scale).rounded()),
                        crits: Int((Double(crits) * scale).rounded()),
                        misses: Int((Double(misses) * scale).rounded()),
                        resists: Int((Double(resists) * scale).rounded()),
                        estimated: isApproximate(tl))
}

// MARK: - Source rows and the pet fold (petRows.ts)

struct MeterSource: Identifiable, Hashable {
    var id: String
    var name: String
    var kind: String
    var total: Double
    var dps: Double
    var pct: Double
    var hits: Int
    var misses: Int
    var crits: Int
    var resists: Int
    var critPct: Double
    var hitPct: Double
    var resistPct: Double
    var ambiguousHits: Int
    var ambiguousTotal: Double
    var missBreakdown: [String: Int]
    /// the engine's own row, kept so a drill can read the parts this struct does not lift.
    var raw: JSONValue
}

private let missKeys = ["miss", "dodge", "parry", "riposte", "block", "absorb"]

func meterSource(_ e: JSONValue) -> MeterSource {
    var mb: [String: Int] = [:]
    for k in missKeys { mb[k] = e["missBreakdown"][k].int ?? 0 }
    return MeterSource(id: e["id"].string ?? "",
                       name: e["name"].string ?? "",
                       kind: e["kind"].string ?? "other",
                       total: e["total"].double ?? 0,
                       dps: e["dps"].double ?? 0,
                       pct: e["pct"].double ?? 0,
                       hits: e["hits"].int ?? 0,
                       misses: e["misses"].int ?? 0,
                       crits: e["crits"].int ?? 0,
                       resists: e["resists"].int ?? 0,
                       critPct: e["critPct"].double ?? 0,
                       hitPct: e["hitPct"].double ?? 0,
                       resistPct: e["resistPct"].double ?? 0,
                       ambiguousHits: e["ambiguousHits"].int ?? 0,
                       ambiguousTotal: e["ambiguousTotal"].double ?? 0,
                       missBreakdown: mb,
                       raw: e)
}

/// Landed detrimental spell/dot hits — the resist rate's denominator, minus the resists
/// themselves. Melee/slay/ds hits can't be resisted, so they are not casts.
private func spellHits(_ e: JSONValue) -> Int {
    (e["categories"].array ?? []).reduce(0) { n, c in
        let cat = c["category"].string ?? ""
        return n + (cat == "spell" || cat == "dot" ? (c["hits"].int ?? 0) : 0)
    }
}

/// YOUR LEVEL-1 BAR WITH THE PETS INSIDE IT. Every counter is SUMMED FROM IDENTITIES and the
/// three percentages re-derived from those sums by the engine's own formulas, never blended from
/// the sources' percentages. `skills`/`categories`/`rounds` stay YOURS — the pet is a line item
/// one level down, not a lane of yours.
private func combinedSelf(_ selfRow: JSONValue, pets: [JSONValue]) -> MeterSource {
    let all = [selfRow] + pets
    var m = meterSource(selfRow)
    m.total = all.reduce(0) { $0 + ($1["total"].double ?? 0) }
    m.dps = all.reduce(0) { $0 + ($1["dps"].double ?? 0) }
    m.hits = all.reduce(0) { $0 + ($1["hits"].int ?? 0) }
    m.misses = all.reduce(0) { $0 + ($1["misses"].int ?? 0) }
    m.crits = all.reduce(0) { $0 + ($1["crits"].int ?? 0) }
    m.resists = all.reduce(0) { $0 + ($1["resists"].int ?? 0) }
    // The pet's name-ambiguity travels WITH its damage: folding the row must not fold away the
    // one badge that says some of these hits may belong to a hostile twin.
    m.ambiguousHits = all.reduce(0) { $0 + ($1["ambiguousHits"].int ?? 0) }
    m.ambiguousTotal = all.reduce(0) { $0 + ($1["ambiguousTotal"].double ?? 0) }
    m.critPct = m.hits > 0 ? Double(m.crits) / Double(m.hits) * 100 : 0
    let swings = m.hits + m.misses
    m.hitPct = swings > 0 ? Double(m.hits) / Double(swings) * 100 : 100
    let casts = all.reduce(0) { $0 + spellHits($1) } + m.resists
    m.resistPct = casts > 0 ? Double(m.resists) / Double(casts) * 100 : 0
    var mb: [String: Int] = [:]
    for k in missKeys { mb[k] = all.reduce(0) { $0 + ($1["missBreakdown"][k].int ?? 0) } }
    m.missBreakdown = mb
    return m
}

/// THE LEVEL-1 SOURCE LIST every damage meter ranks — the engine's rows with the pet-nesting
/// preference applied. `pct` is re-based over the surviving rows because it is a BAR WIDTH.
///
/// `combine` is the SURFACE's allowance ("this meter nests pets at all"); the user's answer is
/// Preferences → Combat → "Show your pet inside your damage", and it is read HERE so that one
/// switch governs every damage meter and no two surfaces can draw the same fight differently.
func meterSources(_ entities: [JSONValue], combine: Bool) -> [MeterSource] {
    let plain = entities.map(meterSource)
    guard combine, Prefs.shared.petInline,
          let selfRow = entities.first(where: { $0["kind"].string == "you" })
    else { return plain }
    let pets = entities.filter { $0["kind"].string == "pet" }
    if pets.isEmpty { return plain }
    let petIds = Set(pets.compactMap { $0["id"].string })
    var kept: [MeterSource] = []
    for e in entities {
        let id = e["id"].string ?? ""
        if petIds.contains(id) { continue }
        kept.append(id == (selfRow["id"].string ?? "") ? combinedSelf(selfRow, pets: pets) : meterSource(e))
    }
    kept.sort { $0.total > $1.total }
    let maxTotal = max(1, kept.map(\.total).max() ?? 1)
    for i in kept.indices { kept[i].pct = kept[i].total / maxTotal * 100 }
    return kept
}

/// One pet, as the synthetic line item that stands for it inside your breakdown.
struct PetLine: Identifiable, Hashable {
    var id: String
    var name: String
    var total: Double
    var dps: Double
    var hits: Int
    var crits: Int
    var misses: Int
    var resists: Int
    var pct: Double
}

/// ONE source's flat skill list with `pets` nested in as line items, ranked together. Bar widths
/// are re-based on the MERGED maximum — the pet is often the largest row.
enum OwnRow: Identifiable, Hashable {
    case skill(SkillRow)
    case pet(PetLine)

    var total: Double {
        switch self {
        case .skill(let s): return s.total
        case .pet(let p): return p.total
        }
    }

    var label: String {
        switch self {
        case .skill(let s): return s.name
        case .pet(let p): return p.name
        }
    }

    var id: String {
        switch self {
        case .skill(let s): return "skill:\(s.id)"
        case .pet(let p): return "pet:\(p.id)"
        }
    }
}

func nestedRows(_ source: JSONValue, pets: [JSONValue]) -> [OwnRow] {
    var merged: [OwnRow] = source.isNull ? [] : flattenSkills(source).map { OwnRow.skill($0) }
    // The same one switch `meterSources` reads: with nesting off the pet keeps its own bar at
    // level 1 and nothing is nested here, so its damage is never listed twice.
    for p in (Prefs.shared.petInline ? pets : []) {
        merged.append(.pet(PetLine(id: p["id"].string ?? "",
                                   name: p["name"].string ?? "",
                                   total: p["total"].double ?? 0,
                                   dps: p["dps"].double ?? 0,
                                   hits: p["hits"].int ?? 0,
                                   crits: p["crits"].int ?? 0,
                                   misses: p["misses"].int ?? 0,
                                   resists: p["resists"].int ?? 0,
                                   pct: 0)))
    }
    merged.sort { a, b in a.total != b.total ? a.total > b.total : a.label < b.label }
    let maxTotal = max(1, merged.map(\.total).max() ?? 1)
    return merged.map { r in
        let pct = r.total / maxTotal * 100
        switch r {
        case .skill(var s): s.pct = pct; return .skill(s)
        case .pet(var p): p.pct = pct; return .pet(p)
        }
    }
}

/// `petRows.panelTotals` — WHAT THE HEADLINE OVER *THIS* PANEL COVERS. Level 1 is the caller's
/// already-scoped pair; level 2 is the drilled subject plus the pets nested INTO it, which is
/// exactly what the rows sum to. `dps` is SCALED rather than re-derived, because every source's
/// rate divides by the same elapsed time.
func panelTotals(shown: Double?, total: Double, dps: Double) -> (total: Double, dps: Double) {
    guard let shown else { return (total, dps) }
    return (shown, total > 0 ? dps * shown / total : 0)
}

// MARK: - Whose damage (meterScope.ts / shared/roster.ts)

enum MeterScope: String, CaseIterable, Hashable {
    case you, group, everyone

    /// The stored preference (Preferences → Combat), degraded to the default rather than to an
    /// empty meter when the value is one this build does not know.
    static var preferred: MeterScope { MeterScope(rawValue: Prefs.shared.meterScope) ?? .everyone }

    var label: String {
        switch self {
        case .you: return "You"
        case .group: return "Group"
        case .everyone: return "Everyone"
        }
    }

    /// The one sentence each scope means. HERE rather than in either surface, so the Combat tab,
    /// the floating meter and the preferences card cannot phrase the same rule three ways.
    var hint: String {
        switch self {
        case .you: return "You and your pets only"
        case .group: return "You, your pets and everyone on your group roster"
        case .everyone: return "Every combatant the log named, including people your group roster never knew about"
        }
    }
}

/// Group with no roster is NOT silently wrong: it falls back to Everyone, because an empty roster
/// means "we have not been told", and unknown must never hide people.
func effectiveScope(_ scope: MeterScope, roster: JSONValue) -> MeterScope {
    scope == .group && roster["seen"].bool != true ? .everyone : scope
}

private func isScopedKind(_ kind: String) -> Bool {
    kind == "member" || kind == "allyPet" || kind == "other"
}

private func memberKey(_ id: String) -> String? {
    id.hasPrefix("member:") ? String(id.dropFirst("member:".count)) : nil
}

/// `allypet:<charmerKey>:<petKey>` — the charmer sits in the middle because the ROW is about the
/// person.
private func charmerKey(_ id: String) -> String? {
    guard id.hasPrefix("allypet:") else { return nil }
    let rest = id.dropFirst("allypet:".count)
    guard let cut = rest.firstIndex(of: ":"), cut != rest.startIndex else { return nil }
    return String(rest[rest.startIndex..<cut])
}

/// DAMAGE rows for one scope, `pct` re-based against the surviving maximum.
func scopeSources(_ rows: [MeterSource], scope: MeterScope, roster: JSONValue) -> [MeterSource] {
    let effective = effectiveScope(scope, roster: roster)
    if effective == .everyone { return rows }
    var kept: [MeterSource]
    if effective == .you {
        // You and your pets only — the narrowest scope, and the one a solo player asks for. A
        // nested pet has already left the list; an unnested one is still yours.
        kept = rows.filter { $0.kind == "you" || $0.kind == "pet" }
    } else {
        let members = Set((roster["members"].array ?? []).compactMap { $0["key"].string })
        kept = rows.filter { r in
            if !isScopedKind(r.kind) { return true }
            guard let key = r.kind == "allyPet" ? charmerKey(r.id) : memberKey(r.id) else { return false }
            return members.contains(key)
        }
    }
    if kept.count == rows.count { return rows }
    let maxTotal = max(1, kept.map(\.total).max() ?? 1)
    for i in kept.indices { kept[i].pct = kept[i].total / maxTotal * 100 }
    return kept
}

/// The headline figures for a scoped damage list — summed from the VISIBLE rows, never carried
/// over from the unfiltered segment.
func scopeTotals(_ rows: [MeterSource], _ scoped: [MeterSource], total: Double, dps: Double) -> (total: Double, dps: Double) {
    if scoped.count == rows.count { return (total, dps) }
    let shown = scoped.reduce(0) { $0 + $1.total }
    return (shown, total > 0 ? dps * shown / total : 0)
}

// MARK: - Procs (procRows.ts)

/// What an absent rate LOOKS like. A dash, never '0.0' and never a blank cell.
let procAbsent = "-"

struct ProcListRow: Identifiable, Hashable {
    var id: String
    var name: String
    /// the label was ambiguous (a shared emote / dispel tier) — the COUNT is exact either way.
    var ambiguous: Bool
    var origin: String
    var count: Int
    /// `4.0 ppm`, or `-` when the engine withheld the division. Never '0.0'.
    var ppm: String
}

private func ppmText(_ rate: JSONValue, origin: String) -> String {
    guard let active = rate["ppmActive"].double else { return procAbsent }
    return origin == "click" ? CFmt.cpm(active) : CFmt.ppm(active)
}

/// The proc list for one selection, RANKED BY COUNT, ties broken by name so the order is stable
/// across ticks. Falls back to the shipped poison-only `strikes` when the engine sent no unified
/// lane list — that payload predates the rate machinery, so those rows say so with the same dash.
func procListRows(_ p: JSONValue) -> [ProcListRow] {
    let lanes = p["lanes"].array ?? []
    var rows: [ProcListRow]
    if !lanes.isEmpty {
        rows = lanes.map { l in
            let origin = l["origin"].string ?? "spell"
            return ProcListRow(id: "\(origin)|\(l["name"].string ?? "")",
                               name: l["name"].string ?? "",
                               ambiguous: l["ambiguous"].bool == true,
                               origin: origin,
                               count: l["count"].int ?? 0,
                               ppm: ppmText(l["rate"], origin: origin))
        }
    } else {
        rows = (p["strikes"].array ?? []).map { s in
            ProcListRow(id: "poison|\(s["name"].string ?? "")",
                        name: s["name"].string ?? "",
                        ambiguous: s["ambiguous"].bool == true,
                        origin: "poison",
                        count: s["count"].int ?? 0,
                        ppm: procAbsent)
        }
    }
    return rows.sorted { a, b in a.count != b.count ? a.count > b.count : a.name < b.name }
}

private func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }

/// How many procs this selection saw — the unified lane count when the engine sent one, else the
/// shipped poison-only count. So the header can never quote a number the list does not add up to.
func procCount(_ p: JSONValue) -> Int {
    p["overall"]["count"].int ?? (p["strikeCount"].int ?? 0)
}

/// Firings of HELD CLICKIES — counted apart from the procs above, because they are not procs.
func clickCount(_ p: JSONValue) -> Int {
    (p["lanes"].array ?? []).reduce(0) { $0 + ($1["origin"].string == "click" ? ($1["count"].int ?? 0) : 0) }
}

/// `12 procs · 3.1 ppm`, or just `12 procs` when the rate was withheld — plus `· 3 clicks`.
func procSummaryHeader(_ p: JSONValue) -> String {
    let count = procCount(p)
    let clicks = clickCount(p)
    let ppm = p["overall"]["ppmActive"].double.map { CFmt.ppm($0) }
    let procs = ppm == nil ? plural(count, "proc") : "\(plural(count, "proc")) · \(ppm!)"
    return clicks == 0 ? procs : "\(procs) · \(plural(clicks, "click"))"
}

// MARK: - Healing wording (healRows.ts)

func healerAmount(_ h: JSONValue) -> String {
    let total = h["total"].double ?? 0
    if total == 0, (h["unstatedCount"].int ?? 0) > 0 { return procAbsent }
    return "\(CFmt.healRate(h["hps"].double ?? 0)) · \(CFmt.num(total))"
}

/// A healer row's stat run. A row can be MIXED (your own carries both your heals and your rune
/// absorption), so the absorbed share is called out separately, never averaged in as a heal.
func healerStat(_ h: JSONValue) -> String {
    var parts: [String] = []
    let count = h["count"].int ?? 0
    if count > 0 { parts.append("\(count)x") }
    if (h["crits"].int ?? 0) > 0 { parts.append("\(CFmt.pct1(h["critPct"].double ?? 0)) crit") }
    if (h["overheal"].double ?? 0) > 0 { parts.append("\(CFmt.pct1(h["overhealPct"].double ?? 0)) over") }
    if (h["absorbedTotal"].double ?? 0) > 0 { parts.append("\(CFmt.num(h["absorbedTotal"].double ?? 0)) absorbed") }
    // Stated as a COUNT with its own word: that figure is the denominator of every rate beside it.
    if (h["unstatedCount"].int ?? 0) > 0 { parts.append("\(h["unstatedCount"].int ?? 0)x no amount") }
    return parts.joined(separator: " · ")
}

private func healRange(_ minV: Int, _ maxV: Int) -> String {
    minV == maxV ? "\(maxV)" : "\(minV) - \(maxV)"
}

/// The per-lane stat run. An absorption lane has no overheal and no crits by construction, and an
/// unstated lane has no NUMBER at all — its count is the whole stat run.
func spellStat(_ s: JSONValue) -> String {
    let cls = s["classification"].string ?? ""
    let count = s["count"].int ?? 0
    if cls == "absorbed" { return "\(count)x · \(healRange(s["min"].int ?? 0, s["max"].int ?? 0)) granted" }
    if cls == "unstated" { return "\(count)x" }
    var parts: [String] = []
    let total = s["total"].double ?? 0
    let over = s["overheal"].double ?? 0
    if over > 0, total + over > 0 { parts.append("\(CFmt.pct1(over / (total + over) * 100)) over") }
    parts.append(healRange(s["min"].int ?? 0, s["max"].int ?? 0))
    return parts.joined(separator: " · ")
}

/// What goes at the RIGHT end of a LANE bar. An unstated lane carries no number.
func laneAmount(_ s: JSONValue) -> String {
    s["classification"].string == "unstated" ? procAbsent : CFmt.num(s["total"].double ?? 0)
}

// MARK: - Fight history by day

/// One calendar day of finalized fights, newest first, for the picker's history.
struct FightDay: Identifiable, Equatable {
    /// `yyyy-MM-dd` in the local zone — the section's id and its scroll anchor.
    var key: String
    var label: String
    var rows: [ScopeOption]
    var id: String { key }
}

/// Fights grouped into local days, newest day first and newest fight first within a day. `Today`
/// and `Yesterday` are named as such; older days read `Mon Sep 21` (with the year once it is not
/// this one). Fights with no start time go last, under `Undated`.
func fightDays(_ rows: [ScopeOption], now: Int64, calendar: Calendar = .current) -> [FightDay] {
    let keyFmt = DateFormatter()
    keyFmt.calendar = calendar
    keyFmt.timeZone = calendar.timeZone
    keyFmt.locale = Locale(identifier: "en_US_POSIX")
    keyFmt.dateFormat = "yyyy-MM-dd"
    let nowDate = Date(timeIntervalSince1970: Double(now) / 1000)
    let today = keyFmt.string(from: nowDate)
    let yesterday = calendar.date(byAdding: .day, value: -1, to: nowDate).map(keyFmt.string(from:)) ?? ""
    let sameYear = DateFormatter(), otherYear = DateFormatter()
    for f in [sameYear, otherYear] {
        f.calendar = calendar; f.timeZone = calendar.timeZone; f.locale = Locale(identifier: "en_US_POSIX")
    }
    sameYear.dateFormat = "EEE MMM d"
    otherYear.dateFormat = "EEE MMM d, yyyy"

    var byKey: [String: [ScopeOption]] = [:]
    var undated: [ScopeOption] = []
    for r in rows {
        guard r.startTs > 0 else { undated.append(r); continue }
        byKey[keyFmt.string(from: Date(timeIntervalSince1970: Double(r.startTs) / 1000)), default: []].append(r)
    }
    var out: [FightDay] = byKey.keys.sorted(by: >).map { k in
        let rows = byKey[k]!.sorted { $0.startTs > $1.startTs }
        let label: String
        if k == today { label = "Today" }
        else if k == yesterday { label = "Yesterday" }
        else {
            let d = Date(timeIntervalSince1970: Double(rows[0].startTs) / 1000)
            label = calendar.component(.year, from: d) == calendar.component(.year, from: nowDate)
                ? sameYear.string(from: d) : otherYear.string(from: d)
        }
        return FightDay(key: k, label: label, rows: rows)
    }
    if !undated.isEmpty { out.append(FightDay(key: "undated", label: "Undated", rows: undated)) }
    return out
}

// MARK: - Fight picker range and filter

/// How far back the fight picker lists, measured back from now.
enum FightRange: String, CaseIterable, Identifiable {
    case day = "24h", threeDays = "3d", week = "7d", month = "30d"
    var id: String { rawValue }
    var label: String { "Last \(rawValue)" }
    var ms: Int64 {
        switch self {
        case .day: return 86_400_000
        case .threeDays: return 3 * 86_400_000
        case .week: return 7 * 86_400_000
        case .month: return 30 * 86_400_000
        }
    }
}

/// Does a fight match what was typed? Case-insensitive, against its name and its zone, anywhere in
/// either: `gloom` finds "a gloomwater mermaid" and "Estrella of Gloomwater". A `*` stands for any
/// run of characters, so `gloom*maid` needs "gloom" and later "maid". An empty query matches all.
func fightMatches(_ o: ScopeOption, _ query: String) -> Bool {
    let pieces = query.lowercased().split(separator: "*").map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    if pieces.isEmpty { return true }
    func inOrder(_ text: String) -> Bool {
        let hay = text.lowercased()
        var from = hay.startIndex
        for p in pieces {
            guard let r = hay.range(of: p, range: from..<hay.endIndex) else { return false }
            from = r.upperBound
        }
        return true
    }
    return inOrder(o.name) || inOrder(o.label) || inOrder(o.zone ?? "")
}

/// The picker's rows for a range and a query: the fights that started inside the window and match.
func fightRows(_ rows: [ScopeOption], range: FightRange, query: String, now: Int64) -> [ScopeOption] {
    let since = now - range.ms
    return rows.filter { $0.startTs >= since && fightMatches($0, query) }
}

// MARK: - A fight digest, read as a timeline

/// The engine's `FightDigest` (a finalized fight whose event ring is gone) in the shape the curve
/// and mob cards read: its curve buckets become `events` (one per side per bucket, at the bucket's
/// middle), and its per-target rows ride along as `digestRows` for `groupByTarget` and
/// `skillsForTarget`. nil when there is no digest. Not for the Timeline pane: a digest has no
/// instants to draw.
func digestTimeline(_ digest: JSONValue, durationSec: Double) -> JSONValue? {
    guard digest.object != nil, let curve = digest["curve"].array else { return nil }
    let bucket = max(1, digest["bucketMs"].int64 ?? 1000)
    let kinds = ["you", "pet", "member", "enemy"]
    var events: [JSONValue] = []
    for (i, c) in curve.enumerated() {
        for (s, v) in (c.array ?? []).enumerated() where s < kinds.count {
            let amount = v.int64 ?? 0
            if amount > 0 {
                events.append(["t": .int(Int64(i) * bucket + bucket / 2), "kind": .string(kinds[s]), "amount": .int(amount)])
            }
        }
    }
    return [
        "durationMs": .int(max(1000, Int64(durationSec * 1000))),
        "events": .array(events),
        "digestRows": digest["rows"],
        "truncated": .bool(digest["truncated"].bool ?? false),
        "digest": .bool(true),
    ]
}

/// `groupByTarget` over a digest's rows: one row per target, its lanes summed.
func groupDigestByTarget(_ rows: [JSONValue], estimated: Bool) -> MobBreakdown {
    var order: [String] = []
    var byTarget: [String: MobRow] = [:]
    var total = 0.0
    for r in rows {
        let name = r["target"].string ?? unknownTarget
        let key = name.lowercased()
        var row = byTarget[key] ?? {
            order.append(key)
            return MobRow(target: name, total: 0, hits: 0, crits: 0, misses: 0, resists: 0, pct: 0, share: 0)
        }()
        row.target = preferredLabel(row.target, name)
        let t = r["total"].double ?? 0
        row.total += t
        row.hits += r["hits"].int ?? 0
        row.crits += r["crits"].int ?? 0
        row.misses += r["misses"].int ?? 0
        row.resists += r["resists"].int ?? 0
        total += t
        byTarget[key] = row
    }
    var out = order.compactMap { byTarget[$0] }
    out.sort { a, b in
        if a.total != b.total { return a.total > b.total }
        if a.hits != b.hits { return a.hits > b.hits }
        return a.target < b.target
    }
    let maxTotal = max(1, out.map(\.total).max() ?? 1)
    for i in out.indices {
        out[i].pct = out[i].total / maxTotal * 100
        out[i].share = total > 0 ? out[i].total / total * 100 : 0
    }
    return MobBreakdown(rows: out, total: total, estimated: estimated)
}

/// `skillsForTarget` over a digest's rows: that target's lanes as skill rows.
func digestSkillsForTarget(_ rows: [JSONValue], target: String, estimated: Bool) -> TargetDetail {
    let want = target.lowercased()
    var skills: [SkillRow] = []
    var total = 0.0, hits = 0, crits = 0, misses = 0, resists = 0
    for r in rows where (r["target"].string ?? unknownTarget).lowercased() == want {
        let row = SkillRow(name: r["lane"].string ?? "", category: r["category"].string ?? "",
                           total: r["total"].double ?? 0, pct: 0,
                           hits: r["hits"].int ?? 0, crits: r["crits"].int ?? 0,
                           misses: r["misses"].int ?? 0, resists: r["resists"].int ?? 0,
                           maxHit: r["maxHit"].int ?? 0, minHit: r["minHit"].int ?? 0, children: nil)
        total += row.total; hits += row.hits; crits += row.crits; misses += row.misses; resists += row.resists
        skills.append(row)
    }
    return TargetDetail(rows: groupSlay(rankRows(skills)), total: total, hits: hits, crits: crits,
                        misses: misses, resists: resists, estimated: estimated)
}

// MARK: - Procs worth a card

/// The poison-damage ledger is a coat's ledger: what a rogue's venoms dealt. The log types a
/// caster's own poison spells (Envenomed Bolt, …) as poison too, and upstream counts those in the
/// same ledger, where they read as procs they are not. So it is shown only when the selection had a
/// coat on record.
func procsShowPoison(_ procs: JSONValue) -> Bool {
    !(procs["coats"].array ?? []).isEmpty || !(procs["combatAtEngage"].array ?? []).isEmpty
}

/// Does the Procs card have anything to show: a real proc, or a coat's poison damage.
func procsHaveContent(_ procs: JSONValue) -> Bool {
    !procListRows(procs).isEmpty || (procsShowPoison(procs) && !(procs["poisonDamage"].array ?? []).isEmpty)
}

// MARK: - One mob of a pull

/// A selection naming one mob of a pull: `fightId#mob`.
func mobSelection(_ fightId: String, _ mob: String) -> String { "\(fightId)#\(mob)" }

/// `fightId#mob` → (fightId, mob); a plain fight id → (id, nil).
func splitMobSelection(_ v: String) -> (fight: String, mob: String?) {
    guard let i = v.firstIndex(of: "#") else { return (v, nil) }
    return (String(v[..<i]), String(v[v.index(after: i)...]))
}

/// The mobs a pull's outgoing damage landed on, largest first — from its events, or from a digest's
/// rows when that is all there is.
func pullMobs(_ detail: JSONValue) -> [(name: String, total: Double)] {
    var order: [String] = []
    var byKey: [String: (name: String, total: Double)] = [:]
    func add(_ name: String, _ amount: Double) {
        let k = name.lowercased()
        if byKey[k] == nil { order.append(k); byKey[k] = (name, 0) }
        byKey[k]!.total += amount
    }
    if let rows = detail["digestRows"].array {
        for r in rows { add(r["target"].string ?? unknownTarget, r["total"].double ?? 0) }
    } else {
        for e in detail["events"].array ?? [] where e["kind"].string != "enemy" {
            guard let t = e["target"].string else { continue }
            add(t, e["outcome"].isNull ? (e["amount"].double ?? 0) : 0)
        }
    }
    return order.compactMap { byKey[$0] }.sorted { $0.total > $1.total }
}

/// A pull's detail cut down to one mob: outgoing events on it (incoming ones name no attacker, so
/// they cannot be split and are left out), or a digest's rows for it.
func mobTimeline(_ tl: JSONValue, mob: String) -> JSONValue {
    guard var o = tl.object else { return tl }
    let want = mob.lowercased()
    if let rows = tl["digestRows"].array {
        o["digestRows"] = .array(rows.filter { ($0["target"].string ?? "").lowercased() == want })
        o["events"] = .array([])   // a digest's curve is the whole pull's; it cannot be split
        return .object(o)
    }
    o["events"] = .array((tl["events"].array ?? []).filter {
        $0["kind"].string != "enemy" && ($0["target"].string ?? "").lowercased() == want
    })
    return .object(o)
}

/// The selected fight's segment for ONE mob: the meter's entities rebuilt from the events on it
/// (You, your pet, and everyone else as Group, each with its lanes), its damage and DPS over the
/// span you fought it, and the damage it dealt you from the fight's own incoming list.
func mobSegment(_ seg: JSONValue, timeline: JSONValue, mob: String) -> JSONValue {
    guard var o = seg.object else { return seg }
    let want = mob.lowercased()
    struct Lane { var name: String; var total = 0.0, hits = 0, crits = 0, misses = 0, resists = 0; var max = 0.0, min = 0.0 }
    struct Who { var id: String; var name: String; var kind: String; var lanes: [String: Lane] = [:]; var order: [String] = [] }
    let petName = (seg["entities"].array ?? []).first { $0["kind"].string == "pet" }?["name"].string ?? "Pet"
    var whos: [String: Who] = [:]
    var whoOrder: [String] = []
    var first = Double.infinity, last = -Double.infinity
    func add(_ kind: String, lane: String, amount: Double, crit: Bool, outcome: String?, t: Double?) {
        let side = kind == "you" ? "you" : kind == "pet" ? "pet" : "group"
        if whos[side] == nil {
            whoOrder.append(side)
            whos[side] = Who(id: "mob-\(side)", name: side == "you" ? "You" : side == "pet" ? petName : "Group",
                             kind: side == "group" ? "member" : side)
        }
        var w = whos[side]!
        if w.lanes[lane] == nil { w.order.append(lane); w.lanes[lane] = Lane(name: lane) }
        var l = w.lanes[lane]!
        switch outcome {
        case "miss": l.misses += 1
        case "resist": l.resists += 1
        default:
            l.total += amount; l.hits += 1
            if crit { l.crits += 1 }
            l.max = Swift.max(l.max, amount)
            if l.min == 0 || amount < l.min { l.min = amount }
        }
        w.lanes[lane] = l
        whos[side] = w
        if let t { first = Swift.min(first, t); last = Swift.max(last, t) }
    }
    if let rows = timeline["digestRows"].array {
        for r in rows where (r["target"].string ?? "").lowercased() == want {
            // A digest does not say whose a row was: it is credited to You.
            var l = Lane(name: r["lane"].string ?? "")
            l.total = r["total"].double ?? 0; l.hits = r["hits"].int ?? 0; l.crits = r["crits"].int ?? 0
            l.misses = r["misses"].int ?? 0; l.resists = r["resists"].int ?? 0
            l.max = r["maxHit"].double ?? 0; l.min = r["minHit"].double ?? 0
            if whos["you"] == nil { whoOrder.append("you"); whos["you"] = Who(id: "mob-you", name: "You", kind: "you") }
            whos["you"]!.order.append(l.name + "|" + (r["category"].string ?? ""))
            whos["you"]!.lanes[l.name + "|" + (r["category"].string ?? "")] = l
        }
    } else {
        for e in timeline["events"].array ?? [] where e["kind"].string != "enemy" {
            guard (e["target"].string ?? "").lowercased() == want else { continue }
            add(e["kind"].string ?? "other", lane: e["lane"].string ?? "", amount: e["amount"].double ?? 0,
                crit: e["crit"].bool == true, outcome: e["outcome"].string, t: e["t"].double)
        }
    }
    let spanSec = first.isFinite ? Swift.max(1, (last - first) / 1000 + 1) : Swift.max(1, seg["durationSec"].double ?? 1)
    let totals = whoOrder.map { k in whos[k]!.lanes.values.reduce(0) { $0 + $1.total } }
    let out = totals.reduce(0, +)
    let top = Swift.max(1, totals.max() ?? 1)
    o["entities"] = .array(zip(whoOrder, totals).map { k, total in
        let w = whos[k]!
        let lanes = w.order.compactMap { w.lanes[$0] }
        let hits = lanes.reduce(0) { $0 + $1.hits }, crits = lanes.reduce(0) { $0 + $1.crits }
        let misses = lanes.reduce(0) { $0 + $1.misses }, resists = lanes.reduce(0) { $0 + $1.resists }
        let skills: [JSONValue] = lanes.sorted { $0.total > $1.total }.map { l in
            var s: [String: JSONValue] = ["name": .string(l.name), "total": .double(l.total),
                                          "pct": .double(total > 0 ? l.total / total * 100 : 0),
                                          "hits": .int(Int64(l.hits)), "crits": .int(Int64(l.crits)),
                                          "max": .double(l.max), "misses": .int(Int64(l.misses))]
            if l.hits > 0 { s["min"] = .double(l.min) }
            if l.resists > 0 { s["resists"] = .int(Int64(l.resists)) }
            return .object(s)
        }
        let swings = Double(hits + misses)
        return .object([
            "id": .string(w.id), "name": .string(w.name), "kind": .string(w.kind),
            "total": .double(total), "dps": .double(total / spanSec), "pct": .double(total / top * 100),
            "hits": .int(Int64(hits)), "crits": .int(Int64(crits)),
            "critPct": .double(hits > 0 ? Double(crits) / Double(hits) * 100 : 0),
            "ambiguousHits": 0, "ambiguousTotal": 0, "misses": .int(Int64(misses)),
            "hitPct": .double(swings > 0 ? Double(hits) / swings * 100 : 0),
            "missBreakdown": [:], "resists": .int(Int64(resists)),
            "resistPct": 0, "skills": .array(skills), "categories": .array([]),
        ])
    })
    // What this mob dealt you: its row of the fight's incoming list (the pull's attackers by name).
    let incoming = (seg["incoming"].array ?? []).filter { ($0["name"].string ?? "").lowercased() == want }
    let inTotal = incoming.reduce(0.0) { $0 + ($1["total"].double ?? 0) }
    o["name"] = .string(mob)
    o["outTotal"] = .double(out)
    o["outDps"] = .double(out / spanSec)
    o["activeDps"] = .double(out / spanSec)
    o["durationSec"] = .double(spanSec)
    o["activeSec"] = .double(spanSec)
    o["incoming"] = .array(incoming)
    o["inTotal"] = .double(inTotal)
    o["inDps"] = .double(inTotal / spanSec)
    return .object(o)
}
