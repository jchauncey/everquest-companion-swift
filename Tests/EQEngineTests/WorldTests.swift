// The world's laws — the epoch, the subscription bookkeeping and the generation — proven twice:
// once with the ingest replaced by a no-op (ports of `world.rs`'s own unit tests, where no thread,
// no file and no timing are in the room), and once against a real attach over a staged fixture log
// (the port of `tests/ingest.rs`, where all three are).
import XCTest
import EQCompanionCore
// Testable: the durability and coalescing laws are proven at `StateDir.put` and `writeDurable`,
// which are internal because no caller outside the file may reach past the cadence.
@testable import EQEngine
import EQFold
import EQLog

/// One connection's frames, stamped with when they arrived. The `WorldSink` a `Connection` will be.
final class RecordingSink: WorldSink, @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [(at: Date, message: EngineMessage)] = []
    private var open = true

    func deliver(_ m: EngineMessage) {
        lock.lock(); defer { lock.unlock() }
        frames.append((Date(), m))
    }

    var isOpen: Bool {
        lock.lock(); defer { lock.unlock() }
        return open
    }

    func close() { lock.lock(); open = false; lock.unlock() }

    /// Everything heard so far, oldest first. A copy — the sink keeps taking frames.
    func heard() -> [(at: Date, message: EngineMessage)] {
        lock.lock(); defer { lock.unlock() }
        return frames
    }

    func count() -> Int { heard().count }
}

/// A fold with nothing behind it — the Rust's `views::NoRows`. Every window it cuts is empty,
/// which is what lets the epoch, subscription and generation laws be proven with no fold, no thread
/// and no file in the room.
struct EmptyRows: ViewRows {
    func rows(_ source: SourceDef) -> [SourceRow]? { nil }
    func revision(_ source: SourceDef) -> UInt64? { nil }
}

/// A sink that folds nothing and counts the beats it was handed — the `tick` oracle.
final class TickCountingSink: EventSink, @unchecked Sendable {
    private let inner = CountingSink()
    private let lock = NSLock()
    private var beats: [Int64] = []

    func event(_ event: IngestEvent) { inner.event(event) }
    func report() -> SinkReport { inner.report() }

    func tick(_ nowMs: Int64) {
        lock.lock(); defer { lock.unlock() }
        beats.append(nowMs)
    }

    func beatsTaken() -> [Int64] {
        lock.lock(); defer { lock.unlock() }
        return beats
    }
}

final class WorldTests: XCTestCase {
    static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let goldens = repo.appendingPathComponent("Goldens")
    static let fixtures = repo.appendingPathComponent("Resources/fixtures")

    /// The fixture every attach test folds. Small enough that a scan lands in well under a second
    /// and every line of it is an event, which is what makes `mark.offset == size` an oracle.
    static let fixture = "w1-current-session"

    // MARK: - Staging

