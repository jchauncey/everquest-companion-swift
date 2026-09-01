// Log lines in, pooled resist observations out (fold/src/modules/resist/mod.rs).
//
// The published state is two integers, and this module is a pull rather than a push: the ledger is
// ~700 kB and its only consumer wants one mob at a time, so nothing is flushed, the mob page asks a
// separate IPC, and `snapshot()` carries counts for diagnostics. Those counts are an unforgiving
// surface — every term of `ResistLedger.rowKey` is load-bearing, so one wrong mob level or ISO week
// splits or merges a row and the count moves.
//
// It does not reset at an epoch boundary. What a mob resists is game knowledge, not character-scoped
// state, and a rebirth does not unlearn it; the per-character bucket still means a re-fold replaces
// that character's contribution and nothing else.
//
// No wall clock reaches a historical fold, so `settle` is never called during one and the end-of-fold
// state deliberately holds a deferred landing that arrived within `LAND_DEFER_MS` of the last event,
// and a song's last open pulse with its interpolation unemitted. A port that "helpfully" settled at
// the end would move every recorded number in the same direction.
//
// How each outcome is earned:
//
//   Resist   the game saying it flatly. Incoming resists are yours and out of scope entirely.
//   Damage   the number goes into the row's histogram, from which the estimator derives
//            full-versus-partial. A critical counts as a landing and stays out of the histogram.
//   Land     the first tick of a DoT after its cast, and a cast-on-other emote joined back to your
//            own `You begin casting` — never both for one spell on one mob, because a spell that
//            emotes and damages produced one roll. The emote's landing is therefore deferred and
//            cancelled by any damage line that follows it for the same mob and spell.
//   Song     decided by spell identity, never by a begin line. A song is never filed as a cast.
//
// It never reads the client's `spells_us.txt`: everything it writes is something the log printed.
//
// Other people's casts are recorded and never estimated from. A `pc` row carries no level; an `npc`'s
// level comes off the same catalog-or-`/con` ladder the target's level climbs. An npc deliberately
// gets no armed cast.
//
// A row's target has to be a creature. `TargetVerdicts.isMobTarget` gates every filing — resist,
// damage, emote and song — because R is a statement about a creature.
import Foundation
import EQLog
import EQCompanionCore

/// How long a deferred emote-landing waits to see whether a damage line cancels it.
public let LAND_DEFER_MS: Int64 = 3_000

/// The separator inside every composite key this module builds. A printable byte on purpose: a raw
/// control byte makes git classify the file as binary. No EQ mob or spell name contains a pipe.
private let SEP = "|"

// MARK: - Checkpoint shadows
//
// Every sub-object this fold drives (`MobLevels`, `CasterIndex`, `DebuffWindows`, `MeleeContact`,
// `SongFold`, `CastState`, `ArmedCasts`, `MobNames`) keeps its state PRIVATE in a file this module
// does not own, so the checkpoint codec cannot read it back. Instead the fold mirrors, beside each
// call it makes, exactly what that call changed — the shadows below — and a restore replays the
// shadows through the same public API. The oracle's re-fold is what proves shadow and object agree.
//
// Two constants are mirrored because they are private where they live. If either drifts from its
// original, the checkpoint oracle's resumed folds diverge — that is the alarm.

/// `ResistCastState.maxArmed`, mirrored.
private let ARMED_CAP_MIRROR = 16
/// `ResistSongs.heartbeatMemory`, mirrored.
private let HEARTBEAT_MEMORY_MIRROR = 32

/// One `SongPulses.Run`, shadowed: the last witnessed pulse and the begin-singing re-anchor.
private struct RunShadow {
    var lastWitness: Int64?
    var reanchor: Int64?
}

/// One `SongPulses.Open`, shadowed: the buffered pulse still able to gain witnesses.
private struct OpenShadow {
    var ts: Int64
    var resisted: [String]
}

/// One `noteNamed` call, compacted to the LAST occurrence per (mob, song) pair. Replaying the pairs
/// in last-occurrence order reproduces both recency lists exactly: a list's final order depends only
/// on the last time each member was named, which is the order this map keeps.
private struct NamedOp {
    var mob: String
    var spell: String
}

/// One kept aura heartbeat, with a candidate name that proved it was a song — stored so the restore
/// can replay it through `onSelfLanding` even when the `sung` set alone would not recognise it.
private struct BeatShadow {
    var ts: Int64
    var cand: String
}

/// Is this name the player? The parser's `norm` produces exactly `You` for every spelling the log
/// uses, so the identity compare answers almost every call and `idKey` is the fallback for shapes that
/// reach here unnormalised. Ordered that way because this runs on every melee swing.
private func isSelfName(_ name: String) -> Bool { name == "You" || Names.idKey(name) == "you" }

/// One thing the log said, as this fold names it before the bucket pools it.
private struct Observation {
    /// The mob's name as the line spelled it; the key is folded from it.
    var mob: String
    var spellKey: String
    var family: ResistFamily
    var kind: ResistCasterKind
    /// The caster's level, or nil when nothing has stated it.
    var level: Int64?
    var ts: Int64
    /// The spell upgrade rank this observation was made at: -15 of resist adjust each.
    var rank: Int64
    /// Whether the overchannel invocation was up. Three states.
    var overchannel: Bool?
}

/// A landing waiting to see whether a damage line cancels it: an `Observation` held for
/// `LAND_DEFER_MS` before it is filed. The fields must stay identical to `Observation`'s, because a
/// deferred filing carrying a different set of facts from an immediate one is a bug with nowhere to be
/// caught. The family is always `cast`: a song pulse is never deferred, its sentence is the landing.
private struct Deferred {
    var mob: String
    var spellKey: String
    var ts: Int64
    var kind: ResistCasterKind
    var level: Int64?
    var rank: Int64
    var overchannel: Bool?
}

public final class ResistFold {
    private let levels = MobLevels()
    private let casters = CasterIndex()
    private let debuffs = DebuffWindows()
    private let contact = MeleeContact()
    private let songs = SongFold()
    private var zone: String?
    private var selfLevel: Int64?
    /// The rank and invocation a self cast is filed under, and the rules for both.
    private let cast = CastState()
    private let casts = ArmedCasts()
    private var dotSeen = Set<String>()
    private var deferred: Deferred?
    /// Mob names both ways, memoised.
    private let names = MobNames()
    /// Per-fold rather than module-scoped, so no verdict cache outlives a `Fold`.
    private let targets = TargetVerdicts()

