import XCTest
@testable import EQCompanion

/// The stats block is the wiki's own text, and it carries the one cross-reference a player most
/// wants to follow: what the proc actually does.
final class WikiMarkupTests: XCTestCase {
    func testTheEffectLineSplitsIntoProseAndALink() {
        // Verbatim from the corpus (Soul Leech, Dark Sword of Blood).
        let line = "Effect: [[Soul Leech|<span class='itemeff'>Soul Leech</span>]] (Combat, Casting Time: Instant) at Level 45"
        let runs = WikiMarkup.runs(line)
        XCTAssertEqual(runs.count, 3)
        XCTAssertEqual(runs[0], WikiMarkup.Run(text: "Effect: ", link: nil))
        // The display half is styled markup; the target half is the page.
        XCTAssertEqual(runs[1], WikiMarkup.Run(text: "Soul Leech", link: "Soul Leech"))
        XCTAssertEqual(runs[2].link, nil)
        XCTAssertTrue(runs[2].text.contains("Casting Time: Instant"))
        XCTAssertFalse(runs.contains { $0.text.contains("<") || $0.text.contains("[[") },
                       "no markup may survive into what is drawn")
    }

    func testAPipelessLinkIsBothTargetAndText() {
        let runs = WikiMarkup.runs("Effect: [[Steal Strength]] (Combat, Casting Time: Instant) at Level 30")
        XCTAssertEqual(runs[1], WikiMarkup.Run(text: "Steal Strength", link: "Steal Strength"))
    }

    func testPlainLinesAreLeftExactlyAsTheyAre() {
        for line in ["MAGIC ITEM LORE ITEM", "Slot: PRIMARY", "WT: 9.5 Size: LARGE", "Class: SHD"] {
            XCTAssertFalse(WikiMarkup.hasMarkup(line))
            XCTAssertEqual(WikiMarkup.runs(line), [WikiMarkup.Run(text: line, link: nil)])
        }
    }

    func testMalformedMarkupNeverLosesTheLine() {
        // An unclosed bracket is prose, not a link, and must still be shown.
        XCTAssertEqual(WikiMarkup.runs("Effect: [[Soul Leech"), [WikiMarkup.Run(text: "Effect: [[Soul Leech", link: nil)])
        XCTAssertEqual(WikiMarkup.runs("[[]]"), [])
        XCTAssertEqual(WikiMarkup.stripTags("<span class='x'>Soul Leech</span>"), "Soul Leech")
        XCTAssertEqual(WikiMarkup.stripTags("plain"), "plain")
    }

    func testTwoLinksOnOneLineBothSurvive() {
        let runs = WikiMarkup.runs("[[A]] and [[B|<i>B</i>]]")
        XCTAssertEqual(runs.compactMap(\.link), ["A", "B"])
        XCTAssertEqual(runs.map(\.text), ["A", " and ", "B"])
    }

    /// Every stats block in the shipped corpus must survive the parser with no markup left in it.
    @MainActor
    func testNoCorpusStatsBlockLeaksMarkup() {
        var seen = 0, linked = 0
        for item in GameData.shared.allItems.prefix(3000) {
            guard let block = item.statsBlock else { continue }
            for line in block.split(separator: "\n") {
                seen += 1
                for run in WikiMarkup.runs(String(line)) {
                    XCTAssertFalse(run.text.contains("[["), "markup left in: \(run.text)")
                    XCTAssertFalse(run.text.contains("</"), "html left in: \(run.text)")
                    if run.link != nil { linked += 1 }
                }
            }
        }
        XCTAssertGreaterThan(seen, 1000, "the corpus should have plenty of stats blocks")
        XCTAssertGreaterThan(linked, 100, "and plenty of effects to follow")
    }
}
