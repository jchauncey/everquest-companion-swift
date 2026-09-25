// The join between `Ingest` (who is folding) and `EQFold` (what a fold is): one `EventSink` and one
// factory that builds the module registry out of what an attach knows. Port of
// engined/src/foldsink.rs. It is the only place either side's construction is spelled.
//
// `ClusterDeps` splits two ways. Facts about committed data are derived here from the parser's own
// catalog; app knowledge is empty at construction and arrives afterwards as `*.define` commands —
// the engine never reads a settings file. The character ref is neither: it comes off the log's file
// name, the same fact the parser derives its character from, because two ways of stating one
// identity is a way for them to disagree.
//
// The combat engine is registered but is not a module — `wiringOrder` does not name it and
// `module.snapshot` refuses the name — so it reaches clients through `combat.snapshot`,
// `combat.searchFights` and the view source `combat.live`.
//
// A combat answer is taken at the wall clock once this world has reached its tail and at the fold's
// own `lastTs` before that; a replay stamped with a host clock would finalize whatever fight was
// open and hand the rest to a fresh encounter. `FoldSink.live` states which world this is
// structurally: `EventSink.tick` is the one call the historical scan cannot reach. The same flag
// decides whether the model may be aged, since a world entitled to a wall clock is exactly one
// entitled to age itself against one.
//
// The attach instant is the only wall clock read at construction; every other time-based rule
// inside the fold advances off log timestamps.
import Foundation
import EQCompanionCore
import EQFold
import EQLog
import EQKnowledge

/// The factory the world is handed: every attach folds the whole registry.
public func foldingSinks() -> SinkFactory {
    { inputs in FoldSink(inputs) }
}

/// The engine's knowledge corpus.
///
/// One instance, handed to the registry at every attach and held by the world for the `knowledge.*`
/// ops. It must be the same instance both times: a second corpus would be a second overlay, so a
/// name the app pushed in answer to a miss would be a hit on one path and a miss on the other.
public func corpus() -> KnowledgeCorpus { KnowledgeCorpus.shared() }

/// One attach's fold, and the counters the ingest reports off it.
public final class FoldSink: EventSink {
    let fold: Fold
    /// The engine's corpus, kept so this sink can drain its miss ledger at the ingest's boundary.
    /// The same instance the registry was handed.
    let knowledge: KnowledgeCorpus
    /// The parser's own clock, kept because a view has to render an instant: `loot.ledger`'s `at`
    /// cell is the wall clock the log's timestamps were read in, and a second clock built from the
    /// same zone would be a second answer waiting to disagree. It is the ZONE that is load-bearing
    /// — nothing in this file asks what time it is now.
    let clock: Clock
    /// Has this world reached its tail? The whole of the `now` decision.
    ///
    /// Set by `tick` and by nothing else, which is what makes it structural: the historical scan
    /// has no path to `tick`, so a fold that is still scanning cannot have this set.
    private var live = false
    /// The app's `userData`, and this generation's memory of what it last wrote there. nil when the
    /// attach carried no `stateDir`, which means this fold neither read a file nor writes one.
    private let state: StateDir?
    /// How many beats this world has taken — half of `combat.live`'s revision signal.
    ///
    /// The meter's rows are a function of the events folded AND of the instant they are read at: a
    /// fight's `durationSec` grows with `now` while the log says nothing. Beats plus events moves
    /// on either and repeats across neither.
    private var beats: UInt64 = 0

    /// Build the registry this attach folds into. See the file header for every input.
    public init(_ inputs: SinkInputs) {
        let launchMs = Epoch.launchMs(inputs.clock)
        let f = Fold(registry: registryFor(inputs, launchMs), launchMs: launchMs)
            .withCombat(combatFor(inputs))
        // Your pet from your heals when the game never names it — the app's fold only (Swift-only).
        f.petInference = PetInference()
        // The app's persisted knowledge, put back before the first byte. Read, seed, then name this
        // fold's own bucket — `seedPersisted` does the last two as one call because their order is
        // load-bearing. It happens after `Fold.init` because the initializer resets every module
        // and the resist module's reset discards its own source's bucket, so an earlier seed is
        // thrown away.
        //
        // None of it runs without a `stateDir`: the whole block is inside the optional, so a fold
        // with no state directory is byte-for-byte the fold built without one — no read, no source
        // rename, no write — which keeps the equivalence oracle's world reachable structurally.
        if let dir = inputs.stateDir {
            let store = StateDir(dir)
            f.registry.seedPersisted(key: sourceKey(inputs), state: store.read())
            state = store
        } else {
            state = nil
        }
        fold = f
        clock = Clock(tz: inputs.clock.tz)
        knowledge = corpus()
    }

