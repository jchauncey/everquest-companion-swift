import XCTest
import EQCompanionCore
@testable import EQCompanion

/// Places the app can be made to TRAP — crash outright, not misbehave — on data it is handed.
///
/// This file exists because one of them reached a user: `AudioWindow` subtracted an `Int64.min`
/// sentinel from a wall-clock millisecond and took the app down on the first alert after launch
/// (see `AudioWindowTests`). An audit of the app layer for the same class of fault found the rest.
/// Every test here fails by KILLING THE RUN rather than reporting, which is the point: a trap is
/// not a wrong answer, it is no answer.
///
/// The pattern common to most of them is a bounds check that exists in one copy of a computation
/// and not in its twin, so several of these fixes were "make the two into one".
final class TrapGuardTests: XCTestCase {

    // MARK: - Bucketing an encounter's events

    /// The Overview tab clamped the bucket index at the top only; the Combat tab clamped both ends.
    /// An event stamped BEFORE its encounter's start gave a negative index and crashed the default
    /// tab on the next subscript.
    func testAnEventBeforeItsEncounterStartsDoesNotIndexBackwards() {
        XCTAssertEqual(dpsBucketIndex(t: -1, bucketMs: 1000, count: 10), 0)
        XCTAssertEqual(dpsBucketIndex(t: -1_000_000, bucketMs: 1000, count: 10), 0)
        // Still bucketing correctly in the middle, and still clamped at the top.
        XCTAssertEqual(dpsBucketIndex(t: 0, bucketMs: 1000, count: 10), 0)
        XCTAssertEqual(dpsBucketIndex(t: 4_500, bucketMs: 1000, count: 10), 4)
        XCTAssertEqual(dpsBucketIndex(t: 9_999_999, bucketMs: 1000, count: 10), 9)
    }

    /// `Int(_:)` traps on a double too large for it, so the clamp has to happen BEFORE the
    /// conversion. A `t` of 1e300 is finite, and JSON is free to carry it.
    func testAnAbsurdTimestampIsClampedRatherThanConverted() {
        XCTAssertEqual(dpsBucketIndex(t: 1e300, bucketMs: 1000, count: 10), 9)
        XCTAssertEqual(dpsBucketIndex(t: -1e300, bucketMs: 1000, count: 10), 0)
        XCTAssertEqual(dpsBucketIndex(t: .infinity, bucketMs: 1000, count: 10), 0)
        XCTAssertEqual(dpsBucketIndex(t: .nan, bucketMs: 1000, count: 10), 0)
        // Degenerate series never index anything.
        XCTAssertEqual(dpsBucketIndex(t: 500, bucketMs: 0, count: 10), 0)
        XCTAssertEqual(dpsBucketIndex(t: 500, bucketMs: 1000, count: 0), 0)
    }

    /// End to end through the real series builder, with the events that used to kill it. The
    /// Overview tab's own `curve` is private to its view, but it now indexes through the same
    /// `dpsBucketIndex` above - which is precisely the point of there being one of them.
    func testTheSeriesBuilderSurvivesEventsOutsideItsEncounter() {
        let tl = JSONValue.object([
            "durationMs": .double(60_000),
            "events": .array([
                .object(["t": .double(-5_000), "amount": .double(100), "kind": .string("you")]),
                .object(["t": .double(1_000), "amount": .double(50), "kind": .string("pet")]),
                .object(["t": .double(1e300), "amount": .double(10), "kind": .string("enemy")]),
            ]),
        ])
        _ = buildDpsSeries(tl)
    }

    // MARK: - Parallel columns from the engine's snapshot

    /// `offlineStart` and `offlineEnd` are decoded from two separate JSON arrays. A logout that has
    /// not ended is a start with no end, and this loop walked `offlineStart` while reading
    /// `offlineEnd`. Two of its three siblings already guarded; this one did not.
    @MainActor
    func testAnOpenLogoutDoesNotIndexPastTheEndColumn() {
        let snap = Self.progression(offlineStart: [1_000, 5_000], offlineEnd: [2_000])
        _ = overviewLeveling(snap, statedLevel: nil)
        _ = overviewRangeStats(snap, t0: 0, t1: 10_000)
    }

    /// A ding whose new level has not been parsed yet is `levelTs` one longer than `levelValue`.
    @MainActor
    func testADingWithoutItsLevelYetDoesNotIndexPastTheValueColumn() {
        let snap = Self.progression(levelTs: [1_000, 2_000, 3_000], levelValue: [10, 11])
        _ = overviewLeveling(snap, statedLevel: nil)
    }

    /// The zone columns, likewise: the name arrived, the start has not.
    @MainActor
    func testAZoneNameWithoutItsStartDoesNotIndexPastTheStartColumn() {
        let snap = Self.progression(zoneName: ["Lower Guk", "Innothule Swamp"],
                                    zoneStart: [1_000], zoneEnd: [2_000])
        _ = overviewLeveling(snap, statedLevel: nil)
    }

    /// Every column one short, all at once — the shape a truncated snapshot actually has.
    @MainActor
    func testAWhollyRaggedSnapshotIsSurvivable() {
        let snap = Self.progression(offlineStart: [1_000, 4_000], offlineEnd: [],
                                    levelTs: [1_000, 2_000], levelValue: [],
                                    zoneName: ["Lower Guk"], zoneStart: [], zoneEnd: [])
        _ = overviewLeveling(snap, statedLevel: nil)
        _ = overviewRangeStats(snap, t0: 0, t1: 10_000)
    }

    // MARK: - Third-party map packs

