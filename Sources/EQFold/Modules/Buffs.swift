// A log-mined buff/debuff-duration model and a small simulation of which ENTITY each buff is bound
// to. All state is derived from events; this file is the `EqModule` surface over the collaborators
// the model is factored into.
//
// A buff INSTANCE is a pair (spell, target entity), keyed by (spell key, entity key). The same spell
// can run on you AND your pet AND a mob at once — three independent instances, three independent
// timers. There is no "pet" class: a pet is simply the entity currently claimed, and buff-vs-debuff
// is a SPELL property read from the catalog's nature.
//
// An instance opens ONLY on a line that CONFIRMS the landing, keyed to the entity that line NAMES.
// Never a cast, never an inferred or "current" target, never a resist. A cast records a pending cast
// and an anchor; it displays nothing.
//
// This module is the only authoritative source of the RESOLVED wear-off signal. When it resolves a
// wear-off against the live active set it synthesizes `buffExpired { spell, target }` back onto the
// same bus, stamped with the PRIMARY event's seq/ts — which is why those are recorded before
// dispatching and why a derived `buffExpired` is refused at the top of `onEvent`.
//
// An EPOCH is a character rebirth: clear all live state. What is kept is deliberate — the mined
// durations, the everFaded/class maps, the learned emote recognition and the message overlay are
// GAME knowledge, identical across a rebirth.
//
// An OFFLINE GAP is the character having been out of the world, and EQ pauses buff timers while it
// is; it is also what answers an open log hole. It arrives drained immediately after its
// `sessionStart`, and therefore BEFORE the zone line that follows every login.
// (fold/src/modules/buffs.rs)
import Foundation
import EQLog
import EQData
import EQCompanionCore

/// The shared halves — the one cast-anchor history and the one learner, held by both this module
/// and the crowd-control one so the two cannot drift.
public final class BuffsCore {
    public let anchors: CastAnchors
    public let stats: SpellStats

    public init(facts: SpellFacts) {
        anchors = CastAnchors()
        stats = SpellStats(db: facts)
    }
}

public final class BuffsModule: EqModule {
    public let id = "buffs"

    private var seq: Int64 = 0
    private let core: BuffsCore
    /// The pet/charm/target identity slots (the who/what).
    private let pets = PetEntities()
    /// The live (spell, entity) instances + every mutation over them.
    private let inst = BuffInstances()
    /// ts from which the Permanent Illusion AA is owned (self illusions become permanent).
    private var permanentIllusionOwnedTs: Int64?
    /// Emote learning: recognize real landing-emote texts.
    private var emoteTextCount = JSMap<Int64>()
    /// Last-seen clock + the log-hole question.
    private let frame = SessionFrame()
    /// The observed-message overlay: which lines the miner is fed, and what it builds.
    private let mining: OverlayMining
    /// A read-only copy of the catalog for the landing gate, which asks it about NATURE.
    private let facts: SpellFacts
    /// The `buffExpired` events synthesized while folding the current PRIMARY event, in emission
    /// order, waiting for the registry to take them.
    private var derived: [Event] = []
    /// The last primary event's identity, which is what an expiry is stamped with. A FIELD rather
    /// than a parameter because a wall-clock tick synthesizes expiries too and has no event of its
    /// own to name — and the stamp is the log's last instant rather than the host's clock.
    ///
    /// Not cleared by `reset()`, and unobservable.
    private var curSeq: Int64 = 0
    private var curTs: Int64 = 0
    /// The announce cursor. Three things are published (`active`, `stats`, `overlay`); each arm
    /// answers whether it could have moved one of them, and anything nobody can answer without
    /// reopening the buff system answers `true`.
    private var announce = Announce()

    public init(facts: SpellFacts, core: BuffsCore) {
        self.core = core
        self.facts = facts
        mining = OverlayMining(facts: facts, seeds: [(overlayBaselineSource, overlayBaselineCounts())])
    }