    /// The instant a combat answer is taken at: the engine's own wall clock once the tail is
    /// running, read fresh per answer, and the fold's own `lastTs` before that — the only honest
    /// instant for a replay.
    private func combatNow() -> Int64 {
        live ? Ingest.wallClockMs() : fold.lastTs
    }

    // MARK: - EventSink

    /// One event, straight from the parser into the fold. There is nothing to decline: the payload
    /// IS what the parser wrote, and a parse that produced no event never reaches this method.
    /// The fold reads the payload and nothing else.
    public var wantsJSON: Bool { false }

    public func event(_ event: IngestEvent) {
        fold.onPrimary(Event.typed(event.payload), live: event.live)
    }

    /// The live heartbeat, straight through. One line, because the whole of the decision is the
    /// fold's: which modules have a tick, what each does with the number, and — the load-bearing
    /// half — that the historical path never calls it.
    ///
    /// The engine needs one because the app has aged its own fold on a wall clock for years; an
    /// engine advancing only off log timestamps served a world correct about the bytes and stale
    /// about the hour.
    ///
    /// It is also the one call that says this world is live, which makes "am I live" a fact stated
    /// by the call graph rather than a second copy of the world's status.
    public func tick(_ nowMs: Int64) {
        // The combat engine goes live here, on the first beat and only on it: this beat IS the
        // go-live moment — one tick at the landing, before `reportFoldLanded` publishes
        // `status: "live"`, then ~1×/sec. The app orders the two the same way, so the engine is
        // told it is live before the model it owns is aged.
        //
        // Guarded on `live` rather than left to `setLive`'s idempotence: the guard says that going
        // live happens once per attach. A new generation is a new sink and a new engine.
        //
        // From here `hydrating` is false, so every combat answer runs the four snapshot-time sweeps
        // at the instant it is taken — the deferred encounter closure among them. A historical scan
        // reaches none of it, because the scan cannot call `tick`.
        if !live { fold.combat?.setLive() }
        live = true
        beats &+= 1
        fold.tick(nowMs: nowMs)
        // Every sixtieth beat, the disk — the app's "every sixtieth tick" ledger persist and its
        // 60-second overlay save, which at a 1 Hz heartbeat are the same minute stated twice.
        //
        // It is in `tick` and nowhere else, which makes "nothing during a replay" a fact about the
        // call graph rather than a guard somebody has to remember. The write is coalesced on a
        // fingerprint and can never take the engine down.
        if beats % writeEveryBeats == 0 { state?.write(fold.registry) }
    }

    /// The fold is being replaced. The last chance this generation's ledger has to reach the disk,
    /// coalesced by the same fingerprint, so a detach that follows a beat writes nothing.
    ///
    /// Only once the fold has gone live. `seedPersisted` gave this source an empty bucket that the
    /// scan fills, so a fold preempted mid-scan holds a prefix of the log; flushing it would put
    /// that prefix over the complete bucket the last live session wrote.
    public func detach() {
        guard live else { return }
        state?.flush(fold.registry)
    }

    /// What the fold can say about itself. `lastTs` is `max(ev.ts)` — the log's own clock, so a log
    /// that rolls over cannot walk it backwards.
    public func report() -> SinkReport {
        SinkReport(events: clampI64(fold.events), lastTs: fold.lastTs)
    }

    /// One module's published state, straight off the registry.
    ///
    /// This splits the module's `{ seq, state }` pair rather than re-deriving either half: four
    /// modules publish a private revision counter instead of an event seq, and reading it off
    /// anything but the module's own answer would be a second opinion about a number it owns.
    public func snapshot(_ module: String) -> ModuleSnapshot? {
        guard let published = fold.registry.snapshotOf(module) else { return nil }
        guard let seq = published["seq"].int64 else { return nil }
        return ModuleSnapshot(seq: seq, state: published["state"])
    }

