// The ingest switch — one canonical event in, one state transition out (`fold/src/combat/ingest.rs`),
// plus the three lines that bind one of YOUR pets and the four the ally model reads.
//
// Split along the five event families, which are disjoint on `kind`, so the chain is exactly the old
// switch: each family tries its own cases and reports whether it consumed the event.
//
//   ingestWorld    epoch · zone · charm · petClaim · allyPetLeader · petSay · uncharm · cc · death
//   ingestCombat   damage · heal · healUnstated · mitigation · miss · resist
//   ingestCast     castBegin · castFizzle · castInterrupted · otherCastBegin · castResumed
//   ingestChoice   stanceChange · invocationChange · specialAttack
//   ingestModifier poisonCoat · poisonDry · poisonProc · buffApply · buffWearOff · aaActivate ·
//                  playerDeath
//
// The proc analytics fold here and must: everything they need is a count or an index over damage the
// meter already counted, and the encounter event ring is capped, truncated at finalize and absent
// entirely for a zone session — so "what was on when this fired" is knowable only now. Nothing below
// calls an `add*` that moves a damage total.
import Foundation
import EQLog
import EQCompanionCore

/// Fold one canonical event into the state machine.
public func ingestEvent(_ st: EngineState, _ ev: Event) {
    // The three deadline models age out on the LOG clock, driven from the event stream and from the
    // snapshot — whichever observes the deadline first acts. The nudge sweep is ungated by
    // `hydrating` because a model that can only be armed live sweeps for nothing in a replay.
    st.sweepCharm(ev.ts)
    st.sweepAlly(ev.ts)
    st.petNudge.sweep(ev.ts)
    // The blade coats are consulted on the same clock but deliberately NOT from the snapshot: the
    // other three are display timers, this one mutates the fold.
    sweepCoatClass(st, ev)
    if ingestWorld(st, ev) { return }
    if ingestCombat(st, ev) { return }
    if ingestCast(st, ev) { return }
    if ingestChoice(st, ev) { return }
    ingestModifier(st, ev)
}

/// Leaving rogue bares the blades — the second of the two boundaries the wiki's Rogue page names.
///
/// The whole feature is the GATE on when the class model may be consulted. Three clauses: there must
/// be something to clear; a loadout-stating event (`selfWho` / `level`) asks immediately; otherwise
/// at most once per `CLASS_CHECK_MS` of LOG time.
///
/// The consultation itself cannot happen without a combo provider, which this fold does not install.
/// The throttle stamp is written BEFORE the ask, so `coatClassCheckedTs` advances on exactly the same
/// events either way.
func sweepCoatClass(_ st: EngineState, _ ev: Event) {
    if st.coatUtility == nil && st.coatCombat.isEmpty { return }
    let statesLoadout = ev.kindOf == .selfWho || ev.kindOf == .level
    if !statesLoadout && ev.ts - st.coatClassCheckedTs < CLASS_CHECK_MS { return }
    st.coatClassCheckedTs = ev.ts
    // The combo provider is nil in this fold, so the TS returns here and so does this.
}

/// The poll period, in LOG milliseconds — never a wall clock, so a replay consults at exactly the
/// instants the live tail did. Fifteen minutes because that is the combo interval model's own
/// `WINDOW_FLOOR_MS`.
let CLASS_CHECK_MS: Int64 = 15 * 60_000