    /// A scratch install of this test's own: `<tmp>/<tag>/Logs/eqlog_Primitive_freeport.txt`, the
    /// path shape `logs.list` and `characterOf` both read.
    func stage(_ tag: String, _ fixture: String = WorldTests.fixture) throws -> (root: URL, log: URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("eqengine-\(tag)-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.removeItem(at: root)
        let logs = root.appendingPathComponent("Logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let log = logs.appendingPathComponent("eqlog_Primitive_freeport.txt")
        let source = Self.fixtures.appendingPathComponent("\(fixture).log")
        try FileManager.default.copyItem(at: source, to: log)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, log)
    }

    /// Wait for the fold to land. A poll rather than a notification: the edge a client waits on is
    /// `status: live`, and this test waits on exactly what a client waits on.
    @discardableResult
    func waitForLive(_ world: World, _ seconds: TimeInterval = 20) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if world.health().status == .live { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return false
    }

    /// The `ts` of the fixture's last timestamped line, read through a host clock — what a fold of
    /// these bytes on THIS machine must report.
    func lastStampOf(_ log: URL) throws -> Int64 {
        let text = try String(contentsOf: log, encoding: .utf8)
        let clock = Clock.host()
        var last: Int64 = 0
        for line in text.split(separator: "\n") {
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { continue }
            let ts = clock.parseEQTimestamp(String(line[line.index(after: line.startIndex)..<close]))
            if ts != 0 { last = ts }
        }
        return last
    }

    func goldenMeta(_ name: String) throws -> JSONValue {
        let data = try Data(contentsOf: Self.goldens.appendingPathComponent("\(name)/snapshots.json"))
        return try JSONValue.parse(data)
    }

    // MARK: - A real attach, over real bytes

    func testAnAttachFoldsTheFixtureAndGoesLive() throws {
        let staged = try stage("live")
        let gold = try goldenMeta(Self.fixture)
        let size = Int64((try FileManager.default
            .attributesOfItem(atPath: staged.log.path)[.size] as? NSNumber)?.int64Value ?? 0)

        let world = World(ingest: starter(countingSinks()))
        let sink = RecordingSink()
        world.join(sink)

        let result = world.attach(staged.log.path)
        XCTAssertTrue(result.accepted)
        XCTAssertEqual(result.epoch, 2, "a launch is generation 1 and the first attach makes it 2")

        XCTAssertTrue(waitForLive(world), "the fold never landed")

        let health = world.health()
        XCTAssertEqual(health.status, .live)
        XCTAssertEqual(health.epoch, 2)
        // Events, not lines: the golden's own count of what the parser produced from these bytes.
        XCTAssertEqual(health.events, gold["meta"]["events"].int64)
        // `lastEventTs` is the LOG's own clock, read through the HOST's zone — the parser derives
        // its zone from the host, so this number moves with the machine and the golden's copy
        // (recorded in America/Los_Angeles) is not an oracle for it. The oracle is the same stamp
        // read the same way: the fixture's last timestamped line, through a host clock.
        XCTAssertEqual(health.lastEventTs, try lastStampOf(staged.log))
        // The mark is the end of the last COMPLETE line folded. The fixture ends on a newline, so
        // that is the whole file.
        XCTAssertEqual(health.mark?.offset, size)
        XCTAssertEqual(health.mark?.log, staged.log.path)
        XCTAssertNotNil(health.logMtimeMs, "an attached log has a stat")

        // …and the world's own door onto the coordinate says the same thing.
        XCTAssertEqual(world.mark().checkpoint, UInt64(size))
        XCTAssertEqual(world.mark().events, gold["meta"]["events"].int64)
    }

    func testHealthBeforeAnyAttachIsIdleAndClaimsNoMeasurement() {
        let world = World(ingest: { _, _, _, _ in })
        let health = world.health()
        XCTAssertEqual(health.status, .idle)
        XCTAssertEqual(health.epoch, 1)
        // Absent, not zero: publishing `offset: 0` would be a measurement nobody took.
        XCTAssertNil(health.mark)
        XCTAssertNil(health.events)
        XCTAssertNil(health.lastEventTs)
        XCTAssertNil(health.logMtimeMs)
        XCTAssertEqual(world.mark().checkpoint, 0)
        XCTAssertNil(world.mark().log)
    }

    // MARK: - Progress

    func testProgressFramesArriveAtMostFourPerSecondAndEndAtOneHundred() throws {
        let staged = try stage("progress")
        let world = World(ingest: starter(countingSinks()))
        let sink = RecordingSink()
        world.join(sink)
        world.attach(staged.log.path)
        XCTAssertTrue(waitForLive(world), "the fold never landed")

        var stamps: [Date] = []
        var progresses: [FoldProgress] = []
        for frame in sink.heard() {
            guard case .epoch(_, let reason, let progress) = frame.message else { continue }
            if reason == "attach" {
                XCTAssertNil(progress,
                             "at the bump the fold has not opened the file, so it claims no pct")
                continue
            }
            XCTAssertEqual(reason, "progress")
            guard let progress else { return XCTFail("a progress frame carries progress") }
            stamps.append(frame.at)
            progresses.append(progress)
        }

        XCTAssertFalse(progresses.isEmpty, "a landing fold announces at least its final frame")
        // The floor between two announcements is 250 ms — a cadence, not a count. The final frame
        // is the one exception: it does not ask the cadence, because a client whose loading bar
        // depends on it must never lose it to a fold that finished inside one interval.
        for i in 1..<max(stamps.count - 1, 1) where stamps.count > 2 {
            XCTAssertGreaterThanOrEqual(stamps[i].timeIntervalSince(stamps[i - 1]), 0.24,
                                        "two scan frames landed inside one cadence")
        }
        // The last frame of the scan states the whole fold: the ceiling and the exact count.
        let scanFrames = progresses.filter { !$0.live }
        XCTAssertEqual(scanFrames.last?.pct, 100)
        XCTAssertEqual(scanFrames.last?.offset, scanFrames.last?.logSize)
        // Absent for the scan, `true` for the tail — never `false`, which would put a field with no
        // reader on every frame of every historical fold.
        XCTAssertFalse(scanFrames.contains { $0.live })
    }

    // MARK: - Preemption

    func testASecondAttachPreemptsTheFirstAndTheLoserSaysNothing() throws {
        let staged = try stage("preempt")
        let world = World(ingest: starter(countingSinks()))
        let sink = RecordingSink()
        world.join(sink)

        let first = world.attach(staged.log.path)
        let loser = world.generation()
        let second = world.attach(staged.log.path)

        XCTAssertEqual(first.epoch, 2)
        XCTAssertEqual(second.epoch, 3, "an attach bumps the epoch")
        XCTAssertNotEqual(world.generation(), loser)

        // The loser is stripped of every way to speak, inside the lock that bumped the epoch.
        XCTAssertFalse(world.owns(loser))
        XCTAssertFalse(world.reportStatus(loser, .live))
        XCTAssertFalse(world.reportProgress(loser, aMark(10, 50)))
        XCTAssertFalse(world.reportIdle(loser))
        XCTAssertFalse(world.reportModulesChanged(loser, [("loot", 3)]))

        XCTAssertTrue(waitForLive(world), "the winner never landed")
        XCTAssertEqual(world.health().epoch, 3, "the world names the winner")

        // Both connections heard both bumps, in order, and nothing named the loser after.
        let epochs = sink.heard().compactMap { frame -> Int? in
            if case .epoch(let e, "attach", _) = frame.message { return e }
            return nil
        }
        XCTAssertEqual(epochs, [2, 3])
    }

    // MARK: - The tick

    func testTheLiveWorldIsTickedOnceASecond() throws {
        let staged = try stage("tick")
        let beats = TickCountingSink()
        let world = World(ingest: starter { _ in beats })
        world.attach(staged.log.path)
        XCTAssertTrue(waitForLive(world), "the fold never landed")

        // One beat at go-live, before `status: live` is published, then the cadence.
        XCTAssertGreaterThanOrEqual(beats.beatsTaken().count, 1,
                                    "the go-live sweep happens before the world says it is live")
        let watched: TimeInterval = 4.2
        Thread.sleep(forTimeInterval: watched)
        let stamps = beats.beatsTaken()
        // The number handed in is a wall clock in epoch millis, and it only moves forwards.
        XCTAssertEqual(stamps, stamps.sorted())
        XCTAssertGreaterThan(stamps[0], 1_700_000_000_000)
        // A ceiling, not a promise: a turn that ran late beats once, not twice, because "age the
        // model to now" is idempotent in `now`. So the count is bounded above by the seconds
        // watched and below by one fewer — the tail polls every 400 ms, so a beat lands on roughly
        // every third turn of the loop and the last one can fall just outside the window.
        let seconds = Double(stamps.last! - stamps.first!) / 1000
        XCTAssertGreaterThanOrEqual(stamps.count, 3,
                                    "beats \(stamps.count) over \(seconds) s: the heartbeat did "
                                    + "not keep up")
        XCTAssertLessThanOrEqual(stamps.count, Int(watched) + 2,
                                 "the heartbeat beat more often than once a second")
        // …and the gaps are the interval, not a burst: no two beats inside 900 ms of each other.
        for i in 1..<stamps.count {
            XCTAssertGreaterThanOrEqual(stamps[i] - stamps[i - 1], 900,
                                        "two beats landed inside one second")
        }
    }

    // MARK: - The module snapshot door

    func testTheLootModuleAnswersThroughTheOneDoorAndMatchesTheGolden() throws {
        let staged = try stage("loot")
        let gold = try goldenMeta(Self.fixture)
        guard let lootGold = (gold["modules"].array ?? [])
            .first(where: { $0["id"].string == "loot" })?["snapshot"] else {
            throw XCTSkip("the golden carries no loot module")
        }

        let world = World(ingest: starter(foldingSinks()))
        world.attach(staged.log.path)
        XCTAssertTrue(waitForLive(world), "the fold never landed")

        switch world.moduleSnapshot("loot") {
        case .snapshot(let snapshot):
            XCTAssertEqual(snapshot.seq, lootGold["seq"].int64)
            XCTAssertEqual(snapshot.state, lootGold["state"])
        case .notFound:
            XCTFail("this fold folds a loot module")
        case .unavailable(let why):
            XCTFail("the fold did not answer: \(why)")
        }
    }

    func testAModuleNobodyFoldsIsNotFoundAndAWorldWithNoFoldIsUnavailable() throws {
        let idle = World(ingest: { _, _, _, _ in })
        switch idle.moduleSnapshot("loot") {
        case .unavailable(let why):
            XCTAssertEqual(why, "no log is attached, so there is no fold to ask")
        default:
            XCTFail("a world with no fold has nobody to ask")
        }

        let staged = try stage("notfound")
        let world = World(ingest: starter(foldingSinks()))
        world.attach(staged.log.path)
        XCTAssertTrue(waitForLive(world), "the fold never landed")
        switch world.moduleSnapshot("nope") {
        case .notFound: break
        default: XCTFail("the registry is the authority on what a module is")
        }
    }

    // MARK: - The epoch and subscription laws, with the ingest replaced by a no-op

    /// A world whose attaches start nothing. The epoch, subscription and generation laws are proven
    /// with no thread, no file and no timing in the room.
    func noopWorld() -> World { World(ingest: { _, _, _, _ in }) }

    /// A path standing in for a log. Nothing in these tests opens it.
    let aLog = "/nowhere/eqlog_Nobody_freeport.txt"

    /// A validated view over a registered source. The smallest real one there is.
    func aView() throws -> View {
        try Views.validate(ViewDescriptor(source: "loot.ledger"))
    }

    func aMark(_ events: Int64, _ pct: Double) -> FoldMark {
        // Every mark these tests make stands in for a scan — the loop a landing fold ends in.
        FoldMark(checkpoint: 4096, events: events, pct: pct, total: 8192,
                 lastTs: 1_787_181_707_000, live: false)
    }

    @discardableResult
    func land(_ world: World, _ generation: UInt64, _ mark: FoldMark) -> Bool {
        world.reportFoldLanded(generation, mark, EmptyRows(), nil, Meter())
    }

    func testAnAttachBumpsTheGenerationAndTellsEveryone() {
        let world = noopWorld()
        let one = RecordingSink(), two = RecordingSink()
        world.join(one)
        world.join(two)

        let result = world.attach(aLog)
        XCTAssertTrue(result.accepted)
        XCTAssertEqual(result.epoch, 2)

        for sink in [one, two] {
            guard case .epoch(let epoch, let reason, let progress)? = sink.heard().first?.message else {
                return XCTFail("a connection-wide announcement is an epoch message")
            }
            XCTAssertEqual(epoch, 2)
            XCTAssertEqual(reason, "attach")
            XCTAssertNil(progress,
                         "at the bump the fold has not opened the file, so it claims no percentage")
        }
    }

    func testAConnectionThatLeftHearsNothingFurther() {
        let world = noopWorld()
        let stayed = RecordingSink(), left = RecordingSink()
        world.join(stayed)
        let leftId = world.join(left)
        world.leave(leftId)

        world.attach(aLog)

        XCTAssertEqual(stayed.count(), 1)
        XCTAssertEqual(left.count(), 0)
    }

    func testTheGenerationIsEngineGlobalAndMonotonic() {
        let world = noopWorld()
        XCTAssertEqual(world.attach(aLog).epoch, 2)
        XCTAssertEqual(world.attach(aLog).epoch, 3)
        XCTAssertEqual(world.health().epoch, 3)
    }

    func testAProgressFrameCarriesTheMeasurementToEveryConnection() {
        let world = noopWorld()
        let sink = RecordingSink()
        world.join(sink)
        world.attach(aLog)
        let generation = world.generation()

        XCTAssertTrue(world.reportProgress(generation, aMark(1571, 62.4)))
        let progress = sink.heard().compactMap { frame -> FoldProgress? in
            if case .epoch(_, "progress", let p) = frame.message { return p }
            return nil
        }
        guard let last = progress.last else { return XCTFail("progress rides an epoch message") }
        XCTAssertEqual(last.pct, 62.4, accuracy: 1e-9)
        XCTAssertEqual(last.events, 1571)
        // The two coordinates a loading bar needs, and they are the mark's own rather than anything
        // derived from `pct` — which is the whole reason they ride the frame.
        XCTAssertEqual(last.offset, 4096)
        XCTAssertEqual(last.logSize, 8192)
        XCTAssertEqual(world.mark().events, 1571)
        XCTAssertEqual(world.mark().checkpoint, 4096)
    }

    func testAScanFrameCarriesNoLiveFlagAndATailFrameCarriesIt() {
        let world = noopWorld()
        let sink = RecordingSink()
        world.join(sink)
        let turn = world.generation()

        XCTAssertTrue(world.reportProgress(turn, aMark(10, 12.5)))
        var live = aMark(11, 100)
        live.live = true
        XCTAssertTrue(world.reportProgress(turn, live))

        let flags = sink.heard().compactMap { frame -> Bool? in
            if case .epoch(_, "progress", let p) = frame.message { return p?.live }
            return nil
        }
        XCTAssertEqual(flags, [false, true],
                       "absent for the scan, true for the tail — never a field with no reader")
    }

    func testALandingFoldResetsEveryOpenSubscriptionAndGoesLive() throws {
        let world = noopWorld()
        let sink = RecordingSink(), bystander = RecordingSink()
        let listener = world.join(sink)
        world.join(bystander)
        world.openSubscription(listener, 7, try aView())
        world.openSubscription(listener, 9, try aView())
        world.attach(aLog)
        let generation = world.generation()

        XCTAssertTrue(land(world, generation, aMark(3, 100)))
        XCTAssertEqual(world.health().status, .live)

        var resetIds: [Int] = []
        for frame in sink.heard() {
            guard case .reset(let id, let epoch, let total, let rows) = frame.message else { continue }
            XCTAssertEqual(epoch, 2, "a reset names the generation that landed")
            XCTAssertTrue(rows.isEmpty)
            XCTAssertEqual(total, 0)
            resetIds.append(id)
        }
        XCTAssertEqual(resetIds, [7, 9])

        // A connection with no subscriptions is told about the epoch and nothing else.
        let bystanderResets = bystander.heard().filter {
            if case .reset = $0.message { return true }
            return false
        }
        XCTAssertTrue(bystanderResets.isEmpty)
    }

    func testASubscriptionBelongsToItsOwnConnection() throws {
        let world = noopWorld()
        let mine = world.join(RecordingSink())
        let theirs = world.join(RecordingSink())
        world.openSubscription(mine, 7, try aView())

        XCTAssertFalse(world.closeSubscription(theirs, 7))
        XCTAssertTrue(world.closeSubscription(mine, 7))
        XCTAssertFalse(world.closeSubscription(mine, 7))
    }

    func testAnIngestThatEndsLeavesTheWorldIdleWithItsGenerationIntact() {
        let world = noopWorld()
        world.attach(aLog)
        let generation = world.generation()
        XCTAssertTrue(world.reportIdle(generation))
        XCTAssertEqual(world.health().status, .idle)
        XCTAssertEqual(world.health().epoch, 2, "a dead fold bumps nothing")
    }

    // MARK: - What the app tells the engine

    func testADefinePushedBeforeAnAttachIsHeldAndReplayedAtConstruction() {
        let world = noopWorld()
        world.define("alerts", ["rules": .array([])])
        world.define("respawn", ["watches": .array([])])
        let held = world.heldDefines().map(\.0)
        XCTAssertEqual(held, ["alerts", "respawn"], "ordered by family")
        // An idempotent full-set replace: the latest push is the whole of what the app has said.
        world.define("alerts", ["rules": .array([.string("one")])])
        XCTAssertEqual(world.heldDefines().count, 2)
        XCTAssertEqual(world.heldDefines().first?.1["rules"].array?.count, 1)
    }

    func testTheLogDirectoryIsAFullSetReplaceAndListingRefusesUntilItIsPushed() throws {
        let world = noopWorld()
        switch world.listLogs() {
        case .success: XCTFail("nothing has been told to this engine")
        case .failure(let why): XCTAssertTrue(why.contains("logs.setDir"))
        }

        let staged = try stage("logsdir")
        world.setLogDir(staged.root.appendingPathComponent("Logs").path)
        guard case .success(let (dir, scan)) = world.listLogs() else {
            return XCTFail("a pushed directory is enumerable")
        }
        XCTAssertEqual(dir, staged.root.appendingPathComponent("Logs").path)
        XCTAssertEqual(scan.readable, .ok)
        XCTAssertEqual(scan.characters.map(\.name), ["Primitive"])
        XCTAssertEqual(scan.characters.map(\.server), ["freeport"])
    }

    func testASessionMarkIsRefusedByAWorldThatIsNotLive() {
        let world = noopWorld()
        let (took, status) = world.sessionMark(1_787_181_707_000)
        XCTAssertFalse(took)
        XCTAssertEqual(status, .idle)
        // …and a confirmation at a world with no fold is about a row that does not exist.
        XCTAssertFalse(world.confirmSighting("freeport::a rat"))
    }
}

// MARK: - The fold thread's own small laws (ingest.rs's unit tests)

final class IngestUnitTests: XCTestCase {
    func testTheCharacterComesOffTheProductsOwnFileName() {
        XCTAssertEqual(Ingest.characterOf(URL(fileURLWithPath: "/EQ/Logs/eqlog_Primitive_freeport.txt")),
                       "Primitive")
        // The oracle corpus's slice form goes through the parser's own rule.
        XCTAssertEqual(Ingest.characterOf(URL(fileURLWithPath: "eqlog_Primitive_freeport.patch-week.txt")),
                       "Primitive")
        // A character name may hold an underscore; the server may not, so the last one splits.
        XCTAssertEqual(Ingest.characterOf(URL(fileURLWithPath: "eqlog_Two_Names_freeport.txt")),
                       "Two_Names")
        XCTAssertEqual(Ingest.serverOf(URL(fileURLWithPath: "eqlog_Two_Names_freeport.txt")), "freeport")
    }