    // Checkpoint shadows — see the header above `RunShadow`. Each mirrors the private state of one
    // sub-object, maintained beside every call that changes it and replayed through the public API
    // on restore. `targets` and the memo halves of `MobLevels`/`MobNames`/`CasterIndex` are pure
    // functions of committed data plus the shadowed facts, so they are deliberately NOT shadowed:
    // an empty cache recomputes the same verdicts.
    /// `MobLevels.conned`, move-to-end so replay order is last-note order (alias groups overlap).
    private var connedShadow = JSMap<Int64>()
    /// `CasterIndex.pets` — idKey to a raw spelling that produces it.
    private var petShadow = JSMap<String>()
    /// `CasterIndex.struck`.
    private var struckShadow = JSMap<String>()
    /// `MobNames.display` — knowledge, not a memo; it survives `beginSource` exactly as the map does.
    private var displayShadow = JSMap<String>()
    /// `DebuffWindows.byMob` — mob key to (spell key → until), swept beside `active`.
    private var debuffShadow = JSMap<JSMap<Int64>>()
    /// `MeleeContact.last`.
    private var contactShadow = JSMap<Int64>()
    /// `CastState.overchannelOn`, as the last invocation line the fold forwarded.
    private var invocationShadow: String?
    /// `CastState.classes`, as the last `/who` class list the fold forwarded.
    private var classesShadow: [String]?
    /// `CastState.songRanks`.
    private var songRankShadow = JSMap<Int64>()
    /// `ArmedCasts.casts`, element for element.
    private var armedShadow: [Armed] = []
    /// `SongFold.sung`.
    private var sungShadow = Set<String>()
    /// `SongFold.named` + `namedByMob`, as the compacted op list that rebuilds both — see `NamedOp`.
    private var namedOps = JSMap<NamedOp>()
    /// The two recency lists themselves, kept live because `resolveSongEmote` must be re-run against
    /// them when mirroring `onEmote`. Rebuilt from `namedOps` on restore, never encoded.
    private var namedShadow: [String] = []
    private var namedByMobShadow: [String: [String]] = [:]
    /// `SongPulses.beats`.
    private var beatShadow: [BeatShadow] = []
    /// `SongPulses.runs`, driven off the emission stream: a witnessed pulse IS a `closeOpen`.
    private var runsShadow = JSMap<RunShadow>()
    /// `SongPulses.open`.
    private var openShadow = JSMap<OpenShadow>()

    public init() {}

    /// One creature's level, for a reader. The read-only form, so the ingest's one door can carry it;
    /// `MobLevels.levelOfRef` states why it answers the same as the fold's own.
    public func levelOfRef(_ mobKey: String, _ display: String) -> MobLevelFact? {
        levels.levelOfRef(mobKey, display)
    }

    /// Start folding a source: the session reset. The bucket discard that makes a re-fold idempotent
    /// belongs to whoever owns the ledger.
    ///
    /// The invocation is not session state and is reset here anyway: a relog carries it across a camp,
    /// but a new source is a different log being folded from its own beginning.
    public func beginSource() {
        levels.reset()
        casters.reset()
        debuffs.reset()
        contact.reset()
        songs.reset()
        zone = nil
        selfLevel = nil
        cast.reset()
        casts.reset()
        dotSeen.removeAll()
        deferred = nil
        names.reset()
        // The shadows follow their objects exactly. `displayShadow` is kept because
        // `MobNames.reset` keeps the display map (knowledge, not a memo).
        connedShadow.clear()
        petShadow.clear()
        struckShadow.clear()
        debuffShadow.clear()
        contactShadow.clear()
        invocationShadow = nil
        classesShadow = nil
        songRankShadow.clear()
        armedShadow.removeAll()
        sungShadow.removeAll()
        namedOps.clear()
        namedShadow.removeAll()
        namedByMobShadow.removeAll()
        beatShadow.removeAll()
        runsShadow.clear()
        openShadow.clear()
    }

    /// The live tail's heartbeat: settle, never finish. A landing that has waited out its cancel window
    /// is decided and a song pulse that can gain no more witnesses is closed, but a bard mid-rotation
    /// still has an open run, and ending it here would forfeit the interpolation the next gap is
    /// entitled to. Hence `songs.settle` rather than `songs.flush`, which a zone line does call.
    ///
    /// It is not the persist: the engine's ledger is in memory.
    public func settle(_ now: Int64, _ bucket: ResistBucket) {
        flushDeferred(now, bucket)
        var out: [SongOut] = []
        songs.settle(now, &out)
        applySongOut(out, bucket)
    }

    public func onEvent(_ ev: Event, _ bucket: ResistBucket) {
        flushDeferred(ev.ts, bucket)
        // Two cascades: lines that move the world (where you are, what level you are, which mob is
        // which, which casts are in flight) and lines that are an outcome.
        if onWorldEvent(ev, bucket) { return }
        onOutcomeEvent(ev, bucket)
    }

    /// State the outcomes are interpreted against. True when the event was one of these.
    private func onWorldEvent(_ ev: Event, _ bucket: ResistBucket) -> Bool {
        switch ev.kindOf {
        case .zone:
            onZone(ev.str(.zone) ?? "", bucket)
            return true
        case .level:
            selfLevel = ev.int(.level)
            return true
        case .selfWho:
            if selfLevel == nil { selfLevel = ev.int(.level) }
            // The one line in the game that states the loadout, and therefore the only thing that can
            // answer "how many non-hybrid caster classes" for the overchannel adjust.
            let classes = ev.arrStr(.classes)
            cast.noteClasses(classes)
            classesShadow = classes
            return true
        case .invocationChange:
            let invocation = ev.str(.invocation) ?? ""
            cast.noteInvocation(invocation)
            invocationShadow = invocation
            return true
        case .consider:
            let mob = ev.str(.mob) ?? ""
            rememberName(mob)
            if let level = ev.int(.level) {
                levels.note(names.key(mob), level)
                mirrorConned(names.key(mob), level)
            }
            return true
        case .death:
            let key = names.key(ev.str(.name) ?? "")
            debuffs.clearMob(key)
            debuffShadow.remove(key)
            // A dead mob stops being a song target immediately (rule 3: alive and in contact). The song
            // itself keeps running, so nothing here touches the reconstruction.
            contact.dropMob(key)
            contactShadow.remove(key)
            return true
        case .petClaim, .petSay:
            mirrorPet(ev.str(.name) ?? "")
            return true
        case .allyPetLeader:
            mirrorPet(ev.str(.pet) ?? "")
            return true
        default:
            return onCastLifecycle(ev, bucket)
        }
    }

    /// The cast lifecycle: what is in flight, and what stopped being in flight. A fizzle or an
    /// interrupt disarms rather than filing anything — a cast that never happened is not a resist.
    private func onCastLifecycle(_ ev: Event, _ bucket: ResistBucket) -> Bool {
        switch ev.kindOf {
        case .castBegin:
            onCastBegin(ev.str(.spell) ?? "", ev.ts, ev.bool(.sung), bucket)
            return true
        case .otherCastBegin:
            onOtherCast(ev.str(.caster) ?? "", ev.str(.spell) ?? "", ev.ts)
            return true
        case .castFizzle, .castInterrupted:
            let key = Names.spellCanonKey(ev.str(.spell) ?? "")
            casts.disarm(key)
            armedShadow.removeAll { $0.spellKey == key }
            return true
        default:
            return false
        }
    }

