// The buff-INSTANCE store: the single pending cast, the landed-and-open casts awaiting their fade,
// and the currently-active instances — plus every mutation of them. Landing, fade pairing (the
// duration sample), the censoring paths (death / zone / log hole / hygiene / entity retirement), and
// the offline PAUSE, which is not a censor at all but the one place a live clock is rewound.
//
// It knows nothing about log events: the module above translates events into these calls.
//
// `active` is a `JSMap` because its ITERATION ORDER IS PUBLISHED. `removeSharedWearOff` closes the
// matching candidates in map order, which decides the order of the duration samples pushed and of
// the derived expiries handed back to the bus; `clearSelfIllusion` emits in map order for the same
// reason.
// (fold/src/modules/buffs_instances.rs)
import Foundation
import EQLog
import EQCompanionCore

/// Everything a LANDING states about itself.
public struct LandingSpec {
    public var target: String
    public var ts: Int64
    public var illusion: Bool
    public var durationMs: Int64?
    /// 'self' or an allowlisted external — the learner's second key.
    public var caster: String?
    /// The spell LINE key this instance is identified by, when it differs from what the row is
    /// named. A family row is named for every candidate and keyed on one of them.
    public var lineKey: String?
    /// The ranked text the cast line spelled, when it is not simply the spell's own name.
    public var castName: String?
    /// The spells this landing sentence could be, when it is a FAMILY the anchor could not narrow.
    public var candidates: [String]?
    public var permanentIllusionOwnedTs: Int64?
}

/// A resolved expiry the module is to synthesize a `buffExpired` for.
public struct Expiry {
    public var spell: String
    public var target: String
}

public final class BuffInstances {
    /// The single cast currently in flight, or none.
    public var pending: Pending?
    /// Landed casts awaiting their fade, keyed by INSTANCE key.
    public var open = JSMap<OpenCast>()
    /// Currently-active buff instances, keyed by INSTANCE key.
    public var active = JSMap<ActiveBuff>()
    /// Resolved expiries produced while folding the current event, in emission order.
    public var expired: [Expiry] = []

    public init() {}

    public func reset() {
        pending = nil
        open.clear()
        active.clear()
        expired.removeAll()
    }

    private func expire(_ spell: String, _ target: String) {
        expired.append(Expiry(spell: spell, target: target))
    }

    /// True when any active instance is of this spell key (the ambiguous-apply tiebreak).
    public func hasActiveSpell(_ key: String) -> Bool {
        active.keys.contains { BuffsShapes.instanceSpellKey($0) == key }
    }

    /// Illusion exclusivity: only ONE illusion can be active on an entity at a time. Removes every
    /// illusion-flagged active and open instance bound to `entityKey` except the one being applied
    /// now. Applies to self and pet alike.
    private func clearIllusionsOn(_ entityKey: String, _ keepKey: String, _ stats: SpellStats) {
        let doomed = active.keys.filter { ik in
            ik != keepKey
                && BuffsShapes.instanceEntityKey(ik) == entityKey
                && stats.isIllusion(BuffsShapes.instanceSpellKey(ik))
        }
        for ik in doomed {
            active.remove(ik)
            open.remove(ik)
        }
    }

    /// Remove the single illusion-flagged SELF active — the `Your illusion fades.` handler.
    ///
    /// The raw line names no spell, but the model has resolved it to the one active self illusion,
    /// so the derived event carries that resolved spell.
    public func clearSelfIllusion(_ stats: SpellStats) {
        let doomed: [(String, String)] = active.pairs
            .filter { $0.1.isSelf && stats.isIllusion(BuffsShapes.instanceSpellKey($0.0)) }
            .map { ($0.0, $0.1.spell) }
        for (ik, spell) in doomed {
            active.remove(ik)
            open.remove(ik)
            expire(spell, BuffsShapes.selfKey)
        }
    }

    /// A cast nothing confirmed within the landing window never landed, so its record is dropped.
    public func dropUnconfirmedPending(_ now: Int64) {
        if let p = pending, now - p.beganTs >= BuffsShapes.landTimeoutMs { pending = nil }
    }

    /// Stage a new cast in flight. A cast opens nothing — no instance, no open cast, no row —
    /// because a provisional row would be bound to a GUESS at the target and a resist retracts
    /// nothing.
    public func beginCast(_ key: String, _ ts: Int64) {
        pending = Pending(key: key, beganTs: ts, emoteSubjectKey: nil)
    }

