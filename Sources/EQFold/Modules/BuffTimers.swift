// Port of fold/src/modules/buff_timers.rs — the crowd-control half of the buffs/debuffs timer
// overlay: per-target holds keyed by mob, so one AE mez landing on four enemies is four named rows
// with four independent clocks.
//
// It is a separate module only because of what the buffs half cannot see. `<mob> has been
// mesmerized.` is claimed by the CC classifier, which sits ABOVE the DB matcher in the parser's
// cascade, so it never becomes a `buffApply` and never becomes an instance. Everything else — the
// cast anchors, the learner, the count-and-close rule — is HANDED to this module by the wiring
// rather than duplicated, because a second fold of the same events is how two halves drift apart.
//
// Its published `seq` is a private REVISION COUNTER, not the last event's. Readers dedupe with
// `seq <= known`, and `onTick` expires holds while the log is idle — which is exactly when somebody
// is watching a mez run out — so a delta advancing no log seq would be dropped as a duplicate and
// the row would sit on screen forever. Every `rev += 1` here is a published number.
//
// An offline gap is an explicit no-op. Everything held here is on somebody else, and the world those
// mobs stand in does not stop when you camp, so their landings stay where they are. The early return
// also keeps the derived event out of `lastEventTs`, which the primary `sessionStart` it restates
// already recorded.
import Foundation
import EQLog
import EQCompanionCore

/// How long an END is remembered — long enough for the projection to retire a matching active buff
/// the buffs model never clears, and for the overlay to flash a drop. It is not a history.
public let ccEndMemoryMs: Int64 = 60_000

/// How close a `<mob> has been awakened by <name>.` line must land to a mint to be about it.
///
/// One second, because EQ stamps are second-resolution and the pair is always inside one stamp.
public let wakeCensorMs: Int64 = 1_000

/// The bound on a hold whose duration nobody states: the longest stated CC duration in the committed
/// spells.json (660 s, Ensnare). Past the longest hold the game's own data describes, a missing break
/// line is evidence we lost the thread rather than evidence the mob is still held.
public let ccUnknownCapMs: Int64 = 660_000

/// The three landing verbs whose hold ANY damage breaks — the holds a corpse cannot be about.
///
/// A mesmerized mob cannot be killed while mesmerized: the first point of damage wakes it and the
/// log says so before the corpse appears. `ensnared` is deliberately not a member: a snare does
/// nothing to stop you killing what it is on. Charm is the same from the other side and reaches this
/// module with no verb at all.
private func damageBreaks(_ verb: String) -> Bool {
    verb == "mesmerized" || verb == "enthralled" || verb == "entranced"
}

/// The row the snapshot publishes. Every optional is skipped when absent, which the goldens pin.
/// Public because the timer-row projection folds these with the buffs half's actives into rows.
public struct CcHold: Equatable, Sendable {
    /// The held entity's canonical key.
    public var key: String
    /// Its display name.
    public var target: String
    /// When the hold landed. The OLDEST of them when `count` is 2+.
    public var startedTs: Int64
    /// The resolved spell, when the model narrowed the landing sentence to one.
    public var spell: String?
    /// Every spell the sentence could have been. Empty once `spell` is known.
    public var candidates: [String]
    /// The estimator's duration, or nil for a hold that counts up.
    public var durationMs: Int64?
    /// Where that duration came from. Read by the Buffs tab, never by the bars.
    public var source: EstimatorSource?
    /// How many entities of this display name are held. Absent for the ordinary one.
    public var count: Int64?
    /// The allowlisted external who cast it; absent for your own.
    public var caster: String?

    public init(key: String, target: String, startedTs: Int64, spell: String?,
                candidates: [String], durationMs: Int64?, source: EstimatorSource?,
                count: Int64?, caster: String?) {
        self.key = key
        self.target = target
        self.startedTs = startedTs
        self.spell = spell
        self.candidates = candidates
        self.durationMs = durationMs
        self.source = source
        self.count = count
        self.caster = caster
    }

    public var json: JSONValue {
        var o: [String: JSONValue] = [
            "key": .string(key),
            "target": .string(target),
            "startedTs": .int(startedTs),
            "candidates": .array(candidates.map { .string($0) }),
            "durationMs": durationMs.map { .int($0) } ?? .null,
        ]
        if let v = spell { o["spell"] = .string(v) }
        if let v = source { o["source"] = .string(v.rawValue) }
        if let v = count { o["count"] = .int(v) }
        if let v = caster { o["caster"] = .string(v) }
        return .object(o)
    }
}

