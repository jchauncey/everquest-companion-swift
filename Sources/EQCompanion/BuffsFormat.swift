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

/// WHICH BUFFS AND DEBUFFS THE TIMER SURFACE IS ALLOWED TO DRAW — this client's half of JOS-168.
///
/// Three facts, ported from `src/shared/buffAllow.ts`: a MODE (off is the shipped answer and means
/// everything draws AND there are no checkboxes); a VERDICT PER SPELL LINE (`true`, `false` or
/// absent, and only `true` draws while the mode is on); and flipping the mode never loses a choice.
///
/// WHAT IS DIFFERENT HERE, AND IT IS STATED RATHER THAN HIDDEN: the Electron app's copy is owned by
/// main, persisted in the settings store and pushed to the engine's `buffTrust`/overlay windows.
/// This one is a LOCAL preference in `UserDefaults`. It filters what this app's Buff timers section
/// draws and it puts the boxes on the durations rows; it reaches no engine and no overlay window.
@MainActor
@Observable
final class BuffAllowStore {
    static let shared = BuffAllowStore()

    /// A bound, not a policy: it only stops a hand-edited defaults file carrying an unbounded map.
    private static let maxLines = 2000
    private static let maxKeyChars = 64
    private static let optInKey = "eq.buffs.allow.optIn"
    private static let linesKey = "eq.buffs.allow.lines"

    private(set) var optIn: Bool
    private(set) var lines: [String: Bool]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        optIn = defaults.bool(forKey: Self.optInKey)
        var read: [String: Bool] = [:]
        for (k, v) in defaults.dictionary(forKey: Self.linesKey) ?? [:] {
            guard let flag = v as? Bool, let key = Self.storableKey(k), read[key] == nil else { continue }
            read[key] = flag
            if read.count >= Self.maxLines { break }
        }
        lines = read
    }

    private let defaults: UserDefaults

    private static func storableKey(_ raw: String) -> String? {
        let k = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !k.isEmpty, k.count <= maxKeyChars else { return nil }
        return k
    }

    func setOptIn(_ value: Bool) {
        optIn = value
        defaults.set(value, forKey: Self.optInKey)
    }

    /// Check or uncheck one spell line. Always an explicit verdict — unchecking is a statement,
    /// and only the mode decides for a line nobody has touched.
    func setLine(_ key: String, _ checked: Bool) {
        guard let k = Self.storableKey(key), lines.count < Self.maxLines || lines[k] != nil else { return }
        lines[k] = checked
        defaults.set(lines, forKey: Self.linesKey)
    }

    /// Does this line draw on the timer surface? With the mode off, everything does.
    func allowed(_ key: String) -> Bool { !optIn || lines[key] == true }

    var checkedCount: Int { lines.values.filter { $0 }.count }
}

/// The box for one spell, and it is the same box on a durations row and on an active card.
/// It exists ONLY in opt-in mode: off means no boxes anywhere, because an empty column would be a
/// box-shaped hole.
struct BuffAllowCheck: View {
    var spell: String
    var dense = false
    @MainActor private var allow: BuffAllowStore { BuffAllowStore.shared }

    var body: some View {
        if allow.optIn {
            let key = BuffFormat.timerNameKey(spell)
            let on = allow.lines[key] == true
            Button { allow.setLine(key, !on) } label: {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .foregroundStyle(on ? Theme.gold : Theme.textFaint)
                    .font(dense ? .caption : .body)
            }
            .buttonStyle(.plain)
            .help(on ? "Showing on the overlay" : "Hidden from the overlay")
            .accessibilityLabel("Track \(spell) on the overlay")
        }
    }
}