func ingestWorld(_ st: EngineState, _ ev: Event) -> Bool {
    switch ev.kindOf {
    // Character rebirth — a same-name character was wiped and recreated. The session's fights are
    // deliberately kept; what goes is the beta character's WORLD state.
    case .epoch:
        finalizeCurrent(st)
        st.petNames.removeAll()
        st.world.reset()
        st.charm.reset()
        st.ally.reset()
        // The blade coats go with them, through the SAME door the death rule uses, so the slots and
        // the spans cannot end up disagreeing.
        _ = clearCoats(st, ev.ts, .epoch)
        // An epoch severs every active-state span. Censored, never `observed`.
        st.stateTimeline.censorAll(ev.ts)
        st.specials.reset()
        return true

    case .zone:
        finalizeCurrent(st)
        // Freeze the just-left stay's aggregate into the capped history before resetting. An empty
        // stay is dropped.
        st.finalizeZoneSession(.zone)
        st.zone = ev.str(.zone)
        // The accumulator half of the boundary, shared with the session mark. Everything BELOW this
        // line is what a mark omits, because it states that the ROOM changed.
        st.resetZoneAccumulators()
        // Charm cannot survive a zone and hostile mobs do not follow, so both retire. Summoned class
        // pets persist, so the survivors are what the fast pet-name index is rebuilt from.
        let survivors = st.world.zone(ev.ts)
        st.drainRetirements()
        let keys = survivors.map(\.nameKey)
        st.petNames = Set(keys)
        st.charm.zone(keys)
        // Somebody else's charm cannot survive a zone either, and neither can a cast in flight. The
        // friendly set survives — it is about people, not about the room.
        st.ally.zone()
        let zone = ev.str(.zone) ?? ""
        st.log(ev.ts, "zone", "info", "▸ entered \(zone)")
        return true

    case .charm:
        ingestCharm(st, ev)
        return true

    case .petClaim:
        // `via: 'petBuff'` never comes off a line: it is `bindPetBuffLanding` handed to the bus,
        // which delivers it straight back here. Refusing it makes the seam provably loop-free.
        if ev.str(.via) != "petBuff", let name = ev.str(.name) {
            let via = ev.str(.via) ?? "tell"
            bindPetClaim(st, name, ev.ts, via)
        }
        return true

    case .allyPetLeader:
        // The speaker just named somebody its leader, which settles what it IS whether or not the
        // ally model goes on to bind it.
        if let pet = ev.str(.pet) {
            let why = "named \(ev.str(.owner) ?? "") its leader"
            st.retractOther(Names.idKey(pet), why)
        }
        ingestAllyPetLeader(st, ev)
        return true

    case .petSay:
        // A `says` line is broadcast and proves nothing about WHOSE pet the speaker is. What it does
        // prove is that the speaker is somebody's pet, which no other rung of the record-everything
        // ladder can establish.
        if let name = ev.str(.name) {
            let why = "said a pet sentence (\(ev.str(.say) ?? ""))"
            st.retractOther(Names.idKey(name), why)
        }
        return true

    case .uncharm:
        // `Your <charm spell> spell has worn off of <mob>` — only the caster sees this, so it is
        // retroactive proof the bind was ours. Corroborate first, then release.
        if let mob = ev.str(.mob) {
            let key = Names.idKey(mob)
            st.charm.notePetEvidence(key)
            _ = st.world.uncharm(mob, ev.ts)
            st.drainRetirements()
            st.petNames.remove(key)
            st.charm.release(key)
            st.log(ev.ts, "uncharm", "info", "✕ charm broke: \(mob)")
        }
        return true

    case .cc:
        ingestCc(st, ev)
        return true

    case .death:
        ingestDeath(st, ev)
        return true

    default:
        return false
    }
}

/// `<mob> has been charmed.` — the ownership gate. The line is a broadcast and names no caster, so it
/// binds only when it resolved one of the owner's own charm casts. A foreign charm is remembered as
/// an observation, so it stays available to the petClaim promote path but never enters the
/// attribution set.
func ingestCharm(_ st: EngineState, _ ev: Event) {
    guard let mob = ev.str(.mob) else { return }
    let key = Names.idKey(mob)
    // Whoever's charm it is, the thing is a MOB — true of both arms below.
    st.retractOther(key, "a charm broadcast named it")
    if st.charm.charmBroadcast(key, mob, ev.ts) == .foreign {
        // A charm broadcast that resolved none of YOUR casts, offered to the ally model before it is
        // dropped. The world model is deliberately not told: `world.charm()` marks an instance as a
        // pet of ours, and an ally's pet is none of those things to us.
        var text: String
        switch st.ally.broadcast(key, mob, ev.ts) {
        case .bind(let bind):
            let note = bind.ambiguous ? " (a same-named twin is active - crediting nothing)" : ""
            st.log(ev.ts, "charm", "info",
                   "⚡ \(mob) charmed by \(bind.charmer) - crediting its damage to them\(note)")
            return
        case .refuse(let reason):
            text = "⚡ \(mob) charmed by someone else - \(reason)"
        case .none:
            text = "⚡ \(mob) charmed by someone else - not your pet"
        }
        st.log(ev.ts, "charm", "dropped", text)
        return
    }
    // Your charm wins outright over any ally bind of the same mob — two models calling one entity a
    // pet is duplicated ownership.
    _ = st.ally.release(key)
    let inst = st.world.charm(mob, ev.ts)
    let label = inst.label, id = inst.instanceId
    st.drainRetirements()
    st.notePet(key)
    st.log(ev.ts, "charm", "info", "⚡ charmed \(label) [\(id)]")
}

