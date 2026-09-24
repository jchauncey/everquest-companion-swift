import XCTest
@testable import EQCompanion

/// The fight picker's history by day: local days, newest first, named Today / Yesterday / a date.
final class FightDaysTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()

    private func ms(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Int64 {
        Int64(cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!.timeIntervalSince1970 * 1000)
    }

    private func fight(_ id: String, _ ts: Int64) -> ScopeOption {
        ScopeOption(value: id, label: id, name: id, dps: 100, startTs: ts, durationSec: 30, live: false, zone: nil)
    }

    func testFightsGroupIntoLocalDaysNewestFirst() {
        let now = ms(2026, 9, 24, 11)
        let days = fightDays([
            fight("a", ms(2026, 9, 24, 7)), fight("b", ms(2026, 9, 24, 10)),
            fight("c", ms(2026, 9, 23, 23, 59)), fight("d", ms(2026, 9, 21, 12)),
            fight("e", ms(2025, 12, 31, 12)), fight("x", 0),
        ], now: now, calendar: cal)
        XCTAssertEqual(days.map(\.label), ["Today", "Yesterday", "Mon Sep 21", "Wed Dec 31, 2025", "Undated"])
        XCTAssertEqual(days[0].rows.map(\.value), ["b", "a"], "newest fight first within a day")
        XCTAssertEqual(days.map(\.key), ["2026-09-24", "2026-09-23", "2026-09-21", "2025-12-31", "undated"])
    }

    func testMidnightIsTheLocalOne() {
        // 03:30 UTC on the 24th is 23:30 on the 23rd in New York.
        let now = ms(2026, 9, 24, 11)
        let lateEvening = Int64(Date(timeIntervalSince1970: 1_790_220_600).timeIntervalSince1970 * 1000)  // 2026-09-24T03:30Z
        XCTAssertEqual(fightDays([fight("late", lateEvening)], now: now, calendar: cal).first?.label, "Yesterday")
    }

    func testNoFightsIsNoDays() {
        XCTAssertTrue(fightDays([], now: 0, calendar: cal).isEmpty)
    }
}

/// The picker's filter: case-insensitive, anywhere in the name or zone, `*` as a gap.
final class FightFilterTests: XCTestCase {
    private func fight(_ name: String, zone: String? = "Kedge Keep 1 (Awakened)", ts: Int64 = 1_000) -> ScopeOption {
        ScopeOption(value: name, label: name, name: name, dps: 1, startTs: ts, durationSec: 1, live: false, zone: zone)
    }

    func testAnyCaseAnywhereInTheName() {
        XCTAssertTrue(fightMatches(fight("a gloomwater mermaid (6) +2"), "gloom"))
        XCTAssertTrue(fightMatches(fight("Estrella of Gloomwater (3) +2"), "GLOOM"), "not only at the start")
        XCTAssertFalse(fightMatches(fight("A piercer swordfish (12)"), "gloom"))
        XCTAssertTrue(fightMatches(fight("anything"), "   "), "a blank query keeps everything")
    }

    func testTheZoneMatchesToo() {
        XCTAssertTrue(fightMatches(fight("a rat", zone: "The Plane of Hate 3 (Fused)"), "hate"))
        XCTAssertTrue(fightMatches(fight("a rat", zone: "The Plane of Hate 3 (Fused)"), "fused"))
        XCTAssertFalse(fightMatches(fight("a rat", zone: nil), "hate"))
    }

    func testAStarIsAnyGapInOrder() {
        XCTAssertTrue(fightMatches(fight("a gloomstalker mermaid (9)"), "gloom*maid"))
        XCTAssertFalse(fightMatches(fight("a gloomstalker mermaid (9)"), "maid*gloom"), "pieces keep their order")
        XCTAssertTrue(fightMatches(fight("a gloomstalker mermaid (9)"), "*mer*"))
        XCTAssertTrue(fightMatches(fight("x", zone: "Kedge Keep 1 (Awakened)"), "kedge*awake"))
    }

    func testTheRangeKeepsOnlyFightsInsideIt() {
        let now: Int64 = 30 * 86_400_000
        let rows = [fight("new", ts: now - 3_600_000), fight("twoDays", ts: now - 2 * 86_400_000),
                    fight("tenDays", ts: now - 10 * 86_400_000), fight("old", ts: now - 40 * 86_400_000)]
        XCTAssertEqual(fightRows(rows, range: .day, query: "", now: now).map(\.value), ["new"])
        XCTAssertEqual(fightRows(rows, range: .threeDays, query: "", now: now).map(\.value), ["new", "twoDays"])
        XCTAssertEqual(fightRows(rows, range: .week, query: "", now: now).map(\.value), ["new", "twoDays"])
        XCTAssertEqual(fightRows(rows, range: .month, query: "", now: now).map(\.value), ["new", "twoDays", "tenDays"])
        XCTAssertEqual(fightRows(rows, range: .month, query: "ten", now: now).map(\.value), ["tenDays"])
    }
}