    /// The view layer's door. One switch on the source, and each case reads its module through
    /// that module's own pull seam — never through `snapshot()`, which would serialize the whole
    /// thing to draw fifty rows of it.
    ///
    /// A source whose module is not registered answers nil, and the view layer serves an empty
    /// window rather than refusing: the descriptor was valid, this fold simply has nothing behind
    /// it.
    public func sourceRows(_ source: SourceDef) -> [SourceRow]? {
        let registry = fold.registry
        switch source.id {
        case Views.Loot.ledger.id:
            return registry.loot().map { Views.Loot.rows($0, clock) }
        case Views.Buffs.active.id:
            return registry.buffs().map { Views.Buffs.rows($0) }
        // Two modules, one source, and the guard on either is what makes that honest: a registry
        // carrying one of them cannot serve half a window, so it serves none.
        case Views.Timers.rowsSource.id:
            guard let buffs = registry.buffs(), let timers = registry.buffTimers() else { return nil }
            return Views.Timers.rows(buffs, timers)
        case Views.Respawn.watches.id:
            return registry.respawn().map { Views.Respawn.rows($0) }
        case Views.Kills.recent.id:
            return registry.progression().map { Views.Kills.rows($0) }
        case Views.Progression.recent.id:
            return registry.progression().map { Views.Progression.rows($0, clock) }
        case Views.EventFeed.recent.id:
            return registry.eventFeed().map { Views.EventFeed.rows($0) }
        // The meter's rows come out of the snapshot's own `selected`, at the cheapest options that
        // produce one: no finalized-fight list, no timeline, no unparsed ring. The current
        // encounter and the zone summary are included whatever the cap, so the selection resolves
        // exactly as a full-fat call resolves it.
        case Views.Combat.live.id:
            guard let snapshot = combatSnapshot(CombatOpts(maxSegments: 0)) else { return nil }
            return Views.Combat.rows(snapshot.state["selected"])
        default:
            return nil
        }
    }

    /// The app-knowledge door. One call through to the registry, which owns the mapping from a
    /// family to the module that answers for it.
    public func define(_ family: String, _ payload: JSONValue) -> Bool {
        fold.registry.define(family: family, payload: payload)
    }

    /// The session mark, straight through to the engine that owns what one means. A sink with no
    /// engine answers `false` — no engine, no meter, nothing split.
    ///
    /// Not `combatNow()`: the instant is the caller's, stamped once app-side for the whole click so
    /// that the loot split and this split share one boundary. The fold's own clock here would put
    /// the two halves of one user action at two different instants.
    public func sessionMark(_ at: Int64) -> Bool {
        fold.combat?.sessionMark(at) ?? false
    }

    /// The confirmed sighting, straight through to the module that owns what one means. A registry
    /// with no respawn module answers `false`, the same honest `false` the module itself gives for
    /// a row it does not carry.
    public func confirmSighting(_ rowId: String) -> Bool {
        fold.registry.respawn()?.confirmSighting(rowId) ?? false
    }

    /// The live `/con`s the consider module saw while folding the last drain, each resolved into
    /// the card the overlay draws.
    ///
    /// A line that names nothing is dropped here rather than sent as an empty card — a creature
    /// name that folds to no key has no queue identity — and so is a person. The corpus that
    /// decides that is the same instance the registry was handed, so the card cannot disagree with
    /// a lookup.
    public func takeConCards() -> [JSONValue] {
        fold.registry.takeCons().compactMap { ConCard.card($0, knowledge) }
    }

    /// The module dirty bits: every registered module's published cursor, straight off the registry
    /// and without building a single module's state.
    public func moduleSeqs() -> [(String, Int64)] {
        fold.registry.publishedSeqs()
    }

    /// The alert fires, straight off the registry. The speech fields cross the seam as the plain
    /// map and options they already are: the fold resolved them, and this is a hand-over rather
    /// than a decision.
    public func takeFires() -> [Fire] {
        fold.registry.takeFires()
    }

    /// One call through to the engine, at the instant this fold is entitled to.
    ///
    /// The roster is pulled from the registry, exactly as the fold pulls it on every event.
    /// Anywhere else would be a second answer to "who am I grouped with" beside the one the meter's
    /// rows were attributed under, and the scope chip and the rows it filters must not disagree.
    public func combatSnapshot(_ opts: CombatOpts) -> CombatSnapshot? {
        guard let engine = fold.combat else { return nil }
        let now = combatNow()
        return CombatSnapshot(now: now,
                              state: engine.snapshot(now: now,
                                                     opts: snapshotOpts(opts),
                                                     roster: fold.registry.roster()))
    }

