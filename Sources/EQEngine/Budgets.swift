// The engine's own performance budgets, judged against the generation that is actually running, so
// the in-app panel and a bug report state what THIS machine did. Port of engined/src/budgets.rs.
//
// The op carries the definitions and not just the numbers: these goals are self-measured and never
// promised, so a reader is owed the ceiling beside the measurement and the caveat beside both.
//
// The rows are rendered here rather than in the panel because views arrive render-ready. The two
// budgets are in different units and each caveat is prose, so serving raw numbers would push all of
// that into the renderer and make a third budget a renderer change.
//
// Everything below is a free function over plain integers, so this file depends on nothing else in
// this target and its unit tests are the whole contract.
import Foundation
import EQCompanionCore

/// The two budgets this build enforces, in the order the panel draws them.
public enum PerfBudgetId: String, Sendable, Hashable, CaseIterable {
    case foldRate
    case serveLatency
}

/// A budget with nothing to judge yet answers `unmeasured` rather than dropping out.
public enum PerfBudgetVerdict: String, Sendable, Hashable {
    case pass
    case fail
    case unmeasured
}

/// One judged budget, as the wire states it (`PerfBudget`).
public struct PerfBudget: Sendable, Hashable {
    public var id: PerfBudgetId
    public var label: String
    public var limit: String
    /// Absent, never zero: a measurement nobody took is not a measurement of zero.
    public var measured: String?
    public var verdict: PerfBudgetVerdict
    public var note: String

    public init(id: PerfBudgetId, label: String, limit: String, measured: String?,
                verdict: PerfBudgetVerdict, note: String) {
        self.id = id; self.label = label; self.limit = limit
        self.measured = measured; self.verdict = verdict; self.note = note
    }

    public var json: JSONValue {
        var o: [String: JSONValue] = [
            "id": .string(id.rawValue),
            "label": .string(label),
            "limit": .string(limit),
            "verdict": .string(verdict.rawValue),
            "note": .string(note)
        ]
        if let measured { o["measured"] = .string(measured) }
        return .object(o)
    }
}

public enum Budgets {
    /// The fold-rate floor, in bytes per second — the number the Rust `tests/budget.rs` asserts.
    ///
    /// Measured before it was chosen: 8.0 MB folded in 1030 ms (7.8 MB/s, 110,319 events) on an
    /// i9-13900KF release build at below-normal priority. The floor is an eighth of that, because a
    /// shared CI runner is several times slower and a debug build about an order of magnitude — the
    /// regression this floor most wants to catch.
    public static let minFoldBytesPerSec: UInt64 = 1_000_000

    /// The serve-latency ceiling, in microseconds.
    ///
    /// Read the unit before the number: `foldToFrameUs` is not compute but the whole engine-side
    /// path from the fold that produced a change to the frame reaching the outbox, so the ~10 Hz
    /// coalescing beat and the tail's poll interval are inside it. The measurement behind it is
    /// 56 ms for a one-row diff, a beat rather than work, which makes this a wedge detector rather
    /// than a budget.
    public static let maxServeLatencyUs: UInt64 = 2_000_000

    /// The fold-rate row's caveat, and the place the unmet fold-time goal is said out loud.
    ///
    /// A pass here means this build is not broken, which is a much smaller claim than the program's
    /// goal, and the row has to say which claim it is making.
    static let foldNote = "The floor is an eighth of the 7.8 MB/s this engine measured on the "
        + "author's machine, so that a debug build or a wedged scan is what trips it rather than a busy "
        + "afternoon. It is not the program's goal: folding the owner's 209 MB log in 20 s is the G3 "
        + "goal and it is NOT met at this release (52.5 s, 3.8 MB/s measured). A pass here says this "
        + "build is not broken, never that the goal is reached."

    /// The serve-latency row's caveat, carried with the number rather than left in a plan document.
    static let serveNote = "Measured fold-to-outbox, so the engine's ~10 Hz coalescing beat and the "
        + "tail's poll interval are inside it: 56 ms for a one-row diff is a beat, not work. The ceiling "
        + "sits two orders of magnitude above anything observed and is a wedge detector rather than a "
        + "performance budget. There is no compute-only serve measurement in this build."

    /// What one generation measured, in the three readings the budgets need.
    ///
    /// Every field is optional and absent means not yet measured, which is why `unmeasured` exists:
    /// a scan still running has no rate, and a session whose every frame was an owed reset has no
    /// latency.
    public struct Readings: Sendable, Hashable {
        /// Wall time from the first byte read to the fold landing.
        public var scanMs: UInt64?
        /// Bytes the scan read, up to the mark it landed on.
        public var scanBytes: UInt64?
        /// The worst fold-to-frame latency any source has reported this generation, in microseconds.
        public var worstServeUs: UInt64?

