import XCTest
import EQCompanionCore
@testable import EQCompanion

/// The Overview's leveling card over the whole log.
final class OverviewPlaytimeTests: XCTestCase {
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// Day 1 (2026-09-01 UTC): 10:00–10:20 fighting (a kill every 4 minutes), a level-up 10→11.
    /// Day 2: 12:00–12:08 (a kill every 4 minutes), a class swap back to 1 and an AA.
    private var snap: OverviewProgression {
        let day1: Int64 = 1_788_220_800_000, h: Int64 = 3_600_000, m: Int64 = 60_000
        let fight1: Int64 = day1 + 10 * h
        let fight2: Int64 = day1 + 36 * h
        var s = OverviewProgression()
        var kills: [Int64] = []
        for k: Int64 in 0...5 { kills.append(fight1 + k * 4 * m) }
        kills.append(fight2)
        kills.append(fight2 + 4 * m)
        kills.append(fight2 + 8 * m)
        s.killTs = kills
        s.killCredit = Array(repeating: 0, count: s.killTs.count)
        s.expTs = [fight1 + 4 * m, fight1 + 20 * m]
        s.expPct = [40, 70]
        s.expFlag = [0, 0]
        s.levelTs = [day1 + 9 * h, fight1 + 20 * m, fight2]
        s.levelValue = [10, 11, 1]
        s.aaGainTs = [fight2 + 8 * m]
        s.aaGainAmount = [2]
        s.lastTs = fight2 + 8 * m
        return s
    }

    func testTheWholeLogIsSummed() {
        let p = overviewPlaytime(snap, statedLevel: nil, calendar: utc)
        XCTAssertFalse(p.empty)
        XCTAssertEqual(p.firstLevel, 10)
        XCTAssertEqual(p.level, 1, "the swap's reset is the level now")
        XCTAssertEqual(p.levelUps, 1)
        XCTAssertEqual(p.swaps, 1)
        XCTAssertEqual(p.kills, 9)
        XCTAssertEqual(p.aa, 2)
        XCTAssertEqual(Double(p.activeMs), Double(28 * 60_000), accuracy: 1_000, "20 minutes one day, 8 the next; the gaps between are idle")
        XCTAssertEqual(p.history, "lvl 10→11 1.3h")
    }

    func testOneBarPerDayPlayed() {
        let p = overviewPlaytime(snap, statedLevel: nil, calendar: utc)
        XCTAssertEqual(p.days.count, 2)
        XCTAssertEqual(Double(p.days[0].activeMs), Double(20 * 60_000), accuracy: 1_000)
        XCTAssertEqual(Double(p.days[1].activeMs), Double(8 * 60_000), accuracy: 1_000)
        XCTAssertEqual(p.days.first?.levels ?? 0, 1.1, accuracy: 0.001)
        XCTAssertEqual(p.days.last?.aa, 2)
    }

    func testALaterWhoIsTheLevelNow() {
        let p = overviewPlaytime(snap, statedLevel: (level: 12, ts: snap.lastTs + 1, source: "who"), calendar: utc)
        XCTAssertEqual(p.level, 12)
    }

    func testAnEmptyLogIsEmpty() {
        XCTAssertTrue(overviewPlaytime(OverviewProgression(), statedLevel: nil).empty)
    }
}
