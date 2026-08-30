import XCTest
import EQCompanionCore
@testable import EQCompanion

/// The map-file parser, the pack resolution and the one `/loc` seam — against synthetic text for
/// the rules, and against the owner's real `maps\` corpus for the numbers.
final class MapFilesTests: XCTestCase {

    // MARK: - The rules that are easy to get wrong

    func testLabelsMayContainCommas() {
        let r = MapFile.parse(text: "P 1, 2, 3, 4, 5, 6, 2, Gate_Guard,_Second_Floor\n", layer: 1)
        XCTAssertEqual(r.skipped, 0)
        XCTAssertEqual(r.points.count, 1)
        XCTAssertEqual(r.points[0].label, "Gate_Guard,_Second_Floor")
        XCTAssertEqual(r.points[0].display, "Gate Guard, Second Floor")
    }

    func testTruncatedSegmentIsCountedNotParsedAsBlack() {
        // `Number('')` is 0 in JS; the empty guard is what stops this becoming a black wall.
        let r = MapFile.parse(text: "L 1, 2, 3, 4, 5, 6, 0, 0,\n", layer: 0)
        XCTAssertEqual(r.lines.count, 0)
        XCTAssertEqual(r.skipped, 1)
    }

    func testUnknownRecordIsSkippedAndBlankLinesAreNot() {
        let r = MapFile.parse(text: "\n\nX 1,2,3\n   \n", layer: 0)
        XCTAssertEqual(r.skipped, 1)
    }

    func testSizeIsATextClassNotARadius() {
        let r = MapFile.parse(text: "P 0,0,0, 1,2,3, 9, big\nP 0,0,0, 1,2,3, 0, small\n", layer: 1)
        XCTAssertEqual(r.points.map(\.size), [3, 1])
    }

    func testCrlfAndLfParseTheSame() {
        let a = MapFile.parse(text: "L 0,0,0,1,1,1,255,0,0\r\n", layer: 0)
        let b = MapFile.parse(text: "L 0,0,0,1,1,1,255,0,0\n", layer: 0)
        XCTAssertEqual(a.lines.count, 1)
        XCTAssertEqual(b.lines.count, 1)
    }

    func testLegendContributesGeometryButNeverBounds() {
        let map = MapFile.parse(text: "L 0,0,0, 10,10,0, 255,255,255\n", layer: 0)
        let legend = MapFile.parse(text: "L 1000,-4000,0, 1000,4800,0, 255,0,0\n", layer: 2)
        let built = MapFile.build([map, legend], zone: "test", sources: [])
        XCTAssertEqual(built.lines.count, 2, "the legend is still drawable")
        XCTAssertEqual(built.bounds.maxY, 10, "but never widens the extent")
        XCTAssertEqual(built.zLevels, [0])
    }

    func testHeightHintAndCreditsAreMinedFromTheLegend() {
        let legend = MapFile.parse(
            text: """
            P 0,0,0, 1,1,1, 1, Height_Filter:_25/25_(in_Dwarf_Keep)
            P 0,0,0, 1,1,1, 1, Original_Map:_Someone
            P 0,0,0, 1,1,1, 1, http://www.eqmaps.info
            P 0,0,0, 1,1,1, 1, not_a_credit
            """, layer: 2)
        let built = MapFile.build([legend], zone: "test", sources: [])
        XCTAssertEqual(built.heightHint?.low, 25)
        XCTAssertEqual(built.heightHint?.high, 25)
        XCTAssertEqual(built.credits, ["Original Map: Someone", "http://www.eqmaps.info"])
    }

    func testStemsMayEndInADigit() {
        XCTAssertEqual(MapFile.splitFileName("Thurgadina1.txt")?.stem, "thurgadina1")
        XCTAssertEqual(MapFile.splitFileName("Thurgadina1.txt")?.layer, 0)
        XCTAssertEqual(MapFile.splitFileName("Thurgadina1_1.txt")?.stem, "thurgadina1")
        XCTAssertEqual(MapFile.splitFileName("Thurgadina1_1.txt")?.layer, 1)
        XCTAssertNil(MapFile.splitFileName("_1.txt"))
        XCTAssertNil(MapFile.splitFileName("gukbottom.txt:crc"), "an NTFS stream is not a map file")
        XCTAssertEqual(MapFile.splitFileName("befallen_4.txt")?.layer, 0, "only _1.._3 are layers")
    }