/// The parenthetical a claim's ring line carries, one per route. `via` reaches the processing log and
/// nothing else: all three routes are ownership-definitive and the model treats them identically.
func claimNote(_ via: String) -> String {
    switch via {
    case "leader": return " (it named you its leader)"
    case "petBuff": return " (you cast a pet-only spell on it)"
    // `tell` — the private, unforgeable route, which needs no explaining.
    default: return ""
    }
}

/// A pet identified you as its owner, so the named entity is your pet. Three lines produce this one
/// transition and this function deliberately does not care which.
///
/// Ownership-definitive and pet-only, which is why it also PROMOTES: a name we saw charmed but
/// declined to bind is bound here, and bound as charmed rather than summoned.
func bindPetClaim(_ st: EngineState, _ name: String, _ ts: Int64, _ via: String) {
    let key = Names.idKey(name)
    // Anything that names itself yours stops being anybody else's.
    _ = st.ally.release(key)
    let promote = st.world.petInstance(name) == nil && st.charm.claimIsCharmed(key, ts)
    let inst = promote ? st.world.charm(name, ts) : st.world.claim(name, ts)
    let label = inst.label, id = inst.instanceId
    st.drainRetirements()
    st.notePet(key)
    // The claim is also the corroboration a provisional charm bind was waiting for.
    st.charm.notePetEvidence(key)
    // …and it answers the nudge, whichever route produced it.
    st.petNudge.noteBound()
    let what = promote ? "charm claim" : "pet claim"
    st.log(ts, promote ? "charm" : "pet", "info",
           "⚡ \(what) \(label) [\(id)]\(claimNote(via))")
    // Single-pet succession: claiming a new summoned pet retires the previous one inside the world
    // model, and the name index has to follow it out. The world model decides; the index and the
    // charm model are told.
    for gone in st.syncPetNames() {
        st.charm.release(gone)
        st.log(ts, "pet", "info", "✕ \(gone) retired - one pet at a time; \(name) is yours now")
    }
}

/// `<PetName> says, 'My leader is <Player>.'` about somebody else — the strongest ally bind, and the
/// only one that reaches a stranger's summoned pet.
func ingestAllyPetLeader(_ st: EngineState, _ ev: Event) {
    guard let pet = ev.str(.pet), let owner = ev.str(.owner) else { return }
    let ownerKey = Names.idKey(owner)
    let petKey = Names.idKey(pet)
    if !st.allyCasterAllowed(ownerKey) { return }
    // Your own pet is yours, whatever a broadcast says. `says` is forgeable and the cost of getting
    // this wrong is deleting a real pet's damage, so the refusal is absolute.
    if st.petNames.contains(petKey) || st.everPet.contains(petKey) { return }
    let everCharmed = st.charm.everCharmed(petKey)
    let bind = st.ally.bindByLeader(AllyLeaderLine(petKey: petKey, pet: pet, owner: owner,
                                                   ownerKey: ownerKey, ts: ev.ts,
                                                   everCharmed: everCharmed))
    // The classification is said out loud: a lifecycle you cannot see is one nobody can report a bug
    // about.
    let shape = bind.kind == .summon ? "summoned pet" : "charmed"
    st.log(ev.ts, "charm", "info",
           "⚡ \(pet) named \(bind.charmer) its leader (\(shape)) - crediting its damage to them")
}

