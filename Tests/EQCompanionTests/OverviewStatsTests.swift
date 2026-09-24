import XCTest
import EQCompanionCore
@testable import EQCompanion

/// The Overview's play statistics: sums and top-N over module snapshots, in the shapes the cards draw.
final class OverviewStatsTests: XCTestCase {
    func testCoinReadsTheWayTheGameSaysIt() {
        XCTAssertEqual(Coin.text(0), "0cp")
        XCTAssertEqual(Coin.text(7), "7cp")
        XCTAssertEqual(Coin.text(36), "3sp 6cp")
        XCTAssertEqual(Coin.text(143), "1gp 4sp")
        XCTAssertEqual(Coin.text(13_753_542), "13,753pp 5gp")
        XCTAssertEqual(Coin.text(3_000), "3pp", "a zero denomination is not spelled")
        XCTAssertEqual(Coin.text(3_004), "3pp", "the biggest two places only")
    }

    private func loot(_ item: String, count: Int = 1, _ disposition: String? = nil) -> LootEvent {
        LootEvent(item: item, itemKey: item.lowercased(), countKey: LootName.countKey(item), source: "a rat",
                  zone: nil, ts: 1, count: count, disposition: disposition)
    }

    func testLootCountsStacksSplitsByWhereItWentAndSkipsTheDestroyed() {
        let s = LootSummary.build([
            loot("Bone Chips", count: 3), loot("Bone Chips"), loot("Rusty Sword", "sold"),
            loot("Mote of Potential", "currency"), loot("Cloth Cap", "destroyed"), loot("Silk", "combined"),
        ])
        XCTAssertEqual(s.items, 7)
        XCTAssertEqual(s.lines, 5)
        XCTAssertEqual(s.distinct, 4)
        XCTAssertEqual([s.kept, s.sold, s.stored, s.combined], [4, 1, 1, 1])
        XCTAssertEqual(s.top.first, LootSummary.Top(item: "Bone Chips", count: 4))
    }

    func testSalesReadTheModuleSnapshot() throws {
        let state = try JSONValue.parse(#"""
        {"auto": {"sales": 3042, "items": 3310, "copper": 13753542, "free": 192},
         "vendor": {"sales": 65, "items": 65, "copper": 122068, "free": 0},
         "copper": 13875610, "distinctItems": 571,
         "items": [{"item": "Ruby Crown +3", "count": 9, "copper": 1285713, "lastTs": 1}]}
        """#)
        let s = SalesSummary.parse(state)
        XCTAssertEqual(s.sales, 3107)
        XCTAssertEqual(s.items, 3375)
        XCTAssertEqual(s.copper, 13_875_610)
        XCTAssertEqual(s.auto.free, 192)
        XCTAssertEqual(s.top.first?.item, "Ruby Crown +3")
        XCTAssertEqual(SalesSummary.parse(.null), SalesSummary(), "no module yet is an empty summary")
    }

    func testKillsSumEveryTierAndRankTheMobs() {
        func info(_ name: String, _ perTier: [Int: Int]) -> (String, KillInfo) {
            var tiers: [Int: KillTierRun] = [:]
            for (t, n) in perTier { tiers[t] = KillTierRun(count: n, firstTs: 10, lastTs: 20) }
            let tot = KillRecord.totals(tiers)
            return (MobKey.of(name), KillInfo(display: name, tiers: tiers, count: tot.count, bestTier: tot.bestTier,
                                              firstTs: tot.firstTs, lastTs: tot.lastTs, credited: tot.credited))
        }
        let s = KillSummary.build(Dictionary(uniqueKeysWithValues: [
            info("a spite golem", [3: 20, 2: 4]), info("a rat", [ZoneTier.openWorld: 7]), info("a ghoul", [ZoneTier.unknown: 1]),
        ]))
        XCTAssertEqual(s.kills, 32)
        XCTAssertEqual(s.distinct, 3)
        XCTAssertEqual(s.tiers.map(\.tier), [ZoneTier.openWorld, 2, 3, ZoneTier.unknown])
        XCTAssertEqual(s.top.map(\.mob), ["a spite golem", "a rat", "a ghoul"])
    }

    func testTheFightSeriesIsDamageOverActiveTimeAcrossEveryFight() {
        func seg(_ ts: Int64, total: Double, active: Double, kind: String = "fight", name: String = "x") -> JSONValue {
            ["kind": .string(kind), "name": .string(name), "startTs": .int(ts), "total": .double(total), "activeSec": .double(active)]
        }
        let s = FightSeries.build([
            seg(1_000_000, total: 1000, active: 10, name: "a"),
            seg(2_000_000, total: 3000, active: 10, name: "b"),
            seg(3_000_000, total: 50, active: 2, name: "stray"),            // under the floor: out
            seg(4_000_000, total: 900, active: 30, kind: "current"),      // the open fight: out
        ], buckets: 10)
        XCTAssertEqual(s.fights, 2)
        XCTAssertEqual(s.average, 200, "(1000 + 3000) / (10 + 10), not the mean of 100 and 300")
        XCTAssertEqual(s.best?.name, "b")
        XCTAssertEqual(s.points.map(\.dps), [100, 300])
        XCTAssertTrue(FightSeries.build([]).points.isEmpty)
    }
}