        public init(scanMs: UInt64? = nil, scanBytes: UInt64? = nil, worstServeUs: UInt64? = nil) {
            self.scanMs = scanMs; self.scanBytes = scanBytes; self.worstServeUs = worstServeUs
        }
    }

    /// Every budget this build enforces, judged and rendered, in the order the panel draws them.
    ///
    /// The list is never empty and never short: a budget with nothing to judge yet answers
    /// `unmeasured` rather than dropping out, because a panel whose row count changed under it
    /// would make "the engine is still starting" look like "this build stopped enforcing that".
    public static func budgets(_ readings: Readings) -> [PerfBudget] {
        [foldRate(readings), serveLatency(readings)]
    }

    /// The fold-rate row: bytes per second over the scan that built this generation.
    static func foldRate(_ readings: Readings) -> PerfBudget {
        let measured = foldBytesPerSec(readings)
        return PerfBudget(id: .foldRate,
                          label: "fold rate",
                          limit: "at least \(rate(minFoldBytesPerSec))",
                          measured: measured.map(rate),
                          verdict: atLeast(measured, minFoldBytesPerSec),
                          note: foldNote)
    }

    /// The serve-latency row: the worst fold-to-frame time any source has reported this generation.
    static func serveLatency(_ readings: Readings) -> PerfBudget {
        PerfBudget(id: .serveLatency,
                   label: "serve latency",
                   limit: "at most \(took(maxServeLatencyUs))",
                   measured: readings.worstServeUs.map(took),
                   verdict: atMost(readings.worstServeUs, maxServeLatencyUs),
                   note: serveNote)
    }

    /// Bytes per second over the scan, or nil while the scan is still running.
    ///
    /// A `scanMs` of zero is a log small enough to fold inside the clock's resolution, so the rate
    /// is reported as if the scan took one millisecond: a fold too fast to time is not a fold that
    /// failed.
    static func foldBytesPerSec(_ readings: Readings) -> UInt64? {
        guard let ms = readings.scanMs, let bytes = readings.scanBytes else { return nil }
        return bytes.multipliedReportingOverflow(by: 1_000).partialValue / max(ms, 1)
    }

    /// `pass` when the measurement clears the floor, `unmeasured` when there is nothing to judge.
    static func atLeast(_ measured: UInt64?, _ floor: UInt64) -> PerfBudgetVerdict {
        guard let measured else { return .unmeasured }
        return measured >= floor ? .pass : .fail
    }

    /// `pass` when the measurement stays under the ceiling, `unmeasured` when there is nothing to
    /// judge.
    static func atMost(_ measured: UInt64?, _ ceiling: UInt64) -> PerfBudgetVerdict {
        guard let measured else { return .unmeasured }
        return measured <= ceiling ? .pass : .fail
    }

    /// A byte rate a person reads, at a precision that does not throw the measurement away.
    ///
    /// MB/s with one decimal, because these numbers run from a floor of 1.0 to a measured 7.8 and
    /// the question is which side of the floor a build landed on; kB/s below a megabyte, because
    /// `0.0 MB/s` reads as a measurement nobody took rather than as the bad news it is. Locale is
    /// fixed en-US, which is why this formats explicitly and uses nothing locale-aware.
    static func rate(_ bytesPerSec: UInt64) -> String {
        let perSec = Double(bytesPerSec)
        if bytesPerSec < 1_000_000 {
            return String(format: "%.0f kB/s", locale: Locale(identifier: "en_US_POSIX"), perSec / 1_000.0)
        }
        return String(format: "%.1f MB/s", locale: Locale(identifier: "en_US_POSIX"), perSec / 1_000_000.0)
    }

    /// A microsecond count a person reads — the meter's own scale, on the wire.
    ///
    /// Three bands rather than one format string: cutting a fifty-row window off a fold takes tens
    /// of microseconds, so a serve path reporting `0.0 ms` reads as a measurement nobody took,
    /// while a two-second ceiling written as `2000000 us` reads as nothing at all.
    static func took(_ us: UInt64) -> String {
        let micros = Double(us)
        if us < 1_000 { return "\(us) us" }
        if us < 1_000_000 {
            return String(format: "%.1f ms", locale: Locale(identifier: "en_US_POSIX"), micros / 1_000.0)
        }
        return String(format: "%.1f s", locale: Locale(identifier: "en_US_POSIX"), micros / 1_000_000.0)
    }
}
