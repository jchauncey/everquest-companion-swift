// The engine measures its own serve path (engined/src/views/meter.rs). Two things are counted:
//
//   * Fold-to-frame latency, per source — from the instant the ingest folded the event that moved
//     the source to the instant the frame describing it reached the connection's outbox. A frame
//     with no fold behind it (the fresh reset a just-opened subscription is owed) carries no
//     latency; a number invented there would be the age of the session.
//   * Diff size, per subscription — ops per frame and bytes on the wire, from the frame's own
//     serialization. That costs one extra serialization per frame actually sent, over a payload
//     bounded by `maxLimit` rows, at most ten times a second.
//
// The numbers leave by three readers with deliberately different verbs: `takeReport` drains its
// cadence flag so a log line is not printed twice, `takeWindow` drains only the windowed extreme,
// and `peek` touches nothing. A reader that reset the counters would make the numbers depend on who
// asked last — two panels open at once would each see half a session — and would rob the log line
// of the interval it was about to print.
import Foundation

/// A span in nanoseconds — Rust's `Duration`, at the resolution the meter measures in.
public typealias Nanos = UInt64

public extension Views {
    /// The nominal interval between two timeline samples.
    ///
    /// Equal to `reportEvery` so a log line and a timeline moment describe the same window, but a
    /// separate constant: they answer to two different readers and either could change alone.
    static let timelineCadence: TimeInterval = 10

    /// How many moments the ring holds before it overwrites — its horizon.
    ///
    /// Thirty samples at `timelineCadence` is five minutes, the window a person can remember doing
    /// something in. The bound is the design: an engine up for a week must cost what one up for a
    /// minute costs, so history that ages out is dropped rather than summarised into a subtler
    /// accumulator.
    static let timelineCapacity = 30
}

/// The floor between two summary lines. Long enough that a live session's log stays readable, short
/// enough that a run worth watching says something while you are watching it.
let reportEvery: Nanos = 10 * 1_000_000_000

/// `Views.timelineCadence`, in the unit the ring measures in.
let timelineCadenceNanos: Nanos = 10 * 1_000_000_000

/// Which kind of frame was served.
public enum FrameKind: Sendable, Equatable {
    /// A full window — a subscription's first, or the one a landed fold owes it.
    case reset
    /// A coalesced batch of ops.
    case diff
}

/// What one source's serve path has cost so far, in this generation.
struct SourceStats {
    var resets: UInt64 = 0
    var diffs: UInt64 = 0
    var rows: UInt64 = 0
    var ops: UInt64 = 0
    var bytes: UInt64 = 0
    var widest: Int = 0
    /// Frames that had a fold instant behind them, and what they took.
    var timed: UInt64 = 0
    var latencyTotal: Nanos = 0
    var latencyWorst: Nanos = 0
    /// The worst timed frame since the last timeline sample, drained by `takeWindow`.
    ///
    /// The one field the ring cannot derive: frames and bytes are cumulative, so a window's figure
    /// is one subtraction, but a maximum is not invertible — a cumulative worst says nothing about
    /// which window set it. Optional rather than zero: a window whose every frame was an owed reset
    /// has no latency, and a `0` would claim the serve path was instantaneous.
    var winWorst: Nanos?
}

/// One source's counters, read rather than drained — what `Meter.peek` answers with.
///
/// Not the protocol type, on purpose: the view layer knows nothing about the protocol, so the meter
/// counts and the op table serializes.
///
/// The two latencies are optional because a frame with no fold instant behind it is counted but not
/// timed; a zero would claim the serve path is instantaneous.
public struct SourceMeter: Sendable, Equatable {
    /// The source's name, as the registry spells it.
    public var source: String
    /// `resets + diffs` — frames actually sent.
    public var frames: UInt64
    public var resets: UInt64
    public var diffs: UInt64
    /// Rows carried by the resets.
    public var rows: UInt64
    /// Ops carried by the diffs.
    public var ops: UInt64
    /// Payload bytes sent, from the frames' own serialization.
    public var bytes: UInt64
    /// The largest single frame.
    public var widest: Int
    /// How many frames had a fold instant behind them — the denominator of `latencyMeanUs`.
    public var timed: UInt64
    /// Mean fold-to-frame latency in microseconds, or nil when nothing was timed.
    public var latencyMeanUs: UInt64?
    /// Worst fold-to-frame latency in microseconds, or nil when nothing was timed.
    public var latencyMaxUs: UInt64?
}

/// What `Meter.takeWindow` hands the ring: two cumulative counters and one drained extreme. The
/// mixed posture is the point — read the field docs.
public struct MeterWindow: Sendable, Equatable {
    /// Frames sent across every source since this generation began — cumulative.
    public var frames: UInt64 = 0
    /// Payload bytes sent across every source since this generation began — cumulative.
    public var bytes: UInt64 = 0
    /// The worst fold-to-frame latency in microseconds since the last call — drained, and nil when
    /// no frame in that span had a fold behind it.
    public var worstUs: UInt64?
}

