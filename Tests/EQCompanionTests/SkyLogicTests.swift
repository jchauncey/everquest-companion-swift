import XCTest
import EQCompanionCore
@testable import EQCompanion

/// The Plane of Sky arithmetic, against the committed quest bundle and the shapes the Electron
/// modules really serve. Every expectation here is one the TS side pins too.
final class SkyLogicTests: XCTestCase {

    // MARK: - The counting key

    func testCountingKeyStripsOnlyATrailingPlusN() {
        XCTAssertEqual(SkyName.normalize("Sphinx Claw +1"), "Sphinx Claw")
        XCTAssertEqual(SkyName.normalize("Sphinx Claw +12"), "Sphinx Claw")
        XCTAssertEqual(SkyName.normalize("Sphinx Claw"), "Sphinx Claw")
        // Not a suffix: no space, no digits, or a plus in the middle.
        XCTAssertEqual(SkyName.normalize("Sphinx Claw+1"), "Sphinx Claw+1")
        XCTAssertEqual(SkyName.normalize("Sphinx +Claw"), "Sphinx +Claw")
        XCTAssertEqual(SkyName.countKey("Wind Rune Fana +2"), "wind rune fana")
        XCTAssertTrue(SkyName.isCurrency("Wind Rune Ozah"))
        XCTAssertFalse(SkyName.isCurrency("Glowing Diamond"))
    }

    // MARK: - Held counts from the log

    private func loot(_ item: String, _ ts: Int64, _ disposition: String? = nil, _ count: Int = 1) -> SkyLootEvent {
        SkyLootEvent(ts: ts, item: item, disposition: disposition, count: count)
    }

    func testHeldCountsFollowTheDispositionRules() {
        let history = [
            loot("Bone Chips", 100, nil, 2),      // a stack is TWO items
            loot("Bone Chips", 200, "sold"),      // gone the instant it dropped
            loot("Bone Chips", 300, "combined"),  // net zero on the counting key
            loot("Hazy Opal", 400, "currency"),   // kept
            loot("Hazy Opal", 500, "hoard")       // kept
        ]
        let c = SkyHeld.counts(history)
        XCTAssertEqual(c["bone chips"], 2)
        XCTAssertEqual(c["hazy opal"], 2)
    }

    func testADestroyIsChronologicalAndFloorsAtZeroPerRow() {
        // loot 1, destroy 3, loot 2 reads 2: the second loot is a fresh copy and owes the first
        // destroy nothing. A max(0, sum) at the end would answer 0.
        let c = SkyHeld.counts([
            loot("Sphinx Claw", 100),
            loot("Sphinx Claw", 200, "destroyed", 3),
            loot("Sphinx Claw", 300, nil, 2)
        ])
        XCTAssertEqual(c["sphinx claw"], 2)
    }

    func testLastLootedIgnoresSoldAndDestroyed() {
        let t = SkyHeld.lastLootedAt([
            loot("Hazy Opal", 100),
            loot("Hazy Opal", 200, "combined"),
            loot("Hazy Opal", 300, "sold"),
            loot("Hazy Opal", 400, "destroyed")
        ])
        XCTAssertEqual(t["hazy opal"], 200)
    }

    func testWindowedFoldsAreStrictlyAfterTheInstant() {
        let history = [loot("Hazy Opal", 100), loot("Hazy Opal", 200), loot("Hazy Opal", 300, "destroyed")]
        XCTAssertEqual(SkyHeld.countsAfter(history, after: 100)["hazy opal"], 1)
        XCTAssertEqual(SkyHeld.destroyedAfter(history, after: 100)["hazy opal"], 1)
        XCTAssertNil(SkyHeld.countsAfter(history, after: 300)["hazy opal"])
    }

    // MARK: - The /outputfile inventory dump

    private static let dump = [
        "Location\tName\tID\tCount\tSlots",
        "Any Slot\tBrigandine Tunic +1\t3307\t1\t10",
        "Any Slot-Slot2\tEmpty\t0\t0\t0",
        "General 1\tSpacious Rucksack\t177751\t1\t24",
        "General 1-Slot9\tGlowing Diamond\t20821\t2\t10",
        "Personal-Depot1\tEfreeti War Horn\t20823\t1\t10",
        "",
        "Hoard\tName\tID\tCount\tSlots",       // a table nobody can name, spelling the item header
        "Hoard1\tGlowing Diamond\t20821\t1\t10",
        "",
        "KeyRing\tName\tID\t",
        "Equipment\tLight Woolen Mask\t20821",
        "Activated\tGuise of the Deceiver\t10000",
        "",
        "Mercenary\tName\tID\tRank\tTier",     // a shape we have never seen: refused
        "Merc1\tGlowing Diamond\t20821\t1\t1"
    ].joined(separator: "\r\n")