    /// The lines that state what happened to a spell.
    private func onOutcomeEvent(_ ev: Event, _ bucket: ResistBucket) {
        switch ev.kindOf {
        case .resist:
            onResist(ev, bucket)
        case .damage:
            onDamage(ev, bucket)
        case .miss:
            onMelee(ev.str(.attacker) ?? "", ev.str(.target) ?? "", ev.ts)
        case .buffApply:
            let cands = ev.candidateNames(.candidates)
            if ev.str(.target) == "self" {
                songs.onSelfLanding(ev.ts, cands)
                mirrorSelfLanding(ev.ts, cands)
            } else {
                onEmote(ev.str(.target) ?? "", ev.ts, cands, bucket)
            }
        case .cc, .charm:
            let mob = ev.str(.mob) ?? ""
            let cands: [String]? = ev.has(.candidates) ? ev.candidateNames(.candidates) : nil
            onEmote(mob, ev.ts, cands, bucket)
        default:
            break
        }
    }

    private func onZone(_ zone: String, _ bucket: ResistBucket) {
        flushDeferred(Int64.max, bucket)
        // A zone change is a real discontinuity, so rule 2 extrapolates past nothing. Flushed before
        // the contact map is dropped, because a pulse filed here still asks who was in melee range when
        // it fired.
        var out: [SongOut] = []
        songs.flush(&out)
        applySongOut(out, bucket)
        self.zone = zone
        debuffs.reset()
        contact.reset()
        casts.reset()
        // The flush's closes were mirrored off its emissions above; what remains is the run map the
        // flush drops, and the shadows of the three resets.
        runsShadow.clear()
        openShadow.clear()
        debuffShadow.clear()
        contactShadow.clear()
        armedShadow.removeAll()
    }

    /// Melee proximity, which exists for one reader: song rule 3, which needs to know who was in range
    /// when a pulse fired. Not tracked until a song has been seen, because this is the busiest arm in
    /// the fold — two swings a second for hours. The cost is the contact from the six seconds before a
    /// session's first song evidence, which can only under-count a song's attempts: the direction rule
    /// 3 already errs in.
    private func onMelee(_ attacker: String, _ target: String, _ ts: Int64) {
        if !songs.active() { return }
        if isSelfName(attacker) {
            noteContact(target, ts)
            return
        }
        if isSelfName(target) { noteContact(attacker, ts) }
    }

    private func noteContact(_ mob: String, _ ts: Int64) {
        contact.note(names.key(mob), ts)
        contactShadow.insert(names.key(mob), ts)
        rememberName(mob)
    }

    private func onCastBegin(_ spell: String, _ ts: Int64, _ sung: Bool, _ bucket: ResistBucket) {
        let key = Names.spellCanonKey(spell)
        let rank = Names.spellRank(spell)
        if sung {
            var out: [SongOut] = []
            songs.noteSung(key, ts, &out)
            applySongOut(out, bucket)
            // Mirror `noteSung`: any close it caused was mirrored off the emissions just applied;
            // what remains is the sung set and the re-anchor.
            sungShadow.insert(key)
            var run = runsShadow[key] ?? RunShadow()
            run.reanchor = ts
            runsShadow.insert(key, run)
        }
        cast.noteSongRank(key, rank)
        if rank > 0 { songRankShadow.insert(key, rank) }
        // A fresh cast re-arms the "first tick counts as a landing" memory for this spell.
        let tail = SEP + key
        dotSeen = dotSeen.filter { !$0.hasSuffix(tail) }
        mirrorArm(Armed(spellKey: key, display: spell, ts: ts, kind: .selfCast, level: selfLevel,
                        rank: rank, overchannel: cast.overchannel(), damaged: []))
    }

    private func onOtherCast(_ caster: String, _ spell: String, _ ts: Int64) {
        if casters.kindOf(caster) != .pc { return }
        mirrorArm(Armed(spellKey: Names.spellCanonKey(spell), display: spell, ts: ts, kind: .pc,
                        level: nil, rank: Names.spellRank(spell),
                        // Nothing states a stranger's invocation, ever. Unknowable, and never assumed.
                        overchannel: nil, damaged: []))
    }

    private func onEmote(_ mobDisplay: String, _ ts: Int64, _ candidates: [String]?,
                         _ bucket: ResistBucket) {
        // A song pulse needs no armed cast: under the Symphonic Aura there is no cast line to arm, and
        // the sentence itself is the landing.
        let mob = names.key(mobDisplay)
        var out: [SongOut] = []
        let handled = songs.onEmote(mobDisplay, mob, ts, candidates, selfLevel, &out)
        applySongOut(out, bucket)
        // Mirror the emote's song half: re-run the same resolution against the shadow lists; a
        // resolved song with no landing sentence in the catalog was a `witness`.
        if let cands = candidates, !cands.isEmpty,
           let songKey = resolveSongEmote(cands, mirrorNamedFor(mob), selfLevel),
           !songLandingObservable(songKey) {
            mirrorWitness(songKey, ts, nil)
        }
        if handled { return }
        guard let armed = casts.take(ts, candidates) else { return }
        mirrorTake(ts, candidates)
        // A buff landed on a groupmate prints the same sentence shape as a debuff on a mob, and filed
        // as a row it becomes a person's name in the ledger.
        if !targets.isMobTarget(mobDisplay) { return }
        rememberName(mobDisplay)
        let key = names.key(mobDisplay)
        if ResistCatalog.isResistDebuff(armed.display) {
            debuffs.open(key, armed.spellKey, ts)
            mirrorDebuffOpen(key, armed.spellKey, ts)
        }
        // One cast is one roll. If this cast already printed damage on this mob, the damage line is the
        // observation and the emote is the same roll saying so twice.
        if armed.damaged.contains(key) { return }
        // Deferred: a damage line for the same mob and spell cancels it.
        flushDeferred(Int64.max, bucket)
        deferred = Deferred(mob: mobDisplay, spellKey: armed.spellKey, ts: ts, kind: armed.kind,
                            level: armed.level, rank: armed.rank,
                            overchannel: cast.invocationFor(armed.kind, .some(armed.overchannel)))
    }

    private func flushDeferred(_ now: Int64, _ bucket: ResistBucket) {
        guard let d = deferred else { return }
        if now &- d.ts <= LAND_DEFER_MS { return }
        deferred = nil
        // Only your own emote-landings are attributable. A stranger's sentence names no caster, and an
        // npc's cast is never armed in the first place.
        if d.kind != .selfCast { return }
        rowFor(bucket, Observation(mob: d.mob, spellKey: d.spellKey, family: .cast, kind: d.kind,
                                   level: d.level, ts: d.ts, rank: d.rank,
                                   overchannel: d.overchannel)).land += 1
    }

    private func cancelDeferred(_ mobDisplay: String, _ spellKey: String) {
        guard let d = deferred, d.spellKey == spellKey else { return }
        if names.key(d.mob) == names.key(mobDisplay) { deferred = nil }
    }