/// Crowd control (mez/root, not charm). Evaluate any pending closure at this ts FIRST, so a CC on a
/// fresh pull cannot attach to a stale fight, then mark the CC'd instance engaged and CC-held.
///
/// Ownership gate: `<mob> has been mesmerized.` is a broadcast with no caster, so an APPLICATION only
/// counts when it resolved one of the owner's own CC casts. A foreign mez is fully inert. The REFRESH
/// shape is exempt by construction.
func ingestCc(_ st: EngineState, _ ev: Event) {
    let refresh = ev.bool(.refresh)
    if !refresh && !st.charm.ccBroadcast(ev.ts) {
        // A stranger's crowd control is an observation about the room, not an event in our fight, and
        // the refusal is said out loud.
        let mob = ev.str(.mob) ?? ""
        st.log(ev.ts, "cc", "dropped", "✜ CC on \(mob) - not ours (no own cast to resolve)")
        return
    }
    guard let mob = ev.str(.mob) else { return }
    evalClosure(st, ev.ts)
    let inst = st.resolve(mob, ev.ts, false)
    if inst.instanceId == "you" { return }
    let label = inst.label
    ensureEncounter(st, ev.ts)
    guard let enc = st.current else { return }
    enc.engaged.insert(inst.instanceId)
    enc.engagedSeen.insert(inst.instanceId, ev.ts)
    enc.ccActiveUntil.insert(inst.instanceId, ev.ts + CC_HOLD_MS)
    st.lastActivityTs = ev.ts
    let tag = refresh ? "refresh" : "applied"
    let spell = ev.str(.spell).map { " (\($0))" } ?? ""
    st.log(ev.ts, "cc", "info", "✜ CC \(tag): \(label)\(spell)")
}

func ingestDeath(_ st: EngineState, _ ev: Event) {
    guard let name = ev.str(.name) else { return }
    let key = Names.idKey(name)
    // A dead pet is not a pet. Unconditional and BY NAME, unlike the world model's pet-vs-twin
    // disambiguation below, because an ally bind is name-keyed to begin with.
    if let gone = st.ally.release(key) {
        st.log(ev.ts, "charm", "dropped", "✕ \(gone.display) died - \(gone.charmer)'s pet is gone")
    }
    let killerKey: String? = ev.bool(.bySelf) ? "you" : ev.str(.killer).map { Names.idKey($0) }
    let res = st.world.death(name, ev.ts, killerKey)
    let petNote = res.wasPet ? " (pet)" : ""
    let ambNote = res.ambiguous ? " ~ambiguous" : ""
    st.log(ev.ts, "death", "info", "☠ \(name) died\(petNote)\(ambNote) - \(res.reason)")
    // The retired instance stays in `engaged` — so an in-fight heal on the corpse still counts —
    // because closure consults `isRetired`, not set membership.
    st.drainRetirements()
    // Keep the fast pet-name set in lockstep: drop the name only when NO pet instance of it remains.
    if st.world.petInstance(name) == nil {
        st.petNames.remove(key)
        st.charm.release(key)
    }
}

/// The sentence a mitigation line gets in the ring, branching on `mtype`.
func mitigationLineText(_ ev: Event) -> String {
    let source = ev.str(.source) ?? "?"
    switch ev.str(.mtype) {
    case "rune": return "⛊ rune +\(ev.int(.amount) ?? 0) absorption"
    case "absorbSwing": return "⛊ absorbed \(source)'s blow"
    default: return "⛊ absorbed \(source)'s damage shield"
    }
}