/// One recorded END of a hold.
public struct CcEnd: Equatable, Sendable {
    /// The entity whose hold ended.
    public var key: String
    /// When, on the log's own clock.
    public var ts: Int64
    /// Which spell, when the break line named one.
    public var spell: String?

    public init(key: String, ts: Int64, spell: String?) {
        self.key = key
        self.ts = ts
        self.spell = spell
    }

    public var json: JSONValue {
        var o: [String: JSONValue] = ["key": .string(key), "ts": .int(ts)]
        if let v = spell { o["spell"] = .string(v) }
        return .object(o)
    }
}

/// What the anchors made of one landing: the spell, whose it is, and what it can be learned from.
private struct CcIdentity {
    var resolved: Bool
    /// The rank-stripped LINE, or `""` for a family the anchors could not narrow.
    var lineKey: String
    /// The RANKED display name from the cast line. Empty alongside an empty `lineKey`.
    var display: String
    var caster: String
    /// Two ranks of this line were in flight at once, so no sample may be minted.
    var rankChanged: Bool
}

/// The landings of one (spell line, mob name), plus the bookkeeping the snapshot does not carry.
/// One of these is one row. A class, because the Rust reaches it through `get_mut`.
private final class Held {
    /// Canonical mob key — the entity half of the identity.
    var entityKey: String
    /// The mob's display name, raw from the log.
    var target: String
    /// The rank-stripped spell LINE, when the anchor resolved one. Empty for a family row.
    var lineKey: String
    /// The RANKED display name from the cast line, when one resolved.
    var spell: String?
    var candidates: [String]
    /// Whose cast: 'self' or an allowlisted external.
    var caster: String
    var durationMs: Int64?
    var source: EstimatorSource?
    /// True when the landing sentence was one of the damage-breaking verbs — a hold whose mob cannot
    /// be damaged without waking it, so no death line may close a landing of this row.
    var mez: Bool
    var group: HoldGroup

    init(entityKey: String, target: String, lineKey: String, spell: String?, candidates: [String],
         caster: String, durationMs: Int64?, source: EstimatorSource?, mez: Bool, group: HoldGroup) {
        self.entityKey = entityKey
        self.target = target
        self.lineKey = lineKey
        self.spell = spell
        self.candidates = candidates
        self.caster = caster
        self.durationMs = durationMs
        self.source = source
        self.mez = mez
        self.group = group
    }
}

/// A culled landing the model still remembers, so a late break line can be measured against it.
///
/// It breaks a trap: a sample can only be minted through a LIVE hold, and a hold is culled at
/// estimate + grace, so once a run of break-shortened cycles drags the learned number below the real
/// duration every full-length hold is culled BEFORE its wear-off arrives and the estimate can never
/// climb back out.
///
/// It is a MEMORY, not a hold. The row still dies on schedule: nothing comes back on screen, no
/// `ends` entry is invented. The join window is DB-floor-scale on purpose — remembering for the
/// culled schedule would be circular, since that schedule is the underestimate.
private struct LateJoin {
    var entityKey: String
    var caster: String
    /// The ranked display name, for the sample's label.
    var spell: String
    /// When the landing happened. The span a late break measures is `breakTs - startedTs`.
    var startedTs: Int64
    /// The last event ts at which this memory may still be joined.
    var joinableUntil: Int64
}

/// One sample this module just minted, kept only long enough for a wake line to annotate it.
private struct RecentMint {
    var entityKey: String
    var lineKey: String
    var caster: String
    var ts: Int64
}

public final class BuffTimersModule: EqModule {
    public let id = "buffTimers"

    private let core: BuffsCore
    private var held = JSMap<Held>()
    private var endsLedger: [CcEnd] = []
    /// Culled landings a late break line may still be measured against.
    private var culled = JSMap<LateJoin>()
    /// Samples minted within the last `wakeCensorMs`, awaiting a possible wake annotation.
    private var recentMints: [RecentMint] = []
    private var lastEventTs: Int64 = 0
    /// Our own revision, not the last event's seq — see the file header.
    private var rev: Int64 = 0

    public init(core: BuffsCore) { self.core = core }

    /// The shared anchors and learner. Both live on `BuffsCore`; nothing here owns either, because
    /// a second fold of the same events is how two halves drift apart.
    private var anchors: CastAnchors { core.anchors }
    private var stats: SpellStats { core.stats }