    private func onResist(_ ev: Event, _ bucket: ResistBucket) {
        // `You resist <mob>'s <Spell>!` is your own resist and a different feature entirely.
        if ev.bool(.incoming) { return }
        let target = ev.str(.target) ?? ""
        if !targets.isMobTarget(target) { return }
        let caster = ev.str(.caster) ?? ""
        let kind = casters.kindOf(caster)
        let spell = ev.str(.spell) ?? ""
        let spellKey = Names.spellCanonKey(spell)
        // The resist line is the one outcome line that often prints the rank, so it beats the armed
        // cast rather than falling back to it.
        let lineRank = Names.spellRank(spell)
        if kind == .selfCast {
            cast.noteSongRank(spellKey, lineRank)
            if lineRank > 0 { songRankShadow.insert(spellKey, lineRank) }
        }
        rememberName(target)
        let mob = names.key(target)
        let ts = ev.ts
        var out: [SongOut] = []
        let handled = songs.onResist(target, mob, spellKey, kind == .selfCast, ts, &out)
        applySongOut(out, bucket)
        if handled {
            // Mirror the resist's song half: a self resist of a song names it (the recency lists)
            // and, when the catalog knows no landing sentence, was a `witness` carrying the mob.
            if kind == .selfCast {
                mirrorNoteNamed(mob, spellKey)
                if !songLandingObservable(spellKey) { mirrorWitness(spellKey, ts, mob) }
            }
            return
        }
        let level = casterLevel(kind, caster)
        let armed = casts.ownedBy(kind, spellKey, ts)
        let overchannel = cast.invocationFor(kind, armed.map { $0.overchannel })
        rowFor(bucket, Observation(mob: target, spellKey: spellKey, family: .cast, kind: kind,
                                   level: level, ts: ts,
                                   rank: lineRank > 0 ? lineRank : (armed?.rank ?? 0),
                                   overchannel: overchannel)).resist += 1
    }

    /// The caster's level, by kind. Self is the session level; another player's is never stated
    /// anywhere this app reads; an NPC's is the same catalog-or-`/con` ladder the target's level
    /// climbs. nil is a first-class answer and simply drops the row from the fit.
    private func casterLevel(_ kind: ResistCasterKind, _ caster: String) -> Int64? {
        switch kind {
        case .selfCast: return selfLevel
        case .pc: return nil
        case .npc: return levels.levelOf(names.key(caster), caster)?.level
        }
    }

    private func onDamage(_ ev: Event, _ bucket: ResistBucket) {
        let attacker = ev.str(.attacker) ?? ""
        if attacker.isEmpty { return }
        let dtype = ev.str(.dtype) ?? ""
        let target = ev.str(.target) ?? ""
        // A swing either way is melee contact, which is the only proxy for point-blank range a song
        // pulse gets (rule 3). A damage shield firing means the mob hit you, so it counts too.
        if dtype == "melee" || dtype == "ds" {
            onMelee(attacker, target, ev.ts)
            // The behavioural guard runs whatever the songs are doing: a name you have landed damage on
            // is a mob, and that is what keeps a proper-named guard out of the player roster.
            if isSelfName(attacker) { mirrorStruck(target) }
            return
        }
        if dtype != "spell" && dtype != "dot" { return }
        onSpellDamage(ev, attacker, target, dtype, casters.kindOf(attacker), bucket)
    }

    /// A spell or DoT line from somebody this fold is willing to learn from.
    private func onSpellDamage(_ ev: Event, _ attacker: String, _ target: String, _ dtype: String,
                               _ kind: ResistCasterKind, _ bucket: ResistBucket) {
        // Before the target test, not after: this is what makes a proper-named creature you have nuked
        // a creature, and it is the evidence the catalog most often lacks.
        if kind == .selfCast { mirrorStruck(target) }
        if !targets.isMobTarget(target) { return }
        let skill = ev.str(.skill) ?? ""
        let spellKey = Names.spellCanonKey(skill)
        rememberName(target)
        let ts = ev.ts
        var out: [SongOut] = []
        let handled = songs.onDamage(spellKey, kind == .selfCast, ts, &out)
        applySongOut(out, bucket)
        if handled {
            // Mirror the tick's song half: with no landing sentence in the catalog it was a `witness`.
            if kind == .selfCast && !songLandingObservable(spellKey) { mirrorWitness(spellKey, ts, nil) }
            return
        }
        cancelDeferred(target, spellKey)
        let targetKey = names.key(target)
        if let i = casts.peekAt(spellKey, ts) {
            casts.noteDamaged(i, targetKey)
            // The shadow is element-for-element the same array, so the peeked index names the same cast.
            if i < armedShadow.count { armedShadow[i].damaged.insert(targetKey) }
        }
        let level = casterLevel(kind, attacker)
        // A damage line almost never prints the rank, so the armed cast is the ordinary source and the
        // line is the rare exception that beats it.
        let lineRank = Names.spellRank(skill)
        let armed = casts.ownedBy(kind, spellKey, ts)
        let overchannel = cast.invocationFor(kind, armed.map { $0.overchannel })
        let obs = Observation(mob: target, spellKey: spellKey, family: .cast, kind: kind, level: level,
                              ts: ts, rank: lineRank > 0 ? lineRank : (armed?.rank ?? 0),
                              overchannel: overchannel)
        if dtype == "dot" {
            // The row is minted whether or not the tick counts — see `ResistBucket.row`.
            let key = names.key(target) + SEP + spellKey
            let fresh = dotSeen.insert(key).inserted
            let row = rowFor(bucket, obs)
            if fresh { row.land += 1 }
        } else {
            let crit = ev.bool(.crit)
            let modifiers = ev.arrLen(.modifiers)
            let amount = ev.int(.amount) ?? 0
            let row = rowFor(bucket, obs)
            // A critical counts as a landing and stays out of the histogram: its number is not the
            // spell's full damage, and would invent a second "full" value to read partials against.
            if crit || modifiers > 0 {
                row.land += 1
            } else {
                ResistLedger.addDamage(row, amount)
            }
        }
    }

    /// Apply what the song half asked for, in the order it asked. A pulse is rule 3, which lives here
    /// because it needs the world: one reconstructed pulse becomes one attempt against every mob alive
    /// and in melee contact inside the last pulse interval, plus every mob the log named as resisting
    /// it — proof of range no proximity heuristic can improve on.
    private func applySongOut(_ out: [SongOut], _ bucket: ResistBucket) {
        mirrorSongEmissions(out)
        for item in out {
            switch item {
            case .file(let mobDisplay, let songKey, let ts, let resisted):
                fileSong(bucket, mobDisplay, songKey, ts, resisted)
            case .pulse(let pulse):
                var keys = contact.within(pulse.ts, SONG_CONTACT_MS)
                for key in pulse.resisted where !keys.contains(key) { keys.append(key) }
                for key in keys {
                    let display = names.displayFor(key)
                    fileSong(bucket, display, pulse.spellKey, pulse.ts, pulse.resisted.contains(key))
                }
            }
        }
    }

