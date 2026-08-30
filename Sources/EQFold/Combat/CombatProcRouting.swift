// Proc / modifier ledger routing plus the stance-and-invocation pair
// (fold/src/combat/procrouting.rs).
//
// Everything here is annotation, never damage: a coat, a rogue-poison Strike, a dispel landing, a
// stance commit. None of it opens, extends or closes an encounter; each attaches to the fight in
// progress only while that fight is fresh, and always to the zone aggregate.
//
// Every state change stamps both minute ledgers, which is what makes the Tier-B purity gate
// implementable — the minute a state changed in is discarded from that state's comparison. Both
// ledgers, so a finalized zone session inherits the stamps frozen.
import Foundation
import EQLog

/// The two exclusivity-group prefixes the coat slots write spans under. One list, so a clear cannot
/// strip a slot family whose spans it forgot to close.
private let COAT_GROUP_PREFIXES = ["coat:utility", "coat:combat:"]

/// Open a span on the session state timeline AND stamp the commit into the minute-window ledgers.
private func commitState(_ st: EngineState, _ kind: StateKind, _ key: String, _ name: String,
                         _ ts: Int64, _ group: String?) {
    let g = group ?? stateKeyOf(kind, key)
    st.stateTimeline.noteState(OpenState(kind: kind, key: key, name: name, ts: ts, group: g))
    noteStateTransition(st, g, ts)
}

/// Stamp a transition into both minute ledgers.
private func noteStateTransition(_ st: EngineState, _ group: String, _ ts: Int64) {
    let active = st.stateTimeline.active
    st.zoneAgg.windows.noteTransition(ts, group, active)
    if let enc = st.current, ts - enc.lastTs <= FALLBACK_IDLE_MS {
        enc.agg.windows.noteTransition(ts, group, active)
    }
}

/// Close a span from a printed line, with the same window stamp — an end is a transition too.
private func endState(_ st: EngineState, _ kind: StateKind, _ key: String, _ ts: Int64,
                      _ evidence: EdgeEvidence) {
    st.stateTimeline.closeState(kind, key, ts, evidence)
    noteStateTransition(st, stateKeyOf(kind, key), ts)
}

/// One blade-coat line.
public struct CoatLine {
    public var ts: Int64
    public var poison: String
    /// `utility`, `combat`, or `unknown` when the line named no family.
    public var group: String
    public var who: String

    public init(ts: Int64, poison: String, group: String, who: String) {
        self.ts = ts; self.poison = poison; self.group = group; self.who = who
    }
}

/// Apply a blade coat. Only your own coats move state — a third-person coat line is another player's
/// blades. A utility coat replaces the one utility slot; a combat venom replaces whatever is on its
/// own line and stacks with the other lines. An `unknown` poison is recorded in the segment's coat
/// list but never placed in a slot, because we cannot claim what is on the blades.
///
/// The stack is keyed on the venom's LINE, not its name: per the wiki an upgrade venom replaces its
/// predecessor, so a name-keyed stack would show more simultaneous venoms than the game allows.
public func routeCoat(_ st: EngineState, _ ev: CoatLine) {
    if Names.idKey(ev.who) != "you" {
        // Somebody else's blades: nothing models a stranger's poison, but the line is worth showing
        // to a person scanning the processing log.
        st.log(ev.ts, "poison", "info", "☠ \(ev.who) coated their blades")
        return
    }
    let slot = CoatSlot(poison: ev.poison, sinceTs: ev.ts)
    if ev.group == "utility" {
        st.coatUtility = slot
    } else if ev.group == "combat" {
        let line = coatLineKey(ev.poison)
        st.coatCombat.removeAll { coatLineKey($0.poison) == line }
        st.coatCombat.append(slot)
    }
    // A coat is not combat: it never opens or extends an encounter. It attaches to an in-progress
    // fight (the same freshness rule a miss uses) and always to the zone aggregate.
    let mark = CoatMark(poison: ev.poison, ts: ev.ts)
    let label = ev.poison == "unknown" ? "poison" : ev.poison
    if let enc = st.freshEncounter(ev.ts) {
        enc.agg.procs.coats.append(mark)
        EngineState.pushMarker(enc, MarkerRaw(ts: ev.ts, kind: "coat", label: label,
                                              detail: "\(ev.group) coat"))
    }
    st.zoneAgg.procs.coats.append(mark)
    // An `unknown` poison opens no span: a span keyed on a name the line refused to give would be an
    // invention. The utility slot is one exclusive group; each combat venom line is its own group,
    // because venoms on different lines stack (confirmed in the real log).
    if ev.poison != "unknown" && ev.group != "unknown" {
        let group = ev.group == "utility"
            ? "coat:utility"
            : "coat:combat:\(coatLineKey(ev.poison))"
        commitState(st, .coat, Names.idKey(ev.poison), ev.poison, ev.ts, group)
    }
    let group = ev.group == "unknown" ? "" : " (\(ev.group))"
    st.log(ev.ts, "poison", "info", "☠ coated: \(label)\(group)")
}

