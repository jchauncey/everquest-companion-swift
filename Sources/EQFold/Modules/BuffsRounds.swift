// One answer to "how many of that name are held, and which one just ended". Pure: no events, no
// clock of its own.
//
// EQ stamps are second-resolution and print no instance identifier, so one AE mez landing on five
// mobs that share a name is five byte-identical lines in one second. So: one group per (spell line,
// entity NAME) holding a LIST of landings, oldest first, drawn as ONE row with a count chip.
//
// A ROUND is every landing sharing one log second, and its rule is:
//
//   a round of N landings on a group already holding M refreshes min(N, M) of them, NEWEST FIRST,
//   and appends the remaining max(0, N - M).
//
// Refreshing rather than appending keeps the count at what is HELD. Newest-first refresh paired
// with OLDEST-first closing makes the row's clock a prediction of the next wear-off line.
//
// Clean cycles are what the bookkeeping is for. A duration sample may be minted only from a landing
// alone in its round, on a group that was empty when the round opened, that nothing touched before
// its wear-off.
// (fold/src/modules/buff_rounds.rs)
import Foundation

/// One landing: an entity of this name we believe is still held, and whether it is measurable.
public struct Hold {
    /// Event ts the landing (or its most recent refresh) happened. Never a wall clock.
    public var startedTs: Int64
    /// True while this landing is still a candidate for a duration SAMPLE. Contamination is
    /// one-way: never set back to true, because the doubt it records does not expire.
    public var clean: Bool
}

/// What `closeOldest` did, so the caller can decide whether a sample was earned.
public struct Closed {
    /// The span in ms, or nil when the hold was contaminated.
    public var sampleMs: Int64?
}

/// The landings of ONE (spell line, entity name) pair.
public struct HoldGroup {
    /// Oldest first. `count` is the row's count chip.
    private var holds: [Hold] = []
    /// A SINGLETON group is one the model holds an IDENTITY for rather than a name — you, your
    /// summoned pet, your charmed pet. A later landing is unambiguously a refresh. A non-singleton
    /// group is keyed by a name the world can duplicate, and that ambiguity is refused as evidence.
    private let singleton: Bool
    /// The log second the current round belongs to, or -1 before the first landing.
    private var roundTs: Int64 = -1
    /// How many landings of the current round have been consumed (refreshes first, then appends).
    private var roundUsed: Int = 0
    /// How many landings the group held when the current round OPENED — the min(N, M) of the rule.
    private var roundStartCount: Int = 0

    public init(singleton: Bool) { self.singleton = singleton }

    public var count: Int { holds.count }
    public var isEmpty: Bool { holds.isEmpty }

    /// The clock the row draws: the oldest landing, the one the next wear-off will close.
    public var oldestTs: Int64 { holds.first?.startedTs ?? 0 }

    /// A landing at `ts`. `contaminated` lets the caller add reasons of its own without this module
    /// knowing what any of them are.
    public mutating func land(_ ts: Int64, _ contaminated: Bool) {
        if singleton {
            // One identity, one landing. A re-cast resets the clock and stays measurable.
            if holds.isEmpty {
                holds.append(Hold(startedTs: ts, clean: !contaminated))
            } else {
                holds[0].startedTs = ts
                holds[0].clean = !contaminated
            }
            return
        }
        if ts != roundTs {
            roundTs = ts
            roundUsed = 0
            roundStartCount = holds.count
        }
        // Clean only if it opened an EMPTY group and is alone in its round so far. The second half
        // is provisional: a later sibling in the same round retroactively dirties it.
        let clean = !contaminated && roundStartCount == 0 && roundUsed == 0
        if roundUsed < roundStartCount {
            // Refresh, newest first: the row never grows a ghost, the landing stops being
            // measurable, and the OLDEST clock stays put.
            let at = roundStartCount - 1 - roundUsed
            holds[at].startedTs = ts
            holds[at].clean = false
        } else {
            if roundUsed > 0 { contaminateRound() }
            holds.append(Hold(startedTs: ts, clean: clean))
        }
        roundUsed += 1
    }

    /// Every landing of the current round loses its clean flag — a round of two is two mobs.
    private mutating func contaminateRound() {
        let rts = roundTs
        for i in holds.indices where holds[i].startedTs == rts { holds[i].clean = false }
    }

    /// A line said one of these ended. Closes the OLDEST and reports whether it was clean enough to
    /// mint. A close with nothing to close returns nil and contaminates the group: a wear-off with
    /// no hold behind it is proof the model under-counted.
    public mutating func closeOldest(_ ts: Int64) -> Closed? {
        if holds.isEmpty {
            contaminateAll()
            return nil
        }
        let hold = holds.removeFirst()
        let span = ts - hold.startedTs
        return Closed(sampleMs: (hold.clean && span > 0) ? span : nil)
    }

    /// Every landing stops being measurable (a zone, a death, a gap, a rule the caller enforces).
    public mutating func contaminateAll() {
        for i in holds.indices { holds[i].clean = false }
    }

    /// Drop every landing older than `cutoffTs` and hand the dropped landings back, oldest first.
    /// It mints nothing: a cull is not an observation.
    @discardableResult
    public mutating func dropExpired(_ cutoffTs: Int64) -> [Hold] {
        var n = 0
        while n < holds.count && holds[n].startedTs <= cutoffTs { n += 1 }
        let out = Array(holds[..<n])
        holds.removeFirst(n)
        return out
    }

    /// Shift the clocks of every landing at or before `onlyBefore` forward by `offsetMs` — the
    /// offline pause, and the only place a live clock moves at all. Re-sorts afterwards because a
    /// shifted older landing can overtake an un-shifted newer one.
    public mutating func shiftBy(_ offsetMs: Int64, _ onlyBefore: Int64) -> Bool {
        var changed = false
        for i in holds.indices where holds[i].startedTs <= onlyBefore {
            holds[i].startedTs += offsetMs
            changed = true
        }
        if changed {
            // A STABLE sort: two landings sharing a ts keep the order they were seen in.
            holds = holds.enumerated().sorted {
                $0.element.startedTs != $1.element.startedTs
                    ? $0.element.startedTs < $1.element.startedTs
                    : $0.offset < $1.offset
            }.map(\.element)
        }
        return changed
    }
}
