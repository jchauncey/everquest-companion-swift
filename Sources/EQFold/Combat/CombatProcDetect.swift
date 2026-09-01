// Proc detection: a spell effect line with no own cast line behind it (fold/src/combat/procdetect.rs).
//
// The log prints `You begin casting <Spell>.` for every hand-cast and nothing at all when a weapon,
// a buff-granted melee proc or the Spellblade invocation fires the same spell. So a cast-less effect
// inside the measured 12 s window is a proc — an inference that may name a co-occurrence, never a
// source, and is labeled as one everywhere it surfaces.
//
// A cast record is consumed, and a firing is identified by its instant: every landing at the same
// second joins it, a landing at any later second needs a cast line of its own. The instant is the
// unit because one firing legitimately prints several lines (an AoE nuke, a lifetap's damage plus
// heal). Honest limit: EQ stamps to the second, so a proc in the same second as its own spell's cast
// landing is invisible.
//
// Four refusals. DoT ticks and rain waves are cast-detached by construction. HoT ticks run a minute
// past a three-second cast. `You activate Quick Buff.` re-applies the player's memorized buffs
// printing only the landings, so the heal side refuses those. An interrupt alone is not evidence a
// cast failed, hence `resume()`; `forget` drops only an unclaimed record.
//
// The lane markers are display, never identity: origin decides the lane name, so a spell that both
// casts and procs occupies two rows, and `laneCanonKey` strips the marker at every join.
import Foundation
import EQLog
import EQCompanionCore

/// The cast-attribution window, fixed at 12 s by a partition sweep over the real log. Do not change
/// it without re-running that sweep.
public let PROC_CAST_WINDOW_MS: Int64 = 12_000

/// Memory bound on the recent-cast map. Entries older than the window are pruned on write; this is
/// the belt-and-braces cap for a pathological burst of distinct spell names.
public let RECENT_CAST_CAP = 512

/// How long after `You activate Quick Buff.` a landing still belongs to that burst.
///
/// Measured: every burst-delivered buff landing in the log sits inside 5 s and the nearest true proc
/// sits at 5–10 s.
public let QUICK_BUFF_BURST_MS: Int64 = 5_000

/// `idKey` of the AA whose activation opens that burst.
public let QUICK_BUFF_AA = "quick buff"

/// What a cast-less lane's display name ends with. Never present in an EQ spell name.
public let PROC_LANE_SUFFIX = " \u{00b7} proc"

/// …and what a held-clicky lane's ends with. A second marker rather than a re-used one: proc and
/// click are different claims about the same log line, and only one is true.
public let CLICK_LANE_SUFFIX = " \u{00b7} click"

private let LANE_SUFFIXES = [PROC_LANE_SUFFIX, CLICK_LANE_SUFFIX]

/// What the cast ledger can answer on its own: did one of your own cast lines explain this firing.
public enum CastVerdict: Sendable { case cast, proc }

/// Where a landed spell effect of yours came from.
///
/// `click` is not something the cast ledger can see: an instant clicky prints exactly what a proc
/// prints, so it arrives as `proc` and is promoted by `castlessKind` on evidence from outside the
/// log — the player's own inventory dump.
public enum SpellOrigin: Sendable { case cast, proc, click }

/// One `You begin casting <Spell>.`, and the firing it has already explained (if any).
private struct CastRecord {
    var ts: Int64
    /// ts of the firing this cast explained; `nil` until it explains one.
    var claimTs: Int64?
}

/// The own-cast ledger. Rank-normalized because cast lines print the numeral (`Swift Like the Wind
/// I`) while effect lines are rank-less.
///
/// Only the player prints `You begin casting`, which is the gate this detector needs: a mob's or
/// another player's cast of the same spell never enters here and so can never explain away a proc.
public struct RecentCasts {
    private var casts: [String: CastRecord] = [:]
    /// The record `forget()` most recently dropped, held for a `resume()`.
    private var suspended: (String, CastRecord)?

    public init() {}

    /// Record an own-cast (`You begin casting <Spell>.` / `You begin singing <Song>.`).
    public mutating func note(_ spell: String, _ ts: Int64) {
        // Casting is serial: a new cast line means whatever was interrupted is over, so a pending
        // suspension cannot belong to the recovery that follows this one.
        suspended = nil
        casts[Names.spellCanonKey(spell)] = CastRecord(ts: ts, claimTs: nil)
        if casts.count > RECENT_CAST_CAP { prune(ts) }
    }