    /// The one shared core both buff modules hold.
    public static func sharedCore(_ facts: SpellFacts) -> BuffsCore { BuffsCore(facts: facts) }

    /// Drain the instance store's resolved expiries into the derived queue, stamped with the PRIMARY
    /// event's identity. The `raw` is a synthesized human-readable line.
    private func flushExpiries(_ seq: Int64, _ ts: Int64) {
        let out = inst.expired
        inst.expired.removeAll()
        for e in out {
            let who = e.target == "self" ? "you" : e.target
            derived.append(Event.fromValue([
                "kind": "buffExpired",
                "seq": .int(seq),
                "ts": .int(ts),
                "raw": .string("\(e.spell) wore off \(who)."),
                "spell": .string(e.spell),
                "target": .string(e.target),
            ]))
        }
    }

    private func onCastBegin(_ ev: Event) {
        let spell = ev.str(.spell) ?? ""
        let key = BuffsShapes.spellKey(spell)
        core.anchors.noteSelfCast(spell, ev.ts)
        core.stats.touchLastSeen(key, ev.ts)
        inst.beginCast(key, ev.ts)
    }

    /// A landing emote adjacent to a cast, learned by REPETITION: a text seen twice next to a cast
    /// is trusted to name that cast's subject, which proves a SELF cast even while a pet is live.
    private func onSpellEmote(_ ev: Event) {
        let ts = ev.ts
        guard let p = inst.pending else { return }
        let beganTs = p.beganTs
        let alreadyNamed = p.emoteSubjectKey != nil
        if ts - beganTs > BuffsShapes.emoteWindowMs || ts < beganTs || alreadyNamed { return }
        let text = ev.str(.text) ?? ""
        let n = (emoteTextCount[text] ?? 0) + 1
        emoteTextCount.insert(text, n)
        if n >= BuffsShapes.emoteMinObservations {
            let subject = ev.str(.subject) ?? ""
            let key = subject == "self" ? BuffsShapes.selfKey : Names.idKey(subject)
            // Re-taken because the count write above ended the first borrow.
            inst.pending?.emoteSubjectKey = key
        }
    }

    /// Cast-anchored attribution: a landing emote is a broadcast naming no caster, so without an
    /// anchor a stranger's buff would bind as ours. A refusal means the landing produces nothing.
    private func onBuffApply(_ ev: Event) {
        let cands = candidatesOf(ev)
        let ts = ev.ts
        let store = inst
        guard let landing = BuffLanding.admitLanding(cands, ts, core.anchors, facts, { k in
            store.hasActiveSpell(k)
        }) else { return }
        let spec = LandingSpec(
            target: ev.str(.target) ?? "",
            ts: ts,
            illusion: landing.illusion,
            durationMs: landing.durationMs,
            caster: landing.caster,
            lineKey: landing.lineKey,
            castName: landing.castName,
            candidates: landing.candidates,
            permanentIllusionOwnedTs: permanentIllusionOwnedTs)
        inst.applyMessageBuff(landing.spell, spec, core.stats, pets)
    }

    /// A HoT tick is not a landing. `You healed <X> over time for N by <Spell>.` is printed once per
    /// tick by an already-landed heal-over-time and is cast-detached by construction, so treating it
    /// as a landing would restart the clock every tick. Only the DIRECT heal line opens anything.
    private func onHeal(_ ev: Event) {
        if ev.bool(.overTime) { return }
        guard let spell = ev.str(.spell), !spell.isEmpty else { return }
        if Names.idKey(ev.str(.healer) ?? "") != "you" { return }
        let key = BuffsShapes.spellKey(spell)
        guard let row = facts.get(key) else { return }
        guard let durationMs = row.durationMs else { return }
        let spec = LandingSpec(
            target: "self",
            ts: ev.ts,
            illusion: row.illusion,
            durationMs: durationMs,
            caster: nil,
            lineKey: nil,
            castName: nil,
            candidates: nil,
            permanentIllusionOwnedTs: permanentIllusionOwnedTs)
        inst.applyMessageBuff(row.name, spec, core.stats, pets)
    }

