import XCTest
import EQLog
import EQFold
import EQCompanionCore

/// The fold oracle: every fixture's golden EVENTS folded through the registry must deep-equal the
/// Rust engine's module snapshots and combat snapshot. Per-module tallies are in the failure text.
final class GoldenSnapshotsTests: XCTestCase {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let goldens = repo.appendingPathComponent("Goldens")
    static let fixtures = repo.appendingPathComponent("Resources/fixtures")

    static func fold(_ name: String) throws -> (Fold, JSONValue) {
        let gdir = goldens.appendingPathComponent(name)
        let events = try String(contentsOf: gdir.appendingPathComponent("events.ndjson"), encoding: .utf8)
        let gold = try JSONValue.parse(try Data(contentsOf: gdir.appendingPathComponent("snapshots.json")))
        let clock = Clock(identifier: gold["meta"]["tz"].string ?? "America/Los_Angeles")!
        let db = SpellDb.shared()
        var deps = ClusterDeps()
        deps.knownSpell = Set(db.keys())
        deps.spellClasses = spellClassIndex(db)
        deps.launchMs = Epoch.launchMs(clock)
        deps.constructionNowMs = gold["meta"]["constructionNowMs"].int64 ?? 0
        let character = gold["meta"]["character"].string ?? "Primitive"
        deps.character = ["name": .string(character), "server": "freeport",
                          "logPath": .string("eqlog_\(character)_freeport.\(name).txt")]
        deps.facts = SpellFacts.project(db)
        let engine = CombatEngine()
        engine.reset()
        engine.setPlayerName(character)
        let f = Fold(registry: registered(deps), launchMs: deps.launchMs).withCombat(engine)
        f.foldNDJSON(events)
        return (f, gold)
    }

    func testTheLaunchAnchorIsLocalMidnightOnLaunchDay() {
        XCTAssertEqual(Epoch.launchMs(Clock(identifier: "America/Los_Angeles")!), 1785222000000)
        XCTAssertEqual(Epoch.launchMs(Clock(identifier: "UTC")!), 1785196800000)
    }

    func testRegistrationFollowsTheWiringOrder() {
        let r = registered(ClusterDeps())
        XCTAssertEqual(r.ids(), wiringOrder)
        XCTAssertTrue(r.missing().isEmpty)
    }

    func testEveryFixtureFoldsToTheGoldenSnapshots() throws {
        guard FileManager.default.fileExists(atPath: Self.goldens.path) else { throw XCTSkip("no Goldens/") }
        // The committed fixtures drive it: a fixture with no golden throws out of `fold` rather than
        // being skipped because `Goldens/` never listed it.
        let names = try FileManager.default.contentsOfDirectory(atPath: Self.fixtures.path)
            .filter { $0.hasSuffix(".log") }.map { String($0.dropLast(4)) }.sorted()
        XCTAssertFalse(names.isEmpty, "no fixtures found")
        var perModule: [String: (Int, Int)] = [:]
        var firstDiff: [String: String] = [:]
        for n in names {
            let (f, gold) = try Self.fold(n)
            let ours = f.registry.snapshots()
            let byId = Dictionary(uniqueKeysWithValues: (ours["modules"].array ?? []).map { ($0["id"].string ?? "", $0["snapshot"]) })
            for m in gold["modules"].array ?? [] {
                let id = m["id"].string ?? ""
                let rep = SnapshotDiff.compare(golden: m["snapshot"], ours: byId[id] ?? .null, limit: 1)
                var e = perModule[id] ?? (0, 0); e.0 += 1; if rep.isEqual { e.1 += 1 } else if firstDiff[id] == nil { firstDiff[id] = "\(n): \(rep.mismatches.first ?? "")" }
                perModule[id] = e
            }
            if let engine = f.combat {
                let rep = SnapshotDiff.compare(golden: gold["combat"], ours: engine.snapshot(now: f.lastTs, opts: .full(), roster: f.registry.roster()), limit: 1)
                var e = perModule["combat"] ?? (0, 0); e.0 += 1; if rep.isEqual { e.1 += 1 } else if firstDiff["combat"] == nil { firstDiff["combat"] = "\(n): \(rep.mismatches.first ?? "")" }
                perModule["combat"] = e
            }
        }
        let bad = perModule.filter { $0.value.0 != $0.value.1 }
        let table = perModule.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value.1)/\($0.value.0)" }.joined(separator: ", ")
        XCTAssertTrue(bad.isEmpty, "Per module: \(table)\n" + firstDiff.sorted { $0.key < $1.key }.map { "\($0.key) — \($0.value)" }.joined(separator: "\n"))
    }
}