    /// A cast line that resolved to nothing (fizzle / interrupt / full resist). Dropped only while
    /// unclaimed — a record that already explained a firing is kept so the rest of that instant's
    /// lines can still join — and remembered so `resume()` can put it back.
    public mutating func forget(_ spell: String) {
        let key = Names.spellCanonKey(spell)
        guard let rec = casts[key] else { return }
        if rec.claimTs != nil { return }
        casts.removeValue(forKey: key)
        suspended = (key, rec)
    }

    /// `You regain your concentration and continue your casting.` — the record comes back with its
    /// original cast ts, because the window runs from when the cast began and the recovery does not
    /// restart it. The line names no spell; it need not, since only one cast can be in flight.
    public mutating func resume() {
        guard let (key, rec) = suspended else { return }
        suspended = nil
        if casts[key] == nil { casts[key] = rec }
    }

    /// The join, and it consumes: ask once per landed effect line, in log order. `cast` when an
    /// in-window cast line explains this firing (claiming it, or matching the instant it already
    /// claimed), `proc` otherwise.
    public mutating func origin(_ spell: String, _ ts: Int64) -> CastVerdict {
        let key = Names.spellCanonKey(spell)
        guard var rec = casts[key] else { return .proc }
        // The window is closed at both ends, so a cast in the future relative to this line (an
        // out-of-order replay) is no cast at all.
        let delta = ts - rec.ts
        if delta < 0 || delta > PROC_CAST_WINDOW_MS { return .proc }
        if let claimed = rec.claimTs {
            return claimed == ts ? .cast : .proc
        }
        rec.claimTs = ts
        casts[key] = rec
        return .cast
    }

    public mutating func clear() {
        casts.removeAll()
        suspended = nil
    }

    /// Drop cast records that can no longer explain anything.
    private mutating func prune(_ now: Int64) {
        casts = casts.filter { now - $0.value.ts <= PROC_CAST_WINDOW_MS }
    }
}

/// The meter lane a landing of `spell` belongs to, given where it came from.
public func laneNameFor(_ spell: String, _ origin: SpellOrigin) -> String {
    switch origin {
    case .proc: return spell + PROC_LANE_SUFFIX
    case .click: return spell + CLICK_LANE_SUFFIX
    case .cast: return spell
    }
}

/// True when a lane name carries either cast-less marker — "is this row one of the cast-less
/// halves".
public func isCastlessLaneName(_ lane: String) -> Bool {
    LANE_SUFFIXES.contains { lane.hasSuffix($0) }
}

/// A lane name with its cast-less marker removed — the spell the row is about.
public func baseLaneName(_ lane: String) -> String {
    for s in LANE_SUFFIXES where lane.hasSuffix(s) {
        return String(lane.dropLast(s.count))
    }
    return lane
}

/// `spellCanonKey` for a meter lane: the marker is display, so both halves of a split key to the one
/// spell they are firings of.
public func laneCanonKey(_ lane: String) -> String {
    Names.spellCanonKey(baseLaneName(lane))
}

/// The rain roster: spells that deliver several waves from one cast. Display spellings only.
private let RAIN_SPELLS = [
    "Avalanche", "Blizzard", "Cascade of Hail", "Energy Storm", "Firestorm", "Frost Storm",
    "Gale of Poison", "Icestrike", "Lava Storm", "Lightning Storm", "Manastorm", "Pogonip",
    "Poison Storm", "Rain of Blades", "Rain of Fire", "Rain of Lava", "Rain of Spikes",
    "Rain of Swords", "Sirocco", "Tears of Druzzil", "Tears of Prexus", "Tears of Solusek",
    "Torrent of Poison",
]

/// True when a spell delivers its damage in waves from one cast. Rank-blind, because a damage line
/// prints the rank-less name while the cast line may carry the numeral.
public func isRainSpell(_ spell: String) -> Bool {
    let key = Names.spellCanonKey(spell)
    return RAIN_SPELLS.contains { Names.spellCanonKey($0) == key }
}

/// Damage lines eligible for cast-less detection: spell effects that are not rain waves.
public func procEligibleDamage(_ dtype: String, _ skill: String) -> Bool {
    dtype == "spell" && !isRainSpell(skill)
}

/// The one place a cast-less firing becomes a click.
///
/// `held` is the set of canonical spell keys the player owns an instant clicky for, empty for a
/// character with no inventory dump — and an empty set makes this the identity function. The catalog
/// is deliberately not used as a fallback: a sweep showed it relabels real procs.
///
/// A `cast` verdict is never promoted: a cast line is direct evidence of a hand-cast, and owning a
/// clicky for the same spell says nothing against it.
public func castlessKind(_ verdict: CastVerdict, _ spell: String, _ held: Set<String>) -> SpellOrigin {
    switch verdict {
    case .cast: return .cast
    case .proc: return held.contains(Names.spellCanonKey(spell)) ? .click : .proc
    }
}

