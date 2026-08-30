// The respawn vocabulary and the two row shapes the Timers tab draws, ported from
// `src/shared/respawn.ts` (the readings, the ordering, every string) and
// `src/renderer/src/features/timers/RespawnRowBar.tsx`.
//
// WHAT THE ROW IS CAREFUL ABOUT. It never says a mob is up FROM A CLOCK. `due` means the estimate
// elapsed — the label says "due" and not "spawned" — and the provenance line under the name states
// which rung of the ladder produced the number and how thin the evidence is ("your kills (2 gaps)").
// The ONE place it says UP is when the log named the mob since the clock started, which is a line
// the game printed rather than a clock this app ran.
//
// A GAP IS AN UPPER BOUND. Rung 2 is the smallest death→death gap this fold measured, which is not
// the respawn, so a number derived from your kills prints as `<= 3m 00s` and never bare.
//
// AND A STALE ROW STOPS COUNTING. Once the estimate has been elapsed longer than the linger,
// `due 5h 12m ago` is a number that grows forever about a mob this app knows nothing about; it says
// "due long ago" (or "awaiting next death" where there was never an estimate) instead, drops its
// bar, and sorts under every live clock. It is never removed: a watched mob always has a row.
import SwiftUI
import EQCompanionCore

// MARK: - The model

/// One live respawn clock, read out of the `respawn.watches` view.
struct RespawnClock: Identifiable, Equatable {
    var id: String
    var key: String
    var display: String
    var zone: String
    var baseTs: Int64
    var basis: String
    var source: String
    var overridden: Bool
    var samples: Int
    var kills: Int
    var seenTs: Int64?
    var seenVia: String?
    var estimateMs: Double?
    var observedMs: Double?
    var customMs: Double?
    var wikiText: String?
    var wikiMs: Double?
    var wikiPage: String?
    var order: Int

    init(row: Row) {
        id = row.key
        key = row["key"].string ?? row.key
        display = row["display"].display
        zone = row["zone"].string ?? ""
        baseTs = row["baseTs"].int64 ?? 0
        basis = row["basis"].string ?? "death"
        source = row["source"].string ?? "none"
        overridden = row["overridden"].bool ?? (row["source"].string == "custom")
        samples = row["samples"].int ?? 0
        kills = row["kills"].int ?? 0
        seenTs = row["seenTs"].int64
        seenVia = row["seenVia"].string
        estimateMs = row["estimateMs"].double
        observedMs = row["observedMs"].double
        customMs = row["customMs"].double
        wikiText = row["wikiText"].string
        wikiMs = row["wikiMs"].double
        wikiPage = row["wikiPage"].string
        order = row["order"].int ?? 0
    }
}

/// A mob you recently killed, offered as a one-click watch. From the module snapshot's `recent`.
struct RespawnCandidate: Identifiable, Equatable {
    var id: String
    var key: String
    var display: String
    var zone: String
    var lastTs: Int64
    var kills: Int
    var watched: Bool
    var wikiText: String?

    init(_ v: JSONValue, wikiFallback: String? = nil) {
        key = v["key"].string ?? v["display"].display.lowercased()
        display = v["display"].string ?? key
        zone = v["zone"].string ?? ""
        id = "\(zone)::\(key)"
        lastTs = v["lastTs"].int64 ?? 0
        kills = v["kills"].int ?? 0
        watched = v["watched"].bool ?? false
        wikiText = v["wikiText"].string ?? wikiFallback
    }

    /// Three fields, one rule: the name as the log printed it, the zone it died in, and the wiki's
    /// verbatim respawn text. Lower-cased substring, no tokenising and no per-field special cases.
    /// `needle` is expected already trimmed and lower-cased.
    func matches(_ needle: String) -> Bool {
        if needle.isEmpty { return true }
        if display.lowercased().contains(needle) { return true }
        if zone.lowercased().contains(needle) { return true }
        return wikiText?.lowercased().contains(needle) ?? false
    }
}

// MARK: - Reading a row against the clock

