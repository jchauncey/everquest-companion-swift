import XCTest
import SwiftUI
@testable import EQCompanion

/// The two promises the Zones picker makes: you can type to find a zone, and what you have already
/// chosen is always right there to take back off.
final class FilterMultiPickerTests: XCTestCase {
    /// The picker's ordering and matching, as pure functions of (options, selection, filter) - the
    /// same shape the view computes, so the rules can be checked without a window.
    private func chosen(_ options: [String], _ selection: Set<String>) -> [String] {
        options.filter { selection.contains($0) }
    }

    private func matches(_ options: [String], _ selection: Set<String>, _ filter: String) -> [String] {
        let q = filter.lowercased().trimmingCharacters(in: .whitespaces)
        let pool = options.filter { !selection.contains($0) }
        guard !q.isEmpty else { return pool }
        let scored: [(String, Int)] = pool.compactMap { o in
            let s = o.lowercased()
            if s.hasPrefix(q) { return (o, 0) }
            if s.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(where: { $0.hasPrefix(q) }) { return (o, 1) }
            if s.contains(q) { return (o, 2) }
            return nil
        }
        return scored.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 < $1.1 }.map(\.0)
    }

    private let zones = ["Befallen", "Blackburrow", "Butcherblock Mountains", "Guk", "Lower Guk",
                         "The Ruins of Old Guk", "Upper Guk", "Nagafen's Lair", "Plane of Fear"]

    func testTypingRanksAPrefixAboveAWordStartAboveASubstring() {
        // "guk" NAMES one zone outright, so that comes first; the other three all carry it as a
        // whole word, so they rank together and stay alphabetical among themselves.
        XCTAssertEqual(matches(zones, [], "guk"),
                       ["Guk", "Lower Guk", "The Ruins of Old Guk", "Upper Guk"])
        // A substring that is not a word start ranks below all of those.
        XCTAssertEqual(matches(["Innothule Swamp", "Thule"], [], "thul"), ["Thule", "Innothule Swamp"])
        // Ties inside a rank stay alphabetical, so the order never wobbles between keystrokes.
        XCTAssertEqual(matches(zones, [], "b"), ["Befallen", "Blackburrow", "Butcherblock Mountains"])
        XCTAssertEqual(matches(zones, [], "  GUK "), matches(zones, [], "guk"), "case and padding are noise")
        XCTAssertEqual(matches(zones, [], "zzz"), [])
        XCTAssertEqual(matches(zones, [], ""), zones, "an empty filter hides nothing")
    }

    func testChosenZonesArePinnedAboveTheMatchesAndSurviveTheFilter() {
        let picked: Set<String> = ["Plane of Fear", "Befallen"]
        // Pinned block keeps the options' own order, not click order, so it cannot shuffle.
        XCTAssertEqual(chosen(zones, picked), ["Befallen", "Plane of Fear"])
        // A chosen zone is never also offered below.
        XCTAssertFalse(matches(zones, picked, "").contains("Befallen"))

        // THE POINT: a filter that matches neither of them still leaves both removable.
        let rows = chosen(zones, picked) + matches(zones, picked, "guk")
        XCTAssertEqual(rows.prefix(2).map { $0 }, ["Befallen", "Plane of Fear"])
        XCTAssertTrue(rows.contains("Lower Guk"))
        XCTAssertEqual(Set(rows).count, rows.count, "no zone appears twice")
    }

    func testTheFaceSaysWhatIsChosenUntilThereAreTooMany() {
        XCTAssertEqual(pickerSummary(title: "Zones", empty: "everywhere", options: zones, picked: []),
                       "Zones: everywhere")
        XCTAssertEqual(pickerSummary(title: "Zones", empty: "everywhere", options: zones, picked: ["Guk"]),
                       "Zones: Guk")
        // Past a handful it becomes a count rather than crowding the filter row.
        let many = Set(zones.prefix(6))
        XCTAssertEqual(pickerSummary(title: "Zones", empty: "everywhere", options: zones, picked: many),
                       "Zones: 6 of 9")
        // Few but long also counts, for the same reason.
        let longOnes: Set<String> = ["Butcherblock Mountains", "The Ruins of Old Guk"]
        XCTAssertEqual(pickerSummary(title: "Zones", empty: "everywhere", options: zones, picked: longOnes),
                       "Zones: 2 of 9")
    }

    /// The picker must render with the real 155-zone vocabulary without being asked for an
    /// unbounded width - it sits in the filter row beside everything else.
    @MainActor
    func testItRendersAtAModestWidthWithTheRealZoneList() {
        let roots = GameData.shared.roots
        let corpus = GearIndex.build(itemsURL: roots.data.appendingPathComponent("items.json"),
                                     zonesURL: roots.generated.appendingPathComponent("zones.json"),
                                     researchURL: roots.data.appendingPathComponent("itemsResearch.json"))
        XCTAssertGreaterThan(corpus.dropZones.count, 100, "the real vocabulary is long - hence the filter")

        let host = NSHostingView(rootView: FilterMultiPicker(
            title: "Zones", empty: "everywhere", options: corpus.dropZones,
            selection: .constant(["Lower Guk"])))
        XCTAssertLessThan(host.fittingSize.width, 260,
                          "the closed picker asked for \(host.fittingSize.width)pt - it must stay a control, not a column")
    }
}