    func testHeldCountsFromDumpReadEveryItemShapedTable() {
        let counts = SkyInventoryDump.parse(Self.dump).heldCounts
        // The Location table AND the unnameable hoard table, because both spell the item header.
        XCTAssertEqual(counts["glowing diamond"], 3)
        XCTAssertEqual(counts["efreeti war horn"], 1)
        // Bags count as items themselves; `+N` variants stay separate at this level.
        XCTAssertEqual(counts["spacious rucksack"], 1)
        XCTAssertEqual(counts["brigandine tunic +1"], 1)
        // `Empty` is a slot that exists and holds nothing.
        XCTAssertNil(counts["empty"])
        // A held keyring category counts one per row; `Activated` stays out.
        XCTAssertEqual(counts["light woolen mask"], 1)
        XCTAssertNil(counts["guise of the deceiver"])
        // The Mercenary table's row never reaches the count.
        XCTAssertEqual(counts["glowing diamond"], 3)
    }

    // MARK: - Reconcile

    private func quest(_ items: [(String, Int)]) -> SkyQuestDef {
        SkyQuestDef(key: "Bard::T", className: "Bard", name: "T", giver: "Cilin Spellsinger",
                    rune: nil, reward: nil, rewardStats: nil,
                    items: items.map { SkyItemDef(name: $0.0, who: [], place: "", count: $0.1, page: nil, stats: nil) })
    }

    private func reconcileInput(_ source: SkyCountSource,
                                log: [String: Int],
                                inv: [String: Int]) -> SkyReconcileInput {
        SkyReconcileInput(log: log, inv: inv, lootNames: [:], countSource: source,
                          quests: [quest([("Glowing Diamond", 1)])], turnInCounts: [:],
                          detectedInstants: [:], overrides: [:], lootSinceOverride: [:],
                          destroyedSinceOverride: [:], allInstants: [:], dumpAt: nil,
                          lootSinceDump: [:], destroyedSinceDump: [:])
    }

    func testBothIsAPerItemMaximumNotAFallback() {
        let log = ["glowing diamond": 5]
        let inv = ["glowing diamond": 3]
        XCTAssertEqual(skyReconcile(reconcileInput(.both, log: log, inv: inv)).net["glowing diamond"], 5)
        XCTAssertEqual(skyReconcile(reconcileInput(.log, log: log, inv: inv)).net["glowing diamond"], 5)
        XCTAssertEqual(skyReconcile(reconcileInput(.inventory, log: log, inv: inv)).net["glowing diamond"], 3)
        // And the other way round, which is what "fallback" would get wrong.
        let other = skyReconcile(reconcileInput(.both, log: ["glowing diamond": 1], inv: ["glowing diamond": 4]))
        XCTAssertEqual(other.net["glowing diamond"], 4)
    }

    func testBothIsANoOpWithNoDumpLoaded() {
        let log = ["glowing diamond": 2]
        XCTAssertEqual(skyReconcile(reconcileInput(.both, log: log, inv: [:])).net,
                       skyReconcile(reconcileInput(.log, log: log, inv: [:])).net)
    }

    func testATurnInSubtractsWhatItConsumed() {
        var input = reconcileInput(.log, log: ["glowing diamond": 3], inv: [:])
        input.turnInCounts = ["Bard::T": 2]
        let r = skyReconcile(input)
        XCTAssertEqual(r.net["glowing diamond"], 1)
        XCTAssertEqual(r.rows.first { $0.key == "glowing diamond" }?.consumedBy, ["T x2"])
    }

    func testAHandStatedCountOutranksBothWitnesses() {
        var input = reconcileInput(.both, log: ["glowing diamond": 9], inv: ["glowing diamond": 9])
        input.overrides = ["glowing diamond": SkyItemOverride(key: "glowing diamond", name: "Glowing Diamond", count: 1, setAt: 1000)]
        XCTAssertEqual(skyReconcile(input).net["glowing diamond"], 1)
        // Loot after the statement counts on top of it.
        input.lootSinceOverride = ["glowing diamond": 2]
        XCTAssertEqual(skyReconcile(input).net["glowing diamond"], 3)
    }

    // MARK: - Turn-in detection

    func testATurnInIsMatchedOnlyWhenEveryItemWasOffered() {
        let q = quest([("Glowing Diamond", 1), ("Efreeti War Horn", 1)])
        let partial = SkyTurnInEvent(ts: 10, npc: "cilin spellsinger", items: ["Glowing Diamond"])
        let whole = SkyTurnInEvent(ts: 20, npc: "Cilin Spellsinger", items: ["Glowing Diamond", "Efreeti War Horn +1"])
        let hits = SkyTurnIns.detected([partial, whole], quests: [q])
        XCTAssertEqual(hits["Bard::T"], [20])
    }