/// One proc whose entire printed footprint is a landing sentence about you.
public struct SelfLandingProcDef: Sendable {
    /// DB spell name, display casing — the lane this firing is counted under.
    public let name: String
}

/// A curated registry, not a stub: a row is earned when a real log shows its sentence firing
/// cast-less inside combat and that sentence is unique in the spell DB, so the count can be
/// attributed to one name. `Blessing of the Theurgist` prints neither a damage nor a heal line — its
/// whole footprint is `The power of your god fills you.`
public let SELF_LANDING_PROCS: [SelfLandingProcDef] = [
    SelfLandingProcDef(name: "Blessing of the Theurgist")
]

/// The registry entry a landing's candidate list names, or `nil`.
///
/// Unambiguous or nothing, stricter than the proc-buff gate: that one opens a span, where a wrong
/// pick mislabels a co-occurrence; this one adds a count to a named lane, where a wrong pick invents
/// firings under somebody else's spell.
public func selfLandingProcIn(_ candidates: [String]) -> SelfLandingProcDef? {
    if candidates.count != 1 { return nil }
    let key = Names.spellCanonKey(candidates[0])
    return SELF_LANDING_PROCS.first { Names.spellCanonKey($0.name) == key }
}

/// Everything the heal side of the inference needs to judge one line.
public struct HealProcInput {
    public var spell: String
    public var ts: Int64
    /// The line said `over time` — a HoT tick.
    public var overTime: Bool
    /// ts of the last `You activate Quick Buff.`, or 0 when none has been seen.
    public var quickBuffTs: Int64

    public init(spell: String, ts: Int64, overTime: Bool, quickBuffTs: Int64) {
        self.spell = spell; self.ts = ts; self.overTime = overTime; self.quickBuffTs = quickBuffTs
    }
}

/// True when a heal line of yours is a cast-less proc, with both exclusions in one place so neither
/// can be applied at one call site and forgotten at another.
///
/// Consuming, and sharing one claim with the damage side: a lifetap's damage and heal lines are one
/// firing at one instant, so whichever arrives first claims the cast and the other matches it.
public func isCastlessHeal(_ recent: inout RecentCasts, _ h: HealProcInput) -> Bool {
    if h.overTime { return false }
    let burst = h.ts - h.quickBuffTs
    if h.quickBuffTs > 0 && burst >= 0 && burst <= QUICK_BUFF_BURST_MS { return false }
    return recent.origin(h.spell, h.ts) == .proc
}

/// Which line carried one firing.
public enum ProcSide: Int, Sendable {
    case damage = 0
    case heal = 1
    case landing = 2

    var slot: Int { rawValue }
}

/// One firing can print two lines: a lifetap prints a damage line and a heal line for one proc.
///
/// So the sides are counted separately and a lane's count is `max` of them, never the sum. `max`
/// rather than the damage side alone because a heal-only proc must still count, and because a tap
/// can print a damage line with no heal line — the larger side is the number of firings observed.
public struct LaneSides {
    private var n: [Int64] = [0, 0, 0]

    public init() {}

    public var damage: Int64 { n[ProcSide.damage.slot] }
    public var heal: Int64 { n[ProcSide.heal.slot] }
    public var landing: Int64 { n[ProcSide.landing.slot] }

    mutating func bump(_ side: ProcSide) { n[side.slot] += 1 }
}

/// Firings across the sides: `max`, never the sum.
public func sidesCount(_ s: LaneSides?) -> Int64 {
    guard let s = s else { return 0 }
    return Swift.max(s.damage, Swift.max(s.heal, s.landing))
}

/// One accumulated proc lane: exact counts and the damage/healing those lines carried. Keyed by
/// `spellCanonKey`, displayed by the raw name first seen.
public struct SpellProcLane {
    public var name: String
    public var hits: LaneSides
    public var damage: Int64
    public var heal: Int64
    /// True when this lane's firings were attributed to a clicky the player holds. A property of the
    /// lane, not of each fold: the held set is fixed for a session.
    public var click: Bool
    /// The per-state firing split, folded on ingest because the encounter event ring is capped,
    /// truncated on finalize and absent for zone sessions.
    ///
    /// States overlap, so these never sum to the lane count: each entry answers only "how many of
    /// this lane's firings happened with X on".
    public var byState: JSMap<LaneSides>
}

/// One lane's firings, the number every rate and every link is built from.
public func laneCount(_ l: SpellProcLane) -> Int64 { sidesCount(l.hits) }