    /// A fresh `<mob> has been mesmerized|enthralled|entranced|ensnared.`
    ///
    /// The anchor gate: the sentence is a broadcast naming no caster, so a hold opens only when a
    /// cast line anchors it — the player's own, or an allowlisted external's. Without it a crowded
    /// zone fills this overlay with other enchanters' work.
    ///
    /// The narrowing: the parser hands over every spell the sentence could be and the MODEL resolves
    /// against the anchors. Exactly one anchored candidate means that spell, by its ranked name.
    /// More than one, or none, leaves the row a FAMILY, stating a duration only if every candidate
    /// agrees on one.
    private func apply(_ mob: String, _ ts: Int64, _ verb: String?, _ cands: [Candidate]) {
        // No candidates, or no anchored cast, means we cannot tell our own mez from a stranger's.
        // A Quick Buff burst is deliberately NOT an anchor here: it names no spell, and every member
        // of the crowd-control roster is a targeted cast with a cast line of its own.
        let own = cands.filter { anchors.namedAnchorFor($0.name, ts) != nil }
        if own.isEmpty { return }
        let id = resolveCc(own, ts)
        // A fresh landing retires the memory of the old one: the next break sentence on this name
        // belongs to the live hold rather than to a landing the cull already gave up on.
        if !id.lineKey.isEmpty {
            culled.remove("\(Names.idKey(mob))|\(id.lineKey)")
        }
        let key = ensureHold(mob, id, cands, own)
        // The row remembers the strongest thing any of its landings said (`mez` never goes back to
        // false): if one sentence in this family stated a hold damage breaks, a corpse cannot be it.
        if let verb, damageBreaks(verb) {
            held[key]?.mez = true
            // A RESOLVED one also says the mob's other mez just ended. Only resolved: a family row
            // cannot name the line it would be overwriting.
            if !id.lineKey.isEmpty { retireOverwritten(key, ts) }
        }

        // The Buffs tab lists every line the model has knowledge about, and a mez is one of them.
        if !id.lineKey.isEmpty {
            stats.noteEverFaded(id.lineKey)
            stats.touchLastSeen(id.lineKey, ts)
            // The rank this cast named is the tab's too, recorded HERE because the cast line is the
            // only line in a mez's family carrying the numeral and a broken cycle mints nothing to
            // carry it.
            stats.noteDisplayName(id.lineKey, id.caster, id.display)
            held[key]?.spell = id.display
        }

        // The duration the bar draws. Resolved: the shared estimator keyed on (line, caster).
        // Unresolved: the DB agreement rule alone, since there is no line to look a value up under.
        let est: (Int64?, EstimatorSource?)
        if id.lineKey.isEmpty {
            est = (BuffLanding.statedDuration(own), nil)
        } else {
            let e = stats.estimateFor(id.lineKey, id.caster)
            est = (e.ms, e.source)
        }
        if let h = held[key] {
            h.durationMs = est.0
            h.source = est.1
            // A family, or a cast window holding two ranks of one line, can never say what it
            // measured.
            h.group.land(ts, id.lineKey.isEmpty || id.rankChanged)
        }
        rev += 1
    }

    /// Which spell (and whose) this landing is, from the anchored candidates. One anchored candidate
    /// resolves it outright; several are narrowed by the nearest completed cast; only a genuine tie
    /// leaves an empty `lineKey`, this file's spelling of "a family, not a name".
    private func resolveCc(_ own: [Candidate], _ ts: Int64) -> CcIdentity {
        // The nearest completed cast wins. Casting is SERIAL — the game will not begin a second cast
        // while one is in flight, and a cast that dies retracts its own anchor — so the newest
        // anchor at or before a landing is the cast that just completed.
        //
        // A tie stays a FAMILY: two different spells anchored at the same ts means the log printed
        // both cast lines in one second, which recency cannot separate.
        var best: (Candidate, CastAttribution)?
        var tied = false
        for cand in own {
            guard let anchor = anchors.namedAnchorFor(cand.name, ts) else { continue }
            guard let b = best else {
                best = (cand, anchor)
                tied = false
                continue
            }
            if anchor.ts > b.1.ts {
                best = (cand, anchor)
                tied = false
            } else if anchor.ts == b.1.ts {
                tied = true
            }
        }
        if !tied, let (cand, anchor) = best {
            return CcIdentity(resolved: true,
                              lineKey: BuffsShapes.spellKey(cand.name),
                              display: anchor.display ?? cand.name,
                              caster: anchor.caster,
                              rankChanged: anchor.rankChanged)
        }
        return CcIdentity(resolved: false, lineKey: "", display: "",
                          caster: BuffsShapes.selfCaster, rankChanged: false)
    }

