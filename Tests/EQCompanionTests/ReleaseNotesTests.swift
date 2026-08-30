import XCTest
@testable import EQCompanion

/// The release history and the "have you read this one?" comparison behind the NEW chips.
final class ReleaseNotesTests: XCTestCase {

    func testHistoryIsNewestFirstAndEveryEntryHasWords() {
        let versions = ReleaseNotes.all.map(\.version)
        XCTAssertEqual(versions, ["0.2.0", "0.1.0"])
        for note in ReleaseNotes.all {
            XCTAssertFalse(note.entries.isEmpty, "\(note.version) has no bullets")
            XCTAssertNotNil(note.date.range(of: "^\\d{4}-\\d{2}-\\d{2}$", options: .regularExpression),
                            "\(note.version) date is not an ISO calendar date")
            XCTAssertFalse(ReleaseNotes.formatDate(note.date).isEmpty)
            for e in note.entries { XCTAssertFalse(e.text.isEmpty) }
        }
    }

    /// A date the formatter cannot read is shown as it stands, never as an empty line.
    func testAnUnparseableDateIsPassedThrough() {
        XCTAssertEqual(ReleaseNotes.formatDate("soon"), "soon")
    }

    /// Numeric part by part, so a two-digit minor sorts above a one-digit one.
    func testVersionComparisonIsNumericNotLexicographic() {
        XCTAssertTrue(ReleaseNotes.isNewer("0.2.0", than: "0.1.0"))
        XCTAssertTrue(ReleaseNotes.isNewer("0.10.0", than: "0.9.0"))
        XCTAssertFalse(ReleaseNotes.isNewer("0.1.0", than: "0.2.0"))
        XCTAssertFalse(ReleaseNotes.isNewer("0.2.0", than: "0.2.0"))
        XCTAssertTrue(ReleaseNotes.isNewer("1.0", than: "0.9.9"))
    }

    /// A fresh install has no news: nothing is marked, because nobody lived through any of it.
    func testAnEmptySeenVersionMarksNothing() {
        for note in ReleaseNotes.all {
            XCTAssertFalse(ReleaseNotes.isNew(note, seen: ""))
        }
    }

    /// Somebody who was two releases behind gets both marked — "new" is a comparison, not a flag.
    func testEveryReleaseAfterTheSeenOneIsMarked() {
        let notes = ReleaseNotes.all
        XCTAssertTrue(ReleaseNotes.isNew(notes[0], seen: "0.1.0"))
        XCTAssertFalse(ReleaseNotes.isNew(notes[1], seen: "0.1.0"))
        XCTAssertTrue(ReleaseNotes.isNew(notes[0], seen: "0.0.1"))
        XCTAssertTrue(ReleaseNotes.isNew(notes[1], seen: "0.0.1"))
        XCTAssertFalse(ReleaseNotes.isNew(notes[0], seen: "0.2.0"))
    }
}
