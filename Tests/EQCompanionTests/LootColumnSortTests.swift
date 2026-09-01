import XCTest
@testable import EQCompanion

/// Sorting the loot table by clicking its columns — what the retired `Sort` dropdown used to do,
/// now for every column rather than the four the dropdown offered.
final class LootColumnSortTests: XCTestCase {
    private func row(_ item: String, count: Int = 0, estimate: Int = 0,
                     source: String? = nil, zones: Int = 0, last: Int64 = 0) -> LootGroupRow {
        LootGroupRow(key: item.lowercased(), countKey: item.lowercased(), item: item,
                     count: count, last: last, topSource: source, zoneCount: zones,
                     disposition: nil, invOnly: false, estimate: estimate)
    }

    private func sorted(_ rows: [LootGroupRow], _ key: String, _ desc: Bool) -> [String] {
        rows.sorted { LootColumnSort.compare($0, $1, key: key, descending: desc) }.map(\.item)
    }

    func testANumericColumnSortsBothWaysAndTiesBreakByName() {
        let rows = [row("Zircon", count: 5), row("Amber", count: 9), row("Beryl", count: 5)]
        XCTAssertEqual(sorted(rows, "count", true), ["Amber", "Beryl", "Zircon"])
        XCTAssertEqual(sorted(rows, "count", false), ["Beryl", "Zircon", "Amber"])
        // Beryl before Zircon in BOTH: a tie is broken by name, never by input order, so the table
        // cannot reshuffle equal rows between renders.
    }

    /// An empty cell sorts last in BOTH directions - the same rule the gear table uses, so "sort by
    /// top source" opens with the rows that state one rather than a screenful of dashes.
    func testAnAbsentCellSortsLastWhicheverWayTheArrowPoints() {
        let rows = [row("Amber", source: nil), row("Beryl", source: "a froglok"), row("Zircon", source: nil)]
        XCTAssertEqual(sorted(rows, "source", true), ["Beryl", "Amber", "Zircon"])
        XCTAssertEqual(sorted(rows, "source", false), ["Beryl", "Amber", "Zircon"])
        // The two absent rows keep name order between themselves.
    }

    func testEveryColumnTheTableDrawsCanOrderIt() {
        let a = row("Amber", count: 1, estimate: 9, source: "zeta", zones: 3, last: 500)
        let b = row("Beryl", count: 9, estimate: 1, source: "alpha", zones: 1, last: 100)
        for key in ["count", "estimate", "source", "zones", "last"] {
            let down = sorted([a, b], key, true)
            let up = sorted([a, b], key, false)
            XCTAssertEqual(down, up.reversed(), "\(key) must reverse cleanly")
            XCTAssertEqual(Set(down), ["Amber", "Beryl"], "\(key) must not drop a row")
        }
        // The name column reads A-Z ascending, and the unknown key falls back to it rather than
        // returning an arbitrary order.
        XCTAssertEqual(sorted([b, a], "item", false), ["Amber", "Beryl"])
        XCTAssertEqual(sorted([b, a], "not-a-column", false), ["Amber", "Beryl"])
    }

    /// A comparator that is not a strict weak ordering makes `sort` misbehave, so the total order is
    /// checked directly: nothing may compare "before" itself, and equals may not both precede.
    func testTheOrderIsTotal() {
        let rows = [row("Amber", count: 5, last: 100), row("Beryl", count: 5, last: 100),
                    row("Amber", count: 5, last: 100)]
        for key in ["item", "count", "estimate", "source", "zones", "last"] {
            for desc in [true, false] {
                for x in rows {
                    XCTAssertFalse(LootColumnSort.compare(x, x, key: key, descending: desc),
                                   "\(key) says a row precedes itself")
                }
                for x in rows where true {
                    for y in rows where x.item != y.item {
                        let xy = LootColumnSort.compare(x, y, key: key, descending: desc)
                        let yx = LootColumnSort.compare(y, x, key: key, descending: desc)
                        XCTAssertFalse(xy && yx, "\(key) says two rows each precede the other")
                    }
                }
            }
        }
    }
}
