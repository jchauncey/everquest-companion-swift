// The one door: every piece of state this engine holds lives behind `World`, and every reader —
// including the engine's own — asks by calling a method. Port of engined/src/world.rs.
//
// There is no public field and no way to borrow the state, so a cache under this seam would stay
// invisible to callers. Nothing is cached now and nothing may be.
//
// State is addressed by (log identity, byte offset), never "current": the epoch is stated on every
// answer that depends on it, and progress is `World.mark()`. No world state may be a function of
// the wall clock — the two clock-shaped reads here, `uptimeMs` and `logMtimeMs`, are properties of
// the process and of a file. A new generation is a new world and the only way between them is the
// fresh reset; there is no incremental repair.
//
// The epoch bump and its announcement are one critical section, so no connection can hear about
// generation N+1 before N; opening a subscription and stamping its reset share that section for the
// same reason. The generation doubles as the ingest's ownership token: bumped under this lock,
// readable without it (an in-flight fold asks "do I still own the world?" at every slice boundary),
// and re-checked inside the lock by every `report*`, so a loser can write nothing, ever.
import Foundation
import EQCompanionCore
import EQFold
import EQKnowledge
import EQLog

/// A refusal carried as the sentence it is. Every `Result` failure in this engine is prose that
/// reaches the client's `ErrorReply.message`, so the failure type is the sentence itself rather
/// than a wrapper nobody reads through.
extension String: @retroactive Error {}

/// The generation a fresh engine starts in.
///
/// One, not zero: there is always a world, even when it is an empty one, and an epoch of zero would
/// read as "no world yet" to anybody skimming a log. A launch is generation 1 and the first attach
/// makes it 2.
public let firstEpoch: Int64 = 1

/// How long `World.moduleSnapshot` waits for the fold thread before calling it unreachable.
///
/// Generous on purpose: the fold answers at a boundary it already reaches — a 1 MiB read of the
/// scan or a 25 ms nap of the tail. Five seconds clears that by a wide margin while still being
/// short enough that a client's request does not look hung.
public let snapshotPatience: TimeInterval = 5

// MARK: - What the world answers with

/// Names one connection's membership of the world. Opaque on purpose: it is a receipt to hand back
/// to `World.leave`, never a thing to do arithmetic on.
public struct ListenerId: Hashable, Sendable {
    let value: UInt64
}

/// What `World.moduleSnapshot` found.
///
/// Three outcomes and not two, because "this engine has no such module" and "this engine has no
/// fold" are different sentences a client branches on differently: the first is a caller bug or a
/// build skew, the second is a session that has not attached yet and will.
public enum SnapshotAnswer {
    /// The module answered with its published state.
    case snapshot(ModuleSnapshot)
    /// The fold carries no module by that name. The registry is the authority.
    case notFound
    /// Nothing is folding, or the fold could not be reached. The string is the diagnostic that
    /// reaches the client's `ErrorReply.message`.
    case unavailable(String)
}

/// What a performance question found.
///
/// There is no `notFound`: a perf question names nothing that could be absent, and an engine with
/// no fold is not a failure but an idle engine, which `status: idle` and an empty serve list say
/// exactly. The only refusal is a fold that has a door and did not answer through it.
public enum PerfAnswer<T> {
    case perf(T)
    case unavailable(String)
}

/// What a combat question found.
///
/// No `notFound`, for `PerfAnswer`'s reason: there is no module id to typo, only one combat engine
/// or none. A fold built without one, a world with no fold, and a fold that did not answer in time
/// are all `unavailable` — the same sentence to a client: ask again when something is attached.
public enum CombatAnswer<T> {
    case answer(T)
    case unavailable(String)
}

/// What the engine's ingest is doing.
public enum HealthStatus: String, Sendable, Equatable {
    case starting, attaching, folding, live, idle
}

/// THE ADDRESSABLE COORDINATE: state is addressed by (log identity, byte offset) and by nothing
/// else — never by wall time, never by "current". `offset` is the end of the last COMPLETE line
/// folded; a half-written line is not an event and the mark waits with it.
public struct LogMark: Sendable, Equatable {
    /// The log being folded, as the path the app handed the engine at attach.
    public var log: String
    /// The end of the last complete line folded, counted from the start of the file.
    public var offset: Int64

    public init(log: String, offset: Int64) { self.log = log; self.offset = offset }

    public var json: JSONValue { ["log": .string(log), "offset": .int(offset)] }
}

/// What `session.health` answers.
///
/// THE LAST FOUR FIELDS ARE OPTIONAL AND THAT IS NOT A CONVENIENCE: a health answer given before
/// any attach honestly has no mark, no event count, no log timestamp and no file to stat, and a
/// zero would be a measurement nobody took.
public struct HealthResult: Sendable, Equatable {
    public var status: HealthStatus
    public var epoch: Int64
    public var uptimeMs: Int64
    public var events: Int64?
    public var lastEventTs: Int64?
    public var logMtimeMs: Int64?
    public var mark: LogMark?

    public var json: JSONValue {
        var o: [String: JSONValue] = [
            "status": .string(status.rawValue),
            "epoch": .int(epoch),
            "uptimeMs": .int(uptimeMs)
        ]
        if let events { o["events"] = .int(events) }
        if let lastEventTs { o["lastEventTs"] = .int(lastEventTs) }
        if let logMtimeMs { o["logMtimeMs"] = .int(logMtimeMs) }
        if let mark { o["mark"] = mark.json }
        return .object(o)
    }
}

/// What `session.attach` answers. `accepted` is always true: the only way to lose is to be
/// superseded, and nothing can supersede an acceptance that completes inside the lock.
public struct AttachResult: Sendable, Equatable {
    public var epoch: Int64
    public var accepted: Bool
    public var json: JSONValue { ["epoch": .int(epoch), "accepted": .bool(accepted)] }
}

/// WHAT STARTING THIS GENERATION COST. Every field is optional and absent means NOT YET MEASURED
/// rather than zero: a `scanMs` of zero would say a whole log folded instantly, which is the report
/// of a scan that has not finished rather than of a fast one.
public struct PerfIngestReport: Sendable, Equatable {
    public var spellDbMs: Int64?
    public var scanMs: Int64?
    public var scanBytes: Int64?

    public var json: JSONValue {
        var o: [String: JSONValue] = [:]
        if let spellDbMs { o["spellDbMs"] = .int(spellDbMs) }
        if let scanMs { o["scanMs"] = .int(scanMs) }
        if let scanBytes { o["scanBytes"] = .int(scanBytes) }
        return .object(o)
    }
}

/// ONE SOURCE'S SERVE PATH, cumulative for this generation.
///
/// QUEUE TIME IS NEVER COUNTED AS COMPUTE: the two latency fields are measured from the instant the
/// fold produced what the frame reports to the instant the frame reached the connection's outbox,
/// and a frame with no fold behind it is COUNTED but not TIMED — which is why they are optional and
/// their absence means "no frame here had a fold behind it", never "zero microseconds".
public struct PerfServeSource: Sendable, Equatable {
    public var source: String
    public var frames: Int64 = 0
    public var resets: Int64 = 0
    public var diffs: Int64 = 0
    public var rows: Int64 = 0
    public var payloadWeight: Int64 = 0
    public var widestPayloadWeight: Int64 = 0
    public var foldToFrameUsMean: Int64?
    public var foldToFrameUsMax: Int64?
    public var subscribers: Int64 = 0

    public var json: JSONValue {
        var o: [String: JSONValue] = [
            "source": .string(source),
            "frames": .int(frames),
            "resets": .int(resets),
            "diffs": .int(diffs),
            "rows": .int(rows),
            "payloadWeight": .int(payloadWeight),
            "widestPayloadWeight": .int(widestPayloadWeight),
            "subscribers": .int(subscribers)
        ]
        if let foldToFrameUsMean { o["foldToFrameUsMean"] = .int(foldToFrameUsMean) }
        if let foldToFrameUsMax { o["foldToFrameUsMax"] = .int(foldToFrameUsMax) }
        return .object(o)
    }
}

/// What `perf.snapshot` answers. The first five fields are `HealthResult`'s and mean exactly what
/// they mean there, restated rather than nested so a panel reads one object — and optional on the
/// same terms.
public struct PerfSnapshotResult: Sendable, Equatable {
    public var status: HealthStatus
    public var epoch: Int64
    public var uptimeMs: Int64
    public var events: Int64?
    public var lastEventTs: Int64?
    public var mark: LogMark?
    public var ingest: PerfIngestReport
    public var serve: [PerfServeSource]