    /// A fizzle/interrupt of `key` clears the pending cast. It never opened anything to retract.
    public func clearPendingCast(_ key: String) {
        if pending?.key == key { pending = nil }
    }

    /// Infer the target disposition of a cast at LAND time from the current entity state, a LEARNED
    /// landing emote, and the spell's class. A learned self-emote proves a SELF cast even while a
    /// pet is live.
    private func inferCastDisposition(_ key: String, _ emoteSubjectKey: String?,
                                      _ stats: SpellStats, _ pets: PetEntities) -> Disposition {
        if emoteSubjectKey == BuffsShapes.selfKey { return .zelf }
        if let sub = emoteSubjectKey, sub != BuffsShapes.selfKey {
            if pets.charmedKey == sub { return .charmed }
            if pets.summonedKey == sub { return .summoned }
            return pets.summonedKey != nil ? .summoned : .charmed
        }
        if stats.classOf(key) == .debuff { return .hostile }
        if pets.charmedKey != nil { return .charmed }
        if pets.summonedKey != nil { return .summoned }
        return .zelf
    }

    /// Apply a buff from an exact chat-message match. `target` is 'self' for a cast-on-you or
    /// self-heal line, else the named target — bound to THAT entity's key.
    ///
    /// A repeat landing is a ROUND, not an overwrite: it goes to the instance's `HoldGroup`.
    public func applyMessageBuff(_ spell: String, _ spec: LandingSpec,
                                 _ stats: SpellStats, _ pets: PetEntities) {
        let key = spec.lineKey ?? BuffsShapes.spellKey(spell)
        // What a landing must state to open a row: a duration, an illusion flag, or the spell DB's
        // own word that it never expires. The third arm is not redundant — a permanent buff has no
        // duration BECAUSE it is permanent.
        if spec.durationMs == nil && !spec.illusion && !stats.isPermanent(key) { return }
        // A self apply of a DETRIMENTAL spell is an incoming debuff a mob cast on the player.
        let isSelf = spec.target == "self"
        if isSelf && stats.classOf(key) == .debuff { return }
        stats.noteEverFaded(key)
        stats.touchLastSeen(key, spec.ts)
        if pending?.key == key { pending = nil }

        // Where it binds: the entity it names, that entity's disposition, whose cast it is, and
        // whether it is permanent. The target's display CASING is remembered here.
        let eKey = isSelf ? BuffsShapes.selfKey : Names.idKey(spec.target)
        if !isSelf { pets.namedEntityDisplay.insert(eKey, spec.target) }
        let disp: Disposition = isSelf ? .zelf : pets.dispForNamedTarget(spec.target)
        let caster = spec.caster ?? BuffsShapes.selfCaster
        let permanent = BuffsInstanceRules.landingIsPermanent(
            isSelf, stats.isPermanent(key), spec.illusion, spec.ts, spec.permanentIllusionOwnedTs)

        let iKey = BuffsShapes.instanceKey(key, eKey)
        openRecord(iKey, spell, spec.castName, key, eKey, caster, disp)
        // A family never mints — we do not know which spell it was — so its landings open
        // contaminated.
        if let rec = open[iKey] { rec.group.land(spec.ts, spec.candidates != nil) }
        // A permanent self illusion has no expiry to pair with, so it keeps no open record at all.
        if permanent { open.remove(iKey) }
        let projected: ActiveBuff = {
            let record = open[iKey]
            let startedTs: Int64
            let count: Int64
            let recordSpell: String
            let recordCast: String?
            if let r = record {
                startedTs = r.group.oldestTs
                count = Int64(r.group.count)
                recordSpell = r.spell
                recordCast = r.castName
            } else {
                // The permanent branch above deleted it: report the landing instant and a count
                // of one.
                startedTs = spec.ts
                count = 1
                recordSpell = spell
                recordCast = spec.castName
            }
            var out = ActiveSpec()
            out.spell = recordSpell
            out.castName = recordCast
            out.key = key
            out.entityKey = eKey
            out.startedTs = permanent ? spec.ts : startedTs
            out.dispOverride = disp
            out.caster = caster
            out.count = permanent ? 1 : count
            out.candidates = spec.candidates
            out.messageDriven = true
            out.permanent = permanent
            return buildActive(out, stats, pets)
        }()
        active.insert(iKey, projected)
        // A new illusion apply on this entity replaces any prior illusion active on it.
        if spec.illusion { clearIllusionsOn(eKey, iKey, stats) }
    }