    private func onBuffFade(_ ev: Event) {
        let spell = ev.str(.spell) ?? ""
        let key = BuffsShapes.spellKey(spell)
        core.stats.noteEverFaded(key)
        // The wear-off channel is witnessed only for the TARGET-NAMED sentence. The targetless
        // shapes are a different channel: the parser emits no target at all for a self buff and the
        // literal `pet` for the possessive form, and a mob can never be called `pet`.
        let target = ev.str(.target)
        if let t = target, t != "pet" { core.stats.witnessWearOffChannel(key) }
        // Resolve the fade's target entity: the possessive `pet` form against the CURRENT pet's key,
        // a named mob to that mob's key, targetless to self.
        let (entityKey, _) = pets.fadeTargetEntity(target)
        // A fade is not a landing: retro-landing the pending cast to measure the span is unsound
        // whenever the fade belongs to an EARLIER instance of the same spell.
        inst.clearPendingCast(key)
        inst.recordFade(key, entityKey, spell, ev.ts, core.stats, pets)
        // `buffFade` already carries a resolved spell and target, so the derived event is
        // synthesized outright: one alert kind covers every shape of wear-off.
        let display = pets.buffFadeTargetDisplay(target, entityKey)
        inst.expired.append(Expiry(spell: spell, target: display))
    }

    /// Disposition, not identity: re-charming the same name after a charm break — with no
    /// intervening death or zone of that name — is the SAME entity. Its buffs are still active on
    /// it and it must not trigger single-pet succession against itself.
    private func onCharm(_ ev: Event) {
        let mob = ev.str(.mob) ?? ""
        let newKey = Names.idKey(mob)
        let sameAsBroken = pets.brokenCharmKey == newKey
        let sameAsCharmed = pets.charmedKey == newKey
        if !sameAsBroken && !sameAsCharmed {
            // Single-pet invariant: charming a DIFFERENT entity retires the prior pet(s), including
            // a broken-charm entity never re-charmed — that one really is left behind.
            for slot in [pets.charmedKey, pets.brokenCharmKey, pets.summonedKey].compactMap({ $0 }) {
                inst.retireEntity(slot, pets)
            }
            pets.petTargetKey = nil
            pets.petTargetDisplay = nil
        }
        // Re-bind the charmed entity. If this reconnects a broken charm, its buff instances were
        // never censored and remain active on it.
        pets.charmedKey = newKey
        pets.charmedDisplay = mob
        pets.brokenCharmKey = nil
        pets.brokenCharmDisplay = nil
    }

    private func onPetClaim(_ ev: Event) {
        let name = ev.str(.name) ?? ""
        let key = Names.idKey(name)
        let known = [pets.charmedKey, pets.summonedKey, pets.brokenCharmKey].contains(key)
        if known { return }
        // Single-pet succession: claiming a DIFFERENT pet retires the prior pet(s), including a
        // broken-charm entity never re-charmed.
        for slot in [pets.summonedKey, pets.charmedKey, pets.brokenCharmKey].compactMap({ $0 }) {
            inst.retireEntity(slot, pets)
        }
        pets.summonedKey = key
        pets.summonedDisplay = name
    }

    /// A charm break is a disposition change, not a retirement. The mob keeps its identity and every
    /// buff instance; it is simply hostile-capable until you re-charm it. The broken-charm slot is
    /// what lets a re-charm of the SAME name reconnect with buffs intact.
    private func onUncharm(_ ev: Event) {
        let mob = Names.idKey(ev.str(.mob) ?? "")
        if pets.charmedKey == mob {
            pets.brokenCharmKey = pets.charmedKey
            pets.brokenCharmDisplay = pets.charmedDisplay
            pets.charmedKey = nil
            pets.charmedDisplay = nil
        }
    }