    public var json: JSONValue {
        var o: [String: JSONValue] = [
            "status": .string(status.rawValue),
            "epoch": .int(epoch),
            "uptimeMs": .int(uptimeMs),
            "ingest": ingest.json,
            "serve": .array(serve.map(\.json))
        ]
        if let events { o["events"] = .int(events) }
        if let lastEventTs { o["lastEventTs"] = .int(lastEventTs) }
        if let mark { o["mark"] = mark.json }
        return .object(o)
    }
}

/// What `perf.budgets` answers. It deliberately restates neither `status` nor `uptimeMs`, which
/// `PerfSnapshotResult` does restate from `HealthResult`: a budgets answer carrying an uptime would
/// be a third shape `session.health`'s guard could not refuse. The epoch is here because a budget
/// verdict is a fact about ONE generation, and a reader comparing two answers across an attach must
/// be able to see that they are not comparable.
public struct PerfBudgetsResult: Sendable, Equatable {
    public var epoch: Int64
    public var budgets: [PerfBudget]
    public var json: JSONValue {
        ["epoch": .int(epoch), "budgets": .array(budgets.map(\.json))]
    }
}

/// What `perf.timeline` answers — the ring as it stands, oldest moment first.
///
/// `capacity` and `cadenceMs` ride the answer because a client inferring the horizon from the
/// length would infer it wrongly for the whole first period of every generation.
public struct PerfTimelineResult: Sendable, Equatable {
    public var epoch: Int64
    public var capacity: Int64
    public var cadenceMs: Int64
    public var timeline: [JSONValue]
    public var json: JSONValue {
        ["epoch": .int(epoch), "capacity": .int(capacity), "cadenceMs": .int(cadenceMs),
         "timeline": .array(timeline)]
    }
}

/// One measurement of an ingest, as the fold thread hands it to the world.
public struct FoldMark: Equatable {
    /// The mark — the end of the last complete line folded.
    public var checkpoint: UInt64
    /// Events folded so far.
    public var events: Int64
    /// How far through the bytes the mark has reached, as a percentage. Bytes over bytes,
    /// engine-measured.
    public var pct: Double
    /// `pct`'s denominator, carried beside it rather than recomputed by anybody downstream.
    ///
    /// `pct` is lossy about the thing a loading bar most wants to say: "62%" cannot be turned back
    /// into "128 MB of 205 MB", and the second sentence is what tells a person whether to wait.
    ///
    /// It can grow between two marks: EverQuest appends while the fold runs, so this is the larger
    /// of the size at open and the bytes actually read rather than a constant.
    public var total: UInt64
    /// The `ts` of the last event folded, if one could be read.
    public var lastTs: Int64?
    /// Which loop took this measurement — false for the historical scan, true for the tail.
    ///
    /// It travels because the numbers beside it cannot be read for it: a caught-up tail reports
    /// `pct` 100 with `events` climbing, byte-for-byte what a scan that has just finished reports.
    ///
    /// It goes on the wire as `FoldProgress.live`, present only when true.
    public var live: Bool

    public init(checkpoint: UInt64, events: Int64, pct: Double, total: UInt64,
                lastTs: Int64?, live: Bool) {
        self.checkpoint = checkpoint; self.events = events; self.pct = pct
        self.total = total; self.lastTs = lastTs; self.live = live
    }
}

/// What the fold has consumed, as a coordinate the caller can name.
public struct Mark: Equatable {
    /// The log being folded, or nil before the first attach.
    public var log: URL?
    /// The mark: the end of the last complete line folded.
    public var checkpoint: UInt64
    /// Events folded in this generation.
    public var events: Int64
    /// The `ts` of the last event folded.
    public var lastTs: Int64?
}

// MARK: - Connections

/// Where a connection's frames go.
///
/// The world pushes the connection-wide announcements and the per-subscription reset/diff frames
/// through this, under the lock that owns the epoch, on the fold thread. The implementation is the
/// connection's: it is responsible for handing them to `EngineClient.deliver` on the MAIN queue, in
/// the order they arrive, which is what makes one ordered stream out of two writers.
public protocol WorldSink: AnyObject {
    func deliver(_ m: EngineMessage)
    /// Still worth talking to. A closed connection is dropped at the next broadcast rather than
    /// being told about, which is the world's fallback for every way a connection can die that is
    /// not a tidy `leave`.
    var isOpen: Bool { get }
}

public extension WorldSink {
    var isOpen: Bool { true }
}

/// One subscription's server-side state — the query, and what the client is holding because of it.
///
/// The engine keeps a copy of the client's window, and that is not a cache: it is the other operand
/// of the diff. There is no way to compute "what changed" without knowing what was last sent, and
/// asking the client would be a round trip per frame on a stream whose point is not having one.
final class Sub {
    /// The validated descriptor. Every name in it resolved when it was opened, so nothing
    /// downstream re-checks anything.
    let view: View
    /// The rows the client holds, or nil when a fresh reset is owed — before the first one, and
    /// after a fold lands. A subscription that owes a reset can be sent nothing else: rule 1.
    var held: [Row]?
    /// The view's total as of the last frame, so a `total` that did not move is not re-sent.
    var total: Int64 = 0
    /// The source revision `held` was cut at. A subscription whose source has not moved since is
    /// not re-cut at all, which is what makes an idle session cost nothing.
    var revision: UInt64?

    init(view: View) { self.view = view }
}

final class Listener {
    let id: ListenerId
    let sink: WorldSink
    /// The subscriptions open on this connection, by the id of the request that opened each.
    ///
    /// They live here, not on the connection, for two reasons: a landing fold must reset every open
    /// subscription, which is a statement about all connections at once; and a subscription's
    /// opening reset must be stamped with the epoch under the same lock that can bump it.
    /// Per-connection isolation is unchanged — request ids are client-chosen and two renderers
    /// routinely pick the same number, so a subscription is named by (listener, id).
    var subscriptions: [Int64: Sub] = [:]
    /// The open ids in one stable order, so a landing fold resets them the same way twice. The Rust
    /// reads a `BTreeMap`; this keeps the order they were opened in, which is the same order for
    /// the monotonic ids a client actually allocates.
    var order: [Int64] = []

    init(id: ListenerId, sink: WorldSink) { self.id = id; self.sink = sink }
}

/// What one source's subscriptions need before a serve pass builds anything.
struct SourceNeed {
    let source: SourceDef
    /// At least one subscription over it owes a reset.
    var owed: Bool
    /// The revisions the open subscriptions were last cut at.
    var held: [UInt64?]
}

// MARK: - The world

/// A handle on the engine's whole state.
public final class World: @unchecked Sendable {
    /// When this engine started. Process metadata, never world state.
    private let started = Instant.now()
    /// The engine's knowledge corpus — committed data plus the overlay the app pushes.
    ///
    /// Not world state, and it does not move with the epoch: a character switch is not the app
    /// withdrawing what it fetched, and `items.json` says the same thing about the same item in
    /// every generation. It is held here so the `knowledge.*` ops are answerable by a world with no
    /// fold at all.
    public let knowledge: KnowledgeCorpus
    /// What an accepted attach starts.
    private let ingest: Starter
    /// The ingest's ownership token. Written only under the state lock; read without it.
    private let generationLock = NSLock()
    /// Every ingest thread this world started and that has not yet returned. `shutdown(wait:)` waits
    /// on it so a quitting process outlives the last fold's final write.
    let ingests = DispatchGroup()
    private var generationValue: UInt64 = 0

    /// The one critical section. Every field below is read and written only inside `locked`.
    private let queue = DispatchQueue(label: "eqcompanion.engine.world")