enum Respawn {
    /// How long a thing the log said stays worth repeating — one number for a sighting's shelf life
    /// and for when a countdown has stopped meaning anything.
    static let lingerMs: Double = 30 * 60 * 1000

    struct Reading {
        var elapsedMs: Double
        var remainingMs: Double?
        var fraction: Double
        var due: Bool
        var overdueMs: Double
        var seen: Bool
        var seenAgoMs: Double
        var stale: Bool
    }

    /// A sighting only counts when it is NEWER than the clock's base — a mention from before the
    /// clock started is not a sighting of the spawn the clock is about — and only while it is
    /// fresh enough to still mean it.
    private static func seenAgo(_ row: RespawnClock, _ now: Int64) -> Double? {
        guard let seen = row.seenTs, seen > row.baseTs else { return nil }
        let ago = max(0, Double(now - seen))
        return ago <= lingerMs ? ago : nil
    }

    static func reading(_ row: RespawnClock, now: Int64) -> Reading {
        let elapsed = max(0, Double(now - row.baseTs))
        let ago = seenAgo(row, now)
        let seen = ago != nil
        guard let est = row.estimateMs, est > 0 else {
            // No estimate to elapse, so the elapsed time is what goes stale.
            return Reading(elapsedMs: elapsed, remainingMs: nil, fraction: 0, due: false, overdueMs: 0,
                           seen: seen, seenAgoMs: ago ?? 0, stale: !seen && elapsed > lingerMs)
        }
        let left = est - elapsed
        return Reading(elapsedMs: elapsed,
                       remainingMs: max(0, left),
                       fraction: min(1, max(0, left / est)),
                       due: left <= 0,
                       overdueMs: left < 0 ? -left : 0,
                       seen: seen,
                       seenAgoMs: ago ?? 0,
                       stale: !seen && -left > lingerMs)
    }

    /// SEEN first (freshest evidence leads), then the live clocks by soonest due, then the ones
    /// with no estimate, and STALE last of all. Ties break on name so the list never shuffles.
    ///
    /// A seen row outranks every countdown because it is a different KIND of fact: the log stating
    /// something already happened, rather than this app's estimate of when it might.
    static func ordered(_ rows: [RespawnClock], now: Int64) -> [RespawnClock] {
        rows.sorted { a, b in
            let ra = reading(a, now: now), rb = reading(b, now: now)
            if ra.seen != rb.seen { return ra.seen }
            if ra.seen, rb.seen, ra.seenAgoMs != rb.seenAgoMs { return ra.seenAgoMs < rb.seenAgoMs }
            if ra.stale != rb.stale { return rb.stale }
            let ka = ra.remainingMs ?? .infinity, kb = rb.remainingMs ?? .infinity
            if ka != kb { return ka < kb }
            return a.display.localizedCaseInsensitiveCompare(b.display) == .orderedAscending
        }
    }

    static let longDueLabel = "due long ago"
    static let awaitingLabel = "awaiting next death"
    static let unwatchLabel = "Unwatch"

    /// The number on the clock, worded once for every surface that draws one.
    static func clockLabel(_ row: RespawnClock, now: Int64) -> String {
        let r = reading(row, now: now)
        if r.seen { return "UP" }
        if r.stale { return row.estimateMs == nil ? awaitingLabel : longDueLabel }
        guard row.estimateMs != nil else { return "+\(BuffFormat.duration(r.elapsedMs))" }
        return r.due ? "due \(BuffFormat.duration(r.overdueMs)) ago" : BuffFormat.duration(r.remainingMs ?? 0)
    }

    /// Did the wiki floor LIFT this row's estimate above what your own kills said?
    static func floored(_ row: RespawnClock) -> Bool {
        guard row.source == "observed", let o = row.observedMs, let w = row.wikiMs else { return false }
        return w > o
    }