    /// A death is two questions with different answers.
    ///
    /// "Did something of that name just die?" — the debuff censor runs unconditionally, on the dead
    /// name and never on the killer. The killer is a name too, and it can be the same name.
    ///
    /// "Is the ENTITY behind that name retired?" — about identity, and the only place the pet
    /// bindings get a vote.
    private func onDeath(_ ev: Event) {
        let name = ev.str(.name) ?? ""
        let key = Names.idKey(name)
        inst.onEntityDeath(key, ev.ts, core.stats, pets)
        if deathRetiresEntity(ev, key) { inst.retireEntity(key, pets) }
        if pets.petTargetKey == key {
            pets.petTargetKey = nil
            pets.petTargetDisplay = nil
        }
    }

    /// Whether this death retires the ENTITY — its identity and every buff on it — not just its
    /// debuffs. A death line naming the LIVE charmed pet is ambiguous between the pet and a twin of
    /// its name, so it never retires.
    private func deathRetiresEntity(_ ev: Event, _ key: String) -> Bool {
        let killerIsYou = ev.bool(.bySelf) || Names.idKey(ev.str(.killer) ?? "") == "you"
        if pets.summonedKey == key { return !killerIsYou }
        if pets.charmedKey == key { return false }
        // A death naming the broken-charm entity genuinely retires it, so the next charm of that
        // name binds a fresh entity.
        return pets.brokenCharmKey == key
    }

    /// Every live instance, oldest first — the same seam `buildState` reads, so the bars and the
    /// Buffs tab can never disagree about what is running. The order is `startedTs` because that is
    /// what `buildState` publishes, and the projection's stable sort runs on top of it.
    public func activeBuffs() -> [JSONValue] { activeBuffRows().map(\.json) }

    /// The typed rows behind `activeBuffs()`.
    public func activeBuffRows() -> [ActiveBuff] { activeInstances().map(\.1) }

    /// The same, with the instance key each was filed under. The key is the model's own identity,
    /// handed out rather than rebuilt: a view needs a stable row key across serve passes.
    public func activeInstances() -> [(String, ActiveBuff)] {
        inst.active.pairs.enumerated()
            .sorted { a, b in
                a.element.1.startedTs != b.element.1.startedTs
                    ? a.element.1.startedTs < b.element.1.startedTs
                    : a.offset < b.offset
            }
            .map(\.element)
    }

    /// The view layer's change signal, and NOT the announce cursor. Deliberately coarse: this module
    /// has no revision counter, so it reports the fold's own `seq`, which moves on every event.
    public func revision() -> Int64 { seq }

    /// A new log is about to be folded from its first byte.
    ///
    /// Mining is GAME knowledge and survives `reset()` on purpose, but the counts THIS log accounts
    /// for are about to be re-stated in full, so its bucket is discarded rather than added to.
    public func beginOverlaySource(_ key: String) { mining.beginSource(key) }

    /// Seed one persisted bucket. See `OverlayMining.seed` for why it is not part of construction.
    public func seedOverlay(source: String, counts: [SeedMessage]) {
        mining.seed(source, OverlayFile.seedMessages(counts))
    }

    /// The persistence view of the mined overlay — raw counts per source, no verdicts.
    public func overlayRegister() -> OverlayRegister { mining.register() }

    /// The persisted-file shape of the register — what the engine writes to disk.
    public func overlayRegisterFile() -> OverlayRegisterFile { OverlayFile.registerFileOf(mining.register()) }

    private func buildState() -> JSONValue {
        [
            "active": .array(activeBuffs()),
            "stats": core.stats.buildStats(),
            "overlay": mining.build(),
        ]
    }

    // MARK: - EqModule

    public func reset() {
        seq = 0
        announce.reset()
        inst.reset()
        core.stats.reset()
        core.anchors.reset()
        emoteTextCount.clear()
        frame.reset()
        permanentIllusionOwnedTs = nil
        pets.reset()
        // Not reset: the message-overlay mining. It is game knowledge, and `beginOverlaySource` —
        // not `reset` — is what discards a source's bucket.
    }

