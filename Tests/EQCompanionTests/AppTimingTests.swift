import XCTest
@testable import EQCompanion

/// The launch stopwatch: the arithmetic behind the bars, and the one rule about duplicates.
final class AppTimingTests: XCTestCase {

    private func profile(_ marks: [(String, Double)]) -> StartupProfile {
        StartupProfile(startedAt: Date(timeIntervalSince1970: 0), version: "1.14.0",
                       marks: marks.map { StartupMark(phase: $0.0, atMs: $0.1) })
    }

    func testAPhasesDurationIsTheGapItClosed() {
        let p = profile([("Settings loaded", 1350), ("Spell + mob knowledge loaded", 1452)])
        XCTAssertEqual(p.timings.map(\.durationMs), [1350, 102])
        XCTAssertEqual(p.totalMs, 1452)
    }

    /// Two phases that race are drawn in the order they landed, never in the list's order — the
    /// other way round draws a negative bar.
    func testMarksAreOrderedByWhenTheyLanded() {
        let p = profile([("Interface drawn", 900), ("Log history replayed", 400)])
        XCTAssertEqual(p.timings.map(\.phase), ["Log history replayed", "Interface drawn"])
        XCTAssertEqual(p.timings.map(\.durationMs), [400, 500])
    }

    func testALaunchShortOfAPhaseIsIncomplete() {
        XCTAssertFalse(profile([("Settings loaded", 10)]).complete)
        XCTAssertTrue(profile(AppTiming.phases.enumerated().map { ($0.element, Double($0.offset + 1) * 100) }).complete)
    }

    func testTheEightUpstreamPhasesAreTheSixThisAppCanMark() {
        XCTAssertEqual(AppTiming.phases, ["Settings loaded", "Spell + mob knowledge loaded",
                                          "Window created", "Log session started",
                                          "Log history replayed", "Interface drawn"])
    }

    func testFormatMsMatchesTheUpstreamsTwoDecimals() {
        XCTAssertEqual(StartupFormat.ms(102), "102 ms")
        XCTAssertEqual(StartupFormat.ms(1350), "1.35 s")
        XCTAssertEqual(StartupFormat.ms(4871), "4.87 s")
        XCTAssertEqual(StartupFormat.ms(2000), "2 s")
        XCTAssertEqual(StartupFormat.ms(-5), "0 ms")
    }

    func testAMarkIsRecordedOnceAndAnUnknownPhaseIsRefused() {
        AppTiming.reset()
        AppTiming.mark("Settings loaded")
        AppTiming.mark("Settings loaded")
        AppTiming.mark("Nothing this app does")
        let p = AppTiming.profile()
        XCTAssertEqual(p?.marks.map(\.phase), ["Settings loaded"])
        XCTAssertEqual(p?.version, AppVersion.current)
        AppTiming.reset()
    }

    func testTheProcessStartIsBeforeNow() {
        XCTAssertLessThanOrEqual(AppTiming.processStart, Date())
        XCTAssertGreaterThan(AppTiming.sinceLaunchMs(), 0)
    }
}
