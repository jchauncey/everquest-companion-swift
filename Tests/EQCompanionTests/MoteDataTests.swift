import XCTest
import EQCompanionCore
@testable import EQCompanion

/// The mote fold: grades off the item name, difficulty off the zone line the way the kills module
/// reads it, kills per (mob, tier) as the denominator, and regrouping that sums rather than
/// averaging averages.
final class MoteDataTests: XCTestCase {
    private func ev(_ item: String, _ mob: String, _ zone: String?, count: Int = 1, ts: Int64 = 1) -> LootEvent {
        LootEvent(item: item, itemKey: item.lowercased(), countKey: LootName.countKey(item), source: mob,
                  zone: zone, ts: ts, count: count, disposition: nil)
    }
    private func kills(_ display: String, _ perTier: [Int: Int]) -> (String, KillInfo) {
        var tiers: [Int: KillTierRun] = [:]
        for (t, n) in perTier { tiers[t] = KillTierRun(count: n, firstTs: 1, lastTs: 9) }
        let tot = KillRecord.totals(tiers)
        return (MobKey.of(display), KillInfo(display: display, tiers: tiers, count: tot.count, bestTier: tot.bestTier,
                                             firstTs: tot.firstTs, lastTs: tot.lastTs, credited: tot.credited))
    }
    private let facts: (String) -> MoteStats.MobFacts = { name in
        MoteStats.MobFacts(catalogLevel: name == "a spite golem" ? "51" : "49-55", catalogZone: "Plane of Hate",
                           dropsRareLoot: false)
    }

    func testGradesComeOffTheNameAndSitOnTheLadder() {
        XCTAssertEqual(MoteLadder.grade("Mote of Lesser Potential"), "Lesser")
        XCTAssertEqual(MoteLadder.grade("Mote of Potential"), "")
        XCTAssertEqual(MoteLadder.grade("3 Mote of Potential"), nil, "a stack count is not part of the name the parser sees")
        XCTAssertEqual(MoteLadder.grade("Crystallized Sulfur"), nil)
        XCTAssertLessThan(MoteLadder.rank("Infinitesimal"), MoteLadder.rank("Minor"))
        XCTAssertLessThan(MoteLadder.rank("Lesser"), MoteLadder.rank(""))
        XCTAssertLessThan(MoteLadder.rank(""), MoteLadder.rank("Major"))
        XCTAssertEqual(MoteLadder.rank("Unheard Of"), MoteLadder.ranks.count, "off the ladder sorts last")
        XCTAssertEqual(MoteLadder.label(""), "Potential")
    }

    func testDifficultyIsReadOffTheZoneLineLikeTheKillsModule() {
        XCTAssertEqual(ZoneTier.decode("The Plane of Hate 3 (Fused)").tier, 3)
        XCTAssertEqual(ZoneTier.decode("The Plane of Hate 3 (Fused)").base, "The Plane of Hate")
        XCTAssertEqual(ZoneTier.decode("Befallen 2 (Adaptive)").tier, 2)
        XCTAssertEqual(ZoneTier.decode("Nagafen's Lair - Solo 4 (Refined)").tier, 4)
        XCTAssertEqual(ZoneTier.decode("Nagafen's Lair - Solo 4 (Refined)").base, "Nagafen's Lair")
        XCTAssertEqual(ZoneTier.decode("Befallen - Group").tier, 0, "an instance with no adjective is the base tier")
        XCTAssertEqual(ZoneTier.decode("The Oasis of Marr").tier, ZoneTier.openWorld)
        XCTAssertEqual(ZoneTier.decode(nil).tier, ZoneTier.unknown)
        XCTAssertEqual(ZoneTier.decode("").tier, ZoneTier.unknown)
        XCTAssertEqual(ZoneTier.label(3), "D3")
        XCTAssertEqual(ZoneTier.label(ZoneTier.openWorld), "OW")
    }

