import XCTest
@testable import EQCompanion

/// The regression this file exists for: searching the Gear table for "A Dark Reaver" - an item the
/// player can see on a mob's drop list - returned nothing and blamed the Current era toggle, while
/// the control actually hiding it was the Classes picker (the item is SHD-only) sitting off the
/// right-hand end of the filter row.
final class GearBlameTests: XCTestCase {
    @MainActor
    private func corpus() -> [GearRow] {
        let roots = GameData.shared.roots
        return GearIndex.build(itemsURL: roots.data.appendingPathComponent("items.json"),
                               zonesURL: roots.generated.appendingPathComponent("zones.json"),
                               researchURL: roots.data.appendingPathComponent("itemsResearch.json")).rows
    }

    private func search(_ needle: String) -> GearFilter {
        GearFilter(label: "the search box", anchor: true) { $0.searchKey.contains(needle) }
    }
    private func onlyClasses(_ want: Set<String>) -> GearFilter {
        GearFilter(label: "the Classes picker") { $0.classes.isEmpty || $0.classes.contains { want.contains($0) } }
    }
    private var inEra: GearFilter { GearFilter(label: "the Current era toggle") { $0.era == .inEra } }
    private func inZones(_ want: Set<String>) -> GearFilter {
        GearFilter(label: "the Zones picker") { row in row.drops.contains { want.contains($0.zone) } }
    }

    /// The Zones picker answers "what drops here", so an item stating no drop at all is NOT in it.
    ///
    /// This is deliberately unlike the Classes picker, which never hides an item whose page states
    /// no class list. The reason they differ: an empty class list means the wiki declined to say,
    /// while an empty drop list mostly means the item is a quest reward, crafted or bought - and
    /// half the corpus is in that state, so treating "no zone stated" as "matches every zone" would
    /// bury the answer under thousands of items from nowhere near it.
    @MainActor
    func testTheZonesPickerKeepsOnlyWhatDropsThere() {
        let rows = corpus()
        let zoneless = rows.filter { $0.drops.isEmpty }
        XCTAssertGreaterThan(zoneless.count, 1000, "much of the corpus states no drop zone")

        let guk = rows.filter { r in inZones(["Lower Guk"]).keeps(r) }
        XCTAssertFalse(guk.isEmpty)
        XCTAssertTrue(guk.allSatisfy { $0.drops.contains { $0.zone == "Lower Guk" } })
        XCTAssertTrue(guk.allSatisfy { !$0.drops.isEmpty }, "a zone-less item is never in a zone's list")
        XCTAssertLessThan(guk.count, zoneless.count, "the filter must not be swamped by zone-less rows")

        // Two zones is a union, not an intersection.
        let both = rows.filter { r in inZones(["Lower Guk", "Befallen"]).keeps(r) }
        XCTAssertGreaterThan(both.count, guk.count)

        // The picker's own vocabulary only lists zones something actually drops in, so no option
        // can empty the table on its own.
        let corpusZones = Set(rows.flatMap { $0.drops.map(\.zone) }).subtracting([""])
        for z in corpusZones.prefix(25) {
            XCTAssertFalse(rows.filter { r in inZones([z]).keeps(r) }.isEmpty, "\(z) lists nothing")
        }
    }

    /// And when it IS the reason the table is empty, it says so with the caveat that explains why.
    @MainActor
    func testTheZonesPickerIsBlamedWithItsCaveat() {
        let rows = corpus()
        // A Lower Guk search for an item that drops elsewhere: the zone picker is what removed it.
        let filters = [search("adamantite epaulets"), inZones(["Befallen"])]
        XCTAssertTrue(rows.filter { r in filters.allSatisfy { $0.keeps(r) } }.isEmpty)
        let text = GearBlame.text(rows: rows, filters: filters)
        XCTAssertTrue(text.contains("the Zones picker"), text)
        XCTAssertTrue(text.contains("quest, crafted and bought items name no zone"), text)
    }

