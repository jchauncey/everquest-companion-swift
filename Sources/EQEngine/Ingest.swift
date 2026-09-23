// One fold thread per attach: open the log, scan it at full speed, then tail it live, handing every
// event to one `EventSink`. Port of engined/src/ingest.rs.
//
// `EQLog` owns what an event is; this file owns who is folding, when it stops, and what it says
// about itself.
//
// An attach preempts any in-flight attach — last pick wins, losers are dropped rather than queued
// and return silently at their next slice boundary. Each attach builds its own sink and its own
// parser, so two folds can never reach one set of modules.
//
// Nothing event-derived reads a wall clock. Exactly two wall-clock reads reach a sink:
// `SinkInputs.attachedAtMs`, once per attach, and `EventSink.tick`, ~1×/sec and live only. The
// historical scan never ticks — the tick loop lives past the `TailStart.at` handoff, which is what
// keeps a replay a pure function of its bytes.
import Foundation
import Darwin
import EQCompanionCore
import EQFold
import EQLog

/// The prefix every diagnostic this engine writes carries. The Rust process printed these to
/// stderr; in-process they are the same sentences on the same channel.
public let diagnosticPrefix = "[engine]"

/// Where diagnostics go when the host wants them somewhere other than stderr (the app files them
/// in its client log). Set once at boot; read on the ingest thread.
public var diagnosticSink: (@Sendable (String) -> Void)?

/// Say something about the engine's own workings. Never on the answer path: a diagnostic is what
/// the engine says about itself, and no client reads one.
public func diagnostic(_ line: String) {
    if let sink = diagnosticSink { sink("\(diagnosticPrefix) \(line)"); return }
    FileHandle.standardError.write(Data("\(diagnosticPrefix) \(line)\n".utf8))
}

/// The process's monotonic clock — Rust's `Instant`. Named so the ingest, the world and the view
/// meter measure fold-to-frame against one clock rather than three.
public typealias Instant = DispatchTime

/// How many bytes one scan read asks for.
///
/// The scan is deliberately impolite — no yield, no throttle, no slice sleep. The tail keeps
/// `EQLog`'s 256 KiB slicing, which is about EverQuest's synchronous append rather than about this
/// engine's manners.
///
/// A buffer, not a promise: a read may hand back less. It is also the granularity at which the
/// generation is polled and progress may be announced — big enough to amortize a read, small enough
/// that a preempted fold abandons within milliseconds.
let scanReadBytes = 1 << 20

/// The floor between two progress announcements — ~4/s max, never per-line.
///
/// A cadence rather than a count: an events-based cadence would announce a hundred frames a second
/// on a dense raid slice and none at all on a quiet one.
let progressEvery: TimeInterval = 0.250

/// The longest prefix of an event's JSON that is searched for its timestamp. See `tsOf`.
let tsScanBytes = 128

/// The nap the tail loop sleeps in, so a preempted tail notices promptly instead of after a whole
/// poll interval. Mirrors `FileTail.follow`'s own nap.
let tailNap: TimeInterval = 0.025

/// The live world's heartbeat interval — the app's `setInterval(…, 1000)`, exactly. See `Ticking`
/// for why it is a ceiling rather than a schedule.
let tickEvery: TimeInterval = 1.0

// MARK: - The two channel shapes the one door is built from

/// A many-to-one queue drained by `tryRecv` at a boundary the fold already reaches. The Rust's
/// `mpsc::channel` receiver half, with the two properties this loop depends on: it never blocks the
/// fold, and a send onto a closed queue fails rather than accumulating for nobody.
public final class Mailbox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    private var closed = false

    public init() {}

    /// Post. `false` when the receiver has gone — the ingest ended between a copy of this handle
    /// and this send.
    @discardableResult
    public func send(_ value: T) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if closed { return false }
        items.append(value)
        return true
    }

    /// Take the next item, or nil when there is none. Never blocks.
    public func tryRecv() -> T? {
        lock.lock(); defer { lock.unlock() }
        return items.isEmpty ? nil : items.removeFirst()
    }

    /// The receiver is gone. Every later send fails, which is how a reader learns the fold ended
    /// rather than waiting out a deadline for it.
    public func close() {
        lock.lock(); defer { lock.unlock() }
        closed = true
        items.removeAll()
    }
}

/// The way back from the fold: one value, waited for with a deadline. The Rust's answer half of a
/// `channel()` plus its `recv_timeout`.
public final class Answer<T>: @unchecked Sendable {
    private let sem = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var value: T?
    private var sent = false

    public init() {}

    /// Answer. A second send is dropped — the asker took the first.
    public func send(_ v: T) {
        lock.lock()
        if sent { lock.unlock(); return }
        value = v
        sent = true
        lock.unlock()
        sem.signal()
    }

