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