func ingestCombat(_ st: EngineState, _ ev: Event) -> Bool {
    switch ev.kindOf {
    case .damage:
        ingestDamage(st, ev)
        return true

    case .heal:
        let line = HealLine(ts: ev.ts, target: ev.str(.target) ?? "", healer: ev.str(.healer),
                            amount: ev.int(.amount) ?? 0, rawAmount: ev.int(.rawAmount),
                            spell: ev.str(.spell), crit: ev.bool(.crit))
        routeHeal(st, line)
        foldHealAnalytics(st, line, ev.bool(.overTime))
        let spell = line.spell.map { " (\($0))" } ?? ""
        st.log(line.ts, "heal", "info",
               "+ \(line.healer ?? "?") → \(line.target) \(line.amount)\(spell)")
        return true

    // A heal with no amount cannot enter the proc model — a 0-amount "Mend proc" is a fabricated
    // observation — so it reaches the healing ledger's count lane and nothing else.
    case .healUnstated:
        routeHealUnstated(st, ev.ts, ev.str(.skill) ?? "")
        // …and the ring says so rather than printing a 0 that reads like a measurement.
        let target = ev.str(.target) ?? "", skill = ev.str(.skill) ?? ""
        st.log(ev.ts, "heal", "info", "+ \(target) \(skill) (amount not stated)")
        return true

    // Damage PREVENTED, not hit points restored: it never touches a damage total, but it does reach
    // the healing total as a rune/absorbed row.
    case .mitigation:
        routeMitigation(st, MitigationLine(ts: ev.ts, mtype: ev.str(.mtype) ?? "",
                                           amount: ev.int(.amount)))
        st.log(ev.ts, "mitigation", "info", mitigationLineText(ev))
        return true

    case .miss:
        guard let mtype = ev.str(.mtype).flatMap(MissType.parse) else { return true }
        let attacker = ev.str(.attacker) ?? ""
        routeMiss(st, MissLine(
            ts: ev.ts, attacker: attacker, target: ev.str(.target) ?? "", mtype: mtype,
            verb: ev.str(.verb),
            // A miss line names no skill, so the round lane's floor is the parser's own
            // `meleeSkill(verb)` answer.
            verbSkill: ev.str(.verb).map { meleeSkill($0) },
            modifiers: ev.arrStr(.modifiers)))
        // Your avoided swing is still an ATTEMPT, and the mechanical proc denominator is attempts.
        if Names.idKey(attacker) == "you" {
            let ts = ev.ts
            foldBoth(st, ts) { agg, active in
                agg.windows.fold(WindowFold(ts: ts, swings: 1), active)
                agg.procs.addSwing(active)
            }
        }
        return true

    case .resist:
        let caster = ev.str(.caster) ?? ""
        let spell = ev.str(.spell) ?? ""
        let incoming = ev.bool(.incoming)
        // `<mob> resisted your <Charm>!` is the third way an armed cast fails to land. Only our own
        // outgoing resist counts.
        if !incoming && Names.idKey(caster) == "you" {
            // A fully-resisted cast landed nothing, so like a fizzle it must not stay in the window
            // to claim the next proc of the same name. `forget` drops only an UNCLAIMED record.
            st.recentCasts.forget(spell)
            st.charm.noteCastFailed(spell, ev.ts)
        }
        routeResist(st, ResistLine(ts: ev.ts, caster: caster, target: ev.str(.target) ?? "",
                                   spell: spell, incoming: incoming))
        return true

    default:
        return false
    }
}

/// One canonical `damage` line: close any pending encounter at this ts BEFORE routing, so attributed
/// damage after a closure starts a fresh encounter rather than reviving the old one.
func ingestDamage(_ st: EngineState, _ ev: Event) {
    // Caster-less other-player DoTs (`attacker: null`) are not our fight, and the raw line is what
    // the ring keeps.
    guard let attacker = ev.str(.attacker) else {
        st.log(ev.ts, "other", "dropped", ev.raw)
        return
    }
    evalClosure(st, ev.ts)
    let modifiers = ev.arrStr(.modifiers)
    let dmg = toDamageEvent(st, ev, attacker, modifiers)
    // The origin verdict names the LANE, so it is reached before `route()` folds the hit — and
    // exactly once, because it CONSUMES the cast claim.
    let origin = damageOrigin(st, dmg)
    // The lane a cast-less firing lands in — a fresh record, never a mutation of the one the ledger
    // gets, because `spellProcs` is keyed by the SPELL and its row must stay one lane.
    var laned = dmg
    if let o = origin { laned.skill = laneNameFor(dmg.skill, o) }
    // Read the active-time clock either side of `route()`: the DIFFERENCE is the capped-gap delta
    // this hit accrued, and a fresh encounter contributes 0.
    let encBefore = st.current?.id
    let activeBefore = st.current?.activeMs ?? 0
    guard let at = route(st, origin != nil ? laned : dmg) else { return }
    let sameEncounter = st.current?.id == encBefore
    let delta = sameEncounter ? (st.current?.activeMs ?? 0) - activeBefore : 0
    foldDamageAnalytics(st, dmg, delta, at, origin)
}