/// One sampled window of the serve path — the ring's element.
///
/// Every figure is an interval, never a running total: `perf.snapshot` answers the cumulative
/// question better, and a history exists to say that this ten seconds cost four times what the last
/// ten did.
public struct Moment: Sendable, Equatable {
    /// Process uptime in milliseconds when this window closed.
    public var atMs: UInt64
    /// How long the window actually covered — measured, never assumed to be the cadence.
    public var spanMs: UInt64
    /// Frames sent during the window, across every source.
    public var frames: UInt64
    /// What those frames weighed, across every source.
    public var bytes: UInt64
    /// The worst timed frame in the window, or nil when none of them had a fold behind it.
    public var worstUs: UInt64?
}

/// The engine's own serve-path counters. One per attach — a new fold is a new world, and a
/// measurement of the last one is not a measurement of this one.
public final class Meter {
    /// Ordered by source name so a redrawing panel's rows hold still.
    private var sources: [String: SourceStats] = [:]
    /// When the last summary line was printed, or nil when none has been.
    private var said: Instant?
    /// Whether anything has been counted since that line.
    private var fresh = false

    public init() {}

    /// Count one frame that was actually sent.
    ///
    /// `since` is the instant the fold produced what this frame reports, or nil when the frame is
    /// not reporting a fold at all.
    public func frame(_ source: String, _ kind: FrameKind, _ rows: Int, _ ops: Int, _ bytes: Int,
                      _ since: Instant?) {
        var stats = sources[source] ?? SourceStats()
        switch kind {
        case .reset: stats.resets += 1
        case .diff: stats.diffs += 1
        }
        stats.rows += UInt64(rows)
        stats.ops += UInt64(ops)
        stats.bytes += UInt64(bytes)
        stats.widest = max(stats.widest, bytes)
        if let foldedAt = since {
            let took = elapsedNanos(since: foldedAt)
            stats.timed += 1
            stats.latencyTotal += took
            stats.latencyWorst = max(stats.latencyWorst, took)
            stats.winWorst = max(stats.winWorst ?? took, took)
        }
        sources[source] = stats
        fresh = true
    }

    /// The ring's reading: cumulative totals, and the windowed extreme drained.
    ///
    /// `frames` and `bytes` stay cumulative because the timeline subtracts its own previous
    /// reading, so the serve path pays nothing for them; `worstUs` is drained because a maximum
    /// cannot be recovered by subtraction. One caller only, on the thread that owns the meter — a
    /// second reader would silently take the first one's window.
    ///
    /// It does not touch the cadence flag, so a timeline sample can never steal the interval a
    /// summary line was about to print.
    public func takeWindow() -> MeterWindow {
        var window = MeterWindow()
        for key in sources.keys.sorted() {
            var stats = sources[key]!
            window.frames += stats.resets + stats.diffs
            window.bytes += stats.bytes
            if let worst = stats.winWorst {
                stats.winWorst = nil
                let us = micros(worst)
                window.worstUs = max(window.worstUs ?? us, us)
            }
            sources[key] = stats
        }
        return window
    }

    /// The summary lines owed right now, or nothing.
    ///
    /// `force` prints whatever there is regardless of the cadence — what a landing fold does, so
    /// the first frames of a generation are always reported.
    public func takeReport(_ force: Bool) -> [String] {
        if !fresh { return [] }
        let due = force || said.map { elapsedNanos(since: $0) >= reportEvery } ?? true
        if !due { return [] }
        said = Instant.now()
        fresh = false
        return sources.keys.sorted().map { line($0, sources[$0]!) }
    }

    /// Every source's counters, and nothing is reset — the `perf.snapshot` reader.
    ///
    /// A read-only verb is the type stating the property: it cannot drain the cadence flag, zero a
    /// total, or change what the next summary line says. Ordered by source name so a redrawing
    /// panel's rows hold still.
    ///
    /// A source that has never served a frame is absent rather than a row of zeros.
    public func peek() -> [SourceMeter] {
        sources.keys.sorted().map { source in
            let stats = sources[source]!
            return SourceMeter(source: source,
                               frames: stats.resets + stats.diffs,
                               resets: stats.resets,
                               diffs: stats.diffs,
                               rows: stats.rows,
                               ops: stats.ops,
                               bytes: stats.bytes,
                               widest: stats.widest,
                               timed: stats.timed,
                               latencyMeanUs: meanUs(stats),
                               latencyMaxUs: stats.timed > 0 ? micros(stats.latencyWorst) : nil)
        }
    }
}

