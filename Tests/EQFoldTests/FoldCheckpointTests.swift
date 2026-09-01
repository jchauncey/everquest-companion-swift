import XCTest
import EQCompanionCore
import EQLog
@testable import EQFold

/// The checkpoint oracle: a fold resumed from a checkpoint must be INDISTINGUISHABLE from the fold
/// that never stopped.
///
/// How it tests one module without checkpointing the whole world: fold a world to a split point,
/// then, on the world's own module, `reset()` and `restoreCheckpoint(blob)` — replacing its state
/// with the codec's copy of itself. If the codec is complete that is a no-op and the tail folds to
/// exactly the straight-through result; if the codec forgot a field, the reset turned that field
/// virgin and the tail diverges, and EVERY module plus combat is compared at the end so a
/// divergence cannot hide behind a neighbour. This is why the contract says restore resets first:
/// restore-in-place would inherit the very state the codec failed to carry, and this oracle could
/// never fail.
///
/// The golden fixtures are the corpus, and Rust-engine parity makes them a strong one: matching the
/// straight-through fold here means matching the Rust engine's answer for the same bytes.
final class FoldCheckpointTests: XCTestCase {
    static let goldens = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Goldens")

    /// A world built exactly the way `GoldenSnapshotsTests` builds one, minus the folding.
    private static func makeWorld(_ gold: JSONValue, fixture: String) -> Fold {
        let clock = Clock(identifier: gold["meta"]["tz"].string ?? "America/Los_Angeles")!
        let db = SpellDb.shared()
        var deps = ClusterDeps()
        deps.knownSpell = Set(db.keys())
        deps.spellClasses = spellClassIndex(db)
        deps.launchMs = Epoch.launchMs(clock)
        deps.constructionNowMs = gold["meta"]["constructionNowMs"].int64 ?? 0
        let character = gold["meta"]["character"].string ?? "Primitive"
        deps.character = ["name": .string(character), "server": "freeport",
                          "logPath": .string("eqlog_\(character)_freeport.\(fixture).txt")]
        deps.facts = SpellFacts.project(db)
        let engine = CombatEngine()
        engine.reset()
        engine.setPlayerName(character)
        return Fold(registry: registered(deps), launchMs: deps.launchMs).withCombat(engine)
    }

    private struct Fixture {
        var name: String
        var gold: JSONValue
        var events: [Event]
    }

    private static func load(_ name: String) throws -> Fixture {
        let dir = goldens.appendingPathComponent(name)
        let text = try String(contentsOf: dir.appendingPathComponent("events.ndjson"), encoding: .utf8)
        let gold = try JSONValue.parse(try Data(contentsOf: dir.appendingPathComponent("snapshots.json")))
        let events = text.split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { Event.fromJSON(String($0)) }
        return Fixture(name: name, gold: gold, events: events)
    }

    /// The world's full answer — every module and the combat engine, one value.
    private static func answer(_ f: Fold) -> JSONValue {
        var o: [String: JSONValue] = [:]
        for m in f.registry.mods { o[m.id] = m.snapshot() }
        if let c = f.combat {
            o["__combat"] = c.snapshot(now: f.lastTs, opts: .full(), roster: f.registry.roster())
        }
        return .object(o)
    }

    /// One fixture, one split, EVERY conforming module at once — the world a real resume builds,
    /// where nothing that can be restored was left un-restored. One straight fold and one resumed
    /// fold per split, however many modules conform; a divergence names its module in the diff
    /// path, so nothing is lost by testing them together.
    private static func oracle(_ fx: Fixture, split: Int) -> SnapshotDiff.Report? {
        let straight = makeWorld(fx.gold, fixture: fx.name)
        for ev in fx.events { straight.onPrimary(ev, live: false) }

        let resumed = makeWorld(fx.gold, fixture: fx.name)
        for ev in fx.events.prefix(split) { resumed.onPrimary(ev, live: false) }
        // THE WHOLE-WORLD DOOR, once every part conforms: detectors, all modules, the combat
        // engine, one blob — the exact artifact the resume path writes to disk. While any part
        // still lacks a codec this is nil, and the per-module loop below keeps the rest honest.
        if let blob = resumed.checkpointState() {
            guard resumed.restoreCheckpoint(blob) else {
                var r = SnapshotDiff.Report()
                r.mismatches.append("the world refused its own checkpoint at split \(split)")
                return r
            }
            let re = resumed.checkpointState()
            if re != blob {
                return SnapshotDiff.compare(golden: blob, ours: re ?? .null, path: "$.reencode.world", limit: 3)
            }
            for ev in fx.events.dropFirst(split) { resumed.onPrimary(ev, live: false) }
            let report = SnapshotDiff.compare(golden: answer(straight), ours: answer(resumed), limit: 3)
            return report.isEqual ? nil : report
        }
        for m in resumed.registry.mods {
            guard let cp = m as? FoldCheckpointable else { continue }
            let blob = cp.checkpointState()
            guard cp.restoreCheckpoint(blob) else {
                var r = SnapshotDiff.Report()
                r.mismatches.append("\(m.id) refused its own checkpoint at split \(split)")
                return r
            }
            // Codec stability: the restored state re-encodes to the same value, byte-deep. A codec
            // that "works" but re-encodes differently would make every later checkpoint a mutation.
            let re = cp.checkpointState()
            if re != blob {
                return SnapshotDiff.compare(golden: blob, ours: re, path: "$.reencode.\(m.id)", limit: 3)
            }
        }
        for ev in fx.events.dropFirst(split) { resumed.onPrimary(ev, live: false) }

        let report = SnapshotDiff.compare(golden: answer(straight), ours: answer(resumed), limit: 3)
        return report.isEqual ? nil : report
    }