    // MARK: - The one /loc -> map seam

    func testMapFromLoc() {
        // Map y grows SOUTH, /loc's first number grows NORTH: both axes negate, and only here.
        let p = MapGeo.mapFromLoc(EqLoc(ns: 1414.20, ew: -735.55, z: 12.19))
        XCTAssertEqual(p.x, 735.55, accuracy: 0.001)
        XCTAssertEqual(p.y, -1414.20, accuracy: 0.001)
        XCTAssertEqual(p.z, 12.19, accuracy: 0.001)
        let back = MapGeo.locFromMap(x: p.x, y: p.y, z: p.z)
        XCTAssertEqual(back.ns, 1414.20, accuracy: 0.001)
        XCTAssertEqual(back.ew, -735.55, accuracy: 0.001)
    }

    func testParseLocAcceptsTheLineTheGamePrints() {
        guard case .ok(let loc) = MapLoc.parse("Your Location is -1234.56, 987.65, 12.00") else {
            return XCTFail("the game's own line must parse")
        }
        XCTAssertEqual(loc.ns, -1234.56, accuracy: 0.001)
        XCTAssertEqual(loc.ew, 987.65, accuracy: 0.001)
        XCTAssertEqual(loc.z, 12, accuracy: 0.001)

        guard case .ok(let bare) = MapLoc.parse("[Wed Aug 27 20:11:03 2026] 10 20 30") else {
            return XCTFail("a timestamped line of bare numbers must parse")
        }
        XCTAssertEqual(bare.z, 30, accuracy: 0.001)

        if case .ok = MapLoc.parse("1, 2, 3, 4") { XCTFail("four numbers is not a /loc") }
        if case .ok = MapLoc.parse("north a bit") { XCTFail("prose is not a /loc") }
    }

    func testProjectionIsAPureScaleAndTranslateOnBothAxes() {
        let b = MapBounds(minX: -100, maxX: 100, minY: -50, maxY: 50, minZ: 0, maxZ: 0)
        let vp = CGSize(width: 400, height: 200)
        let cam = MapGeo.fit(b, vp)
        let centre = MapGeo.project(cam, vp, MapXY(x: 0, y: 0))
        XCTAssertEqual(centre.px, 200, accuracy: 0.001)
        XCTAssertEqual(centre.py, 100, accuracy: 0.001)
        // South (+y) must be DOWN the screen. A minus sign here mirrors every zone.
        let south = MapGeo.project(cam, vp, MapXY(x: 0, y: 10))
        XCTAssertGreaterThan(south.py, centre.py)
    }

    func testDeclutterDropsTheOverlapAndKeepsTheImportantOne() {
        func p(_ display: String, _ size: Int) -> MapPoint {
            MapPoint(x: 0, y: 0, z: 0, r: 255, g: 255, b: 255, size: size,
                     label: display.replacingOccurrences(of: " ", with: "_"), display: display, layer: 1)
        }
        let items = [
            MapLabelItem(index: 0, point: p("a rat", 1), px: 100, py: 100, inBand: true),
            MapLabelItem(index: 1, point: p("to Freeport", 3), px: 102, py: 101, inBand: true)
        ]
        let slots = MapLabels.layout(items)
        XCTAssertEqual(slots[1].shown, true, "the size-3 zone connection wins")
        XCTAssertEqual(slots[0].shown, false)
    }

    // MARK: - The real corpus

    /// The owner's install, when this machine has one. Skipped elsewhere rather than failed.
    private func mapsRoot() -> URL? {
        let root = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/CrossOver/Bottles/EverQuest/drive_c/users/Public/Daybreak Game Company/Installed Games/EverQuest Legends")
        return FileManager.default.fileExists(atPath: root.appendingPathComponent("maps").path) ? root : nil
    }

