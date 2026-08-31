import XCTest
@testable import EQCompanion

/// A generated label carries a height, and the game uses it to decide whether to draw the label at
/// all. These tests exist because that height was zero for 98% of the pins we wrote - so the pack
/// contained every spawn point and the game showed almost none of them.
final class MapElevationTests: XCTestCase {
    private func mapsRoot() -> URL? {
        let root = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/CrossOver/Bottles/EverQuest/drive_c/users/Public/Daybreak Game Company/Installed Games/EverQuest Legends")
        return FileManager.default.fileExists(atPath: root.appendingPathComponent("maps").path) ? root : nil
    }

    func testItAnswersWithTheNearestFloorAndFallsBackToTheMiddle() {
        // Two floors, far apart in x, each flat.
        var lines = MapLines()
        for (x, z) in [(0.0, -100.0), (10.0, -100.0), (500.0, -200.0), (510.0, -200.0)] {
            lines.coords += [Float(x), 0, Float(z), Float(x + 5), 0, Float(z)]
            lines.layer.append(1)
            lines.count += 1
        }
        let floors = MapElevation(lines)
        XCTAssertEqual(floors.z(x: 2, y: 0), -100, accuracy: 0.01, "stands on the near floor")
        XCTAssertEqual(floors.z(x: 505, y: 0), -200, accuracy: 0.01, "and not on the far one")
        // Nowhere near anything: the zone's middle rather than a confident wrong answer.
        XCTAssertEqual(floors.z(x: 100_000, y: 100_000), floors.median, accuracy: 0.01)
        // An empty map cannot answer at all, and says so with its median rather than crashing.
        XCTAssertEqual(MapElevation(MapLines()).z(x: 0, y: 0), 0)
    }

    func testTheLegendIsNotAFloor() {
        var lines = MapLines()
        // A real floor at -200, and a legend key sitting at zero right next to it.
        lines.coords += [0, 0, -200, 10, 0, -200]; lines.layer.append(1); lines.count += 1
        lines.coords += [1, 0, 0, 2, 0, 0]; lines.layer.append(UInt8(MapFile.legendLayer)); lines.count += 1
        let floors = MapElevation(lines)
        XCTAssertEqual(floors.z(x: 1, y: 0), -200, accuracy: 0.01,
                       "the colour key is not a place; answering with its height is how a pin ends up above the dungeon")
    }

    /// End to end, on the real install: every label the generator writes for a zone must sit inside
    /// that zone's own geometry, not hundreds of units above it.
    @MainActor
    func testEveryGeneratedLabelSitsInsideTheZonesOwnHeights() throws {
        guard let root = mapsRoot() else { throw XCTSkip("no EverQuest install on this machine") }
        let packs = MapFile.discoverPacks(eqRoot: root, userPacksRoot: nil)
        guard let guk = MapFile.load(packs, zone: "gukbottom", prefs: MapPackPrefs()) else {
            throw XCTSkip("no Lower Guk map on this machine")
        }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("elevation-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        // Common spawns included: the zone states no elevation for any of them, so every one of
        // these heights had to be worked out from the map.
        _ = try MapAnnotations.generate(into: tmp, filter: .init(common: true), packs: packs)

        let text = try String(contentsOf: tmp.appendingPathComponent("gukbottom_1.txt"), encoding: .utf8)
        let parsed = MapFile.parse(text: text, layer: 1)
        XCTAssertEqual(parsed.skipped, 0)
        XCTAssertGreaterThan(parsed.points.count, 20, "Lower Guk has plenty of stated spawns")

        // The dungeon's real extent, taken from the GEOMETRY it is drawn from - not from
        // `bounds`, which also spans the label points and so includes the zeros written by the
        // very pack this test is about, installed on this machine and read back in.
        var lo = Double.infinity, hi = -Double.infinity
        var i = 0
        while i + 5 < guk.lines.coords.count {
            let segment = i / 6
            if segment >= guk.lines.layer.count || Int(guk.lines.layer[segment]) != MapFile.legendLayer {
                for k in 0..<2 {
                    let z = Double(guk.lines.coords[i + k * 3 + 2])
                    lo = min(lo, z); hi = max(hi, z)
                }
            }
            i += 6
        }
        XCTAssertLessThan(hi, 0, "Lower Guk is below zero throughout - which is why zero was wrong")
        for p in parsed.points {
            XCTAssertTrue(p.z >= lo && p.z <= hi,
                          "\(p.display) written at z=\(p.z), outside the zone's \(Int(lo))…\(Int(hi))")
        }
        XCTAssertFalse(parsed.points.contains { p in p.z == 0 }, "no label may be left at zero")
    }

    /// An exit's height is the source pack's own, carried through rather than flattened.
    @MainActor
    func testExitsKeepTheHeightTheirPackStated() throws {
        guard let root = mapsRoot() else { throw XCTSkip("no EverQuest install on this machine") }
        let packs = MapFile.discoverPacks(eqRoot: root, userPacksRoot: nil)
        let markers = MapZoneLines.markers(zone: "gukbottom", packs: packs, excluding: "eqc")
        try XCTSkipIf(markers.isEmpty, "no exits in the installed packs")
        XCTAssertTrue(markers.contains { $0.z != 0 }, "the packs state real heights for their doors")
    }
}