    @MainActor
    func testTheClassPickerIsBlamedAndTheEraToggleIsNot() {
        let rows = corpus()
        // The item is present, in-era, and matches the query: only the class list excludes it.
        XCTAssertEqual(rows.filter { $0.searchKey.contains("dark reaver") }.count, 1)

        let filters = [search("a dark reaver"), onlyClasses(["SHM", "NEC"]), inEra]
        XCTAssertTrue(rows.filter { r in filters.allSatisfy { $0.keeps(r) } }.isEmpty, "the table is empty")
        XCTAssertEqual(GearBlame.culprits(rows: rows, filters: filters), ["the Classes picker"])

        let text = GearBlame.text(rows: rows, filters: filters)
        XCTAssertTrue(text.contains("the Classes picker"), text)
        XCTAssertFalse(text.contains("Current era"), "the era toggle was never the reason: \(text)")
        XCTAssertTrue(text.contains("defaults to the classes"), "the aside explains the default: \(text)")

        // A Shadow Knight sees the same item: the picker is only blamed when it is the cause.
        let shd = [search("a dark reaver"), onlyClasses(["SHD"]), inEra]
        XCTAssertEqual(rows.filter { r in shd.allSatisfy { $0.keeps(r) } }.count, 1)
    }

    private var headSlot: GearFilter {
        GearFilter(label: "the Slots picker") { $0.slots.contains("HEAD") }
    }

    /// The search box is never offered up as the thing to drop while it is finding something -
    /// "clear your search" is not an answer to "where is this item".
    @MainActor
    func testTheSearchBoxIsHeldFixedWhileItMatchesSomething() {
        let rows = corpus()
        let both = [search("a dark reaver"), headSlot]
        XCTAssertTrue(rows.filter { r in both.allSatisfy { $0.keeps(r) } }.isEmpty)
        XCTAssertEqual(GearBlame.culprits(rows: rows, filters: both), ["the Slots picker"])
        XCTAssertEqual(GearBlame.text(rows: rows, filters: both),
                       "No gear matches these filters - the Slots picker is hiding what is left.")

        // The one case where the query IS the problem: nothing in the corpus answers to it.
        let nothing = [search("no item is called this"), inEra]
        XCTAssertEqual(GearBlame.culprits(rows: rows, filters: nothing), ["the search box"])
        XCTAssertEqual(GearBlame.text(rows: rows, filters: nothing), "Nothing in the item database is called that.")

        // Nothing active: nothing to blame.
        XCTAssertEqual(GearBlame.text(rows: rows, filters: []), "No gear matches these filters.")
    }

    @MainActor
    func testTwoControlsThatWouldEachAloneBringRowsBackAreBothNamed() {
        let rows = corpus()
        // No query. A HEAD slot and a two-hand-slashing weapon type cannot both hold.
        let twoHand = GearFilter(label: "the Weapon type picker") { $0.skill?.contains("2H Slashing") ?? false }
        let f = [headSlot, twoHand]
        XCTAssertTrue(rows.filter { r in f.allSatisfy { $0.keeps(r) } }.isEmpty)
        XCTAssertEqual(GearBlame.culprits(rows: rows, filters: f), ["the Slots picker", "the Weapon type picker"])
        XCTAssertEqual(GearBlame.text(rows: rows, filters: f),
                       "No gear matches these filters - relaxing the Slots picker or the Weapon type picker would bring rows back.")
    }

    /// The reported case: a search for "Dark" as a NEC/SHM/WAR character lists two swords and
    /// silently drops the SHD-only Dark Reaver. The table is not empty, so only this note can say it.
    @MainActor
    func testASearchThatShowsLessThanItFoundSaysWhat() {
        let rows = corpus()
        let filters = [search("dark reaver"), onlyClasses(["NEC", "SHM", "WAR"]), inEra]
        let (count, labels) = GearBlame.hidden(rows: rows, filters: filters)
        XCTAssertEqual(count, 1)
        XCTAssertEqual(labels, ["the Classes picker"])
        XCTAssertEqual(GearBlame.hiddenText(rows: rows, filters: filters),
                       "1 more item matches your search but the Classes picker is hiding it.")

        // Nothing hidden: the note stays silent rather than nagging.
        XCTAssertNil(GearBlame.hiddenText(rows: rows, filters: [search("dark reaver"), onlyClasses(["SHD"])]))
        XCTAssertNil(GearBlame.hiddenText(rows: rows, filters: [onlyClasses(["NEC"])]), "no query, no note")
    }

    @MainActor
    func testFiltersThatOnlyEmptyTheTableTogetherSaySo() {
        let rows = corpus()
        // The query finds the item; two constraints on top each independently exclude it, so
        // dropping either one alone still shows nothing and no control can be blamed.
        let f = [search("a dark reaver"), headSlot, onlyClasses(["SHM"])]
        XCTAssertTrue(GearBlame.culprits(rows: rows, filters: f).isEmpty)
        XCTAssertTrue(GearBlame.text(rows: rows, filters: f).contains("relaxing any single one"),
                      GearBlame.text(rows: rows, filters: f))
    }
}