    /// A new mez on a mob retires the old one.
    ///
    /// EQ prints nothing when one mez-line spell replaces another on the same mob, so the landing
    /// sentence is the only evidence there is, and it is enough: a mob holds ONE mez, so a mez-verb
    /// landing that resolved to a different line is that mob's previous mez ending.
    ///
    /// It closes one landing and contaminates the rest, as a death does to a snare row: a name is a
    /// name, so an overwrite cannot say which of the mobs we hold was re-mezzed. Oldest-first is also
    /// the one closest to expiring, which is the one a chain-mezzer re-mezzes on purpose.
    ///
    /// Nothing is learned from it and it records no `CcEnd`: the ends ledger exists to retire an
    /// active buff the buffs model never clears, and a hold carrying a mez verb can never have one.
    private func retireOverwritten(_ landedKey: String, _ ts: Int64) {
        guard let landedEntity = held[landedKey]?.entityKey else { return }
        let victims = held.pairs
            .filter { $0.0 != landedKey && $0.1.entityKey == landedEntity && $0.1.mez }
            .map(\.0)
        for key in victims {
            guard let h = held[key] else { continue }
            h.group.contaminateAll()
            _ = h.group.closeOldest(ts)
            let empty = h.group.isEmpty
            let memory = "\(h.entityKey)|\(h.lineKey)"
            culled.remove(memory)
            if empty { held.remove(key) }
        }
    }

    /// The (mob, line) hold this landing belongs to, created on first sight.
    private func ensureHold(_ mob: String, _ id: CcIdentity, _ cands: [Candidate],
                            _ own: [Candidate]) -> String {
        let shown = sortedNames(cands)
        let tail = id.lineKey.isEmpty ? shown.joined(separator: "+").lowercased() : id.lineKey
        let key = "\(Names.idKey(mob))|\(tail)"
        if let existing = held[key] {
            existing.target = mob
            existing.caster = id.caster
            return key
        }
        held.insert(key, Held(
            entityKey: Names.idKey(mob),
            target: mob,
            lineKey: id.lineKey,
            spell: nil,
            candidates: id.resolved ? shown : sortedNames(own),
            caster: id.caster,
            durationMs: nil,
            source: nil,
            mez: false,
            // Never a singleton: a mob is a NAME the world hands out more than once, and no line
            // separates two of them.
            group: HoldGroup(singleton: false)))
        return key
    }

    /// A break line said one of these ended — a mez/root wear-off, or a charm break.
    ///
    /// It closes the OLDEST landing of that (mob, spell) and mints a duration sample when that
    /// landing was a clean cycle. The row survives with one fewer on its count chip; only an empty
    /// group removes it.
    ///
    /// A death does not come here: it names a mob that stopped existing rather than a hold that
    /// ended.
    private func end(_ entityKey: String, _ ts: Int64, _ spell: String?) {
        let line = spell.map { BuffsShapes.spellKey($0) }
        let closedAny = closeLive(entityKey, line, ts)
        // The late join runs only when nothing live was closed — a live hold is always the better
        // answer — and only for a break line that NAMES its spell.
        if !closedAny, let line { lateJoin(entityKey, line, ts) }
        // Recorded even when we held nothing: the projection uses it to retire an active buff the
        // buffs model does not clear, which can exist without a hold beside it.
        endsLedger.append(CcEnd(key: entityKey, ts: ts, spell: spell))
        rev += 1
    }

    /// Close the LIVE holds this ending applies to. Returns whether it found any, which is what
    /// decides between the ordinary path and the late join.
    private func closeLive(_ entityKey: String, _ line: String?, _ ts: Int64) -> Bool {
        var closedAny = false
        for key in held.keys {
            guard let h = held[key] else { continue }
            if h.entityKey != entityKey { continue }
            // A named break line closes only the matching LINE; an anonymous one (a charm break with
            // no spell on it) closes every hold on that mob.
            if let line, !h.lineKey.isEmpty, h.lineKey != line { continue }
            closeOne(key, ts)
            closedAny = true
            if held[key]?.group.isEmpty == true { held.remove(key) }
            rev += 1
        }
        return closedAny
    }