    private var epoch: Int64 = firstEpoch
    /// Every open connection. Connection-wide messages — the epoch, and the per-subscription resets
    /// a landing fold produces — are pushed here under the same lock that owns the epoch.
    private var listeners: [Listener] = []
    /// The next listener id. Monotonic, never reused, so a stale id can never name a live
    /// connection.
    private var nextListener: UInt64 = 0
    /// What the ingest is doing. `idle` when there is none.
    private var status: HealthStatus = .idle
    /// What the current ingest has folded, in the only coordinates the addressing rule allows.
    private var foldLog: URL?
    private var foldCheckpoint: UInt64 = 0
    private var foldEvents: Int64 = 0
    private var foldLastTs: Int64?
    /// The app knowledge the engine has been told — the latest `*.define` payload per family.
    ///
    /// One entry per family, because a define is an idempotent full-set replace: the latest push is
    /// the whole of what the app has said, so overwriting is the absence of history by design.
    ///
    /// It survives an attach, deliberately. This is not fold state — the fold's own copy is cleared
    /// with the fold — it is what the app has told this engine, and a character switch is not the
    /// app withdrawing it. Every attach re-applies it at construction.
    private var defines: [String: JSONValue] = [:]
    /// The way to write into the current fold, or nil when nothing is folding — app knowledge and
    /// the session mark, the statements made *to* a fold rather than about one. Cleared by an
    /// attach and by an ended ingest, in the same critical section `asks` is: a preempted fold must
    /// not be able to take a define or a mark either.
    private var writeTo: Mailbox<Write>?
    /// The way to ask the current fold a question, or nil when nothing is folding.
    ///
    /// One door, every question. A second queue would be a second thing the fold loop has to
    /// remember to drain at every boundary, which is how one ends up drained only while the tail is
    /// live.
    ///
    /// It is a way to reach the fold thread, never a second handle on its state. A preemption drops
    /// it — `attach` clears the field under the same lock that bumps the epoch — so a reader can
    /// never be answered by a disowned fold.
    private var asks: Mailbox<Ask>?
    /// The client's spell table for the install this world is attached to. nil before the first
    /// attach, and replaced by every attach.
    ///
    /// A third kind of field: not folded from the log, so it does not belong to a generation the
    /// way the fold coordinates do; not something the app told this engine, so it does not survive
    /// an attach the way `defines` does. It is a fact about an install, and the install is named by
    /// the log — so it is derived at attach and replaced at attach.
    private var clientSpellsValue: ClientSpells?
    /// Where the character logs live, as the app named it. nil until a `logs.setDir` arrives, which
    /// is what makes `logs.list` refusable rather than emptily wrong.
    private var logDir = LogDir()

    /// A fresh world folding into counting sinks. A respawn is a launch, so this is the only way
    /// one is ever made and there is no state to restore.
    public convenience init() { self.init(ingest: defaultStarter()) }

    /// A fresh world whose attaches start the ingest the caller names — the seam the fold registry
    /// arrives through, as `World(ingest: starter(foldingSinks()))`.
    public convenience init(ingest: @escaping Starter) {
        self.init(ingest: ingest, knowledge: corpus())
    }

    /// A world whose knowledge corpus is the caller's. The corpus is otherwise the engine's one
    /// instance and must be, or a name the app pushed in answer to a miss would be a hit on one
    /// path and a miss on the other; this exists for tests that want their own overlay and their
    /// own miss ledger.
    public init(ingest: @escaping Starter, knowledge: KnowledgeCorpus) {
        self.ingest = ingest
        self.knowledge = knowledge
    }

    /// Take the lock. Named so every critical section in this file reads the same way, and so the
    /// one rule about it is stated in one place: nothing that can block may happen inside.
    @inline(__always)
    private func locked<T>(_ body: () -> T) -> T { queue.sync(execute: body) }

    // MARK: - Membership

    /// Register a connection.
    @discardableResult
    public func join(_ sink: WorldSink) -> ListenerId {
        locked {
            let id = ListenerId(value: nextListener)
            nextListener += 1
            listeners.append(Listener(id: id, sink: sink))
            return id
        }
    }

    /// Deregister a connection, and with it every subscription it held. Idempotent: leaving twice
    /// is not an error, because a connection can end in more than one way and the tidy-up path must
    /// not care which.
    public func leave(_ id: ListenerId) {
        locked { listeners.removeAll { $0.id == id } }
    }

    /// Open one subscription over a validated view, and answer with the epoch its reset must name.
    ///
    /// The descriptor was resolved before this call: validation names a static registry and refuses
    /// by name, and neither act needs the world.
    ///
    /// The registration and the stamp are one critical section, so a subscription's opening
    /// reset cannot name a generation an attach on another connection has already superseded. An
    /// attach that lands after this returns finds the subscription registered and resets it when
    /// its fold lands.
    ///
    /// It opens owing a reset, which is why the ack's own reset is empty even over a live fold. The
    /// rows live on the fold thread and this call is on a caller's, so the honest opening frame is
    /// the empty window the protocol requires and the fold answers with a full one at the next
    /// boundary it reaches (one tail nap).
    ///
    /// The empty reset is delivered here, inside the same critical section, rather than handed back
    /// for the caller to send: the fold's serve pass delivers under this lock too, so a full reset
    /// it owes this subscription is queued strictly behind the empty one. Sent by the caller after
    /// the lock, the empty reset could land second and leave the client holding nothing while the
    /// engine diffs against the full window.
    @discardableResult
    public func openSubscription(_ listener: ListenerId, _ subscription: Int64, _ view: View) -> Int64 {
        locked {
            let e = epoch
            if let l = listeners.first(where: { $0.id == listener }) {
                if l.subscriptions[subscription] == nil { l.order.append(subscription) }
                l.subscriptions[subscription] = Sub(view: view)
                l.sink.deliver(.reset(id: Int(subscription), epoch: Int(e), total: 0, rows: []))
            }
            return e
        }
    }

    /// Close one subscription. `false` when this connection does not hold it — including one it
    /// held a moment ago, which is the honest answer rather than a comforting one.
    @discardableResult
    public func closeSubscription(_ listener: ListenerId, _ subscription: Int64) -> Bool {
        locked {
            guard let l = listeners.first(where: { $0.id == listener }),
                  l.subscriptions.removeValue(forKey: subscription) != nil else { return false }
            l.order.removeAll { $0 == subscription }
            return true
        }
    }

    // MARK: - The serve path

    /// Serve every open subscription — the view layer's cadence tick.
    ///
    /// Called from the fold thread at `SERVE_EVERY` at most. A short lock learns which sources are
    /// subscribed and at what revision; the expensive build of each moved or owed source happens
    /// outside the lock, so a connection asking `session.health` is never behind a fold's loot
    /// ledger; then under the lock the ownership is re-asked and the frames are cut, diffed and
    /// pushed. A turn that lost the world between the build and the push writes nothing, which is
    /// what makes building outside safe.
    ///
    /// `foldedAt` is when the ingest folded the events this pass is reporting, or nil when it
    /// folded none. It is the origin of the fold-to-frame measurement and nothing else.
    @discardableResult
    public func serveViews(_ generation: UInt64, _ rows: ViewRows,
                           _ foldedAt: Instant?, _ meter: Meter) -> Bool {
        let prepared = prepare(rows, force: false)
        if prepared.isEmpty { return owns(generation) }
        let sent: [SentFrame]? = locked {
            if !owns(generation) { return nil }
            return serve(prepared, resetAll: false)
        }
        guard let sent else { return false }
        weigh(sent, foldedAt, meter)
        return true
    }

    /// Which sources have to be built for the next serve pass, and their rows.
    ///
    /// `force` is a landing fold: every subscription is owed a reset, so every subscribed source is
    /// built whatever its revision says.
    private func prepare(_ rows: ViewRows, force: Bool) -> [Prepared] {
        let needs: [SourceNeed] = locked {
            var needs: [SourceNeed] = []
            for listener in listeners {
                for id in listener.order {
                    guard let sub = listener.subscriptions[id] else { continue }
                    let source = sub.view.source
                    if let at = needs.firstIndex(where: { $0.source.id == source.id }) {
                        needs[at].owed = needs[at].owed || sub.held == nil
                        needs[at].held.append(sub.revision)
                    } else {
                        needs.append(SourceNeed(source: source,
                                                owed: sub.held == nil,
                                                held: [sub.revision]))
                    }
                }
            }
            return needs
        }
        return needs.compactMap { need in
            // The change signal is read first and it is cheap — a counter the module bumps on any
            // change it could have made. Everything after this line is only paid for when something
            // actually moved.
            let revision = rows.revision(need.source) ?? 0
            let stale = need.held.contains { $0 != revision }
            if !force && !need.owed && !stale { return nil }
            return Prepared(source: need.source.id, revision: revision,
                            rows: rows.rows(need.source) ?? [])
        }
    }

    // MARK: - The answers