    /// Wait for the answer, or nil when the deadline passed with nobody answering.
    public func recv(timeout: TimeInterval) -> T? {
        if sem.wait(timeout: .now() + timeout) == .timedOut { return nil }
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

// MARK: - The event, and the sink it reaches

/// One folded event, as the ingest hands it to a sink.
///
/// Named `IngestEvent` rather than `Event`: `EQFold.Event` is the fold's own shape and both are in
/// scope here. The Rust's `ingest::Event` is this, field for field.
public struct IngestEvent {
    /// The event, serialized. Byte-identical to the TS pipeline's `JSON.stringify(ev)`.
    ///
    /// Built eagerly even though the fold reads `payload` instead: this is the parser oracle's
    /// byte-identity artifact and the format every golden is recorded in.
    public var json: String
    /// The same event, typed — what the fold reads. Recorded in the same call that serialized
    /// `json`, so the two halves cannot disagree about what the parser said.
    public var payload: Payload
    /// The event's sequence number. Counts events, not lines, and starts at 0 for each attach.
    public var seq: Int64
    /// `false` for the historical scan, `true` for the live tail. A property of the source, not of
    /// the line.
    public var live: Bool

    public init(json: String, payload: Payload, seq: Int64, live: Bool) {
        self.json = json; self.payload = payload; self.seq = seq; self.live = live
    }
}

/// One module's published state, exactly as a module publishes it.
public struct ModuleSnapshot: Equatable {
    /// The module's own seq — for most modules the seq of the last event it folded, and for the
    /// four that publish a private revision counter, that counter. A hydration cursor, never the
    /// fold's event count.
    public var seq: Int64
    /// The module's state. The shape is the module's, not this layer's and not the protocol's.
    public var state: JSONValue

    public init(seq: Int64, state: JSONValue) { self.seq = seq; self.state = state }
}

/// What a combat snapshot was asked for — the app's `SnapshotOpts`, in the ingest's vocabulary.
///
/// A second spelling of one idea: this layer must not learn what a fold is, and the op table must
/// not learn what the fold's types are called. The op table validates and clamps; this carries;
/// `FoldSink` converts.
public struct CombatOpts: Equatable {
    /// Which fight or zone session to resolve the selection against, or nil for the default.
    public var selectedId: String?
    /// Include lines the engine could not classify.
    public var showUnparsed: Bool
    /// Cap on finalized-fight summaries. A payload bound, never a retention one.
    public var maxSegments: Int
    /// Include the selected encounter's event timeline.
    public var timeline: Bool

    public init(selectedId: String? = nil, showUnparsed: Bool = false,
                maxSegments: Int = 0, timeline: Bool = false) {
        self.selectedId = selectedId; self.showUnparsed = showUnparsed
        self.maxSegments = maxSegments; self.timeline = timeline
    }
}

/// The combat engine's snapshot, and the instant it describes.
///
/// The pair rather than the state alone, because `now` is not recoverable from the payload and the
/// whole answer is a function of it.
public struct CombatSnapshot: Equatable {
    /// The instant the snapshot was taken at, in epoch millis.
    public var now: Int64
    /// The snapshot. The shape is the engine's — nothing between the fold and the wire has an
    /// opinion about it.
    public var state: JSONValue

    public init(now: Int64, state: JSONValue) { self.now = now; self.state = state }
}

/// One ranked fight.
public struct FightHit: Equatable {
    /// The `SegmentSummary`, exactly as the fold published it.
    public var summary: JSONValue
    /// 0..1 relevance.
    public var score: Double

    public init(summary: JSONValue, score: Double) { self.summary = summary; self.score = score }
}

/// What a fight search found, and how much it looked through.
public struct FightSearch: Equatable {
    /// The ranked hits, already capped by the caller's limit.
    public var hits: [FightHit]
    /// How many fights were searched — present even when nothing matched, because "no matches in
    /// 1,428" and "nothing to search" are different sentences.
    public var corpus: Int64

    public init(hits: [FightHit], corpus: Int64) { self.hits = hits; self.corpus = corpus }
}

/// One alert fire, as the ingest hands it to the world.
///
/// The fold's own shape rather than a third spelling of it: `EQFold.Fire` already carries exactly
/// the seven fields the Rust's `ingest::Fire` renames, and a second identical struct in this module
/// would be a conversion that decides nothing.
public typealias Fire = EQFold.Fire

/// What a sink volunteers about itself.
public struct SinkReport: Equatable {
    /// Events this sink has taken.
    public var events: Int64 = 0
    /// How many of them arrived live. The split between "this came out of history" and "this is
    /// happening now" is the one a loading UI and a bug report both want.
    public var liveEvents: Int64 = 0
    /// The `seq` of the last event taken. Reported rather than derived from `events`: they are the
    /// same number only for a sink that keeps everything.
    public var lastSeq: Int64?
    /// The `ts` of the last event taken — the log's own clock, never the host's.
    public var lastTs: Int64?

    public init(events: Int64 = 0, liveEvents: Int64 = 0, lastSeq: Int64? = nil, lastTs: Int64? = nil) {
        self.events = events; self.liveEvents = liveEvents; self.lastSeq = lastSeq; self.lastTs = lastTs
    }
}

/// Where ingest ends. The fold seam: one protocol, events in, state out.
///
/// `FoldSink` implements it. It is built on the fold thread and never crosses a thread boundary —
/// stated by the call graph rather than by the type, since a Swift class carries no `!Send`.
public protocol EventSink: AnyObject {
    /// One event, in emission order. Called once per event, on the fold thread, and on no other.
    func event(_ event: IngestEvent)

    /// The live heartbeat: the wall clock, in epoch millis, handed to the fold ~1×/sec.
    ///
    /// Called only while the status is `live`. A replay whose output depended on when it was run
    /// would break the equivalence oracle. The one driver is the tail loop, past the `TailStart.at`
    /// handoff.
    func tick(_ nowMs: Int64)

    /// What this sink can say about itself.
    func report() -> SinkReport

    /// One module's published state, or nil when this sink folds no module by that name.
    ///
    /// A read: a snapshot that could advance the fold would make the answer depend on who asked.
    /// nil becomes the protocol's `notFound` — the registry is the authority, and an empty state
    /// would be a lie about a module that does not exist.
    func snapshot(_ module: String) -> ModuleSnapshot?

    /// Every row of one view source, in its natural order — the view layer's door onto this fold.
    /// nil for a source this sink does not carry, which is not an error: a subscription over a sink
    /// that folds no modules gets an honest empty window.
    func sourceRows(_ source: SourceDef) -> [SourceRow]?

    /// Take one family of app knowledge — the `*.define` commands.
    ///
    /// `true` when a module took it. `false` is not an error: the world still holds the push, and
    /// the next attach that builds a real fold applies it at construction.
    func define(_ family: String, _ payload: JSONValue) -> Bool

    /// Take a session mark. `true` when the combat engine took it — a sink with no engine has no
    /// fight to close, the same honest `false` a hydrating engine answers.
    func sessionMark(_ at: Int64) -> Bool

    /// Confirm a sighting. `true` when the fold re-based that row's clock onto the log's last
    /// sighting; `false` covers no respawn module, an unknown id and a row not currently seen.
    func confirmSighting(_ rowId: String) -> Bool

    /// The alert fires this sink produced since the last drain. Structurally empty for a historical
    /// scan: firing is live-only, gated where the app gates it.
    func takeFires() -> [Fire]

    /// The con cards this sink resolved since the last drain. Structurally empty for a historical
    /// scan on `takeFires`'s terms: a card is a thing that happens, and a startup replay of a month
    /// of logs must draw none.
    func takeConCards() -> [JSONValue]

    /// Every module's published cursor — the module dirty bit's whole read.
    ///
    /// Cheap by contract: a counter per module, never a serialization.
    func moduleSeqs() -> [(String, Int64)]

    /// The combat engine's whole snapshot, and the instant it was taken at. nil when this sink
    /// folds no combat engine, which the world turns into `unavailable`.
    ///
    /// Not "nothing moved" once the tail is live: the engine ages its model at the instant taken —
    /// charm sweep, ally-bind expiry, pet nudge, deferred encounter closure. While the scan runs
    /// the sweeps are unreachable.
    func combatSnapshot(_ opts: CombatOpts) -> CombatSnapshot?

    /// The fight-history search. nil on `combatSnapshot`'s terms.
    func searchFights(_ query: String, _ limit: Int) -> FightSearch?

    /// The names the fold's own knowledge probes could not answer, drained here and announced
    /// connection-wide as `knowledgeMiss` frames.
    func takeKnowledgeMisses() -> [KnowledgeMiss]

    /// What you have looted off one creature, for a `knowledge.mob` answer.
    func ownLootDrops(_ spellings: [String]) -> [SeenDrop]

    /// How old these creatures are, as the resist fold knows it. A sink with no resist module
    /// answers with no rows — the same value a creature the catalog has never heard of answers
    /// with, so neither is a special case.
    func mobLevels(_ names: [String]) -> [(String, MobLevelFact)]

    /// The fold is being replaced. The one hook the Rust process had no need for — its engine died
    /// with the app — and an in-process engine's attach preempts a fold that may hold state nobody
    /// has written yet. Defaulted to nothing: a sink with no disk has nothing to close.
    func detach()

    /// A monotonic signal that moves whenever `source` could have changed.
    ///
    /// The view layer's whole cost model rests on this: a subscription is re-cut only when its
    /// source's revision has moved since the window it holds was built. It must be cheap (a counter
    /// read, never a serialization) and honest — a signal that could repeat across a change would
    /// let a stale window stand.
    func sourceRevision(_ source: SourceDef) -> UInt64?
}

public extension EventSink {
    func tick(_ nowMs: Int64) {}
    func report() -> SinkReport { SinkReport() }
    func snapshot(_ module: String) -> ModuleSnapshot? { nil }
    func sourceRows(_ source: SourceDef) -> [SourceRow]? { nil }
    func define(_ family: String, _ payload: JSONValue) -> Bool { false }
    func sessionMark(_ at: Int64) -> Bool { false }
    func confirmSighting(_ rowId: String) -> Bool { false }
    func takeFires() -> [Fire] { [] }
    func takeConCards() -> [JSONValue] { [] }
    func moduleSeqs() -> [(String, Int64)] { [] }
    func combatSnapshot(_ opts: CombatOpts) -> CombatSnapshot? { nil }
    func searchFights(_ query: String, _ limit: Int) -> FightSearch? { nil }
    func takeKnowledgeMisses() -> [KnowledgeMiss] { [] }
    func ownLootDrops(_ spellings: [String]) -> [SeenDrop] { [] }
    func mobLevels(_ names: [String]) -> [(String, MobLevelFact)] { [] }
    func sourceRevision(_ source: SourceDef) -> UInt64? { nil }
    func detach() {}
}

/// The view layer's `Rows`, over whatever sink this attach is folding into.
///
/// Built per pass and dropped with it: the sink lives on the fold thread and this is only the shape
/// the world asks it questions in.
public struct SinkRows: ViewRows {
    let sink: EventSink
    public init(_ sink: EventSink) { self.sink = sink }
    public func rows(_ source: SourceDef) -> [SourceRow]? { sink.sourceRows(source) }
    public func revision(_ source: SourceDef) -> UInt64? { sink.sourceRevision(source) }
}

/// The honest floor under a fold: a counter, and nothing else. `session.health` can say how much has
/// been folded and how far into the log's own time it reached without any module existing yet.
public final class CountingSink: EventSink {
    private var events: Int64 = 0
    private var liveEvents: Int64 = 0
    private var lastSeq: Int64?
    private var lastTs: Int64?

    public init() {}

    public func event(_ event: IngestEvent) {
        events += 1
        if event.live { liveEvents += 1 }
        lastSeq = event.seq
        // A stamp that cannot be read is not a zero: the last one that could be read stands, which
        // keeps `lastTs` monotonic over a log holding a line the timestamp pattern declines.
        if let ts = tsOf(event.json) { lastTs = ts }
    }

    public func report() -> SinkReport {
        SinkReport(events: events, liveEvents: liveEvents, lastSeq: lastSeq, lastTs: lastTs)
    }
}

// MARK: - The one door: reads on `Ask`, writes on `Write`

/// One request for one module's state, and the way back.
///
/// A queue and not a lock, which is the load-bearing rule of this seam. A locked fold would make
/// the fold's hot loop take a lock per event to serve a reader that asks a few times a minute, and
/// a snapshot copy published after every event is a cache. So the reader posts and waits, and the
/// ingest answers between two reads of the scan or two polls of the tail — never shared, never
/// locked, never interrupted mid-event, so the answer is a real prefix state.
public final class SnapshotAsk {
    /// The module id the client named.
    public let module: String
    /// Where the answer goes. nil means the sink folds no such module.
    public let answer = Answer<ModuleSnapshot?>()
    public init(module: String) { self.module = module }
}

/// One request for the combat engine's snapshot.
public final class CombatAsk {
    /// What the caller asked for, already validated and clamped by the op table.
    public let opts: CombatOpts
    /// Where the answer goes. nil means this fold carries no combat engine.
    public let answer = Answer<CombatSnapshot?>()
    public init(opts: CombatOpts) { self.opts = opts }
}

/// One fight-history search — the one ask on this door that is user-initiated.
public final class FightSearchAsk {
    public let query: String
    /// How many ranked hits to return, already clamped by the op table.
    public let limit: Int
    public let answer = Answer<FightSearch?>()
    public init(query: String, limit: Int) { self.query = query; self.limit = limit }
}

/// One request for the own-loot half of a mob answer.
///
/// The answer is never nil: a fold with no such index and a creature nothing has been looted from
/// both answer with no rows, which is the same sentence and deserves the same value.
public final class LootAsk {
    /// Every `mobKey` the creature answers to, canonical first — the corpus resolved them.
    public let spellings: [String]
    public let answer = Answer<[SeenDrop]>()
    public init(spellings: [String]) { self.spellings = spellings }
}

/// One `resist.levels` question.
///
/// The answer is session state: a `/con` the player typed thirty seconds ago beats the committed
/// catalog, and that statement lives inside the resist fold on this thread.
public final class MobLevelAsk {
    /// The creature names to answer for, as the asker spelled them.
    public let names: [String]
    /// Where the answer goes: the echoed name beside the fact, and no entry for a creature the fold
    /// can state nothing about. A short list is the honest answer rather than a padded one.
    public let answer = Answer<[(String, MobLevelFact)]>()
    public init(names: [String]) { self.names = names }
}

/// One request for the ingest's own cost.
///
/// The answer is never nil: an ingest that has served nothing still has an honest answer, which is
/// a different sentence from the `unavailable` a world with no fold at all gives.
public final class PerfAsk {
    public let answer = Answer<EnginePerf>()
    public init() {}
}

/// Every question the one door carries. Adding a reader means adding a case here and nowhere else.
///
/// One queue rather than one per question: the fold is asked at a boundary it already reaches, and
/// a second queue would be a second place the fold loop has to remember to drain — which is how one
/// ends up drained only during the tail.
public enum Ask {
    case module(SnapshotAsk)
    case perf(PerfAsk)
    case combat(CombatAsk)
    case fights(FightSearchAsk)
    case loot(LootAsk)
    case mobLevels(MobLevelAsk)
}

/// One push of app knowledge, and the way back.
///
/// The fold lives on the fold thread and a `*.define` arrives on a caller's. A shared, locked fold
/// would put a second owner on state whose whole design is one door; a copy applied later would
/// make the moment a define takes effect unknowable. So the writer posts and waits, and the ingest
/// applies it at a boundary it reaches.
///
/// The wait is what makes the ack mean something: `applied: true` says the live fold has this set,
/// not that a queue accepted it.
public final class DefineAsk {
    /// The family: `alerts`, `buffTrust`, `respawn`, `combo`, `roster`.
    public let family: String
    /// The whole set, as the app pushed it.
    public let payload: JSONValue
    /// Where the answer goes: `true` when a module took it.
    public let answer = Answer<Bool>()
    public init(family: String, payload: JSONValue) { self.family = family; self.payload = payload }
}

/// One session mark, and the way back — its effect on the meter.
///
/// On the write door because of what it does: a mark closes the open fight and freezes the running
/// stay.
public final class MarkAsk {
    /// The instant the caller stamped for the whole click, so the loot split and this split share
    /// one boundary. Never re-derived here from a host clock.
    public let at: Int64
    /// Where the answer goes: whether the engine took it (false while it is still hydrating).
    public let answer = Answer<Bool>()
    public init(at: Int64) { self.at = at }
}

/// One confirmed sighting, and the way back.
///
/// It carries no instant, which is the one place it differs from `MarkAsk`. A mark's subject is an
/// instant; a confirmation's subject is a row, and the instant it re-bases onto is that row's own
/// `seenTs`, a log timestamp this fold already holds.
public final class ConfirmAsk {
    /// The row the person pressed — `<zone key>::<mob key>`.
    public let rowId: String
    /// Where the answer goes: whether a clock actually moved.
    public let answer = Answer<Bool>()
    public init(rowId: String) { self.rowId = rowId }
}

/// Every statement made *to* the fold — the write door, the mirror image of `Ask`.
///
/// A case here may move the world; a case on `Ask` may only read. One queue for every write, for
/// the reason `Ask` is one queue for every read: the fold is reached at a boundary it already
/// services, and a second queue would be a second thing this loop has to remember to drain in all
/// four places (mid-scan, the live poll, the nap, the landing).
public enum Write {
    case define(DefineAsk)
    case mark(MarkAsk)
    case confirm(ConfirmAsk)
}

// MARK: - What the fold thread says about itself

/// What starting one generation cost, measured rather than modelled.
///
/// Every field is optional and absent means not yet measured. A `scanMs` of zero would say a whole
/// log folded instantly, which is the report of a scan that has not finished rather than of a fast
/// one — the same rule `HealthResult`'s last three fields keep.
public struct IngestCost {
    /// How long the spell catalog took to become available for this attach.
    public var spellDbMs: UInt64?
    /// Wall time from the first byte read to the fold landing.
    public var scanMs: UInt64?
    /// Bytes the scan read, up to the mark it landed on.
    public var scanBytes: UInt64?
    public init() {}
}

/// What the fold thread says about itself: what starting this generation cost, and what serving it
/// has cost since.
public struct EnginePerf {
    /// What building this generation cost.
    public var ingest = IngestCost()
    /// One row per source that has served a frame, ordered by name.
    public var serve: [SourceMeter] = []
    /// The bounded recent history, oldest first — what `perf.timeline` serves.
    ///
    /// It rides the answer `perf.snapshot` already asked for rather than earning a second `Ask`
    /// case: each new door would be another drain on the hot boundary.
    public var timeline: [Moment] = []
    public init() {}
}

// MARK: - Construction

/// Everything an attach knows by the time it could build a fold, handed to the sink factory.
///
/// Exactly the set the parse is a pure function of, plus the one wall-clock instant a world is
/// constructed at. Nothing here is discovered by the engine: the log path came from the app, the
/// character comes off that path's file name, and the catalog is committed data.
public struct SinkInputs {
    /// The log this attach opened.
    public var log: URL
    /// The character whose log it is, off the file name. nil when the name is not a log's.
    public var character: String?
    /// The parser's effective spell catalog — the process's one copy. nil is representable so a
    /// caller can build a sink with no catalog; production never does.
    public var db: SpellDb?
    /// The parser's own clock. Handed over rather than rebuilt, because a fold that resolved its
    /// launch instant through a second zone would answer a different question than the parser's
    /// timestamps ask.
    public var clock: Clock
    /// When this attach happened, in epoch millis — the world's construction clock.
    ///
    /// The one wall-clock read that reaches a sink. It is not fold-derived state, and no module may
    /// read a clock after this.
    public var attachedAtMs: Int64
    /// The app's `userData`, or nil when the attach did not carry one.
    ///
    /// App knowledge: the engine cannot derive it and must not guess it. nil means no persistence
    /// at all — no read, no write, and the file-free fold the equivalence oracle records.
    public var stateDir: URL?

    public init(log: URL, character: String?, db: SpellDb?, clock: Clock,
                attachedAtMs: Int64, stateDir: URL?) {
        self.log = log; self.character = character; self.db = db; self.clock = clock
        self.attachedAtMs = attachedAtMs; self.stateDir = stateDir
    }
}

/// Builds the sink one attach folds into. The construction seam.
public typealias SinkFactory = @Sendable (SinkInputs) -> EventSink

/// What `World` does when an attach is accepted: begin folding this log, under this generation.
///
/// The world holds one of these rather than a sink factory so that what an attach starts is a
/// single injected decision. Production hands it `starter(foldingSinks())`; the world's own unit
/// tests hand it a no-op, which is how the epoch and subscription laws are proven without a fold in
/// the room.
public typealias Starter = @Sendable (World, UInt64, URL, URL?) -> Void

/// The factory a plain engine uses.
public func countingSinks() -> SinkFactory {
    { _ in CountingSink() }
}

/// The starter a real engine uses: one fold thread per attach, folding into `sinks`.
public func starter(_ sinks: @escaping SinkFactory) -> Starter {
    { world, generation, log, stateDir in
        Ingest.start(world: world, generation: generation, log: log, stateDir: stateDir, sinks: sinks)
    }
}

/// The starter `World()` uses — counting sinks, nothing folded.
public func defaultStarter() -> Starter { starter(countingSinks()) }

// MARK: - What the fold thread yields to

/// The scheduling class the fold thread runs at.
///
/// `.utility` puts the fold below the game, so EverQuest gets the processor first whenever both
/// want it; `.userInitiated` competes on equal terms. Set before an attach it decides what the new
/// fold thread starts at; set while a fold is running it reaches that thread at its next slice
/// boundary, because Darwin lets a thread change its own class and nobody else's.
public enum FoldPriority {
    private static let lock = NSLock()
    private static var wanted: QualityOfService = .userInitiated
    private static var applied: QualityOfService?

    /// What the next fold thread starts at, and what a running fold moves to.
    public static var qos: QualityOfService {
        get { lock.lock(); defer { lock.unlock() }; return wanted }
        set { lock.lock(); wanted = newValue; lock.unlock() }
    }

    /// Called by the fold thread on itself, and by nothing else. `force` is the thread's first
    /// call: a thread that has just started has applied nothing, whatever the last one applied.
    static func applyToFoldThread(force: Bool = false) {
        lock.lock()
        let want = wanted
        let stale = force || applied != want
        if stale { applied = want }
        lock.unlock()
        guard stale else { return }
        pthread_set_qos_class_self_np(qosClass(want), 0)
    }

    static func qosClass(_ q: QualityOfService) -> qos_class_t {
        switch q {
        case .userInteractive: return QOS_CLASS_USER_INTERACTIVE
        case .userInitiated: return QOS_CLASS_USER_INITIATED
        case .utility: return QOS_CLASS_UTILITY
        case .background: return QOS_CLASS_BACKGROUND
        default: return QOS_CLASS_DEFAULT
        }
    }
}

// MARK: - The fold thread

public enum Ingest {
    /// How an ingest ended, when it ended without an error.
    enum Ended {
        /// A newer attach took the world. The loser touched nothing and said nothing.
        case preempted
    }

    /// The wall clock, in epoch millis — the engine's one spelling of `Date.now()`.
    ///
    /// Three readers and all three are live-world readers: `SinkInputs.attachedAtMs`, read once per
    /// attach; `Ticking`'s beat, live only; and a combat answer taken while the tail is running.
    /// Nothing a historical fold computes can reach any of them — the scan does not construct, does
    /// not beat, and answers its combat questions at the fold's own `lastTs` instead.
    public static func wallClockMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    /// The character whose log this is, from the file name.
    ///
    /// The name is load-bearing and must be known before the fold starts: the self-`/who` rule and
    /// the pet-leader carve-out both decline every line until it is set. The engine derives it
    /// rather than being told it, because the log's identity and the character's identity are the
    /// same fact, and two ways of stating it is a way for them to disagree.
    ///
    /// Two shapes, both `EQLog`'s: the product's own `eqlog_<Name>_<server>.txt`, and the oracle
    /// corpus's slice form `eqlog_<Name>_<server>.<slice>.txt`. Anything else yields nil, and a
    /// parser with no character is the honest result rather than a guess.
    public static func characterOf(_ log: URL) -> String? {
        Parser.characterOf(log.lastPathComponent)
    }

    /// The server out of a log's file name — the second half of what `characterOf` reads.
    public static func serverOf(_ log: URL) -> String? {
        Parser.serverOf(log.lastPathComponent)
    }

    /// Start one attach's ingest on its own thread.
    ///
    /// A failure to spawn is not a dead engine: the epoch has already been bumped and announced,
    /// and all that is left is to say the world holds no fold, which is what `idle` means.
    public static func start(world: World, generation: UInt64, log: URL,
                             stateDir: URL?, sinks: @escaping SinkFactory) {
        world.ingests.enter()
        let thread = Thread {
            defer { world.ingests.leave() }
            // The class this thread was created at, restated by the thread itself: the setter can
            // only ever change `wanted`, and this is the one place the running fold reads it.
            FoldPriority.applyToFoldThread(force: true)
            // A fold that throws must not take the engine: one bad line costs the fold and nothing
            // else, the same blast-radius rule the world's lock keeps. The epoch is untouched — a
            // fold that died created no new generation, and the client's state is still the one it
            // was told about.
            do {
                _ = try run(world: world, generation: generation, log: log,
                            stateDir: stateDir, sinks: sinks)
            } catch {
                diagnostic("the ingest of \(log.path) ended: \(error)")
                _ = world.reportIdle(generation)
            }
        }
        thread.name = "eqengine-ingest"
        thread.stackSize = 4 << 20
        thread.qualityOfService = FoldPriority.qos
        thread.start()
    }

    /// Open the log, fold its history, then follow it. Returns when this turn no longer owns the
    /// world.
    static func run(world: World, generation: UInt64, log: URL,
                    stateDir: URL?, sinks: @escaping SinkFactory) throws -> Ended {
        // Attaching is exactly "opening the file and building what a fold depends on" — the spell
        // DB, the character and the registry. Nothing is folded until all of it exists, and the
        // whole of it happens inside this window.
        if !world.reportStatus(generation, .attaching) { return .preempted }

        let character = characterOf(log)
        if character == nil {
            diagnostic("no character name in \(log.path); the self-referential rules will decline "
                       + "every line")
        }
        // One spell DB per process: it is a pure function of committed data, so `SpellDb.shared()`
        // is the process's one copy and the second attach of a session pays ~0 ms. Measured and
        // printed rather than assumed.
        let building = Instant.now()
        let db = SpellDb.shared()
        let spellDbMs = elapsedMs(since: building)
        diagnostic("ingest: spell db ready in \(spellDbMs) ms")

        // What this generation has cost, from before the first byte. `Serving` is built here rather
        // than at the fold landing because it is also the answer to `perf.snapshot`, and a door
        // that opens before the scan must have something behind it during the scan.
        let serving = Serving()
        serving.cost.spellDbMs = spellDbMs

        // The parser derives its character from the FILE NAME and its zone from the host.
        let parser = character.map { Parser.forCharacter($0, clock: Clock.host()) }
            ?? Parser(clock: Clock.host(), db: db, character: nil)

        // The sink is built here, on this thread, and after the catalog exists. It is handed the
        // parser's own clock rather than a second one built from the same zone, so a fold resolving
        // a local-time anchor cannot drift from the timestamps it will compare against.
        // `attachedAtMs` is read once, now, because now is when this world was constructed.
        let sink = sinks(SinkInputs(log: log, character: character, db: db, clock: parser.clock,
                                    attachedAtMs: wallClockMs(), stateDir: stateDir))

        let fd = open(log.path, O_RDONLY)
        if fd < 0 { throw TailIOError(errno) }
        defer { close(fd) }
        var st = stat()
        if fstat(fd, &st) != 0 { throw TailIOError(errno) }
        let size = UInt64(st.st_size)

        // The checkpoint, BEFORE the defines: a restore resets the world, so defines applied first
        // would be wiped. Restored-then-defined is also the honest order — the checkpoint carries
        // the defines as they stood when it was cut, and the app's re-push lands on top exactly
        // like any define push a running engine takes mid-scan.
        var resumed: FoldCheckpointStore.Resume?
        if let dir = stateDir, let foldSink = sink as? FoldSink {
            switch FoldCheckpointStore.tryResume(dir: dir, log: log, fd: fd, size: size, sink: foldSink) {
            case .success(let r):
                resumed = r
                diagnostic("checkpoint: resumed \(r.events) events at mark \(r.mark) of \(size); "
                           + "parsing only the tail")
            case .failure(let why):
                diagnostic("checkpoint: full scan (\(why))")
            }
        }

        if !world.reportStatus(generation, .folding) { return .preempted }

        // The snapshot door opens before the first byte is folded, so `module.snapshot` can be
        // asked during the scan and answered with a real prefix state. Installed through a
        // `report*` method like every other statement an ingest makes, so a turn that has already
        // lost installs nothing.
        let answers = Mailbox<Ask>()
        if !world.serveAsks(generation, answers) { return .preempted }

        // …and so does the define door, at the same instant: a preference the user changes while a
        // 200 MB log is folding must reach the fold that is folding it, not the next one. A second
        // queue rather than a second case on the first, because the two carry opposite directions
        // and share nothing but the boundary they are serviced at.
        let writes = Mailbox<Write>()
        guard let held = world.serveWrites(generation, writes) else { return .preempted }

        // App knowledge, applied before the first byte. A `*.define` pushed before this attach — an
        // ordinary launch, since the app pushes all five on connect and attaches afterwards — is
        // held by the world and applied here, at construction. Alert defs, buff trust, respawn
        // watches, combo corrections and roster edits all change what a fold produces, so taking
        // them after the historical scan would fold the log twice into two different answers.
        //
        // The copy comes from `serveWrites`, taken with the door installed: read any earlier and a
        // define pushed in between is recorded by the world but reaches no fold of this generation.
        for (family, payload) in held {
            _ = sink.define(family, payload)
        }

        // Whatever this fold owns gets one last chance to reach the disk, and both doors close so
        // a reader learns the fold has ended rather than waiting out a deadline for it. On every way
        // out from here — a lost turn and a thrown read error alike.
        defer {
            sink.detach()
            answers.close()
            writes.close()
        }

        // The scan: the whole file, at full speed. The line splitting is `TailCore`'s rather than
        // `Scan.bytes`'s, and the two are the same law — a tail's line sequence equals the scan's
        // over any chunking at all. The chunked one buys three things the whole-file one cannot: a
        // 200 MB log is never a 200 MB allocation, the read cursor is a live measurement to report
        // progress from, and every read boundary is a place to ask who owns the world.
        // At the resumed mark when there is one — the fd is seeked to the exact byte the
        // checkpointed fold stopped at, and `seq` continues where it stopped, because views key
        // rows by their position in the append-only event array.
        let startMark = resumed?.mark ?? 0
        if startMark > 0, lseek(fd, off_t(startMark), SEEK_SET) < 0 { throw TailIOError(errno) }
        var core = TailCore.at(startMark)
        let ev = Ev()
        var seq: Int64 = resumed?.seq ?? 0
        var buf = [UInt8](repeating: 0, count: scanReadBytes)
        let cadence = Cadence(every: progressEvery)
        let scanning = Instant.now()
        while true {
            var got = 0
            try buf.withUnsafeMutableBytes { raw in
                let n = Foundation.read(fd, raw.baseAddress!, raw.count)
                if n < 0 { throw TailIOError(errno) }
                got = n
            }
            if got == 0 { break }
            buf.withUnsafeBytes { raw in
                core.consume(UnsafeRawBufferPointer(rebasing: raw[..<got])) { line in
                    if parser.parseEvent(line, seq: seq, into: ev) {
                        sink.event(IngestEvent(json: ev.finish(), payload: ev.payload,
                                               seq: seq, live: false))
                        seq += 1
                    }
                }
            }
            // The slice boundary, where every one of this loop's outward-facing acts happens: the
            // generation poll, at most one progress frame per cadence, and whatever was asked for
            // while the last megabyte was folding. The order is deliberate — a turn that has lost
            // answers nobody, including a reader that is waiting.
            if !world.owns(generation) { return .preempted }
            if cadence.due(),
               !world.reportProgress(generation, mark(core, size, seq, sink)) {
                return .preempted
            }
            answerAsks(answers, sink, serving)
            // A define mid-scan is taken mid-scan and the fold does not restart for it. That is the
            // honest reading of a full-set replace: it is a fact about the world from here on, and
            // the events already folded were folded under what the user had said at the time.
            answerWrites(writes, sink)
        }

        // The final measurement is not optional and does not ask the cadence. It is the one frame
        // that states the whole fold — `pct` at its ceiling and the exact event count — and a
        // client whose loading bar depends on it must never lose it to a fold that finished inside
        // one interval.
        let landed = mark(core, size, seq, sink)
        let landedAt = Instant.now()
        // The scan's own bill, closed at the instant it landed. `readOffset` rather than the file's
        // size at open: the file may have grown under the scan, and this measurement is about the
        // bytes this fold actually read.
        serving.cost.scanMs = elapsedMs(since: scanning)
        serving.cost.scanBytes = core.readOffset
        if !world.reportProgress(generation, landed) { return .preempted }

        // The fold lands. The handoff is the scan's end offset → `TailStart.at`: the tail picks up
        // at the end of the last complete line the scan folded, so bytes appended during the scan
        // are read rather than skipped and none are read twice. The landing is a reset per open
        // subscription, carrying rows; `landedAt` is the instant the scan finished, so the first
        // frame of a generation reports the honest fold-to-frame cost.
        //
        // One tick before the cadence, ordered BEFORE `reportFoldLanded` on purpose. That call
        // publishes `status: "live"`, which is the edge every client waits on, so ticking
        // afterwards would leave a window in which the engine served a world the app had already
        // swept.
        let ticking = Ticking()
        ticking.beat(sink)
        if !world.reportFoldLanded(generation, landed, SinkRows(sink), landedAt, serving.meter) {
            return .preempted
        }

        // The checkpoint saver. At the landing and then every `checkpointEvery` of live tailing;
        // never on preemption, because a preempted fold's one duty is to get out of the winner's
        // way within milliseconds and an encode is not that. The 5-minute cadence bounds what a
        // crash or a quit can cost to that much catch-up parsing.
        var lastCheckpointSeq: Int64 = resumed?.seq ?? -1
        var lastCheckpointAt = Instant.now()
        func saveCheckpoint(mark: UInt64) {
            guard let dir = stateDir, let foldSink = sink as? FoldSink,
                  seq != lastCheckpointSeq, let worldBlob = foldSink.checkpointWorld() else { return }
            FoldCheckpointStore.save(dir: dir, log: log, fd: fd, mark: mark, seq: seq,
                                     world: worldBlob, events: UInt64(max(0, foldSink.report().events)))
            lastCheckpointSeq = seq
            lastCheckpointAt = Instant.now()
        }
        saveCheckpoint(mark: landed.checkpoint)
        // Read back through the one door: this diagnostic states the world's copy of the coordinate
        // rather than the ingest's local one, so a mark the world failed to record cannot print as
        // if it had.
        let recorded = world.mark()
        diagnostic("fold landed: \(recorded.events) events, mark \(recorded.checkpoint) of "
                   + "\((recorded.log ?? log).path), now live")
        // …and beside it, what serving every open window off that fold cost. Forced rather than
        // left to the meter's cadence: a session quiet enough never to reach the cadence would
        // otherwise never report the one pass it did make.
        serving.say(true)
        let tail = FileTail(log, .at(landed.checkpoint))

        // The tail: live, until something newer takes the world. `announced` is what has been
        // announced, not what has been folded — the cadence may defer a frame but must never drop
        // one, because an event whose arrival was announced by nobody is an event the client cannot
        // know about at all.
        var announced = seq
        while true {
            if !world.owns(generation) { return .preempted }
            let before = seq
            var pollError: Error?
            do {
                _ = try tail.poll { line in
                    if parser.parseEvent(line, seq: seq, into: ev) {
                        sink.event(IngestEvent(json: ev.finish(), payload: ev.payload,
                                               seq: seq, live: tailLive))
                        seq += 1
                    }
                }
            } catch {
                pollError = error
            }
            // When the fold produced what the next frame will report. Read once, at the end of the
            // drain that produced it — the origin of the fold-to-frame measurement, and the one
            // number that cannot be recovered later. A drain that folded nothing sets nothing, so a
            // frame with no fold behind it is not timed against the age of the session.
            if seq != before, serving.foldedAt == nil { serving.foldedAt = Instant.now() }
            // The heartbeat, after the drain and before anything publishes. Order within one turn
            // of this loop is the only ordering claim available, and the useful one is this:
            // whatever the poll folded is aged by the same beat, and both are visible to this
            // turn's progress frame, snapshot answers and view pass rather than to the next turn's.
            ticking.due(sink)
            if Double(elapsedMs(since: lastCheckpointAt)) / 1000 > checkpointEvery {
                saveCheckpoint(mark: tail.checkpointOffset)
            }
            if let pollError {
                // A failed poll leaves the tail running — `FileTail` drops its handle and the next
                // cycle opens a fresh one. Ending the ingest here would turn a transient sharing
                // violation into a session that never sees another line.
                diagnostic("a tail poll of \(log.path) failed: \(pollError)")
            }
            // A live progress frame is emitted when the fold advanced and the cadence allows, never
            // on an idle poll, which is what keeps an idle session silent. `pct` is the mark over
            // the bytes read, which is 100 exactly when the game is not mid-line.
            if seq != announced, cadence.due() {
                // The live denominator is the tail's own read offset: the file has no fixed size
                // once EverQuest is appending to it.
                let liveTotal = tail.readOffset
                let advanced = FoldMark(checkpoint: tail.checkpointOffset,
                                        events: seq,
                                        pct: pctOf(tail.checkpointOffset, liveTotal),
                                        total: liveTotal,
                                        lastTs: sink.report().lastTs,
                                        // The tail says so, with the same constant it stamps on
                                        // every event it folds. The frame is otherwise
                                        // indistinguishable from the last frame of a scan.
                                        live: tailLive)
                announced = seq
                if !world.reportProgress(generation, advanced) { return .preempted }
            }
            answerAsks(answers, sink, serving)
            answerWrites(writes, sink)
            // The fires, immediately and not at a cadence. Everything else this loop publishes is
            // state, which coalesces by definition; a fire is not state — two charm breaks are two
            // sounds, and folding them would silence one. Every fire the drain produced goes out
            // now, in fold order.
            for fire in sink.takeFires() {
                if !world.reportFire(generation, fire) { return .preempted }
            }
            // The con cards, on the fires' terms and for the fires' reason: a `/con` is a thing
            // that happened rather than state, and coalescing two cards would drop the first.
            for card in sink.takeConCards() {
                if !world.reportConCard(generation, card) { return .preempted }
            }
            // …and the names the fold's probes could not answer, beside the fires and for the same
            // reason. Not generation-gated: a miss describes the process's corpus rather than this
            // generation's world.
            world.announceKnowledgeMisses(sink.takeKnowledgeMisses())
            // The views, at their own cadence. Everything the drain above folded collapses into at
            // most one frame per subscription per `Views.serveEvery` — rule 2 of the diff protocol,
            // held as a cadence rather than as a per-event push.
            if !serving.tick(world, generation, sink) { return .preempted }
            nap(tailDefaultPollInterval, world, generation, answers, writes, sink, serving)
        }
    }

    /// Sleep out one poll interval in short naps, waking early when the world changes hands — and
    /// answering asks between them.
    ///
    /// A live engine spends almost all of its time here, so a reader served only at the top of a
    /// poll would wait a whole poll interval. Serving inside the nap makes the live latency one
    /// `tailNap`.
    static func nap(_ interval: TimeInterval, _ world: World, _ generation: UInt64,
                    _ answers: Mailbox<Ask>, _ writes: Mailbox<Write>,
                    _ sink: EventSink, _ serving: Serving) {
        var slept: TimeInterval = 0
        while slept < interval && world.owns(generation) {
            Thread.sleep(forTimeInterval: tailNap)
            slept += tailNap
            // The one place a live fold picks up a changed priority — a boundary it already stops
            // on, checked against a stored value so the common case costs a lock and no syscall.
            FoldPriority.applyToFoldThread()
            answerAsks(answers, sink, serving)
            // A write arriving while the tail naps is taken in that nap, for the same reason — and
            // a session mark, which the user presses because the log has gone quiet, lands almost
            // always in exactly this nap.
            answerWrites(writes, sink)
            // A subscription opened while the tail is napping is owed a reset, for the same reason:
            // serving here makes the wait for a full window one nap instead of one poll. Nothing is
            // built when nothing owes and nothing moved.
            _ = serving.tick(world, generation, sink)
        }
    }

    /// Answer everything asked of the fold since the last boundary, and block on none of it.
    ///
    /// Drain until empty rather than a blocking read: this is called from the fold's own loop and
    /// must never stall it. An asker that gave up is answered anyway and the answer is dropped.
    ///
    /// Every case is a read of the fold, which is what makes it safe to call at every boundary,
    /// including inside the nap.
    ///
    /// With one stated exception: the combat engine ages itself, so a snapshot is a mutating read
    /// once the tail is live. It advances only what time advances, it is idempotent in `now`, and
    /// while the scan runs it cannot happen at all — the gate is `hydrating` and the scan never
    /// leaves it.
    static func answerAsks(_ answers: Mailbox<Ask>, _ sink: EventSink, _ serving: Serving) {
        while let ask = answers.tryRecv() {
            switch ask {
            case .module(let a): a.answer.send(sink.snapshot(a.module))
            case .perf(let a): a.answer.send(serving.perf())
            case .combat(let a): a.answer.send(sink.combatSnapshot(a.opts))
            case .fights(let a): a.answer.send(sink.searchFights(a.query, a.limit))
            case .loot(let a): a.answer.send(sink.ownLootDrops(a.spellings))
            case .mobLevels(let a): a.answer.send(sink.mobLevels(a.names))
            }
        }
    }

    /// Apply every write pushed since the last boundary, and block on none of them.
    ///
    /// Drained until empty, exactly as `answerAsks` is and for the same reason. A pusher whose
    /// deadline passed still has its write applied, because the fold is the only place it can take
    /// effect and a half-applied world would be worse than a lost receipt. A mark and a confirm are
    /// stored nowhere by design, so a lost receipt costs the client its answer and nothing else.
    static func answerWrites(_ writes: Mailbox<Write>, _ sink: EventSink) {
        while let write = writes.tryRecv() {
            switch write {
            case .define(let a): a.answer.send(sink.define(a.family, a.payload))
            // The engine's own gate answers, not this loop's idea of whether the world is live:
            // the combat engine refuses while hydrating, which is the same boundary the world's
            // status gate reads and the one that actually owns the model.
            case .mark(let a): a.answer.send(sink.sessionMark(a.at))
            // The module's own two refusals answer, and there is no gate above them. A confirmation
            // is about a row, so "is the world live" is not a question that could bear on it.
            case .confirm(let a): a.answer.send(sink.confirmSighting(a.rowId))
            }
        }
    }

    /// Build the measurement one progress frame carries, from the scan's own coordinates.
    static func mark(_ core: TailCore, _ size: UInt64, _ events: Int64, _ sink: EventSink) -> FoldMark {
        // The file may have grown under the scan, so the denominator is the larger of what it was
        // and what has actually been read. `pct` then never exceeds 100 and never claims an unseen
        // byte.
        let total = max(size, core.readOffset)
        return FoldMark(checkpoint: core.checkpointOffset,
                        events: events,
                        pct: pctOf(core.checkpointOffset, total),
                        // The denominator rides along: computed here anyway, and it buys the
                        // loading bar its human units, which `pct` alone cannot reconstruct.
                        total: total,
                        lastTs: sink.report().lastTs,
                        // The scan's own stamp. This helper is the scan's and only the scan's — the
                        // tail builds its `FoldMark` inline because its denominator is its own read
                        // offset — so the constant is honest here rather than a parameter every
                        // caller has to be trusted to pass correctly.
                        live: false)
    }
}

/// `offset / total * 100`, clamped to [0, 100] and answering 0 for a log with no bytes in it rather
/// than a NaN.
func pctOf(_ offset: UInt64, _ total: UInt64) -> Double {
    if total == 0 { return 0 }
    return min(max(Double(offset) / Double(total) * 100, 0), 100)
}

/// Read an event's `ts` back out of its serialized form.
///
/// A scan of a bounded prefix, exact rather than heuristic: the envelope writes `seq`, `ts`, `raw`
/// in that order and the only kind that writes anything ahead of the envelope is `group` (a short
/// `change` string), so the first `"ts":` in an event is always the envelope's and always well
/// inside `tsScanBytes`. `raw` — the only field that could contain a counterfeit — is written after
/// it, every time.
///
/// Bytes, not characters, so a prefix cut cannot land inside a multi-byte character.
func tsOf(_ json: String) -> Int64? {
    let key = Array("\"ts\":".utf8)
    let bytes = Array(json.utf8.prefix(tsScanBytes))
    guard bytes.count >= key.count else { return nil }
    var at = -1
    for i in 0...(bytes.count - key.count) where Array(bytes[i..<(i + key.count)]) == key {
        at = i
        break
    }
    if at < 0 { return nil }
    var i = at + key.count
    let negative = i < bytes.count && bytes[i] == UInt8(ascii: "-")
    if negative { i += 1 }
    let firstDigit = i
    var value: Int64 = 0
    while i < bytes.count, bytes[i] >= UInt8(ascii: "0"), bytes[i] <= UInt8(ascii: "9") {
        let (mul, o1) = value.multipliedReportingOverflow(by: 10)
        if o1 { return nil }
        let (sum, o2) = mul.addingReportingOverflow(Int64(bytes[i] - UInt8(ascii: "0")))
        if o2 { return nil }
        value = sum
        i += 1
    }
    if i == firstDigit { return nil }
    return negative ? -value : value
}

/// Milliseconds since `since`, saturating.
func elapsedMs(since: Instant) -> UInt64 {
    let now = Instant.now().uptimeNanoseconds
    let then = since.uptimeNanoseconds
    return now <= then ? 0 : (now - then) / 1_000_000
}

// MARK: - The three pacers

/// A pacer: it decides how often something is announced, never what is announced, and a skipped
/// tick changes no state — which is why it may read a clock at all.
///
/// Two cadences use it at different rates: progress is ~4/s because a loading bar needs no more,
/// and the view layer is ~10/s, the rate the diff protocol names for a live meter.
final class Cadence {
    private var last: Instant
    private let every: TimeInterval

    /// Set back a full interval so the first boundary of a long fold announces immediately rather
    /// than after a quarter second of silence.
    init(every: TimeInterval) {
        self.every = every
        let back = UInt64(every * 1_000_000_000)
        let now = Instant.now().uptimeNanoseconds
        last = Instant(uptimeNanoseconds: now > back ? now - back : 0)
    }

    /// The same pacer, armed rather than owed: the first `due()` comes one whole interval from now.
    ///
    /// For a caller that has already done the thing once — `Ticking`, whose go-live beat mirrors
    /// the app's single `registry.tick(Date.now())` before its `setInterval` is armed.
    static func fromNow(_ every: TimeInterval) -> Cadence {
        let c = Cadence(every: every)
        c.last = Instant.now()
        return c
    }

    func due() -> Bool {
        let now = Instant.now()
        if Double(now.uptimeNanoseconds &- last.uptimeNanoseconds) / 1_000_000_000 < every {
            return false
        }
        last = now
        return true
    }
}

/// The live world's own clock — one cadence and one wall-clock read.
///
/// One per attach, constructed at the landing rather than at the top of the ingest: a heartbeat
/// belongs to a live world, and that is where the value is created rather than a policy in a flag.
///
/// The interval is the app's `setInterval(…, 1000)`; the tail polls every 400 ms, so a beat lands on
/// roughly every third turn of the loop. It is a ceiling and not a promise: a turn that ran late
/// beats once, not twice, because "age the model to now" is idempotent in `now`.
final class Ticking {
    private let cadence: Cadence

    /// Armed from now, not owed: `beat` is called once at go-live, so the cadence's job is the
    /// interval after that one.
    init() { cadence = Cadence.fromNow(tickEvery) }

    /// Beat if the cadence allows.
    func due(_ sink: EventSink) {
        if cadence.due() { beat(sink) }
    }

    /// Beat now, whatever the cadence says — the go-live sweep. Reads the wall clock once and hands
    /// it in; nothing here interprets it, which is the whole of this seam's contract with the fold.
    func beat(_ sink: EventSink) { sink.tick(Ingest.wallClockMs()) }
}

/// What the live tail owes the view layer: a cadence, the counters, and the fold instant the next
/// frame will be measured against.
///
/// One per attach, like the sink and the parser — a new generation is a new world, and last world's
/// measurements are not this one's.
final class Serving {
    let cadence = Cadence(every: Views.serveEvery)
    let meter = Meter()
    /// When the fold produced what the next frame will report, or nil when it has produced nothing
    /// since the last one. Taken by a frame, never merely read: a second frame with no new events
    /// behind it must not be timed against the first one's fold.
    var foldedAt: Instant?
    /// What building this generation cost — filled in as each half of it is measured.
    var cost = IngestCost()
    /// The bounded history behind `perf.timeline`, sampled off the serve beat.
    ///
    /// It lives here rather than in the world for the two reasons the meter does: it is a property
    /// of this generation, and it is written on the thread that already owns the counters it reads,
    /// so a history costs no lock on the path every `report*` contends for.
    let timeline = Timeline()
    /// The module cursor last announced, per module.
    ///
    /// Here and not in the world, for the meter's two reasons. It is a property of this generation
    /// — a new attach builds a new `Serving` and the fresh fold announces every module on its first
    /// beat, which is right, because after an epoch bump a client has dropped everything anyway.
    /// And it is touched only on the fold thread, so it costs no lock on the `report*` path.
    ///
    /// It is also what makes the frame coalesced: a busy tail moves a module's seq many times
    /// between two beats, so what goes out is one frame per module per beat carrying the newest
    /// cursor.
    private var announcedSeqs: [String: Int64] = [:]

    init() {}

    /// Which modules have moved since the last beat, and record that they were told about.
    ///
    /// A module absent from `moduleSeqs` keeps whatever it last announced: a fold that stopped
    /// reporting a cursor has said nothing, which is not the same as saying it went back to zero.
    func changedModules(_ sink: EventSink) -> [(String, Int64)] {
        var changed: [(String, Int64)] = []
        for (module, seq) in sink.moduleSeqs() {
            if announcedSeqs[module] == seq { continue }
            announcedSeqs[module] = seq
            changed.append((module, seq))
        }
        return changed
    }

    /// This ingest's own answer to `perf.snapshot`. A read: the meter is peeked rather than
    /// drained, so a polling panel cannot zero the counters under the report or make one poll's
    /// numbers depend on the last one.
    func perf() -> EnginePerf {
        var out = EnginePerf()
        out.ingest = cost
        out.serve = meter.peek()
        out.timeline = timeline.peek()
        return out
    }

    /// One cadence tick. `false` when this turn no longer owns the world.
    ///
    /// The views first, then the module dirty bits: a client that draws a view and also holds a
    /// module snapshot should see the rows before it is told to refetch, or the other order sends
    /// it to `module.snapshot` for state the very next frame was about to hand it.
    func tick(_ world: World, _ generation: UInt64, _ sink: EventSink) -> Bool {
        if !cadence.due() { return true }
        let at = foldedAt
        foldedAt = nil
        let served = world.serveViews(generation, SinkRows(sink), at, meter)
        say(false)
        // The ring rides the serve beat and enforces its own cadence, which keeps the horizon a
        // property of `Timeline` rather than of this loop. Offered after the serve so a window
        // closes on frames that have actually been counted, and the uptime comes from the world
        // because a performance question is never answered off a wall clock.
        timeline.tick(world.uptimeMs(), meter)
        if !served { return false }
        let changed = changedModules(sink)
        return changed.isEmpty || world.reportModulesChanged(generation, changed)
    }

    /// Print whatever the meter owes. `force` ignores its cadence — what a landing fold does.
    func say(_ force: Bool) {
        for line in meter.takeReport(force) { diagnostic(line) }
    }
}