    /// Close this hold's OLDEST landing, minting a sample when that landing was a clean cycle. Only
    /// a break line reaches here.
    private func closeOne(_ key: String, _ ts: Int64) {
        guard let h = held[key] else { return }
        let closed = h.group.closeOldest(ts)
        guard let sample = closed?.sampleMs else { return }
        if sample <= 0 || sample > BuffsShapes.maxSampleMs { return }
        let display = h.spell ?? h.candidates.first ?? h.lineKey
        let at = RecentMint(entityKey: h.entityKey, lineKey: h.lineKey, caster: h.caster, ts: ts)
        mintSample(at, display, sample)
    }

    /// Record one duration sample and re-read every bar it could move.
    ///
    /// The mint is remembered for `wakeCensorMs` so the wake line that follows a break can find the
    /// sample it explains. It is a method rather than two lines inside `closeOne` because the
    /// late-join path mints too, and both have to be annotatable.
    private func mintSample(_ at: RecentMint, _ display: String, _ sampleMs: Int64) {
        stats.pushSample(at.lineKey, at.caster, display,
                         DurationSample(ms: sampleMs, ts: at.ts, censored: false, deathBound: false))
        let (lineKey, caster) = (at.lineKey, at.caster)
        recentMints.append(at)
        // Re-read the estimate for every live hold of this line: a sample that just beat the DB
        // floor must move the bars that are still counting, not only the next cast's.
        restatLine(lineKey, caster)
    }

    /// A break line for a mob whose hold the cull already took — measure it against the landing this
    /// module still remembers.
    ///
    /// It mints through the same cleanliness rules and adds none of its own. The memory is CONSUMED
    /// whether or not the span turns out usable, because a second break sentence for the same
    /// landing is not a second observation of it.
    private func lateJoin(_ entityKey: String, _ lineKey: String, _ ts: Int64) {
        let key = "\(entityKey)|\(lineKey)"
        guard let mem = culled[key] else { return }
        let (joinableUntil, startedTs, caster, spell) =
            (mem.joinableUntil, mem.startedTs, mem.caster, mem.spell)
        culled.remove(key)
        if ts > joinableUntil { return }
        let span = ts - startedTs
        if span <= 0 || span > BuffsShapes.maxSampleMs { return }
        mintSample(RecentMint(entityKey: entityKey, lineKey: lineKey, caster: caster, ts: ts),
                   spell, span)
    }

    /// A mob of this name died, and "which one?" is answered per hold.
    ///
    /// The landing VERB decides. A mez is protected — see `damageBreaks` — so a corpse sharing its
    /// name cannot close it. A snare or a charm has no such protection and a corpse genuinely does
    /// end it, so those keep the count-chip rule.
    ///
    /// A death still does two things to a mez row: it CONTAMINATES the whole group and it forgets
    /// the culled memories for that name.
    ///
    /// It records no `CcEnd`. An end with no spell on it matches every active buff on that entity in
    /// the projection, so a death that closed a snare would blank a slow row the buffs model had
    /// deliberately kept standing.
    private func onMobDeath(_ entityKey: String, _ ts: Int64) {
        var changed = false
        for key in held.keys {
            guard let h = held[key] else { continue }
            if h.entityKey != entityKey { continue }
            h.group.contaminateAll()
            if h.mez { continue }
            _ = h.group.closeOldest(ts)
            if h.group.isEmpty { held.remove(key) }
            changed = true
        }
        forgetCulled(entityKey)
        if changed { rev += 1 }
    }

    /// Every remembered landing on one mob is forgotten (a death, and nothing else calls it).
    private func forgetCulled(_ entityKey: String) {
        for k in culled.pairs.filter({ $0.1.entityKey == entityKey }).map(\.0) {
            culled.remove(k)
        }
    }

    /// `<mob> has been awakened by <name>.` — mark whatever this mob's break just minted as censored.
    ///
    /// It ends nothing: the wear-off line preceding it in the same second already did, and closing a
    /// second landing here would delete a hold on another mob of that name. Nothing displays
    /// differently either, since the estimate is a MAX over both sample windows. What changes is that
    /// a censored sample can no longer evict a full-length one.
    private func censorWake(_ entityKey: String, _ ts: Int64) {
        let candidates = recentMints
            .filter { $0.entityKey == entityKey && ts - $0.ts <= wakeCensorMs && ts >= $0.ts }
            .map { ($0.lineKey, $0.caster, $0.ts) }
        for (lineKey, caster, at) in candidates {
            if !stats.censorSampleAt(lineKey, caster, at) { continue }
            restatLine(lineKey, caster)
            rev += 1
        }
    }