    func testTheLedgerMergesTheLogAndTheHandRecordWithoutDoubleCounting() {
        let r = SkyTurnIns.resolve(stored: ["Bard::T": [20, 99]], detected: ["Bard::T": [20]])
        XCTAssertEqual(r.instants["Bard::T"], [20, 99])
        XCTAssertEqual(r.all["Bard::T"], 2)
    }

    // MARK: - Sort

    private func progress(_ name: String, className: String = "Bard",
                          missing: Int = 0, ratio: Double = 0, lastDrop: Int64? = nil,
                          turnIns: Int = 0, needCount: Int = 3) -> SkyQuestProgress {
        SkyQuestProgress(key: "\(className)::\(name)", className: className, name: name,
                         giver: nil, rune: nil, reward: nil, rewardStats: nil, items: [],
                         haveCount: 0, needCount: needCount, ratio: ratio,
                         missing: Array(repeating: "x", count: missing), turnIns: turnIns,
                         logTurnIns: 0, completed: turnIns > 0, evidence: nil, lastDropAt: lastDrop)
    }

    func testQuestsWithNoDropEverSortBelowEveryQuestThatHasOne() {
        let list = [progress("A"), progress("B", lastDrop: 100), progress("C", lastDrop: 200)]
        XCTAssertEqual(skySortQuests(list, .recent).map(\.name), ["C", "B", "A"])
    }

    func testTheFavoritePinNeverOverridesMostRecentlyLooted() {
        // The owner's live report: a starred quest must not outrank the drop that just landed.
        let starred = progress("Starred", lastDrop: 100)
        let fresh = progress("Fresh", lastDrop: 900)
        let rank: (SkyQuestProgress) -> Int = { $0.name == "Starred" ? 2 : 0 }
        XCTAssertEqual(skyOrderQuests([starred, fresh], .recent, rank: rank).map(\.name), ["Fresh", "Starred"])
        XCTAssertEqual(skyOrderQuests([fresh, starred], .name, rank: rank).map(\.name), ["Starred", "Fresh"])
    }

    // MARK: - Class unlocks

    func testALoggedUnlockOutranksTheCountAndACompleteSetIsOnlyOurReading() {
        let rows = skyClassUnlockRows(
            [progress("W1", className: "Warrior"), progress("W2", className: "Warrior"),
             progress("B1", className: "Bard", turnIns: 1)],
            observed: [(className: "warrior", ts: 1787050720000)])
        let byClass = Dictionary(uniqueKeysWithValues: rows.map { ($0.className, $0) })
        XCTAssertEqual(byClass["Warrior"]?.label, "Unlocked, the log said so")
        XCTAssertEqual(byClass["Warrior"]?.turnedIn, 0)
        XCTAssertEqual(byClass["Bard"]?.label, "Every test turned in")
        XCTAssertEqual(byClass["Bard"]?.source, .derived)
    }

    func testAClassWithTestsLeftReadsTheCount() {
        let rows = skyClassUnlockRows([progress("A", className: "Monk"), progress("B", className: "Monk")], observed: [])
        XCTAssertEqual(rows.first?.label, "2 tests left")
        XCTAssertEqual(rows.first?.unlocked, false)
    }

    // MARK: - Cleanup

    func testCleanupNeedsEveryClaimingQuestToBeTurnedIn() {
        var done = progress("Done", turnIns: 1)
        done.items = [SkyItemProgress(name: "Sphinx Claw", who: [], place: "", droppers: [],
                                      need: 1, have: 1, held: 2, stats: nil, lastLootedAt: nil, override: nil)]
        var notDone = progress("Open", className: "Monk")
        notDone.items = done.items
        XCTAssertEqual(skyCleanupRows([done]).first?.name, "Sphinx Claw")
        XCTAssertEqual(skyCleanupRows([done]).first?.quantity, 2)
        // One un-turned-in claimant is enough to keep it off the list.
        XCTAssertTrue(skyCleanupRows([done, notDone]).isEmpty)
    }

    // MARK: - The committed bundle
    //
    // Read straight off disk rather than through GameData: under `swift test` Bundle.main is the
    // xctest harness, so the app's own root walk cannot find the checkout.

    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // EQCompanionTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // macos
        .deletingLastPathComponent()   // <repo>