    /// The row one song pulse belongs to, or nothing when the pulse landed on a person.
    ///
    /// `kind` is always `self` by construction: `SongFold` recognises a song by spell identity and
    /// hands back anything that is not the tailed character's.
    ///
    /// The target test matters most on this arm: a bard's group songs pulse on groupmates and print a
    /// landing sentence naming each of them.
    private func fileSong(_ bucket: ResistBucket, _ mobDisplay: String, _ songKey: String,
                          _ ts: Int64, _ resisted: Bool) {
        if !targets.isMobTarget(mobDisplay) { return }
        rememberName(mobDisplay)
        let obs = Observation(mob: mobDisplay, spellKey: songKey, family: .song, kind: .selfCast,
                              level: selfLevel, ts: ts, rank: cast.songRank(songKey),
                              // A song is not a cast spell, so the -150 overchannel adjust does not
                              // reach it.
                              overchannel: false)
        let row = rowFor(bucket, obs)
        if resisted { row.resist += 1 } else { row.land += 1 }
    }

    private func spec(_ obs: Observation) -> ResistRowSpec {
        let key = names.key(obs.mob)
        let level = levels.levelOf(key, obs.mob)
        let ranged = level.flatMap { $0.lo != $0.hi ? $0 : nil }
        return ResistRowSpec(
            mobKey: key,
            zone: zone,
            spellKey: obs.spellKey,
            family: obs.family,
            casterKind: obs.kind,
            casterLevel: obs.level,
            mobLevel: level.map(\.level),
            mobLevelLo: ranged.map(\.lo),
            mobLevelHi: ranged.map(\.hi),
            debuffs: activeMirrored(key, obs.ts),
            rank: obs.rank,
            overchannel: obs.overchannel,
            // Only where it changes `rc`, which is what keeps it out of the key on every ordinary row.
            casterClasses: obs.overchannel == true ? cast.casterClasses() : nil,
            // The one key term that is not about `rc`: a row's age, so recent evidence can weigh more
            // than old. Off the log's own clock, never a wall clock — a replay must produce the same
            // ledger twice.
            week: ResistLedger.isoWeekKey(obs.ts))
    }

    private func rowFor(_ bucket: ResistBucket, _ obs: Observation) -> ResistRow {
        bucket.row(spec(obs), obs.ts)
    }

    // MARK: Checkpoint mirrors — each keeps one shadow in step with the call it sits beside.

    /// `MobNames.remember`, mirrored: the display map is knowledge the ledger needs back.
    private func rememberName(_ display: String) {
        names.remember(display)
        displayShadow.insert(names.key(display), display)
    }

    /// `MobLevels.note`, mirrored move-to-end. Replaying the shadow in order re-runs the alias
    /// resolution, and last-note order is what makes overlapping alias groups land on the same
    /// final values the original sequence did.
    private func mirrorConned(_ key: String, _ level: Int64) {
        if level <= 0 { return }
        connedShadow.remove(key)
        connedShadow.insert(key, level)
    }

    private func mirrorPet(_ name: String) {
        casters.notePet(name)
        petShadow.insert(Names.idKey(name), name)
    }

    private func mirrorStruck(_ name: String) {
        casters.noteStruck(name)
        struckShadow.insert(Names.idKey(name), name)
    }

    /// `ArmedCasts.arm`, real and shadow together.
    private func mirrorArm(_ a: Armed) {
        casts.arm(a)
        armedShadow.append(a)
        if armedShadow.count > ARMED_CAP_MIRROR {
            armedShadow.removeFirst(armedShadow.count - ARMED_CAP_MIRROR)
        }
    }

    /// `ArmedCasts.take`'s scan, replayed on the shadow — the same walk over the same array finds
    /// the same cast the real take consumed. Called only after a successful take.
    private func mirrorTake(_ ts: Int64, _ candidates: [String]?) {
        let keys: Set<String>? = candidates.map { Set($0.map { Names.spellCanonKey($0) }) }
        for i in stride(from: armedShadow.count - 1, through: 0, by: -1) {
            let cast = armedShadow[i]
            if ts < cast.ts || ts - cast.ts > CAST_JOIN_MS { continue }
            if let keys, !keys.contains(cast.spellKey) { continue }
            armedShadow.remove(at: i)
            return
        }
    }

    private func mirrorDebuffOpen(_ mobKey: String, _ spellKey: String, _ ts: Int64) {
        var m = debuffShadow[mobKey] ?? JSMap<Int64>()
        m.insert(spellKey, ts + DEBUFF_WINDOW_MS)
        debuffShadow.insert(mobKey, m)
    }

    /// `DebuffWindows.active` with its expiry sweep mirrored, so the shadow drops exactly the
    /// entries the real map dropped.
    private func activeMirrored(_ mobKey: String, _ ts: Int64) -> String {
        if var m = debuffShadow[mobKey] {
            for (spell, until) in m.pairs where until <= ts { m.remove(spell) }
            debuffShadow.insert(mobKey, m)
        }
        return debuffs.active(mobKey, ts)
    }

    /// `SongFold.noteNamed`, mirrored: the two recency lists, plus the compacted op map the
    /// checkpoint carries (move-to-end, so its order is last-occurrence order).
    private func mirrorNoteNamed(_ mobKey: String, _ songKey: String) {
        var next = [songKey]
        next.append(contentsOf: namedShadow.filter { $0 != songKey })
        if next.count > 8 { next.removeSubrange(8...) }
        namedShadow = next
        let here = namedByMobShadow[mobKey] ?? []
        var mine = [songKey]
        mine.append(contentsOf: here.filter { $0 != songKey })
        if mine.count > 4 { mine.removeSubrange(4...) }
        namedByMobShadow[mobKey] = mine
        let opKey = mobKey + SEP + songKey
        namedOps.remove(opKey)
        namedOps.insert(opKey, NamedOp(mob: mobKey, spell: songKey))
    }

    /// `SongFold.namedFor`, against the shadows.
    private func mirrorNamedFor(_ mobKey: String) -> [String] {
        var out = namedByMobShadow[mobKey] ?? []
        out.append(contentsOf: namedShadow)
        return out
    }

    /// `SongFold.onSelfLanding` + `SongPulses.noteHeartbeat`, mirrored — the candidate that proved
    /// the line a song is stored with the instant, so the restore can replay it.
    private func mirrorSelfLanding(_ ts: Int64, _ cands: [String]) {
        for name in cands {
            let key = Names.spellCanonKey(name)
            if !(sungShadow.contains(key) || isSongSpell(key)) { continue }
            if let last = beatShadow.last, ts - last.ts < SONG_WITNESS_JOIN_MS { return }
            beatShadow.append(BeatShadow(ts: ts, cand: name))
            if beatShadow.count > HEARTBEAT_MEMORY_MIRROR {
                beatShadow.removeFirst(beatShadow.count - HEARTBEAT_MEMORY_MIRROR)
            }
            return
        }
    }

    /// `SongPulses.witness`'s own state change, mirrored. Any close the witness caused was already
    /// mirrored off the emission stream, so what is left is the merge-or-fresh-open half.
    private func mirrorWitness(_ spellKey: String, _ ts: Int64, _ mobKey: String?) {
        if var o = openShadow[spellKey], ts - o.ts <= SONG_WITNESS_JOIN_MS {
            if let mob = mobKey, !o.resisted.contains(mob) {
                o.resisted.append(mob)
                openShadow.insert(spellKey, o)
            }
            return
        }
        var fresh = OpenShadow(ts: ts, resisted: [])
        if let mob = mobKey { fresh.resisted.append(mob) }
        openShadow.insert(spellKey, fresh)
    }