/// Where one of your spell effects came from, decided before the line is routed because the answer
/// names the meter LANE it lands in. `nil` = the question does not arise.
///
/// The two eligibility gates run first and in that order, so only a `dtype: spell` line of the
/// player's ever pays for the extra `classify`.
func damageOrigin(_ st: EngineState, _ ev: DamageEvent) -> SpellOrigin? {
    if ev.amount <= 0 { return nil }
    if !procEligibleDamage(ev.dtype, ev.skill) { return nil }
    if Names.idKey(ev.attacker) != "you" { return nil }
    if classify(st, ev.attacker, ev.target) != .outYou { return nil }
    // The cast ledger answers cast-or-not; the held-clicky set is what turns a `proc` verdict into a
    // `click` one. Empty set ⇒ identity, so this line changes nothing without a dump.
    let verdict = st.recentCasts.origin(ev.skill, ev.ts)
    return castlessKind(verdict, ev.skill, st.heldClickies)
}

/// Fold one judgement into both ledgers this segment has — the zone aggregate and the FRESH
/// encounter, if any. Every proc counter is written through here, so the two can never disagree about
/// a line and the per-state split is fed from exactly one place.
///
/// `active` is the state timeline's open set, read at the event's own instant and passed (never
/// re-read) into every accumulator, because the point of folding on ingest is that "what was on when
/// this fired" is knowable only now.
func foldBoth(_ st: EngineState, _ ts: Int64, _ f: (Agg, Set<String>) -> Void) {
    let fresh = st.freshEncounterId(ts)
    let active = st.stateTimeline.active
    f(st.zoneAgg, active)
    if fresh, let enc = st.current { f(enc.agg, active) }
}

/// Proc analytics for one attributed damage line. Purely additive.
///
/// The three judgements, each with its gate:
///   * Outgoing-YOURS only. Proc analytics stay strictly first-person.
///   * A SWING is a melee or slay hit (misses are added by the miss path).
///   * A PROC is a cast-less spell effect. A click is a cast-less firing too, so it folds a lane;
///     what changes is the lane NAME, which `ingestDamage` has already applied.
func foldDamageAnalytics(_ st: EngineState, _ ev: DamageEvent, _ activeDeltaMs: Int64,
                         _ at: Attribution, _ origin: SpellOrigin?) {
    if ev.amount <= 0 || at == .ignore { return }
    let mine = at == .outYou
    let swing = mine && (ev.category == "melee" || ev.category == "slay")
    let proc = mine && (origin == .proc || origin == .click)
    let click = origin == .click
    let fold = WindowFold(ts: ev.ts, activeDeltaMs: activeDeltaMs,
                          outDamage: mine ? ev.amount : 0,
                          procDamage: proc ? ev.amount : 0,
                          swings: swing ? 1 : 0)
    // The ledger gets the un-split skill: `spellProcs` is keyed by the SPELL, so its row, PPM and
    // drill tag stay one lane however many meter rows the spell occupies.
    let spell = ev.skill
    let amount = ev.amount
    foldBoth(st, ev.ts) { agg, active in
        agg.windows.fold(fold, active)
        agg.procs.addActiveMs(activeDeltaMs, active)
        if swing { agg.procs.addSwing(active) }
        if proc {
            agg.procs.addSpellProc(SpellProcFold(spell: spell, side: .damage, amount: amount,
                                                 active: active, click: click))
        }
    }
}

/// A heal with no own cast behind it — the healing half of the same inference. Gated to your own
/// heals and to the two refusals `isCastlessHeal` owns: a HoT tick and a Quick Buff burst landing.
func foldHealAnalytics(_ st: EngineState, _ ev: HealLine, _ overTime: Bool) {
    guard let spell = ev.spell else { return }
    if Names.idKey(ev.healer ?? "") != "you" { return }
    let quickBuffTs = st.quickBuffTs
    if !isCastlessHeal(&st.recentCasts, HealProcInput(spell: spell, ts: ev.ts, overTime: overTime,
                                                      quickBuffTs: quickBuffTs)) {
        return
    }
    // The gate above has already reached `proc`; the held set is what would promote it to a click.
    let click = castlessKind(.proc, spell, st.heldClickies) == .click
    let amount = ev.amount
    foldBoth(st, ev.ts) { agg, active in
        agg.procs.addSpellProc(SpellProcFold(spell: spell, side: .heal, amount: amount,
                                             active: active, click: click))
    }
}

