// The buff vocabulary, ported from the Electron renderer so the two clients say the same words
// about the same numbers: `src/renderer/src/features/buffs/format.ts` (the duration spelling, the
// provenance sentences, the `≥` a bound wears), `src/shared/buffTimers.ts` (the spell-line fold and
// the rank a row may print) and `src/shared/buffAllow.ts` (the allow-list's three facts).
import Foundation
import Observation
import SwiftUI
import EQCompanionCore

/// One entity's rows under a heading — the shape both the active-buff grid and the timer bars group
/// into. A named struct rather than a tuple because a `ForEach` needs an id key path.
struct RowGroup: Identifiable {
    var id: String
    var rows: [Row]
}

enum BuffFormat {
    /// `fmtDuration`: seconds under a minute, `m ss` under an hour, `h mm` above. Nothing (or a
    /// non-positive number) is a dash, never a zero — an unstated duration is not a measured one.
    static func duration(_ ms: Double?) -> String {
        guard let ms, ms > 0 else { return "-" }
        let totalSec = Int((ms / 1000).rounded())
        if totalSec < 60 { return "\(totalSec)s" }
        let totalMin = totalSec / 60
        let sec = totalSec % 60
        if totalMin < 60 { return String(format: "%dm %02ds", totalMin, sec) }
        return String(format: "%dh %02dm", totalMin / 60, totalMin % 60)
    }

    static func duration(ms: Int64?) -> String { duration(ms.map(Double.init)) }

    /// Share of the estimated window still to run, clamped to [0,1].
    static func remainingFraction(elapsedMs: Double, estimatedMs: Double) -> Double {
        guard estimatedMs > 0 else { return 0 }
        return min(1, max(0, 1 - elapsedMs / estimatedMs))
    }

    /// Run past the observed window: elapsed beyond p75 with at least two samples behind it.
    static func isOverdue(elapsedMs: Double, p75: Double?, n: Int) -> Bool {
        guard let p75, n >= 2 else { return false }
        return elapsedMs > p75
    }

    /// What the provenance chip means, in the user's words. Every learned source wears the same
    /// `log` chip — the number came from the log either way — but they claim different things, so
    /// the sentence behind them is not shared.
    static func estimatorSourceTitle(_ src: String?) -> String {
        switch src {
        case "db": return "The spell-database baseline"
        case "cluster":
            return "From your logged casts - three clean casts agree it runs shorter than the baseline"
        case "deathBound":
            return "At least this long - the target died still carrying it and no wear-off was ever printed"
        default: return "From your logged casts - longer than the baseline"
        }
    }

    /// The prefix a number wears when it is a bound and not an answer: `≥` for a death bound, and
    /// nothing at all for every other source.
    static func estimatePrefix(_ src: String?) -> String { src == "deathBound" ? "≥ " : "" }

    /// The chip's own word: the database baseline, or the log.
    static func sourceChip(_ src: String) -> String { src == "db" ? "db" : "log" }

    /// A debuff reads red, a beneficial buff gold. The accent is a property of the SPELL, never of
    /// who is carrying it.
    static func classAccent(_ cls: String) -> Color { cls == "debuff" ? Theme.red : Theme.gold }

    /// Self buffs first, then one group per bound entity.
    static func groupKey(isSelf: Bool, target: String?) -> String {
        isSelf ? "self" : (target ?? "other")
    }

    static func groupLabel(_ key: String) -> String {
        switch key {
        case "self": return "Your buffs"
        case "other": return "Other targets"
        default: return key
        }
    }

    // MARK: - The spell line

    private static let rankTail: Set<String> = ["i", "ii", "iii", "iv", "v", "vi", "vii", "viii", "ix", "x"]

    /// `timerNameBase`: the name with its rank numeral stripped, display casing kept.
    static func timerNameBase(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard let space = trimmed.lastIndex(of: " ") else { return trimmed }
        let tail = trimmed[trimmed.index(after: space)...]
        guard rankTail.contains(tail.lowercased()) else { return trimmed }
        return String(trimmed[..<space]).trimmingCharacters(in: .whitespaces)
    }

    /// `timerNameKey`: the same fold, case-folded. The one definition of what a spell LINE is —
    /// a haste is a haste across ranks, so a rank upgrade never resets a user's answer.
    static func timerNameKey(_ name: String) -> String { timerNameBase(name).lowercased() }

    /// The rank a row may print beside the name: the numeral the cast line spelled, and nothing
    /// when the cast line spelled none or named a different line entirely.
    static func rowRankLabel(name: String, castName: String?) -> String? {
        guard let castName, timerNameKey(castName) == timerNameKey(name) else { return nil }
        let trimmed = castName.trimmingCharacters(in: .whitespaces)
        guard let space = trimmed.lastIndex(of: " ") else { return nil }
        let tail = String(trimmed[trimmed.index(after: space)...])
        guard rankTail.contains(tail.lowercased()) else { return nil }
        return tail.uppercased()
    }
}
