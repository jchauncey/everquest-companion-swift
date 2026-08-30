// How fast AA is coming in, when the next point lands, and what the item-shop potion is doing to
// the points. Ported from src/shared/aaPace.ts and
// src/renderer/src/features/leveling/aaPaceRows.ts.
//
// WHAT THE LOG STATES, AND WHAT IT DOES NOT. A completed AA is stated — one line carrying the
// POINTS it paid and the resulting unspent balance — so AA-per-hour and POINTS-per-hour are both
// measurements, and they are different measurements. Where you are in the AA bar is NOT stated:
// there is no AA-experience percentage anywhere in the log, so "time to next AA" is INFERRED from
// the rhythm of recent completions and is labelled inferred at every surface that prints it.
//
// THE POTION DOES NOT SPEED AA UP. It doubles the POINTS each of the next five completions pays;
// the experience a completion needs is untouched. So `perHour` and the ETA read the same with a
// bottle running as without one, and only `pointsPerHour` moves.
import Foundation

/// Completions one bottle pays double for. Not a log fact — the log never counts charges — but a
/// measurement of the whole log: 32 quaffs partition 160 doubled completions into runs of five
/// with nothing left over.
let lvAaPotionCharges = 5

/// Fewest completions a window must hold before its mean gap is quoted as a rhythm. With ONE the
/// "mean gap" is the window's own length wearing a different name.
private let aaEtaMinEvents = 2

/// How far past the mean gap the last completion may sit before the ETA is REFUSED. The estimate
/// is honest while you are still killing things and becomes a lie the moment you stop.
private let aaEtaStaleFactor = 3.0

/// Why there is no estimate. Each is a hole in the evidence, and each is shown on hover.
enum LvAaEta: Sendable {
    case noPace
    case stale
    case due(meanIntervalMs: Double, samples: Int, sinceLastMs: Double)
    case inMs(Double, meanIntervalMs: Double, samples: Int, sinceLastMs: Double)

    var blocked: Bool {
        switch self { case .noPace, .stale: return true; default: return false }
    }

    /// `~12m` / `due`, or nil when the estimate is refused.
    var value: String? {
        switch self {
        case .noPace, .stale: return nil
        case .due: return "due"
        case .inMs(let ms, _, _, _): return "~\(LevelingFormat.duration(ms))"
        }
    }

    var title: String {
        switch self {
        case .noPace: return "Fewer than two AA completions here, so there is no gap to project forward."
        case .stale: return "The last completion is far older than this window's rhythm between them."
        case .due(let mean, let samples, let since):
            return "\(Self.base(mean, samples, since)) Already past that gap."
        case .inMs(_, let mean, let samples, let since):
            return Self.base(mean, samples, since)
        }
    }

    private static func base(_ mean: Double, _ samples: Int, _ since: Double) -> String {
        "Mean gap over \(samples) completions (\(LevelingFormat.duration(mean))), minus the \(LevelingFormat.duration(since)) already waited."
    }
}

/// What the log says about the bottle, and what the model says on top of it.
struct LvAaPotionState: Sendable {
    var activations = 0
    var lastTs: Int64?
    /// completions since that quaff, capped at the charge count — the charges it burned.
    var burned = 0
    /// charges the model says remain. INFERRED: the log never counts them.
    var charges = 0
    /// what each burned charge's completion actually stated, oldest first — the model's own
    /// evidence. A run of 2s is the doubling the bottle promises, printed by the game.
    var burnedPoints: [Int] = []

    var title: String {
        let paid = burnedPoints.isEmpty ? "" : " Paid so far: \(burnedPoints.map(String.init).joined(separator: ", "))."
        return "Each completion since the quaff burns a charge.\(paid)"
    }
}

struct LvAaPace: Sendable {
    var activeMs: Double = 0
    var wallMs: Double = 0
    var events = 0
    var points = 0
    var perHourActive: Double?
    var pointsPerHourActive: Double?
    var perHourWall: Double?
    var pointsPerHourWall: Double?
    var eta: LvAaEta = .noPace
    var potion = LvAaPotionState()

    /// ONLINE ms between two instants: wall, minus the intervals the log says you were logged out.
    /// An overnight between two completions is not evidence that AA comes slowly.
    private static func onlineMs(_ prog: LvProgressionColumns, _ from: Int64, _ to: Int64) -> Double {
        max(0, Double(to - from) - LvProgressionStats.offlineMsIn(prog, from, to))
    }

