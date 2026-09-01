import XCTest
import EQCompanionCore
import EQFold
import EQLog
@testable import EQEngine

/// The resume path, end to end over real bytes: attach, checkpoint, quit, PLAY WHILE THE APP IS
/// CLOSED (the log grows), attach again — and the resumed world must be indistinguishable from the
/// world that scanned every byte from zero. That last clause is the whole feature: a checkpoint is
/// a saved rescan, never a second source of truth.
final class FoldResumeTests: XCTestCase {
    static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let fixtures = repo.appendingPathComponent("Resources/fixtures")
    /// Dense enough that a half-fold has real state in every corner: pets, buffs, kills, credit.
    static let fixture = "p4-pet-buff-kill-credit"

    private var caught: [String] = []
    private let caughtLock = NSLock()
    private var oldSink: (@Sendable (String) -> Void)?

    override func setUp() {
        super.setUp()
        oldSink = diagnosticSink
        caughtLock.lock(); caught = []; caughtLock.unlock()
        let lock = caughtLock
        diagnosticSink = { [weak self] line in
            lock.lock(); self?.caught.append(line); lock.unlock()
        }
    }

    override func tearDown() {
        diagnosticSink = oldSink
        super.tearDown()
    }

    private func diagnostics() -> [String] {
        caughtLock.lock(); defer { caughtLock.unlock() }
        return caught
    }

    // MARK: - Staging

    private struct Staged {
        var root: URL
        var log: URL
        var stateDir: URL
        /// The bytes not yet in the log — what "playing while EQC is closed" appends.
        var remainder: Data
    }