    /// `live` is unused here, and stating that is the point: the drain re-uses the PRIMARY event's
    /// own flag for everything it delivers.
    public func onEvent(_ ev: Event, live: Bool) {
        seq = ev.seq
        // A derived `buffExpired` is our own synthesized event — never fold it. It exists purely for
        // the alerts module to match.
        if ev.kind == "buffExpired" { return }
        if ev.kind == "epoch" {
            frame.closeHole()
            inst.clearForGap()
            pets.clearForGap()
            announce.changed(seq)
            return
        }
        if ev.kind == "offlineGap" {
            let fromTs = ev.int(.fromTs) ?? 0
            let toTs = ev.int(.toTs) ?? 0
            frame.closeHole()
            inst.onOfflinePause(fromTs, toTs - fromTs, core.stats, pets)
            // A logout despawns your pet, so the bindings go even though the buffs on YOU stay. The
            // last-event ts is NOT advanced: the gap restates an instant already recorded.
            pets.clearForGap()
            announce.changed(seq)
            return
        }
        let seqNow = ev.seq
        let ts = ev.ts
        // Record the primary event's identity so any `buffExpired` synthesized while folding it —
        // or on a later wall-clock tick, which has no event of its own — is stamped with it.
        curSeq = seqNow
        curTs = ts
        // The per-event prelude. All four of these run for EVERY line, so each has to answer for
        // itself whether it published anything. First: a log hole no login ever explained means we
        // lost the thread rather than the character having left.
        var published = false
        if let unexplainedBefore = frame.observe(ev) {
            inst.dropPredating(unexplainedBefore)
            pets.clearForGap()
            published = true
        }
        // Not counted: `pending` is a cast in flight and is not in `buildState`.
        inst.dropUnconfirmedPending(ts)
        if inst.sweepHygiene(ts, frame.heldBeforeTs, core.stats, pets) { published = true }

        // Overlay mining: feed the anchor cast and any candidate message line so the miner accretes
        // (message, spell) associations across replay AND live. The overlay is published, so a line
        // that reaches the miner counts.
        if mining.observe(ev) { published = true }

        // Every arm answers one question: can this move `active`, `stats` or `overlay`? The arms
        // answering `false` move the anchors, the pending cast, the pet bindings or the AA ownership
        // stamp — real state, none of it in the snapshot.
        let armPublished: Bool
        switch ev.kindOf {
        case .castBegin:
            onCastBegin(ev)
            armPublished = true
        case .spellEmote:
            onSpellEmote(ev)
            armPublished = true
        // An anchor ONLY for a caster on the externals allowlist (default: nobody). The anchors
        // enforce that; the event is folded either way so the refusal lives in one place.
        case .otherCastBegin:
            core.anchors.noteOtherCast(ev.str(.caster) ?? "", ev.str(.spell) ?? "", ts)
            // An anchor is what a LATER landing is attributed by. It is not published.
            armPublished = false
        case .castFizzle, .castInterrupted:
            let spell = ev.str(.spell) ?? ""
            inst.clearPendingCast(BuffsShapes.spellKey(spell))
            core.anchors.clearCast(spell)
            // A cast that never landed opened nothing to retract.
            armPublished = false
        // `You activate Quick Buff.` is a SELF anchor naming a window rather than a spell: it
        // applies many spells at once with no cast line of their own.
        case .aaActivate:
            if Names.idKey(ev.str(.name) ?? "") == BuffsShapes.quickBuff { core.anchors.noteQuickBuff(ts) }
            // A window an anchor is read through — not published.
            armPublished = false
        case .aaSpend:
            if permanentIllusionOwnedTs == nil,
               Names.idKey(ev.str(.ability) ?? "") == BuffsShapes.permanentIllusion {
                permanentIllusionOwnedTs = ts
            }
            // The stamp decides how a LATER illusion is classified; no snapshot carries it.
            armPublished = false
        case .buffApply:
            onBuffApply(ev)
            armPublished = true
        // The wear-off emote prints to the buff HOLDER, so it clears the SELF instance. Many spells
        // share one wear-off message, so it is resolved against the ACTIVE self set.
        case .buffWearOff:
            inst.removeSharedWearOff(wearOffCandidates(ev), BuffsShapes.selfKey, ts, core.stats, pets)
            armPublished = true
        // `Your illusion fades.` — only one illusion is ever active on self, so this removes
        // whichever illusion self buff is active. The line is 27-way ambiguous by design.
        case .illusionFade:
            inst.clearSelfIllusion(core.stats)
            armPublished = true
        case .heal:
            onHeal(ev)
            armPublished = true
        case .buffFade:
            onBuffFade(ev)
            armPublished = true
        case .playerDeath:
            inst.onPlayerDeath(core.stats, pets)
            armPublished = true
        // These three are `true` by the unsure rule rather than by audit: a charm or a claim rebinds
        // an entity and instances are held against entities.
        case .charm:
            onCharm(ev)
            armPublished = true
        case .petClaim:
            onPetClaim(ev)
            armPublished = true
        case .uncharm:
            onUncharm(ev)
            armPublished = true
        case .cc:
            let mob = ev.str(.mob) ?? ""
            pets.petTargetKey = Names.idKey(mob)
            pets.petTargetDisplay = mob
            // Which mob your pet is on. It names the target a later landing binds to and is
            // published nowhere.
            armPublished = false
        case .death:
            onDeath(ev)
            armPublished = true
        case .zone:
            inst.onZone(core.stats, pets)
            armPublished = true
        default:
            armPublished = false
        }
        if armPublished { published = true }
        if published { announce.changed(seq) }
        flushExpiries(seqNow, ts)
    }