    /// Charge state from the last quaff and the completions after it. STRICTLY after: EQ stamps
    /// whole seconds, and a completion in the same second as the quaff was paid by a kill that
    /// landed before the bottle did.
    static func potionState(gains: [LevelingSnap.AAGain], potions: [Int64]) -> LvAaPotionState {
        guard let last = potions.last else { return LvAaPotionState() }
        var after: [Int] = []
        var i = gains.count - 1
        while i >= 0, gains[i].ts > last { after.append(gains[i].amount); i -= 1 }
        after.reverse()
        let burned = min(after.count, lvAaPotionCharges)
        return LvAaPotionState(activations: potions.count, lastTs: last, burned: burned,
                             charges: lvAaPotionCharges - burned, burnedPoints: Array(after.prefix(burned)))
    }

    /// The inferred wait for the next completion: the WINDOW's mean gap between completions, minus
    /// the wait already served. Bounded to the window the panel already names, and divided by that
    /// window's ONLINE wall — a rolling mean over an unbounded lookback is a statement about last
    /// week printed beside a number labelled "next". `now` is the LOG's own clock, never the wall.
    static func eta(window: LvRangeStats, lastGainTs: Int64?, prog: LvProgressionColumns, now: Int64) -> LvAaEta {
        let onlineWallMs = window.durationMs - window.offlineMs
        guard let lastGainTs, window.aaGainEvents >= aaEtaMinEvents, onlineWallMs > 0 else { return .noPace }
        let mean = onlineWallMs / Double(window.aaGainEvents)
        let since = onlineMs(prog, lastGainTs, now)
        if since > mean * aaEtaStaleFactor { return .stale }
        if since > mean { return .due(meanIntervalMs: mean, samples: window.aaGainEvents, sinceLastMs: since) }
        return .inMs(max(0, mean - since), meanIntervalMs: mean, samples: window.aaGainEvents, sinceLastMs: since)
    }

    /// Adds NO sweep of its own: the counts come from the `LvRangeStats` the caller already computed,
    /// and the ETA and the charges read the uncapped AA arrays from the tail.
    init(leveling: LevelingSnap, prog: LvProgressionColumns, window: LvRangeStats) {
        activeMs = window.activeMs
        wallMs = window.wallMs
        events = window.aaGainEvents
        points = window.aaGained
        perHourActive = window.aaPerHourActive
        pointsPerHourActive = window.aaPointsPerHourActive
        perHourWall = window.aaPerHourWall
        pointsPerHourWall = window.aaPointsPerHourWall
        eta = Self.eta(window: window, lastGainTs: leveling.aaGains.last?.ts, prog: prog, now: prog.lastTs)
        potion = Self.potionState(gains: leveling.aaGains, potions: leveling.aaPotions)
    }

    func read(_ basis: LvRateBasis) -> LvBasisRead {
        LvBasisRead(basis, durationMs: wallMs, activeMs: activeMs, offlineMs: 0)
    }

    /// `3 completions · 5 points · over 42m elapsed`, or the honest empty form.
    func caption(_ basis: LvRateBasis) -> String {
        let span = read(basis).spanText
        if events == 0 { return "no AA completions \(span)" }
        return "\(events) \(LevelingFormat.plural(events, "completion")) · \(points) \(LevelingFormat.plural(points, "point")) · \(span)"
    }

    func tiles(_ basis: LvRateBasis) -> [LvAaPaceTile] {
        let r = read(basis)
        let rate = r.pick(active: perHourActive, elapsed: perHourWall)
        let pts = r.pick(active: pointsPerHourActive, elapsed: pointsPerHourWall)
        var out: [LvAaPaceTile] = [
            LvAaPaceTile(id: .rate,
                       value: rate.map { LevelingFormat.small($0) } ?? LevelingFormat.none,
                       unit: "AA/hr", label: "this window", inferred: false,
                       title: "AA completions per hour of \(r.word) time."),
            LvAaPaceTile(id: .points,
                       value: pts.map { LevelingFormat.small($0) } ?? LevelingFormat.none,
                       unit: "pts/hr", label: "points earned", inferred: false,
                       title: "Ability points per hour of \(r.word) time."),
            LvAaPaceTile(id: .eta, value: eta.value ?? LevelingFormat.none, unit: "",
                       label: "to next AA", inferred: true, title: eta.title)
        ]
        if potion.activations > 0 {
            out.append(LvAaPaceTile(id: .potion, value: String(potion.charges), unit: "of \(lvAaPotionCharges)",
                                  label: "potion charges", inferred: true, title: potion.title))
        }
        return out
    }
}

struct LvAaPaceTile: Identifiable, Sendable {
    enum Kind: String, Sendable { case rate, points, eta, potion }
    var id: Kind
    var value: String
    var unit: String
    var label: String
    /// State, not process: the chip says the number is a model, and the tooltip says which part of
    /// it the log actually printed.
    var inferred: Bool
    var title: String
}