    /// Answer `session.health`.
    ///
    /// The status is the ingest's: `idle` with no fold, `starting` when an attach is accepted,
    /// `attaching` while the log is opened and the parse's inputs are built, `folding` for the
    /// historical scan, `live` once the tail owns the file.
    ///
    /// The mark, the event count and the log's last timestamp are all absent before the first
    /// attach, and absent is not zero: publishing `offset: 0` would be a measurement nobody took.
    /// The discriminator is the log, which the world knows from the instant an attach is accepted.
    ///
    /// `logMtimeMs` is not a fold fact at all, and three properties of it are deliberate. It is
    /// re-stated per answer, never remembered, because a remembered mtime is wrong the moment the
    /// game appends a line. It never enters fold state — a module that folded an mtime would be a
    /// module whose output depended on when it ran. And the stat happens with the lock released,
    /// because a filesystem call is unbounded and this lock is on the path of every `report*` the
    /// ingest makes; the state is copied out first and the stat is made against the copy.
    public func health() -> HealthResult {
        // The lock is taken and released in this block, and everything below is a function of the
        // copy — see the note above about statting outside it.
        let (status, epoch, log, checkpoint, events, lastTs) = locked {
            (self.status, self.epoch, self.foldLog, self.foldCheckpoint,
             self.foldEvents, self.foldLastTs)
        }
        let mark = log.map { LogMark(log: $0.path, offset: clampI64(checkpoint)) }
        return HealthResult(
            status: status,
            epoch: epoch,
            uptimeMs: clampI64(elapsedMs(since: started)),
            // `events` rides with the mark, because they are one measurement read two ways: the
            // count and the coordinate it was reached at. One present and the other absent would be
            // a pair a reader has to reason about.
            events: mark == nil ? nil : events,
            // …and `lastEventTs` does not, because it has its own reason to be missing: a fold that
            // has folded nothing yet, or whose events carried no stamp the parser could read,
            // honestly has no log clock to report.
            lastEventTs: lastTs,
            // The file fact. Absent before an attach because there is no file, and absent when the
            // stat fails because a log renamed out from under the engine has no answer — `0` would
            // claim 1970 rather than admit the miss.
            logMtimeMs: log.flatMap(mtimeMs),
            mark: mark)
    }

    /// Answer `module.snapshot` — one module's published state, from the fold that is running.
    ///
    /// The answer comes from the fold thread and from nowhere else. This method holds the world's
    /// lock only long enough to copy the way in; the wait happens with the lock released, or the
    /// fold's own `reportProgress` would deadlock against the reader waiting for it.
    ///
    /// The deadline is a failure mechanism, not a latency budget: the answer arrives within one
    /// read boundary of a scan or one nap of a tail, and `snapshotPatience` exists so a fold wedged
    /// on a pathological file becomes an `unavailable` reply rather than a connection that never
    /// answers.
    public func moduleSnapshot(_ module: String) -> SnapshotAnswer {
        guard let asks = locked({ self.asks }) else {
            return .unavailable(noFoldToAsk)
        }
        let ask = SnapshotAsk(module: module)
        if !asks.send(.module(ask)) {
            // The receiver is gone: the ingest ended between the copy above and this send. That is
            // the same outcome as never having had one, and it is stated differently because the
            // two are different things to read in a bug report.
            return .unavailable(foldHasEnded)
        }
        guard let answered = ask.answer.recv(timeout: snapshotPatience) else {
            return .unavailable(notInTime)
        }
        guard let snapshot = answered else { return .notFound }
        return .snapshot(snapshot)
    }

    /// Answer `perf.snapshot` — what this engine is doing and what it has cost.
    ///
    /// Two halves from two places. The world knows where the fold has got to and who is subscribed
    /// to what, both in one critical section so the counts and the coordinate describe the same
    /// instant; the fold thread knows what the scan and the serve path cost, and is asked through
    /// the one door with the lock released, for `moduleSnapshot`'s deadlock reason.
    ///
    /// An engine with nothing attached still answers: the ingest half is empty, but `status`,
    /// `epoch` and `uptimeMs` are real facts about a real process.
    ///
    /// It reads the counters and resets nothing: two panels open at once must see the same session,
    /// and the report must not lose the interval it was about to print.
    public func perfSnapshot() -> PerfAnswer<PerfSnapshotResult> {
        // One critical section for the world's whole half, ending before anything can block.
        //
        // It copies the state rather than calling `health()`, which stats the log file with
        // the lock deliberately released — calling it from inside a lock would be the
        // deadlock-and-stall shape that method's design forbids. The copy has to happen here
        // anyway: the subscriber counts and the coordinate must describe the same instant, or the
        // row states one epoch's mark beside another's watchers.
        //
        // `perf.snapshot` carries no mtime: it is a question about this engine rather than about
        // the file it is reading, and `session.health` is where the file fact belongs.
        let (status, epoch, log, checkpoint, events, lastTs, watched, asks) = locked {
            (self.status, self.epoch, self.foldLog, self.foldCheckpoint, self.foldEvents,
             self.foldLastTs, subscriberCounts(), self.asks)
        }
        // A world with no fold has no door, and that is an idle engine rather than a refusal.
        var measured = EnginePerf()
        if let asks {
            switch askPerf(asks) {
            case .success(let m): measured = m
            case .failure(let why): return .unavailable(why)
            }
        }
        let mark = log.map { LogMark(log: $0.path, offset: clampI64(checkpoint)) }
        return .perf(PerfSnapshotResult(
            status: status,
            epoch: epoch,
            uptimeMs: clampI64(elapsedMs(since: started)),
            // The same pairing `health()` argues for.
            events: mark == nil ? nil : events,
            lastEventTs: lastTs,
            mark: mark,
            ingest: PerfIngestReport(spellDbMs: measured.ingest.spellDbMs.map(clampI64),
                                     scanMs: measured.ingest.scanMs.map(clampI64),
                                     scanBytes: measured.ingest.scanBytes.map(clampI64)),
            serve: serveRows(measured.serve, watched)))
    }

    /// How long this engine has been up, in milliseconds — the one clock a performance answer is
    /// allowed to read.
    ///
    /// Process-relative and not a wall clock: it survives an attach, which the epoch does not, and
    /// carries nothing about when or where a person plays, which is why the timeline stamps its
    /// moments with it. It takes no lock — the start instant is set once at construction and never
    /// written again, and the fold thread calls this on the serve beat.
    public func uptimeMs() -> UInt64 { elapsedMs(since: started) }

    /// Answer `perf.budgets` — the readings, beside the generation they were taken in. The
    /// arithmetic and the prose are `Budgets`'.
    ///
    /// Same door, deadline and ask as `perfSnapshot`. The world's half is one field, so there is no
    /// critical section here. A budget verdict is a fact about the generation the measurements came
    /// from, so the epoch is carried and a reader comparing two answers across an attach can see
    /// they are not comparable.
    public func perfBudgets() -> PerfAnswer<PerfBudgetsResult> {
        let (epoch, asks) = locked { (self.epoch, self.asks) }
        var measured = EnginePerf()
        if let asks {
            switch askPerf(asks) {
            case .success(let m): measured = m
            case .failure(let why): return .unavailable(why)
            }
        }
        return .perf(PerfBudgetsResult(epoch: epoch, budgets: Budgets.budgets(Budgets.Readings(
            scanMs: measured.ingest.scanMs,
            scanBytes: measured.ingest.scanBytes,
            // The worst across every source, and the generation's worst rather than any window's: a
            // wedge detector that forgot the frame that wedged would clear itself. The sources
            // whose frames were all owed resets are dropped — absent, never zero, the rule the
            // whole meter keeps.
            worstServeUs: measured.serve.compactMap(\.latencyMaxUs).max()))))
    }

    /// Answer `perf.timeline` — the bounded recent history behind the snapshot's totals.
    ///
    /// Same door and same ask as `perfBudgets`. The ring arrives already bounded and ordered
    /// oldest-first, so this method maps five fields and states the horizon: `capacity` and
    /// `cadenceMs` ride the answer because a client inferring the horizon from the length would
    /// infer it wrongly for the first five minutes of every generation.
    public func perfTimeline() -> PerfAnswer<PerfTimelineResult> {
        let (epoch, asks) = locked { (self.epoch, self.asks) }
        var measured = EnginePerf()
        if let asks {
            switch askPerf(asks) {
            case .success(let m): measured = m
            case .failure(let why): return .unavailable(why)
            }
        }
        return .perf(PerfTimelineResult(
            epoch: epoch,
            capacity: Int64(Views.timelineCapacity),
            cadenceMs: Int64(Views.timelineCadence * 1000),
            timeline: measured.timeline.map(momentRow)))
    }

    /// Answer `combat.snapshot` — the combat engine's whole state, from the fold that is running.
    ///
    /// The same door and deadline `moduleSnapshot` uses, and it is not a registry op: the combat
    /// engine is the post-registry subscriber, so it is reached by its own case rather than by a
    /// module id.
    public func combatSnapshot(_ opts: CombatOpts) -> CombatAnswer<CombatSnapshot> {
        let ask = CombatAsk(opts: opts)
        switch askFold(.combat(ask), ask.answer) {
        case .failure(let why): return .unavailable(why)
        case .success(nil):
            return .unavailable("this fold carries no combat engine, so there is no meter to read")
        case .success(.some(let snapshot)): return .answer(snapshot)
        }
    }