    /// The open record this landing belongs to, created on first sight — or recreated when the
    /// CASTER changed, because a different caster's durations are a different learner key.
    private func openRecord(_ iKey: String, _ spell: String, _ castName: String?, _ key: String,
                            _ eKey: String, _ caster: String, _ disp: Disposition) {
        if let existing = open[iKey], existing.caster == caster {
            existing.spell = spell
            // The NEWEST landing's word on what was cast, including "nothing extra".
            existing.castName = castName
            existing.disp = disp
            return
        }
        // Singleton unless the entity is a plain HOSTILE: you, your summoned pet and your charmed
        // pet are identities this model tracks. A mob is only ever a NAME.
        open.insert(iKey, OpenCast(spell: spell, castName: castName, spellKey: key, entityKey: eKey,
                                   group: HoldGroup(singleton: disp != .hostile), caster: caster,
                                   disp: disp, spannedGap: false))
    }

    /// Authoritative removal: a wears-off message proves the SELF instance expired now. Pairs a
    /// duration sample if the open cast exists, then clears that instance.
    private func removeAuthoritative(_ key: String, _ entityKey: String, _ ts: Int64,
                                     _ stats: SpellStats, _ pets: PetEntities) {
        let iKey = BuffsShapes.instanceKey(key, entityKey)
        let spell: String = active[iKey]?.spell
            ?? stats.sampleSpellName(key, open[iKey]?.caster ?? BuffsShapes.selfCaster)
            ?? key
        stats.noteEverFaded(key)
        recordFade(key, entityKey, spell, ts, stats, pets)
        // Now resolved to `spell` on `entityKey`. Alerts match this unambiguous kind.
        expire(spell, pets.targetDisplayFor(entityKey))
    }

    /// Shared wears-off resolution. A wears-off line whose message maps to MULTIPLE candidate spells
    /// resolves against the ACTIVE set rather than guessing a single spell.
    public func removeSharedWearOff(_ candidateNames: [String], _ entityKey: String, _ ts: Int64,
                                    _ stats: SpellStats, _ pets: PetEntities) {
        let cands = candidateNames.map { BuffsShapes.spellKey($0) }
        var matched: [String] = []
        for ik in active.keys {
            if BuffsShapes.instanceEntityKey(ik) != entityKey { continue }
            let k = BuffsShapes.instanceSpellKey(ik)
            if cands.contains(k) && !matched.contains(k) { matched.append(k) }
        }
        for k in matched { removeAuthoritative(k, entityKey, ts, stats, pets) }
    }

    /// Pair a fade with its own open landed instance (a duration sample) and clear the active.
    ///
    /// A sample is minted only from an exact (spell, entity, CASTER) chain. It closes the OLDEST
    /// landing: the wear-off names the mob but not which mob of that name. The row survives with one
    /// fewer on its count chip; only an empty group clears it.
    public func recordFade(_ key: String, _ entityKey: String, _ spell: String, _ fadeTs: Int64,
                           _ stats: SpellStats, _ pets: PetEntities) {
        stats.touchLastSeen(key, fadeTs)
        let iKey = BuffsShapes.instanceKey(key, entityKey)
        if let openRec = open[iKey] {
            let closed = openRec.group.closeOldest(fadeTs)
            let sample = closed?.sampleMs
            let caster = openRec.caster
            let spanned = openRec.spannedGap
            let empty = openRec.group.isEmpty
            // Censor a sample whose land→fade window crossed an offline gap. The fade itself is
            // still authoritative and the instance clears, but the SPAN is not a duration.
            if !spanned, let ms = sample, ms > 0, ms <= BuffsShapes.maxSampleMs {
                // Never censored on this path: the wake line is a crowd-control annotation, and no
                // sentence in the log says a beneficial buff or a debuff ended early.
                addSample(key, caster, spell,
                          DurationSample(ms: ms, ts: fadeTs, censored: false, deathBound: false),
                          stats, pets)
            }
            if empty {
                open.remove(iKey)
            } else {
                restat(iKey, stats, pets)
                return
            }
        }
        active.remove(iKey)
    }

    /// Re-project one live instance after its group changed (count / oldest clock moved).
    private func restat(_ iKey: String, _ stats: SpellStats, _ pets: PetEntities) {
        guard let prev = active[iKey], let openRec = open[iKey] else { return }
        let spec = reprojectSpec(prev, openRec.spellKey, openRec.entityKey, openRec.group.oldestTs,
                                 openRec.caster, Int64(openRec.group.count))
        active.insert(iKey, buildActive(spec, stats, pets))
    }