    /// Map packs are files other people wrote. The parser admits any FINITE double, so a size field
    /// of `1e300` reached `Int(_:)` and trapped - taking the zone's whole map with it. Its
    /// neighbour `byte()` had clamped all along.
    func testAnAbsurdSizeFieldClampsInsteadOfTrapping() {
        XCTAssertEqual(MapFile.sizeClass(1e300), 3)
        XCTAssertEqual(MapFile.sizeClass(-1e300), 1)
        XCTAssertEqual(MapFile.sizeClass(Double(Int64.max)), 3)
        // The real vocabulary still reads the same.
        XCTAssertEqual(MapFile.sizeClass(1), 1)
        XCTAssertEqual(MapFile.sizeClass(2), 2)
        XCTAssertEqual(MapFile.sizeClass(3), 3)
        XCTAssertEqual(MapFile.sizeClass(0), 1)
        XCTAssertEqual(MapFile.sizeClass(9), 3)
    }

    /// Through the parser, as a pack would deliver it.
    func testAPackWithAnAbsurdSizeFieldStillParses() {
        let text = """
        P 100.0, -200.0, -50.0, 255, 0, 0, 1e300, Absurd_Size
        P 101.0, -201.0, -51.0, 255, 0, 0, 2, Ordinary
        """
        let parsed = MapFile.parse(text: text, layer: 1)
        XCTAssertEqual(parsed.points.count, 2)
        XCTAssertEqual(parsed.points[0].size, 3)
        XCTAssertEqual(parsed.points[1].size, 2)
    }

    /// The same unbounded coordinates reach the elevation index, which turns them into cell keys.
    func testAnAbsurdCoordinateDoesNotTrapTheElevationIndex() {
        var lines = MapLines()
        for (x, z) in [(1e300, -100.0), (-1e300, -200.0), (0.0, -150.0)] {
            lines.coords += [Float(x), 0, Float(z), Float(x), 0, Float(z)]
            lines.layer.append(1)
            lines.count += 1
        }
        let floors = MapElevation(lines)
        // Building it is the test; querying the far ends must not trap either.
        _ = floors.z(x: 1e300, y: 1e300)
        _ = floors.z(x: -1e300, y: -1e300)
        XCTAssertEqual(floors.z(x: 0, y: 0), -150, accuracy: 1)
    }

    // MARK: - Free text from the scraped catalog

    /// `levelRange` reads a mob page's level field, which is prose. It accumulated digits into an
    /// unbounded `Int`, so twenty of them in a row overflowed and trapped the Mobs list.
    func testALongRunOfDigitsInALevelFieldDoesNotOverflow() {
        // Longer than Int64 can hold, several times over.
        _ = MobsView.levelRange("12345678901234567890123456789")
        _ = MobsView.levelRange(String(repeating: "9", count: 400))
        _ = MobsView.levelRange("\(Int.max)0")

        // And the real vocabulary still parses exactly as before.
        XCTAssertEqual(MobsView.levelRange("45"), 45...45)
        XCTAssertEqual(MobsView.levelRange("30-50"), 30...50)
        XCTAssertNil(MobsView.levelRange("unknown"))
        XCTAssertNil(MobsView.levelRange(""))
    }

    // MARK: - The surviving sentinel

    /// `LootSessions.openEnd`/`recordStart` are `Int64.max`/`.min` - the exact shape of the bug
    /// that crashed the app - and the only thing between them and `t1 - t0` is `clamp`. This pins
    /// that, so the guard cannot be refactored away quietly.
    @MainActor
    func testTheOpenEndedLootRangeIsClampedBeforeAnyArithmetic() {
        // An open logout as well, so the ragged-column guard is exercised on this side too.
        let p = Self.lootProgression(offlineStart: [2_000, 6_000], offlineEnd: [3_000])
        let wide = LootRange(t0: LootSessions.recordStart, t1: LootSessions.openEnd)

        // `resolve` is what stands between the sentinels and the arithmetic: it must hand back a
        // range inside the record, never the sentinels themselves.
        let slice = LootTimeslice.resolve(snap: p, bounds: (lo: 1_000, hi: 9_000),
                                          id: .custom, custom: wide)
        XCTAssertGreaterThan(slice.range.t0, LootSessions.recordStart)
        XCTAssertLessThan(slice.range.t1, LootSessions.openEnd)

        // And the spans of that clamped range compute without trapping.
        _ = lootRangeSpans(p, range: slice.range, key: nil, exact: nil)
    }

    // MARK: - Fixtures

    /// A progression with exactly the columns a test wants to make ragged. Defaults are balanced
    /// and boring; each test unbalances the pair it is about.
    private static func progression(offlineStart: [Int64] = [], offlineEnd: [Int64] = [],
                                    levelTs: [Int64] = [1_000], levelValue: [Int] = [10],
                                    zoneName: [String] = ["Lower Guk"],
                                    zoneStart: [Int64] = [1_000],
                                    zoneEnd: [Int64] = [9_000]) -> OverviewProgression {
        var s = OverviewProgression()
        s.lastTs = 10_000
        s.windowStart = 1_000
        s.offlineStart = offlineStart
        s.offlineEnd = offlineEnd
        s.levelTs = levelTs
        s.levelValue = levelValue
        s.zoneName = zoneName
        s.zoneStart = zoneStart
        s.zoneEnd = zoneEnd
        return s
    }

    /// The loot side's own progression, ragged in the same way.
    private static func lootProgression(offlineStart: [Int64], offlineEnd: [Int64]) -> LootProgression {
        var p = LootProgression()
        p.offlineStart = offlineStart
        p.offlineEnd = offlineEnd
        p.zoneName = ["Lower Guk"]
        p.zoneStart = [1_000]
        p.zoneEnd = [9_000]
        return p
    }
}