/// The bounded history behind `perf.timeline` — a fixed-capacity ring, oldest first.
///
/// The bound is the feature: `Views.timelineCapacity` moments, and the oldest is dropped rather than
/// folded into a summary, so an engine up for a week costs what one up for a minute costs.
///
/// It reads a clock it is given, never one it takes. Every method takes process uptime in
/// milliseconds from its caller: the engine does not read a wall clock to answer a performance
/// question, and a process-relative stamp says nothing about when or where a person plays.
///
/// A quiet window is recorded as a quiet window. Skipping empty samples would compress a lull into
/// no space and make the busy moments either side of it look adjacent.
public final class Timeline {
    private var moments: [Moment] = []
    /// Uptime at the close of the last sample, or nil until the first tick opens the first window.
    /// The first tick establishes a baseline and pushes nothing — a first moment measured from
    /// process start would report the boot as a serve window.
    private var sinceMs: UInt64?
    /// The cumulative counters as of the last sample, so a window is one subtraction.
    private var frames: UInt64 = 0
    private var bytes: UInt64 = 0

    public init() {}

    /// Offer the ring a tick. It samples only when a whole `Views.timelineCadence` has passed.
    ///
    /// Called on the serve beat, far more often than it samples; the cadence check lives here
    /// rather than at the call site so the ring's horizon cannot be changed from the ingest loop.
    ///
    /// `atMs` must be monotonic (it is process uptime). A backwards tick is treated as a
    /// zero-length window rather than trusted, because an instrument that can print a negative
    /// duration is one nobody believes afterwards.
    public func tick(_ atMs: UInt64, _ meter: Meter) {
        guard let since = sinceMs else {
            // The first tick opens the window and takes the baseline. `takeWindow` is called for
            // its drain: anything timed before the ring existed belongs to no window.
            let opening = meter.takeWindow()
            sinceMs = atMs
            frames = opening.frames
            bytes = opening.bytes
            return
        }
        let spanMs = atMs > since ? atMs - since : 0
        if spanMs < millis(timelineCadenceNanos) { return }
        let window = meter.takeWindow()
        push(Moment(atMs: atMs,
                        spanMs: spanMs,
                        frames: window.frames > frames ? window.frames - frames : 0,
                        bytes: window.bytes > bytes ? window.bytes - bytes : 0,
                        worstUs: window.worstUs))
        sinceMs = atMs
        frames = window.frames
        bytes = window.bytes
    }

    /// Add one moment, dropping the oldest when the ring is full.
    private func push(_ moment: Moment) {
        if moments.count == Views.timelineCapacity { moments.removeFirst() }
        moments.append(moment)
    }

    /// The ring as it stands, oldest first, and nothing is reset — `perf.timeline`'s reader. Two
    /// panels open at once must see the same history.
    public func peek() -> [Moment] { moments }
}

/// A span as whole milliseconds.
private func millis(_ d: Nanos) -> UInt64 { d / 1_000_000 }

/// The mean of the timed frames, in microseconds, or nil when none were timed.
///
/// Divides the total span rather than a sum of rounded microseconds: rounding once, at the end, is
/// the only order that keeps a sub-microsecond serve path from accumulating into a lie.
private func meanUs(_ stats: SourceStats) -> UInt64? {
    if stats.timed == 0 { return nil }
    return micros(stats.latencyTotal / stats.timed)
}

/// A span as whole microseconds.
private func micros(_ d: Nanos) -> UInt64 { d / 1_000 }

/// One source's line. Cumulative for the generation, so two lines read as a progression rather than
/// as two disconnected samples.
private func line(_ source: String, _ stats: SourceStats) -> String {
    let frames = stats.resets + stats.diffs
    let mean = stats.timed == 0 ? "n/a" : took(stats.latencyTotal / stats.timed)
    return "views: \(source) \(frames) frames (\(stats.resets) reset / \(stats.diffs) diff), "
        + "\(stats.rows) rows, \(stats.ops) ops, \(stats.bytes) B (widest \(stats.widest) B); "
        + "fold->frame mean \(mean) max \(took(stats.latencyWorst)) over \(stats.timed)"
}

/// A span a person reads, at a precision that does not throw the measurement away.
///
/// Microseconds under a millisecond: cutting a fifty-row window takes tens of microseconds, and
/// `0.0 ms` reads as a measurement nobody took rather than as the good news it is.
private func took(_ d: Nanos) -> String {
    let ms = Double(d) / 1_000_000.0
    if ms < 1.0 { return "\(micros(d)) us" }
    return String(format: "%.1f ms", ms)
}

/// Nanoseconds since a monotonic instant, saturating at zero rather than wrapping.
func elapsedNanos(since: Instant) -> Nanos {
    let now = Instant.now().uptimeNanoseconds
    return now > since.uptimeNanoseconds ? now - since.uptimeNanoseconds : 0
}