    func testRealCorpusParsesAndTheCountsAreReported() throws {
        guard let root = mapsRoot() else { throw XCTSkip("no EverQuest install on this machine") }
        let packs = MapFile.discoverPacks(eqRoot: root, userPacksRoot: nil)
        XCTAssertFalse(packs.isEmpty)
        print("PACKS: " + packs.map { "\($0.pack.id) (\($0.pack.zoneCount) zones, \($0.pack.fileCount) files)" }
            .joined(separator: ", "))
        print("ZONES: \(MapFile.zoneStems(packs).count)")

        let auto = try XCTUnwrap(MapFile.load(packs, zone: "gukbottom", prefs: MapPackPrefs()))
        print("gukbottom auto: sources=\(auto.sources.map { "\($0.layer):\($0.packId)" }.joined(separator: ",")) "
              + "segments=\(auto.lines.count) points=\(auto.points.count) palette=\(auto.lines.palette.count / 3) "
              + "skipped=\(auto.skipped) zLevels=\(auto.zLevels.count) credits=\(auto.credits.count)")
        XCTAssertGreaterThan(auto.lines.count, 1000)
        XCTAssertEqual(auto.skipped, 0, "the shipped corpus is clean")
        XCTAssertEqual(auto.lines.colorIndex.count, auto.lines.count)
        XCTAssertEqual(auto.lines.layer.count, auto.lines.count)
        XCTAssertEqual(auto.lines.coords.count, auto.lines.count * 6)
        // The legend never widens the extent, so the map is never a speck in the corner.
        XCTAssertLessThan(auto.bounds.maxX - auto.bounds.minX, 20_000)

        // The screenshot's "75 labels": brewalls supplies 50 POIs and a 25-row legend. Anything
        // above that is a third pack supplying a layer the other two do not have.
        XCTAssertEqual(auto.points.filter { $0.layer == 1 }.count, 50)
        XCTAssertEqual(auto.points.filter { $0.layer == 2 }.count, 25)

        // Geometry from the game's own files, labels from an installed pack — the split the
        // whole per-layer resolution exists for.
        let geomSource = try XCTUnwrap(auto.sources.first { $0.layer == 0 })
        XCTAssertEqual(geomSource.packId, "default")
        if packs.contains(where: { $0.pack.id == "brewalls" }) {
            XCTAssertEqual(auto.sources.first { $0.layer == 1 }?.packId, "brewalls")
            let forced = try XCTUnwrap(MapFile.load(packs, zone: "gukbottom",
                                                    prefs: MapPackPrefs(geometry: "brewalls", labels: "default")))
            print("gukbottom forced: sources=\(forced.sources.map { "\($0.layer):\($0.packId)" }.joined(separator: ","))"
                  + " segments=\(forced.lines.count) points=\(forced.points.count)")
            XCTAssertEqual(forced.sources.first { $0.layer == 0 }?.packId, "brewalls")
            XCTAssertEqual(forced.sources.first { $0.layer == 1 }?.packId, "default")
        }

        let bands = MapFloors.bands(auto.zLevels, hint: auto.heightHint)
        print("gukbottom bands: \(bands.count) -> \(bands.map(\.label).joined(separator: " | "))")
        XCTAssertFalse(bands.isEmpty)
        for i in 0..<bands.count {
            XCTAssertTrue(MapFloors.inActiveBand(bands, i, (bands[i].lo + bands[i].hi) / 2))
        }
    }

    /// A sweep over the whole corpus: nothing throws, nothing is silently dropped.
    func testEveryZoneInTheDefaultPackParses() throws {
        guard let root = mapsRoot() else { throw XCTSkip("no EverQuest install on this machine") }
        let packs = MapFile.discoverPacks(eqRoot: root, userPacksRoot: nil)
        let stems = MapFile.zoneStems(packs)
        var segments = 0, points = 0, skipped = 0, worst = ("", 0)
        for stem in stems {
            guard let d = MapFile.load(packs, zone: stem, prefs: MapPackPrefs()) else { continue }
            segments += d.lines.count
            points += d.points.count
            skipped += d.skipped
            if d.lines.count > worst.1 { worst = (stem, d.lines.count) }
        }
        print("CORPUS: \(stems.count) zones, \(segments) segments, \(points) points, \(skipped) unparsed; "
              + "biggest = \(worst.0) at \(worst.1) segments")
        XCTAssertGreaterThan(segments, 100_000)
        XCTAssertEqual(skipped, 0)
    }