    /// Which conforming modules exist — phase 2 grows this by conforming more modules, and this
    /// test grows with it automatically.
    private static func checkpointableIds() -> [String] {
        makeWorld(.object(["meta": .object([:])]), fixture: "probe")
            .registry.mods.compactMap { $0 is FoldCheckpointable ? $0.id : nil }
    }

    /// Every fixture, every conforming module, split at the middle. The broad sweep: cheap per
    /// fixture, and the fixtures were built to exercise every module's corners.
    func testEveryFixtureResumesCleanlyFromAMidFoldCheckpoint() throws {
        guard FileManager.default.fileExists(atPath: Self.goldens.path) else { throw XCTSkip("no Goldens/") }
        let ids = Self.checkpointableIds()
        XCTAssertFalse(ids.isEmpty, "no module conforms to FoldCheckpointable yet")
        let names = try FileManager.default.contentsOfDirectory(atPath: Self.goldens.path)
            .filter { !$0.hasPrefix("_") && !$0.hasPrefix(".") }.sorted()
        var folded = 0, failures: [String] = []
        for name in names {
            let fx = try Self.load(name)
            guard !fx.events.isEmpty else { continue }
            folded += 1
            if let bad = Self.oracle(fx, split: fx.events.count / 2) {
                failures.append("\(name): \(bad.mismatches.joined(separator: "; "))")
                if failures.count >= 5 { break }
            }
        }
        // Divergences first: the sweep stops early on them, so judging the corpus size in that
        // run would bury the real report under a misleading one.
        XCTAssertTrue(failures.isEmpty, "resumed folds diverged:\n" + failures.joined(separator: "\n"))
        XCTAssertGreaterThan(folded, 100, "the fixture corpus should be large")
    }

    /// The split positions that break naive codecs: before anything happened, after exactly one
    /// event, straddling wherever state churns, and at the very end (a checkpoint of the final
    /// state, resumed with nothing to fold). Run against a handful of the densest fixtures.
    func testTheAwkwardSplitsOnDenseFixtures() throws {
        guard FileManager.default.fileExists(atPath: Self.goldens.path) else { throw XCTSkip("no Goldens/") }
        var failures: [String] = []
        var visited = 0
        for name in ["p4-pet-buff-kill-credit", "e2e-combat", "w14-sky-currency-loot"] {
            guard let fx = try? Self.load(name), !fx.events.isEmpty else { continue }
            visited += 1
            let n = fx.events.count
            let splits = Set([0, 1, n / 3, n / 2, 2 * n / 3, n - 1, n]).sorted()
            for s in splits where s >= 0 {
                if let bad = Self.oracle(fx, split: s) {
                    failures.append("\(name) split \(s)/\(n): \(bad.mismatches.joined(separator: "; "))")
                }
            }
        }
        XCTAssertGreaterThanOrEqual(visited, 3,
            "the dense fixtures were not found - this test silently proved nothing once already")
        XCTAssertTrue(failures.isEmpty, "resumed folds diverged:\n" + failures.joined(separator: "\n"))
    }

    /// The refusal arm: garbage in leaves the module RESET, not half-applied — the caller's answer
    /// to `false` is a full rescan, and a half-applied blob must not survive into it.
    func testAnUnusableBlobIsRefusedAndLeavesTheModuleVirgin() {
        let m = LootModule()
        m.onEvent(Event.fromJSON(#"{"kind":"zone","ts":1,"seq":0,"zone":"Lower Guk"}"#)!, live: false)
        m.onEvent(Event.fromJSON(#"{"kind":"loot","ts":2,"seq":1,"item":"Bone Chips"}"#)!, live: false)
        XCTAssertEqual(m.rows().count, 1)

        XCTAssertFalse(m.restoreCheckpoint(.null))
        XCTAssertFalse(m.restoreCheckpoint(.object(["loot": .string("not an array")])))
        let virgin = LootModule()
        XCTAssertEqual(m.snapshot()["state"], virgin.snapshot()["state"],
                       "a refused restore must leave nothing behind")
    }
}
