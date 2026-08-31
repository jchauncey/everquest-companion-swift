import XCTest
@testable import EQCompanion

/// The exits carried into the generated pack. The rule under test is the narrow one: a `to_…`
/// label is an exit only when what follows names a zone the catalog knows - which is the only
/// thing separating `to_Innothule_Swamp` from `to_King` and `to_library`.
final class MapZoneLinesTests: XCTestCase {
    @MainActor
    func testOnlyLabelsNamingARealZoneCount() {
        XCTAssertEqual(MapZoneLines.target(ofLabel: "to_Innothule_Swamp"), "Innothule Swamp")
        XCTAssertEqual(MapZoneLines.target(ofLabel: "to_The_City_of_Guk"), "The City of Guk")
        XCTAssertEqual(MapZoneLines.target(ofLabel: "To Katta Castrum") ?? "-", "-", "not a classic zone")
        // The pack's spelling and the catalog's differ by a leading article, both directions.
        XCTAssertEqual(MapZoneLines.target(ofLabel: "to_Greater_Faydark"), "The Greater Faydark")
        XCTAssertEqual(MapZoneLines.target(ofLabel: "to_The_Warsliks_Woods"), "Warslik's Woods")
        // An alias and a /who short name both resolve to the catalog's display name.
        XCTAssertEqual(MapZoneLines.target(ofLabel: "to_Upper_Guk"), "The City of Guk")
        XCTAssertEqual(MapZoneLines.target(ofLabel: "to_gukbottom"), "The Ruins of Old Guk")
        // A trailing note about the exit is not part of the name.
        XCTAssertEqual(MapZoneLines.target(ofLabel: "to_Innothule_Swamp_(one-way)"), "Innothule Swamp")

        // Room pointers wearing the same prefix are NOT exits.
        XCTAssertNil(MapZoneLines.target(ofLabel: "to_King"))
        XCTAssertNil(MapZoneLines.target(ofLabel: "to_Ghoul_Lord"))
        XCTAssertNil(MapZoneLines.target(ofLabel: "to_library"))
        XCTAssertNil(MapZoneLines.target(ofLabel: "to_A"), "a single letter labels a door")
        XCTAssertNil(MapZoneLines.target(ofLabel: "Scribe_&_Sage"), "no prefix, no exit")
        XCTAssertNil(MapZoneLines.target(ofLabel: "Tomb_of_Terris_Thule"), "'to' must be a whole word")

        // A destination outside the eras this companion covers is not a door on this server. The
        // modern packs mark these in classic zones; following one walks you into a wall.
        for hub in ["to_The_Plane_of_Knowledge", "to_PoK", "to_The_Bazaar", "to_The_Nexus",
                    "to_The_Guild_Lobby", "to_The_Barter_Hall"] {
            XCTAssertNil(MapZoneLines.target(ofLabel: hub), "\(hub) is post-Velious")
        }
    }

    /// Two packs describing DIFFERENT VERSIONS of a zone must not both be believed.
    ///
    /// Nektulos Forest was revamped and its door to Neriak moved. The game's own file and Brewall's
    /// `nektulos_1_original` say (1108, -2276); Brewall's revamped file and Good's say
    /// (1001, -1798), 480 units away. Unioning drew two "to Neriak - Foreign Quarter" labels on one
    /// map, which is what the owner saw in game.
    @MainActor
    func testOneDestinationIsAnsweredByOnePack() throws {
        guard let root = mapsRoot() else { throw XCTSkip("no EverQuest install on this machine") }
        let packs = MapFile.discoverPacks(eqRoot: root, userPacksRoot: nil)
        try XCTSkipIf(packs.count < 2, "needs at least two installed map packs")

        let nek = MapZoneLines.markers(zone: "nektulos", packs: packs, excluding: "eqc")
        let neriak = nek.filter { $0.zone == "Neriak - Foreign Quarter" }
        XCTAssertEqual(neriak.count, 1, "one door, one marker - got \(neriak.map { ($0.x, $0.y) })")
        // The game's own pack is first in resolution order, and it ships the zone the client loads.
        XCTAssertEqual(neriak.first?.x ?? 0, 1108, accuracy: 2)

        // The contract, over every zone: the doors to a destination are EXACTLY what some single
        // pack says about that destination - never a blend of two packs' accounts. Packs agreeing
        // on a position is not a blend; two packs each contributing a different position is, and
        // that is the shape that put two Neriak labels on one map.
        let sources = packs.filter { $0.pack.id != "eqc" }
        for z in GameData.shared.zones {
            let markers = MapZoneLines.markers(zone: z.short, packs: packs, excluding: "eqc")
            guard !markers.isEmpty else { continue }
            for dest in Set(markers.map(\.zone)) {
                let doors = markers.filter { $0.zone == dest }
                let matchesOnePack = sources.contains { p in
                    MapZoneLines.markers(zone: z.short, from: p).filter { $0.zone == dest } == doors
                }
                XCTAssertTrue(matchesOnePack,
                    "\(z.short) -> \(dest) is a blend no single pack states: \(doors.map { (Int($0.x), Int($0.y)) })")
            }
        }
    }