    /// Re-read the estimator for every live hold of one (line, caster) after a sample landed.
    private func restatLine(_ lineKey: String, _ caster: String) {
        if lineKey.isEmpty { return }
        let est = stats.estimateFor(lineKey, caster)
        for h in held.values where h.lineKey == lineKey && h.caster == caster {
            h.durationMs = est.ms
            h.source = est.source
        }
    }

    /// Drop landings nothing ended and ends nobody needs any more.
    private func sweep(_ nowMs: Int64) {
        for key in held.keys {
            // The unwitnessed-expiry cull: a hold whose countdown ran out and whose break line never
            // arrived (you died, you zoned, the mob wandered off) is dropped rather than left
            // squatting at 0 s. It mints nothing and records no end, because nothing was observed.
            guard let h = held[key] else { continue }
            let life = h.durationMs.map { $0 + BuffsShapes.unwitnessedTimeoutMs(h.source) }
                ?? ccUnknownCapMs
            let dropped = h.group.dropExpired(nowMs - life)
            if !dropped.isEmpty {
                remember(key, dropped, life)
                rev += 1
            }
            if held[key]?.group.isEmpty == true { held.remove(key) }
        }
        sweepMemories(nowMs)
        if !endsLedger.isEmpty {
            let before = endsLedger.count
            endsLedger = endsLedger.filter { nowMs - $0.ts <= ccEndMemoryMs }
            if endsLedger.count != before { rev += 1 }
        }
    }

    /// File the CLEAN landings a cull just dropped, so a late break line can still find them.
    ///
    /// Only clean ones: a contaminated landing could not have minted on the live path either.
    /// `lineKey` is necessarily non-empty for a clean landing (`apply` contaminates every family
    /// row), so the memory can always be keyed by (entity, line).
    private func remember(_ key: String, _ dropped: [Hold], _ liveLifeMs: Int64) {
        guard let h = held[key] else { return }
        let dbMs = stats.dbDurationFor(h.lineKey)
        // The learning-record schedule: 3x the DB floor, never shorter than the one the row actually
        // had. Same rule and same function as the buffs half's orphaned open record.
        let window = max(liveLifeMs, BuffsShapes.learningRecordCapMs(dbMs, ccUnknownCapMs))
        let (entityKey, lineKey, caster) = (h.entityKey, h.lineKey, h.caster)
        let spell = h.spell ?? h.candidates.first ?? h.lineKey
        for d in dropped where d.clean {
            culled.insert("\(entityKey)|\(lineKey)",
                          LateJoin(entityKey: entityKey, caster: caster, spell: spell,
                                   startedTs: d.startedTs, joinableUntil: d.startedTs + window))
        }
    }

    /// Retire memories past their join window, and mints too old for a wake line to be about.
    private func sweepMemories(_ nowMs: Int64) {
        for k in culled.pairs.filter({ nowMs > $0.1.joinableUntil }).map(\.0) {
            culled.remove(k)
        }
        if !recentMints.isEmpty {
            recentMints = recentMints.filter { nowMs - $0.ts <= wakeCensorMs }
        }
    }

    /// You left them behind. The memories go too: a landing you left behind is one whose break line
    /// you will never see.
    private func clearHolds() {
        culled.clear()
        if held.isEmpty { return }
        held.clear()
        rev += 1
    }

    private func clearAll() {
        let had = !held.isEmpty || !endsLedger.isEmpty
        held.clear()
        endsLedger.removeAll()
        culled.clear()
        recentMints.removeAll()
        if had { rev += 1 }
    }