/// The engine's internal damage record, with the lane named.
///
/// EQ Legends' upgraded specials print no verb of their own (a Dragon Punch lands as `You strike …`),
/// so the parser can only answer the generic skill. The lane applies the log's own statement of which
/// special is live in that verb's lane. It is a pure RENAME of `skill` — amount, type, category and
/// attribution are untouched — and it is gated on the attacker being You.
func toDamageEvent(_ st: EngineState, _ ev: Event, _ attacker: String,
                   _ modifiers: [String]) -> DamageEvent {
    let verb = ev.str(.verb)
    var skill = ev.str(.skill) ?? ""
    if Names.idKey(attacker) == "you", let lane = st.specials.laneSkill(verb) {
        skill = lane
    }
    let dtype = ev.str(.dtype) ?? ""
    return DamageEvent(
        ts: ev.ts,
        attacker: attacker,
        target: ev.str(.target) ?? "",
        amount: ev.int(.amount) ?? 0,
        dtype: dtype,
        dclass: ev.str(.dclass),
        skill: skill,
        crit: ev.bool(.crit),
        // Prefer the parse-time category; derive as a fallback so any path that omits it still
        // aggregates under the right axis.
        category: ev.str(.category) ?? Taxonomy.damageCategory(dtype, modifiers),
        modifiers: modifiers,
        verb: verb)
}

/// The own-cast lifecycle. Its own family because both of the engine's ownership inferences run off
/// it and must see the same lines: the cast-less proc detector, and the charm/CC/pet-buff ownership
/// model, whose only honest owner signal is the exclusivity of `You begin casting <Spell>.`
func ingestCast(_ st: EngineState, _ ev: Event) -> Bool {
    switch ev.kindOf {
    case .castBegin:
        if let spell = ev.str(.spell) {
            st.recentCasts.note(spell, ev.ts)
            st.charm.noteCastBegin(spell, ev.ts)
        }
        // The third reader of the same exclusivity. A pet summon is knowable from this line and only
        // from this line, so a summon with no bind behind it is the one moment the meter can honestly
        // say it is about to miss a pet. Live only.
        if !st.hydrating, let spell = ev.str(.spell), isPetSummonSpell(spell) {
            st.petNudge.noteSummonCast(ev.ts)
        }
        return true

    case .castFizzle, .castInterrupted:
        // A cast that resolved to nothing explains no landing, and nothing it might have "resolved"
        // is ours. An interrupt can still RECOVER, which is what `castResumed` is for.
        if let spell = ev.str(.spell) {
            st.recentCasts.forget(spell)
            st.charm.noteCastFailed(spell, ev.ts)
            // The same for the nudge: a summon that never resolved summoned nothing.
            if isPetSummonSpell(spell) { st.petNudge.noteCastFailed() }
        }
        return true

    case .otherCastBegin:
        // The only sentence in this log that says who ELSE is casting what, and therefore the only
        // thing that can name the owner of a caster-less `<mob> has been charmed.` broadcast.
        guard let caster = ev.str(.caster), let spell = ev.str(.spell) else { return true }
        let casterKey = Names.idKey(caster)
        let allowed = st.allyCasterAllowed(casterKey)
        st.ally.noteCast(AllyCastLine(caster: caster, casterKey: casterKey, spell: spell,
                                      ts: ev.ts, allowed: allowed))
        return true

    // `You regain your concentration and continue your casting.` — the interrupted cast is back on
    // and will land, so give it back its claim with its ORIGINAL cast ts.
    case .castResumed:
        st.recentCasts.resume()
        return true

    default:
        return false
    }
}

/// The character's standing choices — stance, invocation, and the active special attack. Its own
/// family because none of the three is an event in a fight.
func ingestChoice(_ st: EngineState, _ ev: Event) -> Bool {
    switch ev.kindOf {
    case .stanceChange:
        if let name = ev.str(.stance) {
            applyStance(st, "stance", name, ev.ts)
            st.log(ev.ts, "stance", "info", "▸ stance: \(name)")
        }
        return true

    case .invocationChange:
        if let name = ev.str(.invocation) {
            applyStance(st, "invocation", name, ev.ts)
            st.log(ev.ts, "invocation", "info", "▸ invocation: \(name)")
        }
        return true

    case .specialAttack:
        // `You will now use Dragon Punch instead of Eagle Strike while attacking.` — the one line
        // that names the special behind an otherwise anonymous `You strike …`. It opens nothing,
        // closes nothing and moves no total; it changes what a later swing is CALLED.
        if let skill = ev.str(.skill) {
            let lane = st.specials.note(skill)
            // A special outside the verified lane table is still seen and still logged.
            let note = lane.map { " (\($0) lane)" } ?? " (no verb lane - label unchanged)"
            let from = ev.str(.replaces).map { " instead of \($0)" } ?? ""
            st.log(ev.ts, "special", "info", "▸ special attack: \(skill)\(from)\(note)")
        }
        return true

    default:
        return false
    }
}