    /// The one-line provenance the UI prints beside a row: which rung produced the number.
    static func sourceLabel(_ row: RespawnClock) -> String {
        switch row.source {
        case "custom": return "your number"
        case "observed":
            let n = row.samples == 1 ? "1 gap" : "\(row.samples) gaps"
            return floored(row) ? "your kills (\(n)), floored by the wiki" : "your kills (\(n))"
        case "wiki": return "wiki default"
        default: return "no estimate yet"
        }
    }

    /// The duration as it is printed. The `<=` is not decoration: rung 2 is the smallest gap you
    /// measured, an upper bound on the respawn rather than the respawn.
    static func durationText(_ row: RespawnClock) -> String {
        guard let est = row.estimateMs else { return "no estimate" }
        return row.source == "observed" ? "<= \(BuffFormat.duration(est))" : BuffFormat.duration(est)
    }

    /// What the clock is counting from. The death case says nothing — it is the norm — while a
    /// re-based row states its provenance out loud.
    static func basisLabel(_ row: RespawnClock) -> String {
        row.basis == "sighting" ? "from your sighting" : ""
    }

    private static let seenViaLabel: [String: String] = [
        "combat": "a combat line",
        "consider": "a consider",
        "hold": "a mez/root/charm line",
        "spell": "a spell line"
    ]

    /// What named it and how long ago. The AGE is always stated and never rounded away: "seen 3s
    /// ago" is a mob in front of you and "seen 24m ago" is a mob that was there once, and the app
    /// declines to turn that judgement into a threshold of its own.
    static func seenLabel(_ row: RespawnClock, now: Int64) -> String {
        let r = reading(row, now: now)
        guard r.seen else { return "" }
        let via = row.seenVia.flatMap { seenViaLabel[$0] }.map { " (\($0))" } ?? ""
        return r.seenAgoMs < 1000 ? "seen just now\(via)" : "seen \(BuffFormat.duration(r.seenAgoMs)) ago\(via)"
    }

    /// The row's hover: the facts stated nowhere else on it — the raw gap behind an observed number
    /// and what a gap proves, the wiki's verbatim text, whether the floor lifted the estimate,
    /// whether the base is a sighting, and the kill count.
    static func provenance(_ row: RespawnClock) -> String {
        var parts: [String] = []
        switch row.source {
        case "observed":
            let gaps = row.samples == 1 ? "1 gap" : "\(row.samples) gaps"
            parts.append("Your shortest gap in one visit: \(BuffFormat.duration(row.observedMs)) over \(gaps). A gap is an upper bound.")
        case "custom": parts.append("Your number.")
        case "wiki": parts.append("Wiki default - no gap of your own yet.")
        default: parts.append("No respawn known yet. Kill it twice in one visit, or type a number.")
        }
        if let w = row.wikiText { parts.append("Wiki: \"\(w)\".") }
        if floored(row) { parts.append("The wiki floor lifted it.") }
        if row.basis == "sighting" { parts.append("Re-based on a sighting you confirmed.") }
        parts.append("Killed \(row.kills) time\(row.kills == 1 ? "" : "s") here.")
        return parts.joined(separator: " ")
    }

    /// Zone equality, the fold the module uses. THE EMPTY ZONE IS A ZONE — its own bucket, not a
    /// wildcard: before the log states one, an unplaced kill shows while the app is unplaced and
    /// vanishes the moment a zone line says where you are.
    static func zoneKey(_ zone: String) -> String {
        zone.trimmingCharacters(in: .whitespaces).lowercased()
    }
}

/// The committed wiki respawn floors (`respawns.json`), indexed by the lower-cased mob name. The
/// engine already attaches these to the rows it can; this is the same table, read for a candidate
/// the module published without one.
@MainActor
enum WikiRespawns {
    private static var index: [String: (text: String, seconds: Int)]?

    static func text(for name: String) -> String? {
        if index == nil {
            var d: [String: (String, Int)] = [:]
            for r in GameData.shared.respawns {
                guard let k = r["key"].string, let t = r["text"].string else { continue }
                d[k] = (t, r["seconds"].int ?? 0)
            }
            index = d
        }
        return index?[GameData.nameKey(name)]?.text
    }
}