/// A coat wore off or was replaced. The line names no poison, only which family dried:
///   utility — unambiguous, there is only ever one; its span ends `observed`.
///   combat  — the log cannot say which venom of a stack expired, so the whole stack is cleared and
///             every span closes `inferred`, under-claiming rather than inventing an observed end.
public func routeDry(_ st: EngineState, _ group: String, _ ts: Int64) {
    let utility = group == "utility"
    if utility {
        st.coatUtility = nil
    } else {
        st.coatCombat.removeAll()
    }
    let prefix = utility ? "coat:utility" : "coat:combat:"
    let evidence: EdgeEvidence = utility ? .observed : .inferred
    st.stateTimeline.closeGroupPrefix(prefix, ts, evidence)
    noteStateTransition(st, prefix, ts)
    st.log(ts, "poison", "info", "☠ \(group) coat dried")
}

/// Why a set of blades went bare without the game printing a line, one sentence each.
///
/// `classSwap` is unreachable in this fold — the coat/class sweep returns before it can fire, since
/// this crate wires no combo provider — and is spelled anyway so the reason table stays a table.
public enum CoatClearReason: Sendable {
    case death, classSwap, epoch

    var note: String {
        switch self {
        case .death: return "your death stripped every coat"
        case .classSwap: return "the loadout no longer contains ROG"
        // The backtick is deliberate: the sentence matches the app's own spelling verbatim so a bug
        // report quoting it is findable in either tree.
        case .epoch: return "a character rebirth - the coats were the previous character`s"
        }
    }
}

/// Strip every blade coat, both families, and end their open spans at `ts`.
///
/// One door for every clearer, so the slots and the spans cannot disagree.
///
/// The edges are `censored`, never `observed` or `inferred`: no line printed an end, so all we know
/// is that our knowledge stops here, and `censored` never renders as an end time.
///
/// It stamps the window transition like a dry line does — a boundary that silently ended four coats
/// is not a minute the purity gate should believe was clean.
///
/// Returns whether anything was cleared.
@discardableResult
public func clearCoats(_ st: EngineState, _ ts: Int64, _ reason: CoatClearReason) -> Bool {
    if st.coatUtility == nil && st.coatCombat.isEmpty { return false }
    st.coatUtility = nil
    st.coatCombat.removeAll()
    for prefix in COAT_GROUP_PREFIXES {
        st.stateTimeline.closeGroupPrefix(prefix, ts, .censored)
        noteStateTransition(st, prefix, ts)
    }
    // Coats come back only when a new coat line is folded. No clear writes a coat observation, which
    // keeps this one-directional against the class model that triggers it.
    st.log(ts, "poison", "info", "☠ blades bare - \(reason.note)")
    return true
}

/// A tracked proc buff landed on you. Gated to the catalog, like the dispel family.
///
/// A re-apply supersedes its own span with `inferred`, because the game printed a new landing and
/// not an end. Buffs are re-applied far more often than they are seen to fade, so nearly every span
/// ends in an inference and the model must say so rather than fabricate an expiry.
public func routeProcBuffApply(_ st: EngineState, _ ts: Int64, _ target: String, _ candidates: [String]) {
    if target != "self" { return }
    guard let def = procBuffInCandidates(candidates) else { return }
    commitState(st, .buff, Names.idKey(def.name), def.name, ts, nil)
}

/// A tracked proc buff's own wears-off line — the rare case where the end is printed, so the span
/// closes `observed`.
public func routeProcBuffWearOff(_ st: EngineState, _ ts: Int64, _ candidates: [String]) {
    guard let def = procBuffInCandidates(candidates) else { return }
    endState(st, .buff, Names.idKey(def.name), ts, .observed)
}

/// A proc whose only printed evidence is this landing.
///
/// A third gate over the same landing stream, disjoint from the other two by intent and not by
/// short-circuit: the dispel family names a lane on a mob, the proc-buff catalog opens a self-buff
/// span, this counts a firing. A spell in two of them yields two true statements about one line.
///
/// It pays the same cast join every other proc pays, so the registry cannot grow a castable spell
/// and start reporting the caster's own casts as procs.
public func routeSelfLandingProc(_ st: EngineState, _ ts: Int64, _ target: String, _ candidates: [String]) {
    if target != "self" { return }
    guard let def = selfLandingProcIn(candidates) else { return }
    if st.recentCasts.origin(def.name, ts) != .proc { return }
    // Annotation, never damage: a landing opens no encounter and extends none. It folds into the
    // fight in progress only while that fight is fresh, and always into the zone aggregate.
    let fold = SpellProcFold(spell: def.name, side: .landing, amount: nil,
                             active: st.stateTimeline.active, click: false)
    st.zoneAgg.procs.addSpellProc(fold)
    if let enc = st.current, ts - enc.lastTs <= FALLBACK_IDLE_MS {
        enc.agg.procs.addSpellProc(fold)
    }
}