/// coats · procs · dispel landings · Quick Buff · your own death. Everything here is an annotation:
/// none of it opens, extends or closes an encounter.
func ingestModifier(_ st: EngineState, _ ev: Event) {
    switch ev.kindOf {
    case .poisonCoat:
        routeCoat(st, CoatLine(ts: ev.ts, poison: ev.str(.poison) ?? "unknown",
                               group: ev.str(.group) ?? "unknown", who: ev.str(.who) ?? ""))

    case .poisonDry:
        routeDry(st, ev.str(.group) ?? "", ev.ts)

    case .poisonProc:
        routeProc(st, ProcLine(ts: ev.ts, strike: ev.str(.strike) ?? "",
                               candidates: ev.arrStr(.candidates),
                               target: ev.str(.target) ?? "", effect: ev.str(.effect) ?? ""))

    case .buffApply:
        let names = ev.candidateNames(.candidates)
        let target = ev.str(.target) ?? ""
        // The pet bind runs FIRST so the three gates below see a world model that already knows whose
        // the buffed entity is. Four disjoint gates over one event, none consuming another's lines.
        if target != "self" { bindPetBuffLanding(st, ev) }
        routeDispelLanding(st, ev.ts, target, names)
        routeProcBuffApply(st, ev.ts, target, names)
        routeSelfLandingProc(st, ev.ts, target, names)

    // The rare printed end of a tracked proc buff — the only path that can close a buff span
    // `observed`. It reads `arrStr`, not `candidateNames`: a `buffApply` carries objects because the
    // buffs module needs the duration, while a `buffWearOff` carries plain STRINGS.
    case .buffWearOff:
        routeProcBuffWearOff(st, ev.ts, ev.arrStr(.candidates))

    // The Quick Buff burst: this AA re-applies every memorized buff and prints their LANDINGS only,
    // with no cast line for any of them, so without this stamp each landing reads as a cast-less
    // proc. The activation is the cast evidence, in a different shape.
    case .aaActivate:
        if Names.idKey(ev.str(.name) ?? "") == QUICK_BUFF_AA { st.quickBuffTs = ev.ts }

    case .playerDeath:
        // Blade coats die with you. The coat clear runs BEFORE the censor so the spans close through
        // `clearCoats`, which — unlike a bare censor — also stamps the window transition.
        _ = clearCoats(st, ev.ts, .death)
        st.stateTimeline.censorAll(ev.ts)

    default:
        break
    }
}

/// The third pet-binding signal, and the only one that costs the player nothing —
/// `You begin casting Burnout.` … `<Name> goes berserk.`
///
/// 40 spells in the DB are `targetType: Pet` and the game will not let one land on anything but your
/// own pet, while `You begin casting <Spell>.` is printed for the player and nobody else. The pair —
/// own cast, then a landing that resolves it — names your pet as surely as a tell does.
///
/// The message is not the gate; the armed own cast is. Silent precondition: the DB must be able to
/// name the spell. If a report says a pet stopped being attributed, check the candidate list first.
func bindPetBuffLanding(_ st: EngineState, _ ev: Event) {
    let target = ev.str(.target) ?? ""
    // The parser emits `target: 'self'` for the msgCastOnYou form; only a named landing can bind.
    if target == "self" || target.isEmpty { return }
    let names = ev.candidateNames(.candidates)
    if !st.charm.petBuffLanding(names, ev.ts) { return }
    // A landing on YOURSELF is a self-buff the DB mislabels, never a pet. The empty-string fallback
    // is load-bearing: with no player key known yet the comparison is against the empty string.
    if Names.idKey(target) == (st.playerKey ?? "") { return }
    bindPetClaim(st, target, ev.ts, "petBuff")
}