    private func addSample(_ key: String, _ caster: String, _ spell: String, _ sample: DurationSample,
                           _ stats: SpellStats, _ pets: PetEntities) {
        stats.pushSample(key, caster, spell, sample)
        // Re-stat every live instance of this spell (they share the per-(line, caster) stats).
        let targets = active.keys.filter { BuffsShapes.instanceSpellKey($0) == key }
        for ik in targets {
            let count = open[ik].map { Int64($0.group.count) } ?? active[ik]?.count ?? 1
            guard let a = active[ik] else { continue }
            let spec = reprojectSpec(a, key, BuffsShapes.instanceEntityKey(ik), a.startedTs,
                                     a.caster ?? BuffsShapes.selfCaster, count)
            active.insert(ik, buildActive(spec, stats, pets))
        }
    }

    /// The offline-gap PAUSE, and the asymmetry it turns on.
    ///
    /// Your buffs pause: EQ does not run buff timers while the character is out of the world. So a
    /// beneficial instance surviving a gap has its clock shifted forward by the absence. Debuffs do
    /// not pause: what EQ pauses is your CHARACTER, and the world it stands in keeps running.
    ///
    /// `fromTs` is the last instant the character is KNOWN to have been in the world, so only
    /// instances predating it are shifted.
    public func onOfflinePause(_ fromTs: Int64, _ offlineMs: Int64,
                               _ stats: SpellStats, _ pets: PetEntities) {
        if offlineMs <= 0 { return }
        for ik in open.keys {
            guard let o = open[ik] else { continue }
            let oldest = o.group.oldestTs
            let isDebuff = stats.classOf(o.spellKey) == .debuff
            if oldest > fromTs { continue }
            // The learner is censored either way; only the CLOCK is asymmetric.
            o.spannedGap = true
            let shifted = !isDebuff && o.group.shiftBy(offlineMs, fromTs)
            if shifted { restat(ik, stats, pets) }
        }
        // An active with no open record behind it (a permanent illusion) has no group to shift.
        let bumped = active.pairs
            .filter { $0.1.cls != .debuff && $0.1.startedTs <= fromTs && !open.containsKey($0.0) }
            .map(\.0)
        for ik in bumped {
            if var a = active[ik] {
                a.startedTs += offlineMs
                active.insert(ik, a)
            }
        }
        // A cast in flight when the character left the world never completed.
        pending = nil
    }

    /// Session-gap clear: wipe live actives/opens/pending.
    public func clearForGap() {
        active.clear()
        open.clear()
        pending = nil
    }

    /// Drop every instance whose clock predates `ts` — the unexplained-hole resolution.
    ///
    /// It is SCOPED rather than blanket because the ruling arrives after the hole did, and anything
    /// raised on this side of the hole is evidence from this side of it.
    public func dropPredating(_ ts: Int64) {
        for ik in active.pairs.filter({ $0.1.startedTs <= ts }).map(\.0) { active.remove(ik) }
        for ik in open.pairs.filter({ $0.1.group.oldestTs <= ts }).map(\.0) { open.remove(ik) }
        if let p = pending, p.beganTs <= ts { pending = nil }
    }

    /// Hygiene sweep: retire any active past its per-spell cap.
    ///
    /// `heldBeforeTs` is the last-known-online instant of a log hole whose explanation has not
    /// arrived yet (0 when there is none). A BUFF older than it is EXEMPT for the length of that
    /// wait. DEBUFFS get no exemption; their clocks never stop.
    ///
    /// The unwitnessed cull takes the ROW and leaves the PAIRING RECORD, deliberately.
    ///
    /// Returns whether it changed the PUBLISHED set. The `reapOrphanedOpen` call at the end is
    /// deliberately not counted: it touches `open`, which is not in the snapshot.
    @discardableResult
    public func sweepHygiene(_ now: Int64, _ heldBeforeTs: Int64,
                             _ stats: SpellStats, _ pets: PetEntities) -> Bool {
        var changed = false
        for ik in active.keys {
            guard let a = active[ik] else { continue }
            if a.permanent == true { continue }
            if heldBeforeTs > 0 && a.cls != .debuff && a.startedTs <= heldBeforeTs { continue }
            let dbMs = stats.dbDurationFor(BuffsShapes.instanceSpellKey(ik))
            // The long stop goes first, because it means "we lost the thread" and is the only one
            // that takes the PAIRING RECORD with it.
            let longCap = BuffsInstanceRules.hygieneCap(a, dbMs)
            let elapsed = Double(now - a.startedTs)
            if elapsed > longCap {
                // The cap is fractional whenever the p75 statistic beat the 90-minute floor, and
                // `dropExpired` compares an integer ts against it. For an integer x, `x <= r` is
                // `x <= floor(r)`.
                let cutoff = Int64((Double(now) - longCap).rounded(.down))
                retireExpired(ik, cutoff, stats, pets)
                changed = true
                continue
            }
            if elapsed > BuffsInstanceRules.unwitnessedCullCap(a) {
                active.remove(ik)
                changed = true
            }
        }
        // The loop above can only reach a record through its active row, so the records the cull
        // left behind need their own reaper.
        BuffsInstanceRules.reapOrphanedOpen(&open, active, stats, now)
        return changed
    }