    /// The emission stream is the run map's mirror: `closeOpen` is the only writer of a witnessed
    /// pulse, and each one means "this spell's open closed at `ts` and its run re-anchored there".
    private func mirrorSongEmissions(_ out: [SongOut]) {
        for item in out {
            guard case .pulse(let p) = item, p.witnessed else { continue }
            openShadow.remove(p.spellKey)
            runsShadow.insert(p.spellKey, RunShadow(lastWitness: p.ts, reanchor: nil))
        }
    }
}

/// The EqModule wrapper.
public final class ResistModule: EqModule {
    public let id = "resist"
    private let ledger = ResistLedgerStore()
    private var fold = ResistFold()
    private var seq: Int64 = 0
    /// The constructed default. `beginSource` names the character whose log is about to be folded; the
    /// bench never calls it, so this is the key the goldens were recorded under.
    private var sourceKey = "log"

    public init() {}

    /// Name the character whose log is about to be folded. Discards that character's bucket first, so
    /// re-reading the same log every launch replaces its contribution instead of doubling it.
    ///
    /// The parity bench never calls it, so the source key stays the constructed default there.
    public func beginSource(_ key: String) {
        sourceKey = key
        ledger.beginSource(key)
        fold.beginSource()
    }

    /// Seed the persisted buckets.
    ///
    /// It must run before `beginSource`, never after: seeding puts every persisted bucket back and the
    /// fold's own source is discarded afterwards by the one call that names it. Reversed, this run's
    /// character would be seeded with counts its own log is about to re-state.
    public func seed(_ sources: [LedgerSource]) {
        ResistLedgerFile.seedStore(ledger, sources)
    }

    /// The user's half of the ledger, as it goes on disk. The shipped baseline's bucket and every empty
    /// bucket are dropped.
    public func userLedgerFile() -> UserLedgerFile {
        ResistLedgerFile.ledgerFileOf(ledger)
    }

    /// The store itself, for the engine's own reads.
    public var store: ResistLedgerStore { ledger }

    /// The pull seam for one creature's level, since this module publishes only counts and has no
    /// cursor to mirror.
    ///
    /// It takes both the key and the display name because the two are used for different things: a
    /// `/con` this session is filed under the folded key, and the committed catalog is looked up under
    /// the name the log spelled. The caller folds the key so one spelling rule serves the whole engine.
    public func levelOf(_ mobKey: String, _ display: String) -> MobLevelFact? {
        fold.levelOfRef(mobKey, display)
    }

    /// One creature's level for every name a reader asked about — the seam the engine's `resist.levels`
    /// op calls.
    public func levels(for names: [String]) -> [(name: String, fact: MobLevelFact?)] {
        names.map { (name: $0, fact: fold.levelOfRef(ResistCatalog.mobKey($0), $0)) }
    }

    public func reset() {
        seq = 0
        // A fresh fold, and the ledger discards this source's bucket before its log is folded again:
        // the discard is what makes a re-fold idempotent.
        fold = ResistFold()
        ledger.beginSource(sourceKey)
        fold.beginSource()
    }

    public func onEvent(_ ev: Event, live: Bool) {
        seq = ev.seq
        fold.onEvent(ev, ledger.bucketMut(sourceKey))
    }

    /// See `ResistFold.settle`.
    ///
    /// `seq` does not move: this module publishes the last event's seq and a settle is not an event.
    /// What it can change is the ledger's row and mob counts.
    public func onTick(nowMs: Int64, timerRows: [BuffTimerRow]) {
        fold.settle(nowMs, ledger.bucketMut(sourceKey))
    }

    /// The same cursor `snapshot` publishes, without building the state to read it.
    public var publishedSeq: Int64? { seq }

    public func snapshot() -> JSONValue {
        let (rows, mobs) = ledger.counts()
        return ["seq": .int(seq), "state": ["rows": .int(Int64(rows)), "mobs": .int(Int64(mobs))]]
    }

    /// The persisted-ledger seam.
    public var asResist: ResistModule? { self }
}

// MARK: - Checkpoint

/// Strict optional readers for the codec: outer nil is "wrong type, refuse the blob", inner nil is
/// "absent or null" — the same double-optional `ResistRowFile` reads with.
private enum CK {
    static func optInt(_ v: JSONValue) -> Int64?? {
        if v.isNull { return .some(nil) }
        return v.int64.map { Optional($0) }
    }
    static func optBool(_ v: JSONValue) -> Bool?? {
        if v.isNull { return .some(nil) }
        return v.bool.map { Optional($0) }
    }
    static func optString(_ v: JSONValue) -> String?? {
        if v.isNull { return .some(nil) }
        return v.string.map { Optional($0) }
    }
    static func strings(_ v: JSONValue) -> [String]? {
        guard let a = v.array else { return nil }
        var out: [String] = []
        out.reserveCapacity(a.count)
        for x in a {
            guard let s = x.string else { return nil }
            out.append(s)
        }
        return out
    }
}

private func armedJSON(_ a: Armed) -> JSONValue {
    var o: [String: JSONValue] = [
        "spellKey": .string(a.spellKey), "display": .string(a.display), "ts": .int(a.ts),
        "kind": .string(a.kind.rawValue), "rank": .int(a.rank),
        "damaged": .array(a.damaged.sorted().map { .string($0) }),
    ]
    if let level = a.level { o["level"] = .int(level) }
    if let oc = a.overchannel { o["overchannel"] = .bool(oc) }
    return .object(o)
}

private func armedFrom(_ v: JSONValue) -> Armed? {
    guard let spellKey = v["spellKey"].string, let display = v["display"].string,
          let ts = v["ts"].int64, let kindText = v["kind"].string,
          let kind = ResistCasterKind(rawValue: kindText), let rank = v["rank"].int64,
          let damaged = CK.strings(v["damaged"]),
          let level = CK.optInt(v["level"]), let oc = CK.optBool(v["overchannel"]) else { return nil }
    return Armed(spellKey: spellKey, display: display, ts: ts, kind: kind, level: level,
                 rank: rank, overchannel: oc, damaged: Set(damaged))
}

/// The fold half of the blob, decoded whole before anything is applied.
private struct FoldBlob {
    var zone: String?
    var selfLevel: Int64?
    var conned: JSMap<Int64>
    var pets: JSMap<String>
    var struck: JSMap<String>
    var displays: JSMap<String>
    var debuffs: JSMap<JSMap<Int64>>
    var contact: JSMap<Int64>
    var invocation: String?
    var classes: [String]?
    var songRanks: JSMap<Int64>
    var armed: [Armed]
    var dotSeen: [String]
    var deferred: Deferred?
    var sung: [String]
    var namedOps: JSMap<NamedOp>
    var beats: [BeatShadow]
    var runs: JSMap<RunShadow>
    var open: JSMap<OpenShadow>