// MARK: - The rows

/// The row's tone: red when the log says it is UP, green once the clock ran out, blue while it
/// runs, and grey when the clock has stopped meaning anything.
private func respawnTone(_ r: Respawn.Reading) -> Color {
    if r.seen { return Theme.red }
    if r.stale { return Theme.textFaint }
    return r.due ? Theme.green : Theme.blue
}

/// One respawn clock, drawn. The row prints STATE — the name, the number, the rung, the zone and
/// the age of any sighting; the sentences behind them live on the hover.
struct RespawnClockRow: View {
    var clock: RespawnClock
    var now: Int64
    var onUnwatch: (RespawnClock) -> Void

    var body: some View {
        let r = Respawn.reading(clock, now: now)
        let tone = respawnTone(r)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(clock.display).font(.callout.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 8)
                Text(Respawn.clockLabel(clock, now: now))
                    .font(.callout.weight(.semibold)).monospacedDigit().foregroundStyle(tone)
                Button { onUnwatch(clock) } label: { Text(Respawn.unwatchLabel) }
                    .buttonStyle(RespawnToggleStyle())
                    .accessibilityLabel("\(Respawn.unwatchLabel) \(clock.display)")
            }
            // The duration and its source are ONE unit — a glance reads "9m 30s, from the wiki" —
            // and a row whose number is the user's own is painted in the theme's gold.
            HStack(spacing: 6) {
                HStack(spacing: 5) {
                    Text(Respawn.durationText(clock)).monospacedDigit()
                    Text(Respawn.sourceLabel(clock)).foregroundStyle(Theme.textDim)
                }
                .font(.caption)
                .foregroundStyle(clock.overridden ? Theme.gold : Theme.text)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(clock.overridden ? Theme.gold.opacity(0.6) : Theme.border))
                if !clock.zone.isEmpty { Chip(text: clock.zone) }
                if !Respawn.basisLabel(clock).isEmpty { Chip(text: Respawn.basisLabel(clock), color: Theme.orange) }
                Spacer(minLength: 0)
            }
            if !Respawn.seenLabel(clock, now: now).isEmpty {
                Text(Respawn.seenLabel(clock, now: now)).font(.caption).foregroundStyle(Theme.red)
            }
            if !r.stale, clock.estimateMs != nil {
                ProgressView(value: r.fraction).tint(tone)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.paper))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
        .opacity(r.stale ? 0.65 : 1)
        .help(Respawn.provenance(clock))
    }
}

/// One recently-killed entry: the mob, where it died, how often, and the one door a clock comes
/// through. Watch and Unwatch are ONE toggle — the same button in the same place, saying the
/// opposite thing.
struct RespawnCandidateRow: View {
    var candidate: RespawnCandidate
    var onWatch: (RespawnCandidate) -> Void
    var onUnwatch: (RespawnCandidate) -> Void

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(candidate.display).font(.callout).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(Theme.textDim).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button { candidate.watched ? onUnwatch(candidate) : onWatch(candidate) } label: {
                Text(candidate.watched ? Respawn.unwatchLabel : "Watch")
            }
            .buttonStyle(RespawnToggleStyle())
            .accessibilityLabel("\(candidate.watched ? Respawn.unwatchLabel : "Watch") \(candidate.display)")
        }
        .padding(.vertical, 4)
    }

    private var subtitle: String {
        var s = "\(candidate.zone.isEmpty ? "unknown zone" : candidate.zone) · \(candidate.kills) kill\(candidate.kills == 1 ? "" : "s")"
        if let w = candidate.wikiText { s += " · wiki: \(w)" }
        return s
    }
}

/// The shape BOTH halves of the toggle wear. Deliberately not `OutlineButtonStyle`: that upper-cases
/// its label, and a control that reads "WATCH" one second and "Unwatch" the next reads as two
/// controls rather than one with two states.
struct RespawnToggleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption)
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(configuration.isPressed ? 0.16 : 0.04)))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.border))
    }
}