    /// The long-stop path: shed the landings older than `cutoffTs`, and drop the record when empty.
    private func retireExpired(_ ik: String, _ cutoffTs: Int64, _ stats: SpellStats, _ pets: PetEntities) {
        if let o = open[ik] {
            o.group.dropExpired(cutoffTs)
            if !o.group.isEmpty {
                restat(ik, stats, pets)
                return
            }
            open.remove(ik)
        }
        active.remove(ik)
    }

    /// A player death strips SELF buffs: censor open self casts and clear their actives.
    public func onPlayerDeath(_ stats: SpellStats, _ pets: PetEntities) {
        for ik in open.pairs.filter({ $0.1.entityKey == BuffsShapes.selfKey }).map(\.0) { open.remove(ik) }
        for ik in active.pairs.filter({ $0.1.isSelf }).map(\.0) { active.remove(ik) }
        if let p = pending {
            // A pending self cast is abandoned (death interrupts it). A debuff/pet cast survives.
            if inferCastDisposition(p.key, p.emoteSubjectKey, stats, pets) == .zelf { pending = nil }
        }
    }

    /// A mob of this name died — the death censor, and the one path every death shape reaches.
    ///
    /// It closes ONE landing, not the row. It mints no CYCLE: a land-to-death span is not a
    /// duration. What it does mint is a LOWER BOUND.
    public func onEntityDeath(_ entityKey: String, _ ts: Int64, _ stats: SpellStats, _ pets: PetEntities) {
        for ik in open.keys { censorOpenOnDeath(ik, entityKey, ts, stats, pets) }
        let dead = active.pairs.filter { (ik, a) in
            !open.containsKey(ik)
                && BuffsInstanceRules.deathCensorsActive(a, BuffsShapes.instanceEntityKey(ik), entityKey)
        }.map(\.0)
        for ik in dead { active.remove(ik) }
    }

    /// One open record against one corpse: measure the lower bound, then close its oldest landing
    /// and contaminate what is left. The bound is read and minted BEFORE the close.
    private func censorOpenOnDeath(_ ik: String, _ entityKey: String, _ ts: Int64,
                                   _ stats: SpellStats, _ pets: PetEntities) {
        guard let o = open[ik] else { return }
        let isDebuff = stats.classOf(o.spellKey) == .debuff
        if !BuffsInstanceRules.deathCensorsOpen(o, entityKey, isDebuff) { return }
        // Never off the `unknown-hostile` bucket `deathCensorsOpen` also sweeps: that row's target
        // is an INFERENCE, and a span measured against a mob the log never named is not evidence.
        let ms = (isDebuff && o.entityKey == entityKey)
            ? BuffsInstanceRules.deathBoundSpan(o, entityKey, ts, stats) : nil
        let spellKeyOf = o.spellKey
        let caster = o.caster
        let spell = o.spell
        if let ms {
            addSample(spellKeyOf, caster, spell,
                      DurationSample(ms: ms, ts: ts, censored: false, deathBound: true), stats, pets)
        }
        guard let o2 = open[ik] else { return }
        o2.group.contaminateAll()
        _ = o2.group.closeOldest(ts)
        if !o2.group.isEmpty {
            restat(ik, stats, pets)
        } else if open.remove(ik) {
            active.remove(ik)
        }
    }