    func testKillsAtTheTierAreTheDenominatorAndAZeroIsARow() {
        let events = [
            ev("Mote of Potential", "a spite golem", "The Plane of Hate 3 (Fused)", count: 2, ts: 10),
            ev("Mote of Major Potential", "a spite golem", "The Plane of Hate 3 (Fused)", ts: 20),
            ev("Mote of Minor Potential", "a spite golem", "The Plane of Hate 1 (Awakened)", ts: 5),
            ev("Crystallized Sulfur", "a spite golem", "The Plane of Hate 3 (Fused)"),
            ev("Mote of Potential", "A Spite Golem", "The Plane of Hate 3 (Fused)", ts: 30)   // the con line's capital
        ]
        let (k1, i1) = kills("a spite golem", [3: 10, 1: 4])
        let (k2, i2) = kills("an ire ghast", [3: 6])
        let rows = MoteStats.fold(events: events, kills: [k1: i1, k2: i2], conLevels: [MobKey.of("an ire ghast"): 50], facts: facts)

        let d3 = try! XCTUnwrap(rows.first { MobKey.of($0.mob) == "a spite golem" && $0.tier == 3 })
        XCTAssertEqual(d3.kills, 10)
        XCTAssertEqual(d3.corpses, 3, "three loot lines under a D3 zone line - the sulfur is not a mote")
        XCTAssertEqual(d3.motes, 4, "a stack of two counts as two motes")
        XCTAssertEqual(d3.byGrade[""], 3)
        XCTAssertEqual(d3.byGrade["Major"], 1)
        XCTAssertEqual(d3.rate!, 0.3, accuracy: 0.0001)
        XCTAssertEqual(d3.perKill!, 0.4, accuracy: 0.0001)
        XCTAssertEqual(d3.level, 51, "no con: the catalog's stated level")
        XCTAssertEqual(d3.zone, "The Plane of Hate")

        let d1 = try! XCTUnwrap(rows.first { MobKey.of($0.mob) == "a spite golem" && $0.tier == 1 })
        XCTAssertEqual(d1.kills, 4); XCTAssertEqual(d1.motes, 1)

        let ghast = try! XCTUnwrap(rows.first { MobKey.of($0.mob) == "an ire ghast" })
        XCTAssertEqual(ghast.kills, 6); XCTAssertEqual(ghast.motes, 0)
        XCTAssertEqual(ghast.rate, 0, "killed, never gave one: a zero rate, not a missing row")
        XCTAssertEqual(ghast.level, 50, "the con line outranks the catalog's span")
        XCTAssertEqual(ghast.zone, "Plane of Hate", "no loot to say where: the catalog's zone")
        XCTAssertFalse(ghast.named)
    }

    func testARateNeverExceedsOneAndNoKillsIsNoRate() {
        let events = [ev("Mote of Potential", "a rat", "Befallen", ts: 1), ev("Mote of Potential", "a rat", "Befallen", ts: 2)]
        let (k, i) = kills("a rat", [ZoneTier.openWorld: 1])
        let row = MoteStats.fold(events: events, kills: [k: i], conLevels: [:], facts: facts).first!
        XCTAssertEqual(row.rate, 1, "two corpses against one counted kill caps, rather than claiming 200%")
        let unkilled = MoteStats.fold(events: events, kills: [:], conLevels: [:], facts: facts).first!
        XCTAssertNil(unkilled.rate); XCTAssertNil(unkilled.perKill)
        XCTAssertEqual(unkilled.motes, 2)
    }

    func testGroupsSumRatherThanAverageAverages() {
        let (k1, i1) = kills("a spite golem", [3: 10])
        let (k2, i2) = kills("an ire ghast", [3: 90])
        let events = [ev("Mote of Potential", "a spite golem", "The Plane of Hate 3 (Fused)", count: 5, ts: 1),
                      ev("Mote of Potential", "an ire ghast", "The Plane of Hate 3 (Fused)", ts: 2)]
        let rows = MoteStats.fold(events: events, kills: [k1: i1, k2: i2], conLevels: [:], facts: facts)
        let byTier = MoteStats.group(rows, by: .difficulty)
        XCTAssertEqual(byTier.count, 1)
        XCTAssertEqual(byTier[0].kills, 100); XCTAssertEqual(byTier[0].corpses, 2); XCTAssertEqual(byTier[0].motes, 6)
        XCTAssertEqual(byTier[0].rate!, 0.02, accuracy: 0.0001, "2 of 100, not the mean of 10% and 1.1%")
        XCTAssertEqual(byTier[0].mob, "D3 · Fused")
        let byZone = MoteStats.group(rows, by: .zone)
        XCTAssertEqual(byZone.count, 1); XCTAssertEqual(byZone[0].mob, "The Plane of Hate")
        let byNamed = MoteStats.group(rows, by: .named)
        XCTAssertEqual(byNamed.map(\.mob), ["Common spawns"])
        let byLevel = MoteStats.group(rows, by: .level)
        XCTAssertEqual(Set(byLevel.map(\.mob)), ["Level 50-54", "Level 45-49"], "51 and 49 (the span's floor) land in their bands")
        XCTAssertEqual(MoteStats.group(rows, by: .mob).count, 2, "by mob is the fold itself")
    }

