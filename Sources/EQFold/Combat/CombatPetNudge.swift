// The nudge for a pet the meter cannot see (fold/src/combat/petnudge.rs).
//
// A charmed pet binds off its own broadcast, but a SUMMONED pet binds only when the player does
// something — order it once, ask `/pet who leader`, or land a pet-only buff on it. A never-ordered
// auto-assisting pet matches none of those, so its damage is dropped at routing and the player is
// told rather than guessed for.
//
// The whole module is a timeout, and each constant keeps one promise: GRACE means a bind that
// arrives promptly draws no nudge at all, SHOW is how long it then stays up, QUIET is what stops it
// nagging. ONE SLOT, which makes it once-per-summon-BURST rather than once-per-line.
//
// Pure and clock-injected: no wall clock, no engine state, no I/O.
import Foundation
import EQCompanionCore

/// How long a summon has to produce a bind before the player is told anything. Above the measured
/// fast path (summon → buff the pet → bound, about six seconds), so that path draws no nudge.
public let NUDGE_GRACE_MS: Int64 = 10_000

/// How long the nudge is then on screen before it times out.
public let NUDGE_SHOW_MS: Int64 = 45_000

/// How long after a nudge has been shown and IGNORED before another summon may raise one.
public let NUDGE_QUIET_MS: Int64 = 300_000

/// What the snapshot carries when there is a nudge to carry.
public struct PetSummonNudge: Equatable, Sendable {
    public var summonedTs: Int64
    public var expiresTs: Int64

    public var json: JSONValue { ["summonedTs": .int(summonedTs), "expiresTs": .int(expiresTs)] }
}

/// The one-slot state machine: the summon cast currently awaiting a bind, and when a shown nudge
/// last timed out unheeded.
public final class PetNudgeState {
    /// The summon cast waiting on a bind, or nil when nothing is armed.
    private var armedTs: Int64?
    /// When a nudge last came off the screen having been ignored. 0 = never.
    private var lastIgnoredTs: Int64 = 0

    public init() {}

    public func reset() {
        armedTs = nil
        lastIgnoredTs = 0
    }

    /// `You begin casting <a pet summon>.` — the line only the player prints.
    ///
    /// Refuses when something is already armed (a chain of summons is ONE question) or when a nudge
    /// was shown and ignored inside NUDGE_QUIET_MS.
    public func noteSummonCast(_ ts: Int64) {
        if armedTs != nil { return }
        if lastIgnoredTs > 0 && ts - lastIgnoredTs < NUDGE_QUIET_MS { return }
        armedTs = ts
    }

    /// The summon cast never resolved (fizzle / interrupt), so there is no pet to talk about. It
    /// errs toward SILENCE: a missed hint is cheaper than a nudge about a pet never summoned.
    public func noteCastFailed() { armedTs = nil }

    /// A pet bound (any of the three claim routes). The question is answered, so the nudge dismisses
    /// early and does not count as ignored — NUDGE_QUIET_MS is not for a player who acted.
    public func noteBound() { armedTs = nil }

    /// Retire an arm whose window has fully elapsed. Driven from the event stream AND from
    /// `snapshot(now)`, whichever observes the deadline first.
    ///
    /// Only an arm that was actually SHOWN records an ignored nudge.
    public func sweep(_ now: Int64) {
        guard let armed = armedTs else { return }
        let elapsed = now - armed
        if elapsed < NUDGE_GRACE_MS + NUDGE_SHOW_MS { return }
        if elapsed >= NUDGE_GRACE_MS {
            lastIgnoredTs = armed + NUDGE_GRACE_MS + NUDGE_SHOW_MS
        }
        armedTs = nil
    }

    /// What the snapshot carries: the nudge, or nothing at all.
    ///
    /// nil in every state but one — nothing armed, inside the grace, or past the timeout — which
    /// makes "no persistent banner" structural rather than a promise the renderer has to keep.
    public func view(_ now: Int64) -> PetSummonNudge? {
        guard let armed = armedTs else { return nil }
        let elapsed = now - armed
        // The range is half-open on purpose: the grace instant DRAWS the nudge, the expiry does not.
        if elapsed < NUDGE_GRACE_MS || elapsed >= NUDGE_GRACE_MS + NUDGE_SHOW_MS { return nil }
        return PetSummonNudge(summonedTs: armed, expiresTs: armed + NUDGE_GRACE_MS + NUDGE_SHOW_MS)
    }
}