/// One rogue-poison Strike landing.
public struct ProcLine {
    public var ts: Int64
    public var strike: String
    public var candidates: [String]
    public var target: String
    public var effect: String

    public init(ts: Int64, strike: String, candidates: [String], target: String, effect: String) {
        self.ts = ts; self.strike = strike; self.candidates = candidates
        self.target = target; self.effect = effect
    }
}

/// A rogue-poison Strike landed on something.
///
/// The emote names no caster, so this is never claimed as "your" proc on its own. It is counted
/// against the fight it lands in, and the slow timing is reported only for pulls that opened with a
/// slow-capable coat on.
///
/// A proc opens no encounter — it is not damage — but it is presence evidence: a mob that just got
/// slowed is still in the fight.
///
/// A proc on you is an incoming mob effect, and a proc on anything we are not fighting is somebody
/// else's blades; neither is ours to count.
public func routeProc(_ st: EngineState, _ ev: ProcLine) {
    let isSlow = ev.effect == "slow"
    let key = Names.idKey(ev.target)
    if key == "you" || !st.isEngagedHostile(key) { return }
    let ambiguous = ev.candidates.count > 1
    let label = ambiguous ? ev.candidates.joined(separator: " / ") : ev.strike
    let target = ev.target
    let fresh = st.freshEncounterId(ev.ts)
    if fresh {
        if let enc = st.freshEncounter(ev.ts) {
            enc.agg.procs.addStrike(label, ambiguous, ev.ts, isSlow)
            if isSlow {
                EngineState.pushMarker(enc, MarkerRaw(ts: ev.ts, kind: "slow", label: SLOW_STRIKE,
                                                      detail: target))
            }
        }
        st.notePresence(target, ev.ts)
    }
    st.zoneAgg.procs.addStrike(label, ambiguous, ev.ts, isSlow)
    st.log(ev.ts, "poison", "you", "☠ \(label) → \(target)")
}

/// Count a dispel landing on an engaged hostile.
///
/// Two load-bearing gates: the curated family (the raw landing stream is far too broad) and
/// engagement (the ledger describes this fight, not every dispel in earshot). Candidates go into the
/// label verbatim, since each message tier is shared by 2–3 spells: the count is exact, the name
/// stays uncertain.
public func routeDispelLanding(_ st: EngineState, _ ts: Int64, _ target: String, _ candidates: [String]) {
    if target == "self" || candidates.isEmpty { return }
    if !candidates.allSatisfy({ isDispelFamily($0) }) { return }
    let key = Names.idKey(target)
    if key == "you" || !st.isEngagedHostile(key) { return }
    let label = candidates.joined(separator: " / ")
    if let enc = st.freshEncounter(ts) { enc.agg.procs.addDispel(label) }
    st.zoneAgg.procs.addDispel(label)
}

/// Apply a stance/invocation change. Updates the current pair and, if an encounter is open, closes
/// the prior span at this ts and opens a new one for the timeline's pinned rows.
///
/// The no-op re-assert returns early, and that is load-bearing rather than an optimisation: stances
/// are mutually exclusive and the game never prints a "your stance ends" line, so a commit is what
/// ends the previous span. Without the guard a re-assert would accrue a zero-width span and move the
/// stance's start to a moment nothing happened at.
public func applyStance(_ st: EngineState, _ group: String, _ name: String, _ ts: Int64) {
    let isStance = group == "stance"
    let cur = isStance ? st.stance : st.invocation
    if let c = cur, c.name == name { return }
    let m = Modifier(name: name, ts: ts)
    if isStance { st.stance = m } else { st.invocation = m }
    // The session span sits alongside, never instead of, the encounter's own span list below, which
    // feeds the shipped timeline view. Two lists, one writer.
    let kind: StateKind = isStance ? .stance : .invocation
    commitState(st, kind, Names.idKey(name), name, ts, group)
    // `current`, not `freshEncounter`: a standing choice belongs to whatever fight is open, stale or
    // not.
    if let enc = st.current {
        for i in enc.stanceSpans.indices.reversed()
        where enc.stanceSpans[i].group == group && enc.stanceSpans[i].end == nil {
            enc.stanceSpans[i].end = ts
            break
        }
        enc.stanceSpans.append(StanceRaw(group: group, name: name, start: ts, end: nil))
        // The span drives the timeline's pinned rows, the marker drives the DPS curve's ticks. Both,
        // because they answer different questions: what was on, versus when it changed.
        EngineState.pushMarker(enc, MarkerRaw(ts: ts, kind: isStance ? "stance" : "invocation",
                                              label: name, detail: nil))
        if isStance { enc.agg.procs.stanceSwitches += 1 } else { enc.agg.procs.invocationSwitches += 1 }
    }
    if isStance { st.zoneAgg.procs.stanceSwitches += 1 } else { st.zoneAgg.procs.invocationSwitches += 1 }
}