    private func bundleRows(_ file: String, _ key: String) throws -> [JSONValue] {
        let url = Self.repoRoot.appendingPathComponent("src/renderer/src/data/eqlegends/\(file)")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "\(file) not in this checkout")
        return try XCTUnwrap(JSONValue.parse(try Data(contentsOf: url))[key].array)
    }

    private func skyIndex() throws -> SkyDropperIndex {
        let rows = try bundleRows("mobs.json", "mobs")
            .filter { m in (m["zones"].array ?? []).contains { $0.string?.lowercased() == "plane of sky" } }
            .map { m in
                (mob: SkyMob(name: m["name"].string ?? "", page: m["page"].string ?? "",
                             level: m["level"].string ?? "", zones: (m["zones"].array ?? []).compactMap(\.string)),
                 drops: (m["drops"].array ?? []).compactMap(\.string))
            }
        return SkyDropperIndex(catalog: rows)
    }

    func testBardTestOfBrassReadsWhatTheBundleSays() throws {
        let defs = SkyCatalog.quests(from: try bundleRows("posky.json", "quests"))
        XCTAssertEqual(defs.count, 95)
        let q = try XCTUnwrap(defs.first { $0.name == "Bard Test of Brass" })
        XCTAssertEqual(q.key, "Bard::Bard Test of Brass")
        XCTAssertEqual(q.reward, "Denon's Horn of Disaster")
        XCTAssertEqual(q.giver, "Cilin Spellsinger")
        XCTAssertEqual(q.items.map(\.name), ["Glowing Diamond", "Efreeti War Horn", "Wind Rune Fana"])
    }

    func testTheKillCaptionNamesTheDroppersTheCatalogKnows() throws {
        let defs = SkyCatalog.quests(from: try bundleRows("posky.json", "quests"))
        let def = try XCTUnwrap(defs.first { $0.name == "Bard Test of Brass" })
        let index = try skyIndex()
        let q = skyComputeQuestProgress(def, held: [:], turnInsAll: [:], turnInsLog: [:],
                                        lastLootedAt: [:], overrides: [:],
                                        droppers: { index.droppers(for: $0, who: $1) })
        XCTAssertEqual(q.needCount, 3)
        XCTAssertEqual(q.missing.count, 3)
        // Four Sky mobs stand in front of this quest; the lead is the first by name because each
        // covers exactly one item, and no island is stated for the item they share.
        XCTAssertEqual(skyKillTargetLabel(skyQuestKillTargets(q.items)), "Kill: Noble Dojorn +3")
        // The rune the data itself calls a random drop resolves no dropper at all (law 1).
        XCTAssertTrue(index.droppers(for: "Wind Rune Fana", who: ["random drop — any Plane of Sky mob"]).isEmpty)
    }

    func testHoldingEveryItemMakesAQuestReady() throws {
        let defs = SkyCatalog.quests(from: try bundleRows("posky.json", "quests"))
        let def = try XCTUnwrap(defs.first { $0.name == "Bard Test of Brass" })
        var held: [String: Int] = [:]
        for it in def.items { held[SkyName.countKey(it.name)] = 9 }
        let q = skyComputeQuestProgress(def, held: held, turnInsAll: [:], turnInsLog: [:],
                                        lastLootedAt: [:], overrides: [:], droppers: { _, _ in [] })
        XCTAssertTrue(q.hasEveryItem)
        XCTAssertEqual(q.haveCount, 3)
        XCTAssertEqual(q.ratio, 1)
    }

    func testTargetsAggregateOneItemAcrossEveryQuestThatWantsIt() throws {
        let defs = SkyCatalog.quests(from: try bundleRows("posky.json", "quests"))
        let index = try skyIndex()
        let quests = defs.map { def in
            skyComputeQuestProgress(def, held: [:], turnInsAll: [:], turnInsLog: [:],
                                    lastLootedAt: [:], overrides: [:],
                                    droppers: { index.droppers(for: $0, who: $1) })
        }
        let model = skyTargets(quests, firstTimeOnly: true)
        XCTAssertFalse(model.mobs.isEmpty)
        // Islands ascend, and an unstated island sorts last.
        let numbers = model.mobs.map { $0.island.map(skyIslandNumber) ?? Int.max }
        XCTAssertEqual(numbers, numbers.sorted())
        // A rune posky calls a random drop is in the random-drop section, never filed under a mob.
        XCTAssertTrue(model.randomDrop.contains { $0.name.lowercased().hasPrefix("wind rune") })
        // Its shortfall is the sum over every quest that wants it, not 1 per quest.
        let rune = try XCTUnwrap(model.randomDrop.first { $0.name.lowercased().hasPrefix("wind rune") })
        XCTAssertEqual(rune.shortfall, rune.quests.reduce(0) { $0 + $1.need })
    }
}