/// Everything one detected proc contributes. A firing whose only line was a landing sentence has no
/// amount: `nil` rather than 0, because 0 would enter the lane's total as a measurement reading "it
/// did nothing" when nothing was measured.
public struct SpellProcFold {
    public var spell: String
    public var side: ProcSide
    /// Non-nil on a measured (damage/heal) fold, nil on a landing.
    public var amount: Int64?
    /// `<kind>:<key>` of every state open at the firing instant. Not optional — an empty set is a
    /// real observation ("nothing was on"), not a missing argument.
    public var active: Set<String>
    public var click: Bool

    public init(spell: String, side: ProcSide, amount: Int64?, active: Set<String>, click: Bool) {
        self.spell = spell; self.side = side; self.amount = amount
        self.active = active; self.click = click
    }
}

/// Fold one detected proc into a lane map. Every fold bumps its own side of the count; only a
/// measured one moves an amount, and no fold moves a damage total the meter already owns.
public func addSpellProc(_ lanes: inout JSMap<SpellProcLane>, _ f: SpellProcFold) {
    let key = Names.spellCanonKey(f.spell)
    var lane = lanes[key] ?? SpellProcLane(name: f.spell, hits: LaneSides(), damage: 0, heal: 0,
                                           click: false, byState: JSMap())
    if f.click { lane.click = true }
    lane.hits.bump(f.side)
    switch f.side {
    case .damage: lane.damage += f.amount ?? 0
    case .heal: lane.heal += f.amount ?? 0
    case .landing: break
    }
    for stateKey in f.active {
        var sides = lane.byState[stateKey] ?? LaneSides()
        sides.bump(f.side)
        lane.byState.insert(stateKey, sides)
    }
    lanes.insert(key, lane)
}

// MARK: - Checkpoint

extension LaneSides {
    func checkpointState() -> JSONValue {
        .array(n.map { .int($0) })
    }

    static func fromCheckpoint(_ v: JSONValue) -> LaneSides? {
        guard let rows = v.array, rows.count == 3 else { return nil }
        var vals: [Int64] = []
        for r in rows {
            guard let i = r.int64 else { return nil }
            vals.append(i)
        }
        var out = LaneSides()
        out.n = vals
        return out
    }
}

extension SpellProcLane {
    func checkpointState() -> JSONValue {
        ["name": .string(name), "hits": hits.checkpointState(), "damage": .int(damage),
         "heal": .int(heal), "click": .bool(click),
         "byState": byState.checkpoint { $0.checkpointState() }]
    }

    static func fromCheckpoint(_ v: JSONValue) -> SpellProcLane? {
        guard let name = v["name"].string, let hits = LaneSides.fromCheckpoint(v["hits"]),
              let damage = v["damage"].int64, let heal = v["heal"].int64,
              let click = v["click"].bool,
              let byState = JSMap<LaneSides>.fromCheckpoint(v["byState"], LaneSides.fromCheckpoint)
        else { return nil }
        return SpellProcLane(name: name, hits: hits, damage: damage, heal: heal, click: click,
                             byState: byState)
    }
}

extension RecentCasts {
    /// The ledger mid-flight, `claimTs` and the suspended record included: a checkpoint can land
    /// between a cast line and the firing it will explain, or between an interrupt and its
    /// `resume()`, and losing either would read the resumed lines as procs.
    func checkpointState() -> JSONValue {
        var o: [String: JSONValue] = [
            "casts": .object(casts.mapValues { rec -> JSONValue in
                var r: [String: JSONValue] = ["ts": .int(rec.ts)]
                if let c = rec.claimTs { r["claimTs"] = .int(c) }
                return .object(r)
            }),
        ]
        if let (key, rec) = suspended {
            var r: [String: JSONValue] = ["key": .string(key), "ts": .int(rec.ts)]
            if let c = rec.claimTs { r["claimTs"] = .int(c) }
            o["suspended"] = .object(r)
        }
        return .object(o)
    }

    static func fromCheckpoint(_ v: JSONValue) -> RecentCasts? {
        guard let castsObj = v["casts"].object else { return nil }
        var out = RecentCasts()
        for (key, rv) in castsObj {
            guard let ts = rv["ts"].int64 else { return nil }
            out.casts[key] = CastRecord(ts: ts, claimTs: rv["claimTs"].int64)
        }
        if let sv = v["suspended"].presentValue {
            guard let key = sv["key"].string, let ts = sv["ts"].int64 else { return nil }
            out.suspended = (key, CastRecord(ts: ts, claimTs: sv["claimTs"].int64))
        }
        return out
    }
}