    /// Answer `combat.searchFights` — a ranked search of the fold's whole encounter history.
    ///
    /// User-initiated, and it travels the same door anyway. A search is heavier than a snapshot —
    /// it summarizes every finalized fight of the session before ranking one — and it is still
    /// answered at a boundary the fold already reaches rather than under a lock, because the
    /// alternative lets a person typing into a box stall the fold between keystrokes.
    public func searchFights(_ query: String, _ limit: Int) -> CombatAnswer<FightSearch> {
        let ask = FightSearchAsk(query: query, limit: limit)
        switch askFold(.fights(ask), ask.answer) {
        case .failure(let why): return .unavailable(why)
        case .success(nil):
            return .unavailable(
                "this fold carries no combat engine, so there is no fight history to search")
        case .success(.some(let found)): return .answer(found)
        }
    }

    /// Answer `resist.levels` — how old these creatures are, as the resist fold knows it.
    ///
    /// The same door and deadline, and like `combat.snapshot` not a registry op: the resist
    /// module's published state is two integers, and this fact is in neither of them.
    ///
    /// There is no `notFound` arm. A creature nobody has conned and the committed catalog has never
    /// heard of is not a request naming something that does not exist — it is a good question whose
    /// honest answer is that nothing states a level, so the name is simply missing from the list.
    public func resistLevels(_ mobs: [String]) -> Result<[(String, MobLevelFact)], String> {
        let ask = MobLevelAsk(names: mobs)
        return askFold(.mobLevels(ask), ask.answer)
    }

    /// The client's spell table for the install this world is attached to. nil when nothing has been
    /// attached, which is the only state in which there is no install to speak of.
    ///
    /// It does not go through the fold door, unlike every other reader on this type. The table is
    /// not fold state — the resist fold never reads it, which is what lets a ledger be replayed and
    /// re-estimated without one — so there is nothing to ask the fold thread about, and reading a
    /// file on the thread that tails the log would be a stall for nothing.
    public func clientSpells() -> ClientSpells? { locked { clientSpellsValue } }

    /// The three sentences a reader on the one door can be refused with. Spelled once: they reach
    /// the client's `ErrorReply.message` from four callers, and they read differently in a bug
    /// report — nothing attached, an ingest that ended between the copy and the send, and a fold
    /// that did not answer inside the deadline.
    private var noFoldToAsk: String { "no log is attached, so there is no fold to ask" }
    private var foldHasEnded: String { "the fold that was answering has ended" }
    private var notInTime: String {
        "the fold did not answer within \(Int(snapshotPatience * 1000)) ms"
    }

    /// Post one ask through the one door and wait for it.
    ///
    /// The lock is taken and released before anything blocks, which is why this is a method and not
    /// a closure at the call site: the fold thread takes this lock in every `report*` it makes, so
    /// waiting under it would deadlock against the thread being waited for.
    private func askFold<T>(_ ask: Ask, _ answer: Answer<T>) -> Result<T, String> {
        guard let asks = locked({ self.asks }) else { return .failure(noFoldToAsk) }
        if !asks.send(ask) { return .failure(foldHasEnded) }
        guard let value = answer.recv(timeout: snapshotPatience) else { return .failure(notInTime) }
        return .success(value)
    }

    /// Post the perf ask and wait for the fold, on the same terms `moduleSnapshot` waits. The lock
    /// is not held here — see the caller.
    private func askPerf(_ asks: Mailbox<Ask>) -> Result<EnginePerf, String> {
        let ask = PerfAsk()
        // The ingest ended between copying the handle and sending through it. Its measurements went
        // with it, and reporting the last generation's numbers under this one's epoch would be
        // worse than saying so.
        if !asks.send(.perf(ask)) { return .failure(foldHasEnded) }
        guard let value = ask.answer.recv(timeout: snapshotPatience) else {
            return .failure(notInTime)
        }
        return .success(value)
    }

    // MARK: - What the app tells the engine

    /// Take one family of app knowledge — `alerts.define` and its four siblings.
    ///
    /// The order is the design: the world records the push first, under the lock, then hands it to
    /// the running fold with the lock released and waits. Recording first is what makes the
    /// before-attach case need no special path — a define pushed at a world with no ingest is one
    /// nobody has asked for yet, and the next attach applies it at construction. The lock is not
    /// held across the wait, or this deadlocks against the fold's own `report*` calls.
    ///
    /// The wait is what the ack is for: `applied: true` says the live fold has this set, not that a
    /// queue accepted it. Bounded by `snapshotPatience`; the world's record is already written by
    /// then, so a timeout costs the current generation's copy and nothing more.
    public func define(_ family: String, _ payload: JSONValue) {
        let push: Mailbox<Write>? = locked {
            defines[family] = payload
            return writeTo
        }
        guard let push else { return }
        let ask = DefineAsk(family: family, payload: payload)
        if push.send(.define(ask)) {
            _ = ask.answer.recv(timeout: snapshotPatience)
        }
    }

    /// Everything the app has told this engine, for an attach to apply at construction.
    ///
    /// A copy, taken under the lock and handed over: the fold thread must not hold a reference into
    /// world state. Ordered by family, so two attaches of the same world apply them in the same
    /// order.
    public func heldDefines() -> [(String, JSONValue)] {
        locked { defines.keys.sorted().map { ($0, defines[$0]!) } }
    }

    /// Where the character logs live, as the app just said.
    ///
    /// An idempotent full-set replace of one value: the latest push is the whole of what the app
    /// has said, the same command law the five defines are under.
    ///
    /// Nothing is handed to a fold, which is the whole difference from `define`. A define changes
    /// what folding a log produces and therefore has to reach the running ingest and be re-applied
    /// at the next attach's construction; a directory changes nothing about any fold, so the write
    /// ends here — and this call therefore cannot block on the fold thread.
    public func setLogDir(_ dir: String) {
        locked { logDir.set(dir) }
    }

    /// The character logs in the directory the app named, or a refusal when it has named none.
    ///
    /// The scan happens with the lock released, as `moduleSnapshot`'s wait does: it is a directory
    /// read plus one stat per file, fast on a warm directory and unbounded on a disconnected
    /// network share, and this lock is taken by the fold thread in every `report*` it makes.
    ///
    /// The path is copied out and echoed back by the caller, so the answer names the directory it
    /// is about — that echo is the client's own staleness test.
    ///
    /// It needs no fold and no attach: a fresh install has characters to choose between before
    /// there is anything to attach to.
    public func listLogs() -> Result<(String, LogScan), String> {
        guard let dir = locked({ logDir.get() }) else {
            return .failure("no log directory has been pushed, so there is nothing to enumerate; "
                            + "the app names it with logs.setDir")
        }
        return .success((dir.path, Logs.scan(dir)))
    }

    /// Take a session mark, or refuse it — `sessionMarks.add`.
    ///
    /// The mark is stored nowhere, and that absence is the feature: a relaunch replays the log into
    /// the records the log alone describes. The other half of that is the refusal — a mark cannot
    /// enter a replaying fold, so a replay cannot diverge from a live run.
    ///
    /// Refused unless the world is live. The two gates are one boundary because the fold's tick
    /// calls the combat engine's `setLive` on a beat that happens before `reportFoldLanded`
    /// publishes `status: "live"`. Both are kept: the status gate is what the client is told, the
    /// engine's is what owns the model.
    ///
    /// The status and the door are read together in one critical section and the wait happens
    /// outside it, or this deadlocks against the fold's own `report*` calls. The wait is what makes
    /// the ack usable: without it a client could ask `combat.snapshot` the instant its ack arrived
    /// and be answered by a fold that had not yet reached the mark's boundary.
    ///
    /// It returns the status it decided under, read in that same section: a client asking
    /// `session.health` afterwards would be racing a fold that may have gone live in between.
    public func sessionMark(_ at: Int64) -> (accepted: Bool, status: HealthStatus) {
        let (status, push) = locked { (self.status, self.writeTo) }
        if status != .live { return (false, status) }
        // A live world with no door is a world being replaced between the two reads above: the
        // attach that cleared it has not yet published its own status. Nothing can be split, so
        // nothing is claimed.
        guard let push else { return (false, status) }
        let ask = MarkAsk(at: at)
        if !push.send(.mark(ask)) { return (false, status) }
        // The fold's own answer is the answer. A timeout answers `false`, the honest reading of
        // what this engine knows: the mark may still be applied at the next boundary, and a client
        // told `true` by a wait that never returned would have been told something nobody observed.
        return (ask.answer.recv(timeout: snapshotPatience) ?? false, status)
    }

