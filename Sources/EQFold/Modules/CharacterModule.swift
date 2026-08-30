// Port of fold/src/modules/character.rs — the active CharacterRef, the current zone and the current
// level, on one transport.
//
// The ref is pushed in, not folded: a construction input (`ClusterDeps.character`) derived from the
// log's filename, so it states a fact about the RUN rather than about the log's contents.
// `reset()` keeps it; everything log-derived clears.
//
// The level is the latest statement with `/who` breaking a tie, and it never enters the ding series
// — a `/who` row is not a level-up.
//
// `seq` is this module's own revision, monotonic and never reset: state here moves without a log
// event (`setCharacter`), and `useModule` dedupes with `d.seq <= knownSeq`.
import Foundation
import EQLog
import EQCompanionCore

public final class CharacterModule: EqModule {
    public let id = "character"

    /// `shared/currentLevel.ts LevelStatement`.
    private struct LevelStatement {
        var level: Int64
        /// LOG timestamp of the line that stated it (not a wall clock).
        var ts: Int64
        var source: String
        var json: JSONValue { ["level": .int(level), "ts": .int(ts), "source": .string(source)] }
    }

    /// `laterStatement` — latest wins, `/who` breaks a tie. Total, so the winner is decided by the
    /// rule rather than by arrival order.
    private static func nextWins(_ held: LevelStatement, _ next: LevelStatement) -> Bool {
        if next.ts > held.ts { return true }
        if next.ts < held.ts { return false }
        return next.source == "who"
    }

    /// The `CharacterRef` as JSON, or nil for the null the snapshot publishes.
    private var character: JSONValue?
    private var zone: String?
    private var level: LevelStatement?
    /// The module's own revision, monotonic for the life of the process. See the header.
    private var rev: Int64 = 0
    /// The ref waiting for the first reset. The double option is the point: the outer is "has
    /// `setCharacter` been called yet", the inner is the ref it was called with — and the call
    /// itself moves the revision, so a nil ref and no call at all publish different seqs.
    private var pending: JSONValue??

    public init(character: JSONValue?) {
        self.pending = .some(character)
    }

    /// `setCharacter` — called when the tailed character changes.
    public func setCharacter(_ character: JSONValue?) {
        self.character = character
        rev += 1
    }

    /// Fold one statement in. A row restating a level you already dinged to still moves the
    /// revision: the age of the statement is part of the fact, and the surfaces hedge on it.
    private func stateLevel(_ next: LevelStatement) {
        if let held = level, !Self.nextWins(held, next) { return }
        level = next
        rev += 1
    }

    public func reset() {
        // The ref survives; see the header.
        zone = nil
        level = nil
        rev += 1
        // The construction ref lands here, once: `rev` IS the published `seq`, so the ORDER of the
        // two bumps is observable, and the composition root spends them as reset-then-setCharacter.
        if let p = pending {
            pending = nil
            setCharacter(p)
        }
    }

    public func onEvent(_ ev: Event, live: Bool) {
        switch ev.kind {
        case "epoch":
            // Character rebirth: the wiped character's level and zone say nothing about this one.
            // The ref is pushed in and stays.
            zone = nil
            level = nil
            rev += 1
        case "zone":
            let next = ev.str(.zone)
            if next != zone {
                zone = next
                rev += 1
            }
        case "level":
            stateLevel(LevelStatement(level: ev.int(.level) ?? 0, ts: ev.ts, source: "ding"))
        case "selfWho":
            stateLevel(LevelStatement(level: ev.int(.level) ?? 0, ts: ev.ts, source: "who"))
        default: break
        }
    }

    /// The same cursor `snapshot` publishes, without building the state to read it.
    public var publishedSeq: Int64? { rev }

    public func snapshot() -> JSONValue {
        // Three fields, two different absences: `character` publishes null (the TS field is
        // `CharacterRef | null`) while `zone`/`level` are `undefined` and `JSON.stringify` drops
        // them.
        var state: [String: JSONValue] = ["character": character ?? .null]
        if let zone { state["zone"] = .string(zone) }
        if let level { state["level"] = level.json }
        return ["seq": .int(rev), "state": .object(state)]
    }
}