    static func from(_ v: JSONValue) -> FoldBlob? {
        guard case .object = v else { return nil }
        guard let zone = CK.optString(v["zone"]),
              let selfLevel = CK.optInt(v["selfLevel"]),
              let conned = JSMap<Int64>.fromCheckpoint(v["conned"], { $0.int64 }),
              let pets = JSMap<String>.fromCheckpoint(v["pets"], { $0.string }),
              let struck = JSMap<String>.fromCheckpoint(v["struck"], { $0.string }),
              let displays = JSMap<String>.fromCheckpoint(v["displays"], { $0.string }),
              let debuffs = JSMap<JSMap<Int64>>.fromCheckpoint(v["debuffs"], { inner in
                  JSMap<Int64>.fromCheckpoint(inner) { $0.int64 }
              }),
              let contact = JSMap<Int64>.fromCheckpoint(v["contact"], { $0.int64 }),
              let invocation = CK.optString(v["invocation"]),
              let songRanks = JSMap<Int64>.fromCheckpoint(v["songRanks"], { $0.int64 }),
              let armedArr = v["armed"].array,
              let dotSeen = CK.strings(v["dotSeen"]),
              let sung = CK.strings(v["sung"]),
              let namedOps = JSMap<NamedOp>.fromCheckpoint(v["namedOps"], { op in
                  guard let mob = op["mob"].string, let spell = op["spell"].string else { return nil }
                  return NamedOp(mob: mob, spell: spell)
              }),
              let beatsArr = v["beats"].array,
              let runs = JSMap<RunShadow>.fromCheckpoint(v["runs"], { r in
                  guard case .object = r, let lw = CK.optInt(r["lastWitness"]),
                        let ra = CK.optInt(r["reanchor"]) else { return nil }
                  return RunShadow(lastWitness: lw, reanchor: ra)
              }),
              let open = JSMap<OpenShadow>.fromCheckpoint(v["open"], { o in
                  guard let ts = o["ts"].int64, let resisted = CK.strings(o["resisted"]) else { return nil }
                  return OpenShadow(ts: ts, resisted: resisted)
              })
        else { return nil }
        var classes: [String]?
        if let present = v["classes"].presentValue {
            guard let list = CK.strings(present) else { return nil }
            classes = list
        }
        var armed: [Armed] = []
        for a in armedArr {
            guard let parsed = armedFrom(a) else { return nil }
            armed.append(parsed)
        }
        var beats: [BeatShadow] = []
        for b in beatsArr {
            guard let ts = b["ts"].int64, let cand = b["cand"].string else { return nil }
            beats.append(BeatShadow(ts: ts, cand: cand))
        }
        var deferred: Deferred?
        if let d = v["deferred"].presentValue {
            guard let mob = d["mob"].string, let spellKey = d["spellKey"].string,
                  let ts = d["ts"].int64, let kindText = d["kind"].string,
                  let kind = ResistCasterKind(rawValue: kindText), let rank = d["rank"].int64,
                  let level = CK.optInt(d["level"]), let oc = CK.optBool(d["overchannel"]) else { return nil }
            deferred = Deferred(mob: mob, spellKey: spellKey, ts: ts, kind: kind, level: level,
                                rank: rank, overchannel: oc)
        }
        return FoldBlob(zone: zone, selfLevel: selfLevel, conned: conned, pets: pets, struck: struck,
                        displays: displays, debuffs: debuffs, contact: contact,
                        invocation: invocation, classes: classes, songRanks: songRanks, armed: armed,
                        dotSeen: dotSeen, deferred: deferred, sung: sung, namedOps: namedOps,
                        beats: beats, runs: runs, open: open)
    }
}

extension ResistFold {
    /// The fold's complete state, as the shadows carry it. The pure memo caches — `TargetVerdicts`,
    /// `MobNames.keys`, `MobLevels.catalog`, `CasterIndex.verdicts` — are deliberately absent: each
    /// is a pure function of committed data plus the shadowed facts, so an empty cache recomputes
    /// the identical verdicts and its absence cannot change any future fold result.
    fileprivate func checkpointState() -> JSONValue {
        var o: [String: JSONValue] = [:]
        o["conned"] = connedShadow.checkpoint { .int($0) }
        o["pets"] = petShadow.checkpoint { .string($0) }
        o["struck"] = struckShadow.checkpoint { .string($0) }
        o["displays"] = displayShadow.checkpoint { .string($0) }
        o["debuffs"] = debuffShadow.checkpoint { $0.checkpoint { .int($0) } }
        o["contact"] = contactShadow.checkpoint { .int($0) }
        o["songRanks"] = songRankShadow.checkpoint { .int($0) }
        o["armed"] = .array(armedShadow.map(armedJSON))
        o["dotSeen"] = .array(dotSeen.sorted().map { .string($0) })
        o["sung"] = .array(sungShadow.sorted().map { .string($0) })
        o["namedOps"] = namedOps.checkpoint {
            .object(["mob": .string($0.mob), "spell": .string($0.spell)])
        }
        o["beats"] = .array(beatShadow.map { .object(["ts": .int($0.ts), "cand": .string($0.cand)]) })
        o["runs"] = runsShadow.checkpoint { r in
            var x: [String: JSONValue] = [:]
            if let lw = r.lastWitness { x["lastWitness"] = .int(lw) }
            if let ra = r.reanchor { x["reanchor"] = .int(ra) }
            return .object(x)
        }
        o["open"] = openShadow.checkpoint {
            .object(["ts": .int($0.ts), "resisted": .array($0.resisted.map { .string($0) })])
        }
        if let zone { o["zone"] = .string(zone) }
        if let selfLevel { o["selfLevel"] = .int(selfLevel) }
        if let invocationShadow { o["invocation"] = .string(invocationShadow) }
        if let classesShadow { o["classes"] = .array(classesShadow.map { .string($0) }) }
        if let d = deferred {
            var x: [String: JSONValue] = ["mob": .string(d.mob), "spellKey": .string(d.spellKey),
                                          "ts": .int(d.ts), "kind": .string(d.kind.rawValue),
                                          "rank": .int(d.rank)]
            if let level = d.level { x["level"] = .int(level) }
            if let oc = d.overchannel { x["overchannel"] = .bool(oc) }
            o["deferred"] = .object(x)
        }
        return .object(o)
    }

    fileprivate static func decodeCheckpoint(_ v: JSONValue) -> JSONValue? {
        FoldBlob.from(v) != nil ? v : nil
    }

