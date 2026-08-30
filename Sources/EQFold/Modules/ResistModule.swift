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
            cast.noteClasses(ev.arrStr(.classes))
            return true
        case .invocationChange:
            cast.noteInvocation(ev.str(.invocation) ?? "")
            return true
        case .consider:
            let mob = ev.str(.mob) ?? ""
            names.remember(mob)
            if let level = ev.int(.level) {
                levels.note(names.key(mob), level)
            }
            return true
        case .death:
            let key = names.key(ev.str(.name) ?? "")
            debuffs.clearMob(key)
            // A dead mob stops being a song target immediately (rule 3: alive and in contact). The song
            // itself keeps running, so nothing here touches the reconstruction.
            contact.dropMob(key)
            return true
        case .petClaim, .petSay:
            casters.notePet(ev.str(.name) ?? "")
            return true
        case .allyPetLeader:
            casters.notePet(ev.str(.pet) ?? "")
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
            casts.disarm(Names.spellCanonKey(ev.str(.spell) ?? ""))
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
        names.remember(mob)
    }

    private func onCastBegin(_ spell: String, _ ts: Int64, _ sung: Bool, _ bucket: ResistBucket) {
        let key = Names.spellCanonKey(spell)
        let rank = Names.spellRank(spell)
        if sung {
            var out: [SongOut] = []
            songs.noteSung(key, ts, &out)
            applySongOut(out, bucket)
        }
        cast.noteSongRank(key, rank)
        // A fresh cast re-arms the "first tick counts as a landing" memory for this spell.
        let tail = SEP + key
        dotSeen = dotSeen.filter { !$0.hasSuffix(tail) }
        casts.arm(Armed(spellKey: key, display: spell, ts: ts, kind: .selfCast, level: selfLevel,
                        rank: rank, overchannel: cast.overchannel(), damaged: []))
    }

    private func onOtherCast(_ caster: String, _ spell: String, _ ts: Int64) {
        if casters.kindOf(caster) != .pc { return }
        casts.arm(Armed(spellKey: Names.spellCanonKey(spell), display: spell, ts: ts, kind: .pc,
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
        if handled { return }
        guard let armed = casts.take(ts, candidates) else { return }
        // A buff landed on a groupmate prints the same sentence shape as a debuff on a mob, and filed
        // as a row it becomes a person's name in the ledger.
        if !targets.isMobTarget(mobDisplay) { return }
        names.remember(mobDisplay)
        let key = names.key(mobDisplay)
        if ResistCatalog.isResistDebuff(armed.display) {
            debuffs.open(key, armed.spellKey, ts)
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
        if kind == .selfCast { cast.noteSongRank(spellKey, lineRank) }
        names.remember(target)
        let mob = names.key(target)
        let ts = ev.ts
        var out: [SongOut] = []
        let handled = songs.onResist(target, mob, spellKey, kind == .selfCast, ts, &out)
        applySongOut(out, bucket)
        if handled { return }
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
            if isSelfName(attacker) { casters.noteStruck(target) }
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
        if kind == .selfCast { casters.noteStruck(target) }
        if !targets.isMobTarget(target) { return }
        let skill = ev.str(.skill) ?? ""
        let spellKey = Names.spellCanonKey(skill)
        names.remember(target)
        let ts = ev.ts
        var out: [SongOut] = []
        let handled = songs.onDamage(spellKey, kind == .selfCast, ts, &out)
        applySongOut(out, bucket)
        if handled { return }
        cancelDeferred(target, spellKey)
        let targetKey = names.key(target)
        if let i = casts.peekAt(spellKey, ts) { casts.noteDamaged(i, targetKey) }
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
        names.remember(mobDisplay)
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
            debuffs: debuffs.active(key, obs.ts),
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