    func testAFileNameThatIsNotALogNamesNobody() {
        for name in ["notalog.txt", "eqlog_freeport.txt", "eqlog__freeport.txt", "eqlog_Primitive_.txt",
                     "eqlog_Primitive_freeport.log", "eqlog_Primitive_freeport", ".txt"] {
            XCTAssertNil(Ingest.characterOf(URL(fileURLWithPath: name)), name)
        }
    }

    func testTheCountingSinkCountsEventsAndRemembersTheLogsOwnClock() {
        let sink = CountingSink()
        // The payload is not read here: a counting sink folds nothing and takes its clock off the
        // serialized half. An empty payload is the honest stand-in.
        let empty = Payload()
        for (seq, ts) in [(0, 100), (1, 200), (2, 300)] {
            sink.event(IngestEvent(json: #"{"kind":"unknown","seq":\#(seq),"ts":\#(ts),"raw":"x"}"#,
                                   payload: empty, seq: Int64(seq), live: false))
        }
        XCTAssertEqual(sink.report().events, 3)
        XCTAssertEqual(sink.report().lastTs, 300)
        XCTAssertEqual(sink.report().liveEvents, 0)
    }

    func testAnEventWithAnUnreadableStampStillCounts() {
        let sink = CountingSink()
        let empty = Payload()
        sink.event(IngestEvent(json: #"{"kind":"unknown","seq":0,"ts":7,"raw":"x"}"#,
                               payload: empty, seq: 0, live: false))
        sink.event(IngestEvent(json: #"{"kind":"nonsense"}"#, payload: empty, seq: 1, live: true))
        XCTAssertEqual(sink.report().events, 2)
        XCTAssertEqual(sink.report().liveEvents, 1)
        XCTAssertEqual(sink.report().lastTs, 7,
                       "the last stamp that could be read stands; a missing one is not a zero")
    }
}

// MARK: - The state directory (state.rs's unit tests)

final class StateDirTests: XCTestCase {
    /// The app's exact bytes for both files, hand-written.
    static let appLedger = #"{"version":3,"sources":[{"key":"baseline","rows":[]},{"key":"primitive_freeport","rows":[{"mobKey":"a rat","spellKey":"malosi","family":"cast","casterKind":"self","casterLevel":51,"mobLevel":20,"debuffs":"","rank":0,"overchannel":false,"week":"2026-W34","resist":4,"land":7,"dmg":{"9":2},"firstTs":1000,"lastTs":2000}]}]}"#
    static let appOverlay = #"{"version":2,"updatedAt":"2026-08-19T16:21:54.000Z","sources":[{"key":"baseline","messages":[]},{"key":"primitive_freeport","messages":[{"text":"You feel much faster.","role":"landing","spells":[{"spell":"Alacrity","count":3}]}]}]}"#

    /// A scratch profile directory of this test's own.
    func scratch(_ name: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("eqengine-state-\(name)-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testTheFingerprintIsTheAppsOwnFunction() {
        // FNV-1a offset basis, paired with a length of zero.
        XCTAssertEqual(fingerprint(""), "0:811c9dc5")
        // Length is UTF-16 code units, so an astral character counts as two — the app's number.
        XCTAssertEqual(fingerprint("\u{1F600}").split(separator: ":").first, "2")
        XCTAssertNotEqual(fingerprint("a"), fingerprint("b"))
    }

    func testTheAppsFilesAreReadAndTheBaselineBucketsAreRefused() throws {
        let dir = try scratch("read")
        try Self.appLedger.write(to: dir.appendingPathComponent(StateFiles.resistLedger),
                                 atomically: true, encoding: .utf8)
        try Self.appOverlay.write(to: dir.appendingPathComponent(StateFiles.messageOverlay),
                                  atomically: true, encoding: .utf8)
        let state = StateDir(dir).read()
        XCTAssertEqual(state.resist.count, 1)
        XCTAssertEqual(state.resist.first?.key, "primitive_freeport")
        XCTAssertEqual(state.overlay.count, 1)
        XCTAssertEqual(state.overlay.first?.0, "primitive_freeport")
    }

    func testAMissingDirectoryReadsAsEmptyAndSaysNothingFatal() {
        let state = StateDir(URL(fileURLWithPath: "/nowhere/there-is-no-such-profile")).read()
        XCTAssertTrue(state.resist.isEmpty)
        XCTAssertTrue(state.overlay.isEmpty)
    }

    func testACorruptFileReadsAsEmpty() throws {
        let dir = try scratch("corrupt")
        try #"{"version":3,"sources":[{"key":"#
            .write(to: dir.appendingPathComponent(StateFiles.resistLedger),
                   atomically: true, encoding: .utf8)
        try "not json at all".write(to: dir.appendingPathComponent(StateFiles.messageOverlay),
                                    atomically: true, encoding: .utf8)
        let state = StateDir(dir).read()
        XCTAssertTrue(state.resist.isEmpty)
        XCTAssertTrue(state.overlay.isEmpty)
    }

    func testADurableWriteLeavesNoScratchFileAndReplacesTheTarget() throws {
        let dir = try scratch("durable")
        let path = dir.appendingPathComponent(StateFiles.resistLedger)
        try "the previous ledger".write(to: path, atomically: true, encoding: .utf8)
        try writeDurable(path, Self.appLedger)
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), Self.appLedger)
        // `<path>.tmp` beside it, gone. A scratch file left behind holds a whole user ledger on a
        // volume that may have just said it had no room.
        XCTAssertFalse(FileManager.default
            .fileExists(atPath: dir.appendingPathComponent("resist-ledger.json.tmp").path))
    }

    func testAnIdenticalWriteIsDeclinedAndAChangedOneIsNot() throws {
        // The proof is the file's absence: after a write lands, the file is deleted out from under
        // the writer, and a second write of identical bytes must not bring it back because the
        // writer declined before touching the disk. A changed one must.
        let dir = try scratch("coalesce")
        let path = dir.appendingPathComponent(StateFiles.resistLedger)
        let state = StateDir(dir)
        let fm = FileManager.default

        state.put(StateFiles.resistLedger, Self.appLedger, isLedger: true)
        XCTAssertTrue(fm.fileExists(atPath: path.path))
        try fm.removeItem(at: path)

        state.put(StateFiles.resistLedger, Self.appLedger, isLedger: true)
        XCTAssertFalse(fm.fileExists(atPath: path.path), "identical bytes were rewritten")

        state.put(StateFiles.resistLedger, #"{"version":3,"sources":[]}"#, isLedger: true)
        XCTAssertTrue(fm.fileExists(atPath: path.path), "changed bytes were declined")

        // Two files, two memories: one shared fingerprint slot would make each write cancel the
        // other's, and the two artifacts change at completely different rates.
        try fm.removeItem(at: path)
        state.put(StateFiles.messageOverlay, Self.appOverlay, isLedger: false)
        state.put(StateFiles.resistLedger, #"{"version":3,"sources":[]}"#, isLedger: true)
        XCTAssertFalse(fm.fileExists(atPath: path.path),
                       "the overlay's write disturbed the ledger's memory")
    }

    func testAWriteIntoAMissingDirectoryCreatesIt() throws {
        let dir = try scratch("makedir").appendingPathComponent("not/yet")
        try writeDurable(dir.appendingPathComponent(StateFiles.resistLedger), Self.appLedger)
        XCTAssertTrue(FileManager.default
            .fileExists(atPath: dir.appendingPathComponent(StateFiles.resistLedger).path))
    }
}

// MARK: - The log directory scan (logs.rs's unit tests)

final class LogsScanTests: XCTestCase {
    func scratch(_ tag: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("eqengine-logs-\(tag)-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// Write one character log with a stated modification time, so order is asserted against a fact
    /// rather than against how fast the test ran.
    @discardableResult
    func log(_ dir: URL, _ file: String, _ mtimeMs: Int64) throws -> URL {
        let path = dir.appendingPathComponent(file)
        try "[Wed Aug 20 12:00:00 2026] You have entered Freeport.\n"
            .write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: Double(mtimeMs) / 1000)],
            ofItemAtPath: path.path)
        return path
    }

    func testADirectoryOfLogsBecomesRowsMostRecentlyWrittenFirst() throws {
        let dir = try scratch("order")
        try log(dir, "eqlog_Primitive_freeport.txt", 1_700_000_002_000)
        try log(dir, "eqlog_Alt_freeport.txt", 1_700_000_009_000)
        try log(dir, "eqlog_Third_povar.txt", 1_700_000_005_000)

        let found = Logs.scan(dir)
        XCTAssertEqual(found.readable, .ok)
        // The sort key is the file's own stamp, which is what "last played" means here.
        XCTAssertEqual(found.characters.map(\.name), ["Alt", "Third", "Primitive"])
        XCTAssertEqual(found.characters.first?.server, "freeport")
        XCTAssertEqual(found.characters.first?.lastPlayed, 1_700_000_009_000)
        XCTAssertEqual(found.characters.first?.logPath,
                       dir.appendingPathComponent("eqlog_Alt_freeport.txt").path)
    }

    func testOnlyCharacterLogsAreRowsAndTheSplitIsLeftmost() throws {
        let dir = try scratch("names")
        try log(dir, "eqlog_Primitive_freeport.txt", 1_700_000_003_000)
        // A server name may carry an underscore and a character name may not, which is why the
        // split is leftmost.
        try log(dir, "eqlog_Bard_test_server.txt", 1_700_000_002_000)
        // Case-insensitive at both ends.
        try log(dir, "EQLOG_Shouty_FREEPORT.TXT", 1_700_000_001_000)
        // …and four things that are not character logs at all.
        try log(dir, "eqlog_.txt", 1_700_000_004_000)
        try log(dir, "eqlog__freeport.txt", 1_700_000_004_000)
        try log(dir, "eqlog_Nameless_.txt", 1_700_000_004_000)
        try log(dir, "dbg.txt", 1_700_000_004_000)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("eqlog_Folder_freeport.txt"), withIntermediateDirectories: true)

        let rows = Logs.scan(dir).characters.map { ($0.name, $0.server) }
        XCTAssertEqual(rows.map(\.0), ["Primitive", "Bard", "Shouty"])
        XCTAssertEqual(rows.map(\.1), ["freeport", "test_server", "FREEPORT"])
    }

    func testAMissingDirectoryIsMissingAndNotAnEmptyInstall() throws {
        // A failed read is not "no logs" — the two are different sentences to a person. A machine
        // with EverQuest installed somewhere else reaches this every launch.
        let found = Logs.scan(try scratch("gone").appendingPathComponent("Logs"))
        XCTAssertEqual(found.readable, .missing)
        XCTAssertTrue(found.characters.isEmpty)
    }

    func testAPathThatIsAFileIsUnreadableRatherThanMissing() throws {
        let dir = try scratch("notadir")
        let file = try log(dir, "eqlog_Primitive_freeport.txt", 1_700_000_000_000)
        let found = Logs.scan(file)
        XCTAssertEqual(found.readable, .unreadable)
        XCTAssertTrue(found.characters.isEmpty)
    }

    func testAnInstallWithNoCharacterLogsIsOkAndEmpty() throws {
        // The third silence, and the one a player is told to fix: the folder is right and `/log on`
        // has never been typed. `ok` with no rows is what says so.
        let dir = try scratch("nologs")
        try log(dir, "dbg.txt", 1_700_000_000_000)
        let found = Logs.scan(dir)
        XCTAssertEqual(found.readable, .ok)
        XCTAssertTrue(found.characters.isEmpty)
    }

    func testTiesAreBrokenByPathSoTwoScansOfOneFolderAgree() throws {
        // A fresh copy of an install is a folder of files with one stamp, and a directory read
        // promises no order — so without the tiebreak two consecutive scans could disagree and a
        // served window would churn for a world that did not move.
        let dir = try scratch("ties")
        try log(dir, "eqlog_Zeta_freeport.txt", 1_700_000_000_000)
        try log(dir, "eqlog_Alpha_freeport.txt", 1_700_000_000_000)
        XCTAssertEqual(Logs.scan(dir).characters.map(\.logPath),
                       Logs.scan(dir).characters.map(\.logPath))
        XCTAssertEqual(Logs.scan(dir).characters.map(\.name), ["Alpha", "Zeta"])
    }

    func testThePushedDirectoryIsAFullSetReplaceOfOneValue() {
        var held = LogDir()
        XCTAssertNil(held.get(), "nothing has been told to this engine")
        held.set("/EverQuest Legends/Logs")
        XCTAssertEqual(held.get()?.path, "/EverQuest Legends/Logs")
        // The latest push is the whole of what the app has said — there is nothing to accumulate.
        held.set("/Second Install/Logs")
        XCTAssertEqual(held.get()?.path, "/Second Install/Logs")
    }
}