    /// The wall-clock heartbeat: the same two calls `onEvent` makes, with the wall clock where the
    /// log's clock goes. A cast nothing confirmed inside the landing window is dropped, and the
    /// hygiene sweep retires every active past its per-spell cap.
    ///
    /// It deliberately does NOT rule on an open log hole: a hole is a question about the LOG, and
    /// only the log's own next line can answer it. The tick only AGES the model, and the sweep still
    /// honours whatever `heldBeforeTs` an open absence is protecting.
    public func onTick(nowMs: Int64, timerRows: [BuffTimerRow]) {
        inst.dropUnconfirmedPending(nowMs)
        let retired = inst.sweepHygiene(nowMs, frame.heldBeforeTs, core.stats, pets)
        // A buff retired by the wall clock has no event behind it. `Announce.changed` lands strictly
        // above the fold position, and a beat that retired nothing stays silent.
        if retired { announce.changed(seq) }
        flushExpiries(curSeq, curTs)
    }

    /// The dirty bit: a landing, a wear-off, a retirement, a mined message, or a rebirth.
    public var publishedSeq: Int64? { announce.cursor }

    public func snapshot() -> JSONValue { ["seq": .int(seq), "state": buildState()] }

    public func takeDerived() -> [Event] {
        let out = derived
        derived.removeAll()
        return out
    }

    public var asDefines: Defines? { self }

    /// The view pull seam.
    public var asBuffs: BuffsModule? { self }
}

extension BuffsModule: Defines {
    public var family: String { "buffTrust" }

    /// The externals allowlist, replaced whole. It lands on the shared core and therefore on both
    /// modules at once, so the buff bar and the crowd-control bar cannot end up with two ideas of
    /// whose spell just landed.
    public func define(_ payload: JSONValue) {
        guard let list = payload["externals"].array else { return }
        core.anchors.setTrust(list.compactMap(\.string))
    }
}

/// The `buffApply` candidate shape.
private func candidatesOf(_ ev: Event) -> [Candidate] {
    ev.candidates(.candidates).map { Candidate(name: $0.name, durationMs: $0.durationMs, illusion: $0.illusion) }
}

/// The `buffWearOff` candidate shape — plain names.
private func wearOffCandidates(_ ev: Event) -> [String] { ev.arrStr(.candidates) }