    /// Rebuild a FRESH fold from a decoded blob, by replaying the shadows through each sub-object's
    /// public API. Must only be called on a fold that has just been constructed.
    ///
    /// The song reconstruction deserves its sequencing spelled out, because `SongPulses` exposes no
    /// direct write and every public door has side effects:
    ///
    ///   1. `sung` via `noteSung(key, 0)` — the junk re-anchors at 0 are flushed in step 3.
    ///   2. Every named op in last-occurrence order via `onResist(ts: 0)` — rebuilds the two recency
    ///      lists exactly; the junk opens it buffers (all at ts 0) are flushed in step 3.
    ///   3. `flush` — wipes the junk runs and opens; `sung`, the named lists and `beats` survive it
    ///      exactly as they survive a zone line.
    ///   4. `beats` via `onSelfLanding` — the stored candidate re-proves each instant a song's.
    ///   5. Runs, one spell at a time: a witness at `lastWitness` (through `onDamage`, which never
    ///      touches the named lists) closed by a `settle` just past the join window plants the run;
    ///      re-anchors via `noteSung`. The settle's `now` is inside every true open's join window
    ///      (opens postdate their spell's last witness), so it can close nothing it should not.
    ///   6. Opens at their true instants: resisted mobs via `onResist(ts: open.ts)`, an unwitnessed
    ///      open via `onDamage`. These re-note their (mob, song) pairs out of order, so
    ///   7. the named-op SUFFIX from the first open pair onward is replayed once more, in true
    ///      order: an open pair merges into its own open (a no-op on the open — the mob is already
    ///      in its resisted list), a catalog-observable pair files into scratch. The one shape with
    ///      no clean replay — a pair of a song that is neither observable nor currently open — is
    ///      skipped; in a historical fold it cannot reach the suffix (its spell's opens died at a
    ///      zone line, which every current open postdates), and in a live resume the cost is only
    ///      recency rank in the ambiguity list, never a filed row.
    fileprivate func applyCheckpoint(_ v: JSONValue) {
        guard let d = FoldBlob.from(v) else { return }
        zone = d.zone
        selfLevel = d.selfLevel
        for (key, level) in d.conned.pairs { levels.note(key, level) }
        for (_, raw) in d.pets.pairs { casters.notePet(raw) }
        for (_, raw) in d.struck.pairs { casters.noteStruck(raw) }
        for (_, display) in d.displays.pairs { names.remember(display) }
        for (mobKey, spells) in d.debuffs.pairs {
            for (spellKey, until) in spells.pairs {
                debuffs.open(mobKey, spellKey, until - DEBUFF_WINDOW_MS)
            }
        }
        for (key, ts) in d.contact.pairs { contact.note(key, ts) }
        if let invocation = d.invocation { cast.noteInvocation(invocation) }
        if let classes = d.classes { cast.noteClasses(classes) }
        for (key, rank) in d.songRanks.pairs { cast.noteSongRank(key, rank) }
        for a in d.armed { casts.arm(a) }
        // Songs — the seven steps above. Every emission lands in scratch and is discarded: the rows
        // those emissions produced are already in the restored ledger.
        var scratch: [SongOut] = []
        for key in d.sung { songs.noteSung(key, 0, &scratch) }
        for (_, op) in d.namedOps.pairs { _ = songs.onResist(op.mob, op.mob, op.spell, true, 0, &scratch) }
        songs.flush(&scratch)
        for b in d.beats { songs.onSelfLanding(b.ts, [b.cand]) }
        for (spellKey, run) in d.runs.pairs {
            if let lw = run.lastWitness {
                _ = songs.onDamage(spellKey, true, lw, &scratch)
                songs.settle(lw + SONG_WITNESS_JOIN_MS + 1, &scratch)
            }
            if let ra = run.reanchor { songs.noteSung(spellKey, ra, &scratch) }
        }
        for (spellKey, o) in d.open.pairs {
            if o.resisted.isEmpty {
                _ = songs.onDamage(spellKey, true, o.ts, &scratch)
            } else {
                for mob in o.resisted { _ = songs.onResist(mob, mob, spellKey, true, o.ts, &scratch) }
            }
        }
        var seenOpenPair = false
        for (_, op) in d.namedOps.pairs {
            let isOpenPair = d.open[op.spell].map { $0.resisted.contains(op.mob) } ?? false
            if !seenOpenPair {
                if !isOpenPair { continue }
                seenOpenPair = true
            }
            if isOpenPair {
                _ = songs.onResist(op.mob, op.mob, op.spell, true, d.open[op.spell]!.ts, &scratch)
            } else if songLandingObservable(op.spell) {
                _ = songs.onResist(op.mob, op.mob, op.spell, true, 0, &scratch)
            }
        }
        // Direct fields, and the shadows — verbatim from the blob, so a re-encode is the blob.
        dotSeen = Set(d.dotSeen)
        deferred = d.deferred
        connedShadow = d.conned
        petShadow = d.pets
        struckShadow = d.struck
        displayShadow = d.displays
        debuffShadow = d.debuffs
        contactShadow = d.contact
        invocationShadow = d.invocation
        classesShadow = d.classes
        songRankShadow = d.songRanks
        armedShadow = d.armed
        sungShadow = Set(d.sung)
        namedOps = d.namedOps
        namedShadow = []
        namedByMobShadow = [:]
        for (_, op) in d.namedOps.pairs { mirrorNoteNamed(op.mob, op.spell) }
        beatShadow = d.beats
        runsShadow = d.runs
        openShadow = d.open
    }
}

extension ResistModule: FoldCheckpointable {
    /// The blob carries ONLY this fold's own bucket — the one `onEvent` writes — plus the fold's
    /// complete state and the source key rows are filed under. The seeded foreign buckets are a
    /// DEPENDENCY, not folded state: `onEvent` never touches them, `reset()` deliberately keeps
    /// them, and the disk copy `seedPersisted` put back at attach is exactly what a from-zero scan
    /// at resume time would read — possibly NEWER than the checkpoint's copy, when another
    /// character's session wrote the shared ledger in between. Carrying them would revert that
    /// newer bucket and then persist the reversion. Rows ride `ResistRowFile`, the same codec the
    /// on-disk ledger uses, so a row that round-trips the file round-trips the checkpoint.
    public func checkpointState() -> JSONValue {
        var own: [String: JSONValue] = ["rows": .array([])]
        if let bucket = ledger.buckets[sourceKey] {
            own["rows"] = bucket.byKey.checkpoint { ResistRowFile.of($0).json }
            if let week = bucket.newest { own["newest"] = .string(week) }
        }
        return .object([
            "seq": .int(seq),
            "sourceKey": .string(sourceKey),
            "bucket": .object(own),
            "fold": fold.checkpointState(),
        ])
    }

    public func restoreCheckpoint(_ state: JSONValue) -> Bool {
        reset()
        guard let savedSeq = state["seq"].int64,
              let key = state["sourceKey"].string,
              // A blob filed under another character's key summarizes another log — refuse it and
              // let the caller rescan. `beginSource` named this attach's key before the restore.
              key == sourceKey,
              let rows = JSMap<ResistRow>.fromCheckpoint(state["bucket"]["rows"], {
                  ResistRowFile.from($0)?.intoRow()
              }),
              let newest = CK.optString(state["bucket"]["newest"]),
              let foldBlob = ResistFold.decodeCheckpoint(state["fold"]) else { return false }
        // `reset()` discarded the own bucket and kept the seeded foreign ones — put the blob's own
        // bucket back beside them.
        let bucket = ledger.bucketMut(sourceKey)
        bucket.byKey = rows
        bucket.newest = newest
        // `reset()` built a fresh fold; rebuild it from the blob.
        fold.applyCheckpoint(foldBlob)
        seq = savedSeq
        return true
    }
}