    /// Confirm a sighting — `respawn.confirmSighting`, the last of the app's commands.
    ///
    /// It holds nothing and stores nothing, unlike `define`: a define is a preference that outlives
    /// any one fold, while a confirmation is a judgement about one spawn of one mob in one session.
    /// So a confirm pushed at a world with no ingest is about a row that does not exist, and
    /// `false` is the honest answer.
    ///
    /// There is no status gate, unlike `sessionMark`: the module's two refusals are both about the
    /// row rather than the world, and nothing persists a confirmation, so a re-fold of this log
    /// never sees one. Mirroring the app-side seam is the bar, and a gate the app does not have
    /// would be this engine disagreeing with it.
    public func confirmSighting(_ rowId: String) -> Bool {
        guard let push = locked({ writeTo }) else { return false }
        let ask = ConfirmAsk(rowId: rowId)
        if !push.send(.confirm(ask)) { return false }
        return ask.answer.recv(timeout: snapshotPatience) ?? false
    }

    /// Answer `knowledge.mob` — the join the two owners have to make together.
    ///
    /// The corpus resolves the identity, the fold answers for the loot, and the corpus joins. The
    /// order is the design: the roster's statement that two spellings are one creature is committed
    /// data, so the keys are known before anything is asked of the fold, and what crosses the
    /// thread boundary is a handful of rows rather than a handle on somebody's state.
    ///
    /// An engine with no fold still answers, with the empty loot history a creature nothing has
    /// been looted from gets. A mob card before the first attach is a real card: the drop table,
    /// the quest cross-ref and the era evidence are committed data.
    public func knowledgeMob(_ name: String) -> KnowledgeAnswer {
        let keys = knowledge.identityKeys(name)
        return knowledge.mob(name, loot: SeenLoot(ownLoot(keys)))
    }

    /// Ask the current fold what has been looted off one creature. No fold, or a fold that does not
    /// answer in time, is an empty history rather than a refusal: the rest of the card is committed
    /// data and is worth drawing.
    private func ownLoot(_ spellings: [String]) -> [SeenDrop] {
        if spellings.isEmpty { return [] }
        guard let asks = locked({ self.asks }) else { return [] }
        let ask = LootAsk(spellings: spellings)
        if !asks.send(.loot(ask)) { return [] }
        return ask.answer.recv(timeout: snapshotPatience) ?? []
    }

    // MARK: - What the fold thread tells the world

    /// The ingest offers to take writes: install this turn's push queue.
    ///
    /// A `report*` method like every other statement an ingest makes, with ownership re-asked
    /// inside the lock: a turn that has already lost must not be able to install a door onto a fold
    /// nobody wants.
    ///
    /// Answers with the held defines, copied in the same critical section that installs the door:
    /// a `define` that lands before it is in the copy, one that lands after goes through the door,
    /// and none can fall between the two. nil when this turn has lost.
    public func serveWrites(_ generation: UInt64, _ push: Mailbox<Write>) -> [(String, JSONValue)]? {
        locked {
            if !owns(generation) { return nil }
            writeTo = push
            return defines.keys.sorted().map { ($0, defines[$0]!) }
        }
    }

    /// The ingest offers to answer questions: install this turn's ask queue.
    ///
    /// Called once per attach, before the first byte is folded, so `module.snapshot` and
    /// `perf.snapshot` during the historical scan are answerable rather than merely eventually
    /// answerable.
    @discardableResult
    public func serveAsks(_ generation: UInt64, _ asks: Mailbox<Ask>) -> Bool {
        locked {
            if !owns(generation) { return false }
            self.asks = asks
            return true
        }
    }

    /// An alert fired — announce it to every connection.
    ///
    /// A `report*` like every other statement an ingest makes: ownership is re-asked inside the
    /// lock, so a preempted fold that matched a line on its way out announces nothing.
    /// Connection-wide, like the epoch, because a fire belongs to the world rather than to any
    /// subscription and every window on this app plays the same sound.
    ///
    /// It changes no world state, which is what makes it unlike every other `report*` here: a fire
    /// is a thing that happened, and the engine keeps no ledger of them (the fold's own module
    /// does). Nothing to reconcile means nothing to re-request, which is why the frame carries no
    /// epoch.
    @discardableResult
    public func reportFire(_ generation: UInt64, _ fire: Fire) -> Bool {
        locked {
            if !owns(generation) { return false }
            // What it says, carried verbatim. Nothing is decided here and nothing is defaulted: an
            // absent field is the fold's statement that this firing has nothing true to say there,
            // and null-filling it would turn "no spell in this family" into a value the app would
            // have to learn to disbelieve.
            broadcast(.fire(FireMessage(at: fire.at, rule: fire.rule, sound: fire.sound,
                                        message: fire.message, captures: fire.captures ?? [:],
                                        spell: fire.spell, dueAt: fire.dueAt)))
            return true
        }
    }

    /// A live `/con` produced a card — announce it to every connection.
    ///
    /// A `report*` like `reportFire` in every respect, including the two that make it unusual:
    /// ownership is re-asked inside the lock, so a preempted fold that parsed a con line on its way
    /// out draws nothing; and it changes no world state, because a card is a thing that happened
    /// rather than a thing to reconcile. Connection-wide, no `id`, no `epoch`.
    @discardableResult
    public func reportConCard(_ generation: UInt64, _ card: JSONValue) -> Bool {
        locked {
            if !owns(generation) { return false }
            broadcast(.conCard(card))
            return true
        }
    }

    /// Modules moved — announce the dirty bits.
    ///
    /// One frame per module, and the caller has already decided which: the ingest holds the last
    /// cursor it announced per module and hands over only the ones that moved, so the coalescing
    /// happens where the beat is.
    ///
    /// They go out under one lock, in the order given, so a connection cannot observe module B's
    /// new cursor before module A's when the same fold moved both.
    @discardableResult
    public func reportModulesChanged(_ generation: UInt64, _ changed: [(String, Int64)]) -> Bool {
        locked {
            if !owns(generation) { return false }
            for (module, seq) in changed {
                broadcast(.moduleChanged(module: module, seq: Int(seq)))
            }
            return true
        }
    }

    /// Announce every name this engine could not answer — the `knowledgeMiss` frames.
    ///
    /// Connection-wide, like the epoch and the fire, because the fetch is the app's and one app
    /// makes it once however many windows are open.
    ///
    /// Not generation-gated, which is the difference from every other broadcast in this file. A
    /// `report*` re-asks ownership because it states something about this generation's world; a
    /// miss states something about the engine's corpus, equally true whichever fold noticed it and
    /// equally true after the next attach. Dropping one because the fold that found it lost the
    /// world would mean the name is never fetched at all: the corpus records it as announced and
    /// never offers it again.
    public func announceKnowledgeMisses(_ misses: [KnowledgeMiss]) {
        if misses.isEmpty { return }
        locked {
            for miss in misses {
                // A domain the wire has no case for cannot be announced, and silence is honester
                // than a frame nobody can read. The corpus only records the two it can be pushed
                // answers for, so this is unreachable by construction — stated rather than
                // asserted, because an engine that died on a diagnostic would be worse than one
                // that says nothing.
                guard fetchableDomains.contains(miss.domain) else { continue }
                broadcast(.knowledgeMiss(domain: miss.domain, name: miss.name))
            }
        }
    }

    /// What the fold has consumed: the log, the mark, and what was counted reaching it. The
    /// engine's own door onto the addressable coordinate.
    public func mark() -> Mark {
        locked { Mark(log: foldLog, checkpoint: foldCheckpoint,
                      events: foldEvents, lastTs: foldLastTs) }
    }