    private func dispatch(_ ev: Event) {
        switch ev.kindOf {
        case .cc:
            let mob = ev.str(.mob) ?? ""
            if ev.bool(.refresh) {
                end(Names.idKey(mob), ev.ts, ev.str(.spell))
            } else {
                apply(mob, ev.ts, ev.str(.verb), ccCandidates(ev))
            }
        // Charm is a detrimental hold in the same shape as a mez: the same call, the same anchor
        // gate, the same learner. It is NOT a claim about the entity's disposition — the charmed mob
        // is your pet and simultaneously carries this hold, so it appears in both windows.
        case .charm:
            apply(ev.str(.mob) ?? "", ev.ts, nil, ccCandidates(ev))
        // The break annotation ends nothing — the wear-off line preceding it in the same second
        // already did, and closing a second landing here would delete another mob's hold.
        case .ccWake:
            censorWake(Names.idKey(ev.str(.mob) ?? ""), ev.ts)
        // Charm and CC break through the same sentence family. The line NAMES the charm spell, so it
        // closes that line's hold and leaves a mez on the same mob alone.
        case .uncharm:
            end(Names.idKey(ev.str(.mob) ?? ""), ev.ts, ev.str(.spell))
        // Every death shape, on the name that DIED and never on the killer. The parser already
        // unified them into one event, so there is nothing to branch on here.
        case .death:
            onMobDeath(Names.idKey(ev.str(.name) ?? ""), ev.ts)
        case .zone:
            clearHolds()
        default:
            break
        }
    }

    private func buildSnap() -> JSONValue {
        ["holds": .array(holds().map(\.json)), "ends": .array(endsLedger.map(\.json))]
    }

    /// Every live hold, oldest first, in the module's own shape.
    ///
    /// Split out of `buildSnap` rather than duplicated: the timer-row projection wants the typed rows
    /// and the snapshot wants them as JSON, and building them twice would be two answers waiting to
    /// disagree about which holds are live.
    public func holds() -> [CcHold] {
        var out: [CcHold] = []
        for h in held.values {
            if h.group.isEmpty { continue }
            let count = Int64(h.group.count)
            out.append(CcHold(
                key: h.entityKey,
                target: h.target,
                startedTs: h.group.oldestTs,
                spell: h.spell,
                candidates: h.candidates,
                durationMs: h.durationMs,
                source: h.source,
                count: count > 1 ? count : nil,
                caster: h.caster != BuffsShapes.selfCaster ? h.caster : nil))
        }
        // Rust's `sort_by_key`, which is stable.
        return rowsStableSorted(out) { $0.startedTs == $1.startedTs ? 0 : ($0.startedTs < $1.startedTs ? -1 : 1) }
    }

    /// The recorded ENDS — the half of the projection's dedupe the buffs model cannot see.
    public func ends() -> [CcEnd] { endsLedger }

    /// The change signal: the same private revision counter this module publishes as its `seq`.
    public func revision() -> Int64 { rev }

    // MARK: - EqModule

    public func reset() {
        held.clear()
        endsLedger.removeAll()
        culled.clear()
        recentMints.removeAll()
        lastEventTs = 0
        rev = 0
    }

    public func onEvent(_ ev: Event, live: Bool) {
        // A 30-minute event-time hole is past any hold this module can carry (the same boundary the
        // buffs model uses), and a character epoch is a different character entirely.
        if ev.kind == "epoch" {
            clearAll()
            return
        }
        // An offline gap changes nothing here — see the file header.
        if ev.kind == "offlineGap" { return }
        let ts = ev.ts
        if lastEventTs > 0 && ts - lastEventTs >= BuffsShapes.sessionGapMs { clearAll() }
        lastEventTs = ts
        sweep(ts)
        dispatch(ev)
    }

    /// The wall-clock heartbeat: a hold expires while the log is idle, which is exactly when a player
    /// is staring at the bar waiting for it. Never called on a historical fold.
    public func onTick(nowMs: Int64, timerRows: [BuffTimerRow]) {
        sweep(nowMs)
    }

    /// The dirty bit — the same cursor `snapshot` publishes, without building the state to read it.
    public var publishedSeq: Int64? { rev }

    public func snapshot() -> JSONValue { ["seq": .int(rev), "state": buildSnap()] }

    /// The view pull seam.
    public var asBuffTimers: BuffTimersModule? { self }
}

// MARK: - Checkpoint