    /// Retire an ENTITY, with no pet-specific branches: censor every open cast and active instance
    /// bound to `entityKey`, buff and debuff alike.
    public func retireEntity(_ entityKey: String, _ pets: PetEntities) {
        for ik in open.pairs.filter({ $0.1.entityKey == entityKey }).map(\.0) { open.remove(ik) }
        for ik in active.keys.filter({ BuffsShapes.instanceEntityKey($0) == entityKey }) { active.remove(ik) }
        pets.retireSlots(entityKey)
    }

    /// Zone: the player keeps self buffs, a SUMMONED pet follows and keeps its buffs, a CHARMED pet
    /// is left behind, and so are hostile mobs.
    public func onZone(_ stats: SpellStats, _ pets: PetEntities) {
        for ik in open.pairs.filter({ BuffsInstanceRules.openLeftBehindOnZone($0.1) }).map(\.0) { open.remove(ik) }
        let dead = active.pairs.filter { (_, a) in
            a.cls == .debuff || a.disposition == .charmed || a.disposition == .hostile
        }.map(\.0)
        for ik in dead { active.remove(ik) }
        pets.clearOnZone()
        if let p = pending {
            let disp = inferCastDisposition(p.key, p.emoteSubjectKey, stats, pets)
            if disp == .charmed || disp == .hostile { pending = nil }
        }
    }

    // MARK: - Checkpoint

    /// The pending cast, the open pairing records (each with its full `HoldGroup`, round
    /// bookkeeping included) and the active rows, all in map order — the order is published.
    /// `expired` is deliberately NOT carried: the module drains it into its derived queue at the
    /// end of every event and tick, so it is empty at any between-events checkpoint instant.
    func checkpointState() -> JSONValue {
        var o: [String: JSONValue] = [
            "open": open.checkpoint { oc in
                var r: [String: JSONValue] = [
                    "spell": .string(oc.spell),
                    "spellKey": .string(oc.spellKey),
                    "entityKey": .string(oc.entityKey),
                    "group": oc.group.checkpointState(),
                    "caster": .string(oc.caster),
                    "disp": .string(oc.disp.rawValue),
                    "spannedGap": .bool(oc.spannedGap),
                ]
                if let c = oc.castName { r["castName"] = .string(c) }
                return .object(r)
            },
            "active": active.checkpoint(\.json),
        ]
        if let p = pending {
            var r: [String: JSONValue] = ["key": .string(p.key), "beganTs": .int(p.beganTs)]
            if let e = p.emoteSubjectKey { r["emoteSubjectKey"] = .string(e) }
            o["pending"] = .object(r)
        }
        return .object(o)
    }

    func restoreCheckpoint(_ v: JSONValue) -> Bool {
        reset()
        guard let openMap = JSMap<OpenCast>.fromCheckpoint(v["open"], { r in
            guard let spell = r["spell"].string, let spellKey = r["spellKey"].string,
                  let entityKey = r["entityKey"].string, let caster = r["caster"].string,
                  let dispRaw = r["disp"].string, let disp = Disposition(rawValue: dispRaw),
                  let spanned = r["spannedGap"].bool,
                  let group = HoldGroup.fromCheckpoint(r["group"]) else { return nil }
            return OpenCast(spell: spell, castName: r["castName"].string, spellKey: spellKey,
                            entityKey: entityKey, group: group, caster: caster, disp: disp,
                            spannedGap: spanned)
        }),
        let activeMap = JSMap<ActiveBuff>.fromCheckpoint(v["active"], ActiveBuff.fromCheckpoint)
        else { return false }
        if case .object = v["pending"] {
            guard let key = v["pending"]["key"].string,
                  let began = v["pending"]["beganTs"].int64 else { return false }
            pending = Pending(key: key, beganTs: began,
                              emoteSubjectKey: v["pending"]["emoteSubjectKey"].string)
        }
        open = openMap
        active = activeMap
        return true
    }
}

/// The spec for re-projecting a row that is already live: everything the instance IS, carried
/// forward from the row being replaced, with only the coordinates a re-projection restates supplied
/// by the caller. It exists because the store re-projects from two places that must not drift.
func reprojectSpec(_ a: ActiveBuff, _ key: String, _ entityKey: String, _ startedTs: Int64,
                   _ caster: String, _ count: Int64) -> ActiveSpec {
    var s = ActiveSpec()
    s.spell = a.spell
    s.castName = a.castName
    s.key = key
    s.entityKey = entityKey
    s.startedTs = startedTs
    s.dispOverride = a.disposition
    s.caster = caster
    s.count = count
    s.candidates = a.candidates
    s.messageDriven = a.messageDriven == true
    s.permanent = a.permanent == true
    return s
}