    /// Answer `session.attach` — begin folding one log, preempting anything already folding.
    ///
    /// Inside the lock: the epoch bumps, the generation bumps (which strips the in-flight ingest of
    /// its ownership before this call returns), the world is emptied of the previous fold's
    /// coordinates, the status becomes `starting`, and the bump is announced to every connection.
    /// Outside it: the fold thread starts, because a thread spawn is a syscall and the epoch's
    /// critical section must stay the length of a few queue pushes.
    ///
    /// `accepted` is always true: the only way to lose is to be superseded, and nothing can
    /// supersede an acceptance that completes inside the lock. The turn that loses is the older
    /// ingest, and it reports nothing to anybody.
    ///
    /// No `progress` rides the announcement: at the bump the fold has not opened the file, so a
    /// percentage would be inventing a measurement.
    ///
    /// `stateDir` is the app's `userData`; nil is the file-free attach a client that said nothing
    /// gets. It is a parameter rather than a second method, even though almost every caller here
    /// passes nil, because a convenience wrapper would let a future call site attach without
    /// considering the question.
    @discardableResult
    public func attach(_ logPath: String, stateDir: String? = nil) -> AttachResult {
        let log = URL(fileURLWithPath: logPath)
        let dir = stateDir.map { URL(fileURLWithPath: $0) }
        let (generation, epoch): (UInt64, Int64) = locked {
            self.epoch += 1
            // Bumped under the lock, so the counter and the epoch can never disagree about which
            // turn owns the world.
            generationLock.lock()
            generationValue += 1
            let generation = generationValue
            generationLock.unlock()
            status = .starting
            foldLog = log
            foldCheckpoint = 0
            foldEvents = 0
            foldLastTs = nil
            // The old fold stops being askable at the bump, in the same critical section that
            // strips it of its ownership — not when it notices, not when its thread ends. A reader
            // must never be answered by a generation the world has already replaced.
            asks = nil
            // …and neither is it writable. `defines` itself is untouched: that is the app's
            // knowledge, not this generation's, and the fold about to be built re-applies it at
            // construction. A session mark has no such second life — it is stored nowhere, so a
            // mark posted at a fold being replaced is a mark that did not happen.
            writeTo = nil
            // The install is named by the log, so the client table is re-derived here and nowhere
            // else. Replaced rather than kept, even when the path is the same: a character switch
            // onto a second EverQuest folder must not answer out of the first folder's table, and
            // deciding that by comparing paths would be a cache with an invalidation rule. A
            // re-attach onto the same install pays one lazy re-read, once, if anybody asks.
            clientSpellsValue = ClientSpells.besideLog(log.path)
            broadcast(.epoch(epoch: Int(self.epoch), reason: "attach", progress: nil))
            return (generation, self.epoch)
        }

        ingest(self, generation, log, dir)

        return AttachResult(epoch: epoch, accepted: true)
    }

    /// Retire the running fold without starting another — the app is quitting. The bump strips the
    /// ingest of its ownership exactly as an attach would, so it exits at its next boundary and
    /// its sink's `detach` writes the persisted state one last time.
    ///
    /// `wait` bounds how long to block for the running ingest to return — its detach is the write
    /// being waited for. A checkpoint save already under way is not preemptible, so a fixed nap is
    /// not enough. Zero waits for nothing.
    public func shutdown(wait: TimeInterval = 0) {
        locked {
            generationLock.lock()
            generationValue += 1
            generationLock.unlock()
            status = .idle
            asks = nil
            writeTo = nil
        }
        if wait > 0, ingests.wait(timeout: .now() + wait) == .timedOut {
            diagnostic("shutdown: the fold did not finish within \(wait) s")
        }
    }

    /// Does this turn still own the world? The lock-free half of the generation law.
    public func owns(_ generation: UInt64) -> Bool {
        generationLock.lock(); defer { generationLock.unlock() }
        return generationValue == generation
    }

    /// The generation the current turn holds. A real ingest is handed its own number by `attach`
    /// and never has to ask; a test that replaced the ingest has to.
    public func generation() -> UInt64 {
        generationLock.lock(); defer { generationLock.unlock() }
        return generationValue
    }

    /// Move the health status, if this turn still owns the world.
    @discardableResult
    public func reportStatus(_ generation: UInt64, _ status: HealthStatus) -> Bool {
        locked {
            if !owns(generation) { return false }
            self.status = status
            return true
        }
    }

    /// Announce one measurement of the fold to every connection.
    ///
    /// The frame is an epoch message carrying `progress` — the schema says in as many words that
    /// progress frames are not a fourth stream kind, they are this — so a client that acked
    /// `session.progress` and a client that acked nothing see the same thing, which is what
    /// connection-wide means.
    @discardableResult
    public func reportProgress(_ generation: UInt64, _ mark: FoldMark) -> Bool {
        locked {
            if !owns(generation) { return false }
            foldCheckpoint = mark.checkpoint
            foldEvents = mark.events
            foldLastTs = mark.lastTs
            broadcast(.epoch(epoch: Int(epoch), reason: "progress", progress: FoldProgress(
                pct: mark.pct,
                events: Int(mark.events),
                // Both coordinates, not a rounded one. `offset` is the mark itself — the same
                // coordinate `LogMark.offset` reports — and `logSize` is what `pct` was divided by.
                // Saturating rather than wrapping: a silent wrap would draw a negative progress bar
                // where a saturate draws a stuck one.
                offset: clampI64(mark.checkpoint),
                logSize: clampI64(mark.total),
                // Present only when true, the `song`/`rare` idiom this wire already uses: a scan
                // frame says nothing rather than saying false, so a historical fold's frames are
                // what they were before this field existed.
                live: mark.live)))
            return true
        }
    }

    /// The fold landed: the historical scan is complete and the tail has the file.
    ///
    /// Every open subscription is reset, on every connection, stamped with this generation — rule 1
    /// of the diff protocol at the one moment the whole window changed at once. A reset is sent
    /// even when the window is empty: a client that special-cased "no reset because there was
    /// nothing" could not tell an empty view from a view that never re-opened.
    ///
    /// Exactly one per winning attach. A preempted ingest never reaches here, and one that does can
    /// only pass through once — the tail loop that follows has no way back.
    ///
    /// The sources are built before the lock is taken, for the reason `serveViews` gives; the
    /// stamp, the status and the send happen in one critical section, so a reset can only ever name
    /// the generation that landed.
    @discardableResult
    public func reportFoldLanded(_ generation: UInt64, _ mark: FoldMark, _ rows: ViewRows,
                                 _ foldedAt: Instant?, _ meter: Meter) -> Bool {
        let prepared = prepare(rows, force: true)
        let sent: [SentFrame]? = locked {
            if !owns(generation) { return nil }
            status = .live
            foldCheckpoint = mark.checkpoint
            foldEvents = mark.events
            foldLastTs = mark.lastTs
            return serve(prepared, resetAll: true)
        }
        guard let sent else { return false }
        weigh(sent, foldedAt, meter)
        return true
    }

    /// There is no fold any more — the ingest could not start, could not read, or threw.
    ///
    /// `idle` is the same word a never-attached engine uses, and that is the honest one: it says
    /// nothing is being folded. The epoch is untouched, deliberately — a fold that died created no
    /// new generation, and a client told about generation N is still looking at generation N's
    /// (empty) world rather than at a world it has never heard of.
    @discardableResult
    public func reportIdle(_ generation: UInt64) -> Bool {
        locked {
            if !owns(generation) { return false }
            status = .idle
            // And nothing is askable any more. Clearing the handles here makes the world say "no
            // fold" rather than making every reader discover it one failed send at a time.
            asks = nil
            writeTo = nil
            return true
        }
    }

    // MARK: - Under the lock

    /// Push a connection-wide message to every open connection, dropping the ones that have gone.
    ///
    /// A connection that has closed is not an error: `leave` remains the tidy path, and this is the
    /// fallback for every other way a connection can die.
    private func broadcast(_ message: EngineMessage) {
        listeners.removeAll { !$0.sink.isOpen }
        for listener in listeners { listener.sink.deliver(message) }
    }