    func testConLevelsTakeTheNewestCon() {
        let state: JSONValue = ["ring": [
            ["mob": "a spite golem", "level": 50, "ts": 1],
            ["mob": "A spite golem", "level": 52, "ts": 5],
            ["mob": "an ire ghast", "ts": 3]
        ]]
        let levels = MoteStats.conLevels(state)
        XCTAssertEqual(levels[MobKey.of("a spite golem")], 52)
        XCTAssertNil(levels[MobKey.of("an ire ghast")], "a con that stated no level is not a level")
    }

    func testSortIsBothWaysWithANameTiebreakAndNilLast() {
        let (k, i) = kills("a", [3: 10]); let (k2, i2) = kills("b", [3: 10])
        // No catalog level for either: only the con line gives "a" one, so "b" is truly level-less.
        let bare: (String) -> MoteStats.MobFacts = { _ in .init(catalogLevel: nil, catalogZone: nil, dropsRareLoot: false) }
        let rows = MoteStats.fold(events: [ev("Mote of Potential", "b", "X 3 (Fused)"), ev("Mote of Potential", "a", "X 3 (Fused)")],
                                  kills: [k: i, k2: i2], conLevels: [MobKey.of("a"): 5], facts: bare)
        let up = rows.sorted { MoteStats.compare($0, $1, key: "motes", descending: false) }.map(\.mob)
        XCTAssertEqual(up, ["a", "b"], "equal motes: the tie breaks by name")
        let lvl = rows.sorted { MoteStats.compare($0, $1, key: "level", descending: false) }.map(\.mob)
        XCTAssertEqual(lvl.last, "b", "a mob with no level sorts last ascending")
        let lvlDesc = rows.sorted { MoteStats.compare($0, $1, key: "level", descending: true) }.map(\.mob)
        XCTAssertEqual(lvlDesc.last, "b", "and last descending too - nil is not a small number")
    }

    // MARK: - The Overview breakdown

    private func row(_ mob: String, tier: Int, motes: Int, kills: Int, grades: [String: Int] = [:]) -> MoteRow {
        MoteRow(key: MobKey.of(mob) + "|" + String(tier), mob: mob, zone: "The Plane of Hate", tier: tier, level: nil,
                named: false, kills: kills, corpses: motes, motes: motes, byGrade: grades, lastTs: 1)
    }

    func testTheBreakdownSumsRowsAndListsDifficultiesInLadderOrder() {
        let b = MoteBreakdown.build([
            row("a spite golem", tier: 3, motes: 9, kills: 20, grades: ["Lesser": 6, "": 3]),
            row("an imp protector", tier: 3, motes: 6, kills: 12, grades: ["": 6]),
            row("a fire giant", tier: ZoneTier.openWorld, motes: 7, kills: 40, grades: ["Minor": 7]),
            row("a ghoul", tier: ZoneTier.unknown, motes: 1, kills: 0, grades: ["": 1]),
            row("a rat", tier: 1, motes: 0, kills: 5),
        ])
        XCTAssertEqual(b.motes, 23)
        XCTAssertEqual(b.kills, 77)
        XCTAssertEqual(b.tiers.map(\.tier), [ZoneTier.openWorld, 1, 3, ZoneTier.unknown],
                       "open world first, then the ladder, then not stated; a tier with kills and no motes stays")
        XCTAssertEqual(b.tiers.first { $0.tier == 3 }?.motes, 15)
        XCTAssertEqual(b.tiers.first { $0.tier == 3 }?.kills, 32)
        XCTAssertEqual(b.grades.map(\.grade), ["Minor", "Lesser", ""], "ladder order")
        XCTAssertEqual(b.grades.map(\.motes), [7, 6, 10])
        XCTAssertEqual(b.top.map(\.mob), ["a spite golem", "a fire giant", "an imp protector"])
    }

    func testTheBestRateNeedsEnoughKillsToMeanSomething() {
        let b = MoteBreakdown.build([
            row("a spite golem", tier: 3, motes: 9, kills: 20),
            row("a lucky rat", tier: 4, motes: 3, kills: 3),
            row("a fire giant", tier: ZoneTier.openWorld, motes: 7, kills: 40),
        ])
        XCTAssertEqual(b.bestTier?.tier, 3, "D4's 1.00/kill over 3 kills is not a recommendation")
        XCTAssertNil(MoteBreakdown.build([row("a lucky rat", tier: 4, motes: 3, kills: 3)]).bestTier)
    }

    func testAnEmptyLogIsAnEmptyBreakdown() {
        let b = MoteBreakdown.build([])
        XCTAssertTrue(b.isEmpty)
        XCTAssertNil(b.perKill)
        XCTAssertTrue(b.tiers.isEmpty)
    }
}