    /// The store and the pane, end to end on the real install: scan, parse, cache, and the wiki
    /// join for the zone the header names.
    @MainActor
    func testStoreAndPaneOverTheRealInstall() async throws {
        guard let root = mapsRoot() else { throw XCTSkip("no EverQuest install on this machine") }
        let store = MapStore()
        await store.scan(root: root)
        XCTAssertTrue(store.ready)
        XCTAssertTrue(store.zones.contains("gukbottom"))
        XCTAssertTrue(store.packs.contains { $0.id == "default" })

        await store.load(zone: "gukbottom", prefs: MapPackPrefs())
        let data = try XCTUnwrap(store.data)
        XCTAssertNil(store.error)
        XCTAssertFalse(store.loading)
        XCTAssertEqual(data.zone, "gukbottom")

        // A second load of the same key is the cache, not a second parse.
        await store.load(zone: "gukbottom", prefs: MapPackPrefs())
        XCTAssertEqual(store.data?.lines.count, data.lines.count)

        // The wiki pane's folding, on a synthetic catalog: `GameData`'s data roots are not
        // resolvable from the xctest runner (Bundle.main is the test tool, not the app), so the
        // JOIN is exercised in the app and the FOLD is exercised here.
        func mob(_ name: String, _ level: String, _ zones: [String], _ loc: [JSONValue]) -> GameData.Mob {
            GameData.Mob(name: name, page: name, level: level, zones: zones, drops: [], loc: loc, raw: .null)
        }
        func at(_ ns: Double, _ ew: Double, pct: Double? = nil) -> JSONValue {
            var o: [String: JSONValue] = ["ns": .double(ns), "ew": .double(ew)]
            if let pct { o["pct"] = .double(pct) }
            return .object(o)
        }
        let rows = MapPaneRows.rows(from: [
            mob("Ghoul Lord", "35", ["Lower Guk"], [at(100, -200, pct: 50), at(300, -400, pct: 50)]),
            mob("a froglok tad", "1", ["Lower Guk"], []),
            mob("Phinigel Autropos", "40", ["Lower Guk", "Kedge Keep"], [at(0, 0)])
        ])
        XCTAssertEqual(rows.map(\.name), ["a froglok tad", "Ghoul Lord", "Phinigel Autropos"], "level order")
        XCTAssertEqual(rows[1].pins.count, 2)
        XCTAssertEqual(rows[1].note, "2 spawn points")
        // Both axes negate, once, here and nowhere else.
        XCTAssertEqual(rows[1].pins[0].x, 200, accuracy: 0.001)
        XCTAssertEqual(rows[1].pins[0].y, -100, accuracy: 0.001)
        XCTAssertEqual(rows[1].pins[0].pct, 50)
        XCTAssertEqual(rows[0].note, "no location on the wiki page")
        XCTAssertFalse(rows[0].locatable)
        XCTAssertTrue(rows[2].pins.isEmpty, "a position that names two zones cannot be attributed")
        XCTAssertEqual(rows[2].note, "position stated, but the page lists 2 zones")

        let labels = MapPaneRows.labelRows(data.points)
        let counts = MapPaneRows.counts(mobs: rows, labels: labels)
        print("gukbottom pane: \(labels.count) map labels (legend excluded), \(counts.located)/\(counts.mobs) placed")
        XCTAssertEqual(counts.located, 1)
        XCTAssertEqual(labels.count, data.points.filter { $0.layer != 2 }.count)
        XCTAssertEqual(MapPaneRows.filter(rows, query: "ghoul lord").map(\.name), ["Ghoul Lord"])

        // An unknown zone is a message, not a crash and not a stale map.
        await store.load(zone: "not-a-zone", prefs: MapPackPrefs())
        XCTAssertNil(store.data)
        XCTAssertNotNil(store.error)
    }
}