    /// Claiming per DESTINATION rather than per zone is what keeps the real exits: the game's own
    /// pack states all four Lower Guk lines to Upper Guk and nothing about the one-way drop to
    /// Innothule, so taking the zone wholesale from it would delete an exit that exists.
    @MainActor
    func testAnExitOnlyALaterPackKnowsIsStillKept() throws {
        guard let root = mapsRoot() else { throw XCTSkip("no EverQuest install on this machine") }
        let packs = MapFile.discoverPacks(eqRoot: root, userPacksRoot: nil)
        try XCTSkipIf(packs.count < 2, "needs at least two installed map packs")

        let guk = MapZoneLines.markers(zone: "gukbottom", packs: packs, excluding: "eqc")
        XCTAssertEqual(guk.filter { $0.zone == "The City of Guk" }.count, 4)
        XCTAssertEqual(guk.filter { $0.zone == "Innothule Swamp" }.count, 1,
                       "the one-way out is stated by a later pack than the one that answered for Upper Guk")
    }

    /// The owner's install, when this machine has one. Skipped elsewhere rather than failed.
    private func mapsRoot() -> URL? {
        let root = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/CrossOver/Bottles/EverQuest/drive_c/users/Public/Daybreak Game Company/Installed Games/EverQuest Legends")
        return FileManager.default.fileExists(atPath: root.appendingPathComponent("maps").path) ? root : nil
    }

    /// Against whatever packs are installed on this machine. Skips rather than fails where there
    /// are none - the rule is what is being tested, not the tester's EverQuest folder.
    @MainActor
    func testMarkersComeFromInstalledPacksAndDedupe() throws {
        guard let root = mapsRoot() else { throw XCTSkip("no EverQuest install on this machine") }
        let packs = MapFile.discoverPacks(eqRoot: root, userPacksRoot: nil)
        try XCTSkipIf(packs.count < 2, "needs at least two installed map packs")

        let guk = MapZoneLines.markers(zone: "gukbottom", packs: packs, excluding: "eqc")
        try XCTSkipIf(guk.isEmpty, "no gukbottom exits in the installed packs")
        XCTAssertTrue(guk.allSatisfy { !$0.zone.isEmpty })
        XCTAssertEqual(guk.filter { $0.zone == "Innothule Swamp" }.count, 1, "the one-way out, once")
        // The wiki's own account of the zone: four lines to Upper Guk. Both installed packs mark
        // all four at coordinates ~40 apart, so without the proximity merge this would be eight.
        XCTAssertEqual(guk.filter { $0.zone == "The City of Guk" }.count, 4)

        // No two markers for one zone may sit on top of each other.
        for (i, a) in guk.enumerated() {
            for b in guk[(i + 1)...] where a.zone == b.zone {
                XCTAssertTrue(abs(a.x - b.x) > MapZoneLines.sameDoorRadius
                              || abs(a.y - b.y) > MapZoneLines.sameDoorRadius,
                              "two markers for \(a.zone) are the same door")
            }
        }

        // Excluding a pack really excludes it: dropping a contributor cannot ADD markers.
        for p in packs {
            let without = MapZoneLines.markers(zone: "gukbottom", packs: packs, excluding: p.pack.id)
            XCTAssertLessThanOrEqual(without.count, guk.count)
        }
    }

    /// End to end: the written pack must parse back with the exits in it, and every generated line
    /// must survive the app's own parser.
    @MainActor
    func testGeneratedPackCarriesTheExits() throws {
        guard let root = mapsRoot() else { throw XCTSkip("no EverQuest install on this machine") }
        let packs = MapFile.discoverPacks(eqRoot: root, userPacksRoot: nil)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("zonelines-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let with = try MapAnnotations.generate(into: tmp, filter: .init(zoneLines: true), packs: packs)
        try XCTSkipIf(with.zoneLines == 0, "the installed packs state no exits")

        let text = try String(contentsOf: tmp.appendingPathComponent("gukbottom_1.txt"), encoding: .utf8)
        let parsed = MapFile.parse(text: text, layer: 1)
        XCTAssertEqual(parsed.skipped, 0, "every generated line must parse")
        let exits = parsed.points.filter { $0.display.hasPrefix("to ") }
        XCTAssertFalse(exits.isEmpty)
        XCTAssertTrue(exits.allSatisfy { $0.b > $0.r }, "exits are blue, not the mobs' red")
        XCTAssertTrue(parsed.points.contains { !$0.display.hasPrefix("to ") }, "mob pins are still there")

        // Turning them off really turns them off.
        try? FileManager.default.removeItem(at: tmp)
        let without = try MapAnnotations.generate(into: tmp, filter: .init(zoneLines: false), packs: packs)
        XCTAssertEqual(without.zoneLines, 0)
        XCTAssertLessThan(without.labels, with.labels)
    }
}