    /// The fight search. The corpus is the engine's — uncapped history plus the open fight, through
    /// its own door rather than through a snapshot — and the ranking is `Search`.
    public func searchFights(_ query: String, _ limit: Int) -> FightSearch? {
        guard let engine = fold.combat else { return nil }
        let corpus = engine.fightSummaries(now: combatNow())
        return FightSearch(
            hits: Search.search(corpus, query, limit).map { FightHit(summary: $0.summary, score: $0.score) },
            // The corpus is counted before the query is looked at, which is what makes an empty
            // query answer `{ hits: [], corpus: n }` rather than `corpus: 0`. A UI saying
            // "search 1,428 fights" in an empty box is reading this number.
            corpus: Int64(corpus.count))
    }

    /// What you have looted off one creature — the half of a `knowledge.mob` answer that only a
    /// fold can give, read through the module's own pull seam.
    ///
    /// It is on the sink rather than on the corpus because the two halves have different lifetimes:
    /// the catalog is committed data that outlives every generation, and this is character- and
    /// epoch-scoped state the consider module clears on a rebirth.
    ///
    /// A build with no consider module answers with no rows — the same value a creature nothing has
    /// been looted from answers with, so neither is a special case.
    public func ownLootDrops(_ spellings: [String]) -> [SeenDrop] {
        fold.registry.ownLoot()?.dropsAcross(spellings) ?? []
    }

    /// How old these creatures are, read through the resist module's own pull seam exactly as
    /// `ownLootDrops` reads the consider module's.
    ///
    /// The key is folded here and not by the caller: a pre-folded key on the wire would be a second
    /// opinion about a join key. The consider module's `mobKey` is the one spelling rule this
    /// engine has, so the app sends the name the log printed and this line files it the way a
    /// `/con` is filed.
    ///
    /// A creature with no level produces no row rather than a row full of nulls — the absence IS
    /// the answer.
    public func mobLevels(_ names: [String]) -> [(String, MobLevelFact)] {
        guard let resist = fold.registry.resist() else { return [] }
        return names.compactMap { name in
            resist.levelOf(mobKey(name), name).map { (name, $0) }
        }
    }

    /// The names this fold's own probes could not answer — drained at the ingest's boundary and
    /// announced connection-wide, exactly as `takeFires` is.
    ///
    /// It is the corpus's ledger, not the fold's: a miss made by a `knowledge.item` op on a
    /// caller's thread lands in the same place, which is why each name is announced once for the
    /// engine rather than once per asker.
    public func takeKnowledgeMisses() -> [KnowledgeMiss] {
        knowledge.takeMisses()
    }

    /// The change signal per source. Cheap by contract — a counter read, never a serialization.
    ///
    /// Three of these are coarse. `loot`, `respawn` and `buffTimers` keep real revision counters
    /// that move only when their state could have; `buffs`, `progression` and `eventFeed` do not,
    /// so they report the fold's own seq, which moves on every event. That never misses a change
    /// and over-reports, costing a re-cut per serve beat on a busy tail; the fix is the counters,
    /// not a cache.
    ///
    /// `timers.rows` takes the max of its two inputs, the only honest answer for a source folded
    /// from two modules: either moving could move the window.
    public func sourceRevision(_ source: SourceDef) -> UInt64? {
        let registry = fold.registry
        func signal(_ seq: Int64) -> UInt64 { seq < 0 ? 0 : UInt64(seq) }
        switch source.id {
        case Views.Loot.ledger.id:
            return registry.loot().map { $0.revision() }
        case Views.Buffs.active.id:
            return registry.buffs().map { signal($0.revision()) }
        case Views.Timers.rowsSource.id:
            guard let buffs = registry.buffs(), let timers = registry.buffTimers() else { return nil }
            return max(signal(buffs.revision()), signal(timers.revision()))
        case Views.Respawn.watches.id:
            return registry.respawn().map { signal($0.revision()) }
        case Views.Kills.recent.id, Views.Progression.recent.id:
            return registry.progression().map { signal($0.revision()) }
        case Views.EventFeed.recent.id:
            return registry.eventFeed().map { signal($0.revision()) }
        // No counter to read, and that is honest rather than a gap: every damage, miss, resist,
        // heal, charm and zone line moves some row of the meter, so "when could this have changed"
        // IS "did an event land". The event count answers that and is monotonic.
        //
        // The beats are added because the rows are a function of `now` too — a live fight's
        // `durationSec` grows while the log is quiet. The sum of two monotonic counters cannot
        // repeat across a change, so a quiet live meter re-cuts once a second and an idle
        // historical one never re-cuts at all.
        case Views.Combat.live.id:
            guard fold.combat != nil else { return nil }
            return fold.events &+ beats
        default:
            return nil
        }
    }
}