extension BuffTimersModule: FoldCheckpointable {
    /// ONLY this module's own state. The shared `core` (anchors + learner) is deliberately absent:
    /// both buff modules hold the one `BuffsCore`, and `BuffsModule` owns its checkpoint — its
    /// blob embeds the core, it registers (and therefore restores) first, and this module's
    /// `reset()` and restore never touch the core, so the state `BuffsModule` just restored is
    /// neither clobbered nor applied twice.
    ///
    /// `rev` IS carried, unlike Loot's `rev`: here it is the published `seq` itself
    /// (`snapshot()` and `publishedSeq` both serve it), so views resume against it.
    /// `recentMints` and `culled` are memories folding still reads (a wake censor, a late join),
    /// `lastEventTs` is what the session-gap clear compares against.
    public func checkpointState() -> JSONValue {
        .object([
            "held": held.checkpoint { h in
                var r: [String: JSONValue] = [
                    "entityKey": .string(h.entityKey),
                    "target": .string(h.target),
                    "lineKey": .string(h.lineKey),
                    "candidates": .array(h.candidates.map { .string($0) }),
                    "caster": .string(h.caster),
                    "mez": .bool(h.mez),
                    "group": h.group.checkpointState(),
                ]
                if let s = h.spell { r["spell"] = .string(s) }
                if let d = h.durationMs { r["durationMs"] = .int(d) }
                if let s = h.source { r["source"] = .string(s.rawValue) }
                return .object(r)
            },
            "ends": .array(endsLedger.map(\.json)),
            "culled": culled.checkpoint { m in
                .object(["entityKey": .string(m.entityKey), "caster": .string(m.caster),
                         "spell": .string(m.spell), "startedTs": .int(m.startedTs),
                         "joinableUntil": .int(m.joinableUntil)])
            },
            "recentMints": .array(recentMints.map {
                .object(["entityKey": .string($0.entityKey), "lineKey": .string($0.lineKey),
                         "caster": .string($0.caster), "ts": .int($0.ts)])
            }),
            "lastEventTs": .int(lastEventTs),
            "rev": .int(rev),
        ])
    }

    public func restoreCheckpoint(_ state: JSONValue) -> Bool {
        reset()
        guard let heldMap = JSMap<Held>.fromCheckpoint(state["held"], { r in
            guard let entityKey = r["entityKey"].string, let target = r["target"].string,
                  let lineKey = r["lineKey"].string, let candRows = r["candidates"].array,
                  let caster = r["caster"].string, let mez = r["mez"].bool,
                  let group = HoldGroup.fromCheckpoint(r["group"]) else { return nil }
            let candidates = candRows.compactMap(\.string)
            guard candidates.count == candRows.count else { return nil }
            var source: EstimatorSource?
            if let s = r["source"].string {
                guard let d = EstimatorSource(rawValue: s) else { return nil }
                source = d
            }
            return Held(entityKey: entityKey, target: target, lineKey: lineKey,
                        spell: r["spell"].string, candidates: candidates, caster: caster,
                        durationMs: r["durationMs"].int64, source: source, mez: mez, group: group)
        }),
        let culledMap = JSMap<LateJoin>.fromCheckpoint(state["culled"], { m in
            guard let entityKey = m["entityKey"].string, let caster = m["caster"].string,
                  let spell = m["spell"].string, let startedTs = m["startedTs"].int64,
                  let until = m["joinableUntil"].int64 else { return nil }
            return LateJoin(entityKey: entityKey, caster: caster, spell: spell,
                            startedTs: startedTs, joinableUntil: until)
        }),
        let endRows = state["ends"].array, let mintRows = state["recentMints"].array,
        let last = state["lastEventTs"].int64, let savedRev = state["rev"].int64
        else { return false }
        var ends: [CcEnd] = []
        ends.reserveCapacity(endRows.count)
        for e in endRows {
            guard let key = e["key"].string, let ts = e["ts"].int64 else { return false }
            ends.append(CcEnd(key: key, ts: ts, spell: e["spell"].string))
        }
        var mints: [RecentMint] = []
        mints.reserveCapacity(mintRows.count)
        for m in mintRows {
            guard let entityKey = m["entityKey"].string, let lineKey = m["lineKey"].string,
                  let caster = m["caster"].string, let ts = m["ts"].int64 else { return false }
            mints.append(RecentMint(entityKey: entityKey, lineKey: lineKey, caster: caster, ts: ts))
        }
        held = heldMap
        endsLedger = ends
        culled = culledMap
        recentMints = mints
        lastEventTs = last
        rev = savedRev
        return true
    }
}

/// The CC/charm broadcast's candidate shape, which carries no illusion flag.
private func ccCandidates(_ ev: Event) -> [Candidate] {
    ev.candidates(.candidates).map {
        // Not the event's flag: this shape carries none.
        Candidate(name: $0.name, durationMs: $0.durationMs, illusion: false)
    }
}

/// Candidate names, ordered by `BuffLanding.compareNames`.
private func sortedNames(_ cands: [Candidate]) -> [String] {
    rowsStableSorted(cands.map(\.name)) { BuffLanding.compareNames($0, $1) }
}
