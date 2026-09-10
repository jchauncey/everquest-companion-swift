import XCTest
@testable import EQCompanion

/// The release history and the "have you read this one?" comparison behind the NEW chips.
final class ReleaseNotesTests: XCTestCase {

    func testHistoryIsNewestFirstAndEveryEntryHasWords() {
        // Newest first is a property of the list, not a fixed roster: asserting the exact versions
        // would make every release a test edit, and the thing worth guarding is the ordering the
        // panel and `isNew` both assume.
        let versions = ReleaseNotes.all.map(\.version)
        XCTAssertFalse(versions.isEmpty)
        XCTAssertEqual(Set(versions).count, versions.count, "a version appears twice")
        for (a, b) in zip(versions, versions.dropFirst()) {
            XCTAssertTrue(ReleaseNotes.isNewer(a, than: b), "\(a) does not precede \(b)")
        }
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
    /// Stated over notes of this test's own making, so a real release never rewrites the assertion.
    func testEveryReleaseAfterTheSeenOneIsMarked() {
        let bullet = [ReleaseEntry(.new, "something")]
        let notes = [ReleaseNote(version: "0.2.0", date: "2026-08-29", entries: bullet),
                     ReleaseNote(version: "0.1.0", date: "2026-08-28", entries: bullet)]
        XCTAssertTrue(ReleaseNotes.isNew(notes[0], seen: "0.1.0"))
        XCTAssertFalse(ReleaseNotes.isNew(notes[1], seen: "0.1.0"))
        XCTAssertTrue(ReleaseNotes.isNew(notes[0], seen: "0.0.1"))
        XCTAssertTrue(ReleaseNotes.isNew(notes[1], seen: "0.0.1"))
        XCTAssertFalse(ReleaseNotes.isNew(notes[0], seen: "0.2.0"))
    }

    /// The shipped notes must carry the version the build calls itself, or a release goes out with
    /// nothing under What's new — the same refusal `make tag` makes, stated as a test.
    func testTheVersionFileHasNotes() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let raw = try String(contentsOf: root.appendingPathComponent("VERSION"), encoding: .utf8)
        let version = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(ReleaseNotes.all.contains { $0.version == version },
                      "VERSION says \(version), which has no ReleaseNote")
    }
}