/// The combat engine one attach folds into.
///
/// `reset()` then `setPlayerName` before the builder, because `withCombat` resets what it is given
/// and the engine's own reset re-seeds an injected name by itself. The name comes off the log's own
/// file name, the same fact the parser derives its character from.
func combatFor(_ inputs: SinkInputs) -> CombatEngine {
    let engine = CombatEngine()
    engine.reset()
    if let name = inputs.character { engine.setPlayerName(name) }
    return engine
}

/// `ClusterDeps`, assembled, and the one place `installKnowledge` is called.
///
/// That is structural rather than conventional: `registered()` — which the parity runner and every
/// fold test call — cannot reach a corpus, because `EQFold` cannot name the module that holds one.
/// So the world the goldens were recorded in is still exactly what those callers build.
///
/// A production fold differs from that world only on the live tail: both knowledge probes sit
/// behind the `live` gate, so a historical fold with a corpus installed is byte-for-byte the same
/// fold as one without.
func registryFor(_ inputs: SinkInputs, _ launchMs: Int64) -> Registry {
    let registry = registered(clusterDeps(inputs, launchMs))
    registry.installKnowledge(corpus())
    return registry
}

/// The deps themselves. Split from `registryFor` so the install above reads as the one extra act it
/// is, rather than hiding at the bottom of a struct literal.
func clusterDeps(_ inputs: SinkInputs, _ launchMs: Int64) -> ClusterDeps {
    var deps = ClusterDeps()
    // Committed data, read off the parser's own catalog — the same database the parser emits
    // `candidates` out of, never a second load: two loads is two answers waiting to disagree after
    // an overlay change.
    if let db = inputs.db {
        deps.knownSpell = Set(db.keys())
        deps.spellClasses = spellClassIndex(db)
        deps.facts = SpellFacts.project(db)
    }
    deps.launchMs = launchMs
    deps.constructionNowMs = inputs.attachedAtMs
    // The identity the log's own file name states. A name that carries no server is the honest
    // outcome, and it becomes an empty string.
    if let name = inputs.character {
        deps.character = ["name": .string(name),
                          "server": .string(Ingest.serverOf(inputs.log) ?? ""),
                          "logPath": .string(inputs.log.path)]
    }
    // App knowledge is empty at construction and pushed afterwards: the ingest applies every held
    // define before the first byte is folded, so a world the app has spoken to differs from this
    // one by exactly those pushes. They arrive through the modules' own `Defines` seam rather than
    // through this struct, because a define also has to be answerable mid-fold and a construction
    // parameter cannot be.
    //
    // `selfName` is not one of the pushed families and stays nil, which is what the bench world and
    // every golden recorded.
    deps.selfName = nil
    deps.respawnPrefs = RespawnPrefs()
    return deps
}

/// Which bucket this fold's observations are filed under: `` `${name}_${server}`.toLowerCase() ``
/// and nothing else.
///
/// It must be the app's spelling character for character. The key is what a re-fold matches on to
/// REPLACE a bucket rather than add to it, so a different spelling would leave two buckets in one
/// register holding the same log's observations, and the app-side reader would sum both.
///
/// A log whose file name states no character falls back to the module's own constructed default,
/// `log`: a fold that cannot say whose log it is cannot file its counts under a character.
func sourceKey(_ inputs: SinkInputs) -> String {
    guard let name = inputs.character else { return "log" }
    let server = Ingest.serverOf(inputs.log) ?? ""
    return "\(name)_\(server)".lowercased()
}

/// The ingest's opts, in the fold's vocabulary. The one place the two spellings meet.
func snapshotOpts(_ opts: CombatOpts) -> SnapshotOpts {
    SnapshotOpts(selectedId: opts.selectedId,
                 showUnparsed: opts.showUnparsed,
                 maxSegments: opts.maxSegments,
                 timeline: opts.timeline,
                 digest: opts.digest,
                 targets: opts.targets)
}