    /// The fixture's log split at a line boundary: the first `head` fraction written, the rest kept
    /// to append later. Splitting on LINES, because the game appends whole lines and the checkpoint
    /// mark always sits at one.
    private func stage(_ tag: String, head: Double) throws -> Staged {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fold-resume-\(tag)-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.removeItem(at: root)
        let logs = root.appendingPathComponent("Logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let source = Self.fixtures.appendingPathComponent("\(Self.fixture).log")
        let text = try String(contentsOf: source, encoding: .isoLatin1)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let cut = Int(Double(lines.count) * head)
        let headText = lines[..<cut].joined(separator: "\n") + "\n"
        let tailText = lines[cut...].joined(separator: "\n")
        let log = logs.appendingPathComponent("eqlog_Primitive_freeport.txt")
        try headText.data(using: .isoLatin1)!.write(to: log)
        let stateDir = root.appendingPathComponent("state")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return Staged(root: root, log: log, stateDir: stateDir,
                      remainder: tailText.data(using: .isoLatin1)!)
    }

    /// The landing save runs on the fold thread AFTER `status: "live"` is published (the edge
    /// `waitForLive` returns on), and shutdown does not wait for it — so the file must be waited
    /// for the same way liveness is. Without this, a refusal test can pass for the wrong reason:
    /// "full scan (no checkpoint)" matches the same diagnostics a real refusal prints.
    private func waitForCheckpoint(_ staged: Staged, _ seconds: TimeInterval = 10) -> Bool {
        let file = FoldCheckpointStore.fileURL(dir: staged.stateDir, log: staged.log)
        let deadline = Date().addingTimeInterval(seconds)
        while !FileManager.default.fileExists(atPath: file.path) {
            if Date() >= deadline { return false }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return true
    }

    private func waitForLive(_ world: World, _ seconds: TimeInterval = 30) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if world.health().status == .live { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return false
    }

    /// One dispatch's single reply, or null. Mirrors OpsTests' `one`.
    private func reply(_ outcome: Outcome) -> JSONValue {
        if case .send(let messages) = outcome { return messages.first ?? .null }
        return .null
    }

    /// Every module's published snapshot plus the combat snapshot, through the same ops a client
    /// uses — the world as anyone can actually observe it.
    private func observableWorld(_ world: World) -> JSONValue {
        let session = Session(listener: world.join(RecordingSink()))
        var o: [String: JSONValue] = [:]
        for id in wiringOrder {
            o[id] = reply(Ops.dispatch(world, session, id: 1, op: "module.snapshot",
                                       params: ["module": .string(id)]))
        }
        o["__combat"] = reply(Ops.dispatch(world, session, id: 2, op: "combat.snapshot", params: [:]))
        return .object(o)
    }

    private func fullConformanceOrSkip() throws {
        let sink = FoldSink(SinkInputs(log: URL(fileURLWithPath: "/nowhere/eqlog_P_f.txt"),
                                       character: "P", db: SpellDb.shared(), clock: Clock.host(),
                                       attachedAtMs: 0, stateDir: nil))
        if sink.checkpointWorld() == nil {
            throw XCTSkip("not every module conforms to FoldCheckpointable yet - the world blob is still partial")
        }
    }

    // MARK: - The feature

    func testAResumedAttachIsIndistinguishableFromAFullScan() throws {
        try fullConformanceOrSkip()

        // Session one: fold 60% of the log, land, quit. The landing writes the checkpoint.
        let staged = try stage("equal", head: 0.6)
        let w1 = World(ingest: starter(foldingSinks()))
        XCTAssertTrue(w1.attach(staged.log.path, stateDir: staged.stateDir.path).accepted)
        XCTAssertTrue(waitForLive(w1), "the first fold must land")
        w1.shutdown()
        XCTAssertTrue(waitForCheckpoint(staged),
                      "the landing must have written a checkpoint:\n"
                        + diagnostics().filter { $0.contains("checkpoint") }.joined(separator: "\n"))

        // The game is played while EQC is closed: the log grows.
        let h = try FileHandle(forWritingTo: staged.log)
        try h.seekToEnd(); try h.write(contentsOf: staged.remainder); try h.close()

        // Session two resumes; session three scans the same final bytes from zero.
        let w2 = World(ingest: starter(foldingSinks()))
        XCTAssertTrue(w2.attach(staged.log.path, stateDir: staged.stateDir.path).accepted)
        XCTAssertTrue(waitForLive(w2), "the resumed fold must land")
        XCTAssertTrue(diagnostics().contains { $0.contains("checkpoint: resumed") },
                      "the second attach must actually have resumed, or this test proves nothing:\n"
                        + diagnostics().filter { $0.contains("checkpoint") }.joined(separator: "\n"))

        let w3 = World(ingest: starter(foldingSinks()))
        XCTAssertTrue(w3.attach(staged.log.path).accepted)   // no stateDir: the from-zero canon
        XCTAssertTrue(waitForLive(w3), "the canonical fold must land")

        let resumed = observableWorld(w2)
        let canon = observableWorld(w3)
        w2.shutdown(); w3.shutdown()
        let diff = SnapshotDiff.compare(golden: canon, ours: resumed, limit: 5)
        XCTAssertTrue(diff.isEqual, "the resumed world diverged from the from-zero world:\n"
                        + diff.mismatches.joined(separator: "\n"))
    }

    func testATrimmedLogIsRefusedAndFullyRescanned() throws {
        try fullConformanceOrSkip()

        let staged = try stage("trim", head: 1.0)
        let w1 = World(ingest: starter(foldingSinks()))
        XCTAssertTrue(w1.attach(staged.log.path, stateDir: staged.stateDir.path).accepted)
        XCTAssertTrue(waitForLive(w1))
        w1.shutdown()
        XCTAssertTrue(waitForCheckpoint(staged), "the landing must have written a checkpoint")

        // The user trims the log below the mark - the bytes the checkpoint summarizes are gone.
        let size = (try FileManager.default.attributesOfItem(atPath: staged.log.path)[.size] as? NSNumber)?.uint64Value ?? 0
        let h = try FileHandle(forWritingTo: staged.log)
        try h.truncate(atOffset: size / 2)
        try h.close()

        let w2 = World(ingest: starter(foldingSinks()))
        XCTAssertTrue(w2.attach(staged.log.path, stateDir: staged.stateDir.path).accepted)
        XCTAssertTrue(waitForLive(w2))
        defer { w2.shutdown() }
        XCTAssertTrue(diagnostics().contains { $0.contains("full scan (the log shrank below the mark)") },
                      "a trimmed log must be refused and rescanned:\n"
                        + diagnostics().filter { $0.contains("checkpoint") }.joined(separator: "\n"))
        XCTAssertFalse(diagnostics().contains { $0.contains("checkpoint: resumed") })
    }

    func testARecreatedLogIsADifferentFileAndFullyRescanned() throws {
        try fullConformanceOrSkip()

        let staged = try stage("inode", head: 1.0)
        let w1 = World(ingest: starter(foldingSinks()))
        XCTAssertTrue(w1.attach(staged.log.path, stateDir: staged.stateDir.path).accepted)
        XCTAssertTrue(waitForLive(w1))
        w1.shutdown()
        XCTAssertTrue(waitForCheckpoint(staged), "the landing must have written a checkpoint")

        // Same bytes, same name, NEW FILE - a deleted and recreated log is a different history.
        let bytes = try Data(contentsOf: staged.log)
        try FileManager.default.removeItem(at: staged.log)
        try bytes.write(to: staged.log)

        let w2 = World(ingest: starter(foldingSinks()))
        XCTAssertTrue(w2.attach(staged.log.path, stateDir: staged.stateDir.path).accepted)
        XCTAssertTrue(waitForLive(w2))
        defer { w2.shutdown() }
        XCTAssertTrue(diagnostics().contains { $0.contains("full scan (the log is a different file)") },
                      diagnostics().filter { $0.contains("checkpoint") }.joined(separator: "\n"))
    }
}