    /// Serve every subscription over a prepared source — the whole of reset-then-diffs, in one
    /// place.
    ///
    /// It runs under the world's lock, which is what stamps every frame it sends with the epoch
    /// that was current when it was cut. `resetAll` is a landing fold: every window is a new
    /// world's and there is nothing to diff against.
    ///
    /// A subscription whose source was not prepared is skipped, silently and correctly: the pass
    /// decided nothing about that source had moved.
    ///
    /// Answers with what it sent, for `weigh` to meter once the lock is released: weighing a frame
    /// serializes all of it, a reset's every row included, and nothing about that needs the lock
    /// `health`, `openSubscription` and `define` are waiting on.
    private func serve(_ prepared: [Prepared], resetAll: Bool) -> [SentFrame] {
        var sent: [SentFrame] = []
        let landed = epoch
        listeners.removeAll { !$0.sink.isOpen }
        for listener in listeners {
            for id in listener.order {
                guard let sub = listener.subscriptions[id] else { continue }
                guard let source = prepared.first(where: { $0.source == sub.view.source.id }) else {
                    continue
                }
                if !resetAll, sub.held != nil, sub.revision == source.revision { continue }
                let cut = Views.cut(sub.view, source.rows)
                let rows = cut.window
                let total = cut.total
                let owed = resetAll || sub.held == nil
                var frame: (FrameKind, Int, Int, EngineMessage)?
                if owed {
                    frame = (.reset, rows.count, 0,
                             .reset(id: Int(id), epoch: Int(landed), total: Int(total), rows: rows))
                } else {
                    let ops = ViewDiff.diff(sub.held ?? [], rows)
                    // A frame that says nothing is not sent. `total` moving on its own is still
                    // something to say — a filtered view can shrink outside the window — so the two
                    // conditions are separate rather than one.
                    if ops.isEmpty && total == sub.total {
                        sub.revision = source.revision
                        continue
                    }
                    frame = (.diff, 0, ops.count,
                             // Present only when it moved — the schema says so.
                             .diff(id: Int(id), epoch: Int(landed),
                                   total: total != sub.total ? Int(total) : nil, ops: ops))
                }
                if let (kind, rowCount, ops, message) = frame {
                    listener.sink.deliver(message)
                    sent.append(SentFrame(source: source.source, kind: kind, rows: rowCount,
                                          ops: ops, message: message))
                }
                sub.held = rows
                sub.total = total
                sub.revision = source.revision
            }
        }
        return sent
    }

    /// Meter what one serve pass sent. On the fold thread, which owns the meter, after the lock.
    ///
    /// The bytes are each frame's own: measured from the message that went out rather than
    /// estimated from the rows, because an estimated payload budget is a payload budget nobody is
    /// keeping.
    private func weigh(_ sent: [SentFrame], _ foldedAt: Instant?, _ meter: Meter) {
        for f in sent {
            meter.frame(f.source, f.kind, f.rows, f.ops, payloadWeight(f.message), foldedAt)
        }
    }

    /// How many subscriptions are open over each source right now, across every connection.
    ///
    /// A live count, not a cumulative one, and the world's own answer rather than the meter's — the
    /// meter counts frames that were sent and knows nothing about who is still listening. It is
    /// what makes a row with no recent frames readable: `subscribers 0` means nobody is watching,
    /// and `subscribers 2, frames 40` on a quiet source means nothing has moved.
    private func subscriberCounts() -> [String: Int64] {
        var counts: [String: Int64] = [:]
        for listener in listeners {
            for sub in listener.subscriptions.values {
                counts[sub.view.source.id, default: 0] += 1
            }
        }
        return counts
    }
}

// MARK: - The `perf.snapshot` folds

// Free functions, and none of them touches the lock: `perfSnapshot` reads the world once and does
// its arithmetic outside the critical section, so no connection waits on a diagnostic being
// formatted.

/// A counter onto the wire's `integer`. Saturating rather than wrapping: a byte count this app can
/// produce does not reach 2^63, and a cast that could silently report a negative one has no place
/// in an instrument.
func clampI64(_ value: UInt64) -> Int64 {
    value > UInt64(Int64.max) ? Int64.max : Int64(value)
}

/// One file's last-modified time, in epoch milliseconds, or nil when there is no answer.
///
/// The engine owns log-file facts, so the reading lives here rather than app-side.
///
/// Every failure is nil, and that is the honest answer: a missing file, a permission refusal, a
/// filesystem with no modification time and a stamp before the epoch are four reasons and one
/// outcome — this engine cannot state the fact. `0` would claim 1970, which a client would draw as
/// a real date beside a real character name.
///
/// Truncated, not rounded, so it equals `Math.floor(statSync(log).mtimeMs)`.
func mtimeMs(_ log: URL) -> Int64? {
    var st = stat()
    if stat(log.path, &st) != 0 { return nil }
    return Logs.mtimeMs(st)
}

/// One ring entry on the wire — five field assignments and no arithmetic. The ring did the
/// subtraction that makes each figure an interval, where the counters live; this is the mapping
/// onto the served shape, which is the one thing the view layer may not know about.
func momentRow(_ moment: Moment) -> JSONValue {
    var o: [String: JSONValue] = [
        "atMs": .int(clampI64(moment.atMs)),
        "spanMs": .int(clampI64(moment.spanMs)),
        "frames": .int(clampI64(moment.frames)),
        "payloadWeight": .int(clampI64(moment.bytes))
    ]
    if let worst = moment.worstUs { o["foldToFrameUsMax"] = .int(clampI64(worst)) }
    return .object(o)
}

/// The union of what has served and what is being watched, ordered by source name.
///
/// Two different reasons put a source in the list. It has served frames — a cost, which belongs
/// whether or not anybody is still subscribed, because the generation's bill does not disappear
/// when a window closes. Or somebody is subscribed to it right now and it has served nothing yet,
/// which is a subscription waiting for its first frame: omitting it would make "opened and nothing
/// came" indistinguishable from "never opened".
///
/// A source in neither set is absent — no rows of zeros for a source this session has never had
/// anything to do with. A source that has served frames and has since been unsubscribed honestly
/// reports zero subscribers.
func serveRows(_ served: [SourceMeter], _ watched: [String: Int64]) -> [PerfServeSource] {
    var rows: [String: PerfServeSource] = [:]
    for source in served {
        rows[source.source] = PerfServeSource(
            source: source.source,
            frames: clampI64(source.frames),
            resets: clampI64(source.resets),
            diffs: clampI64(source.diffs),
            rows: clampI64(source.rows),
            payloadWeight: clampI64(source.bytes),
            widestPayloadWeight: clampI64(UInt64(max(0, source.widest))),
            foldToFrameUsMean: source.latencyMeanUs.map(clampI64),
            foldToFrameUsMax: source.latencyMaxUs.map(clampI64),
            subscribers: 0)
    }
    for (source, count) in watched {
        if rows[source] == nil { rows[source] = PerfServeSource(source: source) }
        rows[source]?.subscribers = count
    }
    return rows.keys.sorted().map { rows[$0]! }
}

/// One frame's payload weight, in bytes.
///
/// Measured from the frame about to go out rather than estimated from the rows, because an
/// estimated payload budget is a payload budget nobody is keeping. In-process there is no wire, so
/// the number is what this frame WOULD weigh on one — the same measurement the socket engine took,
/// and the only one a budget stated in bytes can be judged against.
///
/// Only the two stream frames are weighed: the connection-wide announcements are a handful of
/// integers and carry no view payload at all.
/// One frame a serve pass delivered, kept for `weigh`.
struct SentFrame {
    var source: String
    var kind: FrameKind
    var rows: Int
    var ops: Int
    var message: EngineMessage
}

func payloadWeight(_ m: EngineMessage) -> Int {
    switch m {
    case .reset(let id, let epoch, let total, let rows):
        return JSONValue.object([
            "kind": "reset", "id": .int(Int64(id)), "epoch": .int(Int64(epoch)),
            "total": .int(Int64(total)), "rows": .array(rows.map(rowJSON))
        ]).serialized().count
    case .diff(let id, let epoch, let total, let ops):
        var o: [String: JSONValue] = [
            "kind": "diff", "id": .int(Int64(id)), "epoch": .int(Int64(epoch)),
            "ops": .array(ops.map(opJSON))
        ]
        if let total { o["total"] = .int(Int64(total)) }
        return JSONValue.object(o).serialized().count
    default:
        return 0
    }
}

func rowJSON(_ row: Row) -> JSONValue {
    ["key": .string(row.key), "cells": .object(row.cells)]
}

func opJSON(_ op: DiffOp) -> JSONValue {
    switch op {
    case .insert(let row, let before, let after):
        var o: [String: JSONValue] = ["op": "insert", "row": rowJSON(row)]
        if let before { o["before"] = .string(before) }
        if let after { o["after"] = .string(after) }
        return .object(o)
    case .update(let key, let cells):
        return ["op": "update", "key": .string(key), "cells": .object(cells)]
    case .drop(let key):
        return ["op": "drop", "key": .string(key)]
    }
}

/// The loot rows a `knowledge.mob` join was handed, as the seam the corpus reads them through.
///
/// A one-line adapter rather than a second implementation somewhere clever: the corpus asks for
/// `dropsAcross(keys)` and the world has already asked the fold for exactly those keys, so the
/// answer is the answer.
final class SeenLoot: OwnLoot {
    private let drops: [SeenDrop]
    init(_ drops: [SeenDrop]) { self.drops = drops }
    func dropsAcross(_ spellings: [String]) -> [SeenDrop] { drops }
}
