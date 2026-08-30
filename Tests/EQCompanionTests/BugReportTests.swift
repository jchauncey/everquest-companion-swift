import XCTest
import EQCompanionCore
@testable import EQCompanion

/// The bug report's one promise: the file a user hands to a stranger names no character.
final class BugReportTests: XCTestCase {

    func testLogFileNamesLoseTheCharacterAndTheServer() {
        let s = BugReport.redact("attached /Users/x/Logs/eqlog_Zoddrick_oggok.txt", names: [])
        XCTAssertEqual(s, "attached /Users/x/Logs/eqlog_*.txt")
    }

    func testSliceFormLogNamesAreStrippedToo() {
        let s = BugReport.redact("eqlog_Zoddrick_oggok.3.txt", names: [])
        XCTAssertEqual(s, "eqlog_*.3.txt")
    }

    func testCharacterNamesGoWhereverTheyAppear() {
        let s = BugReport.redact("Zoddrick hit a rat", names: ["Zoddrick"])
        XCTAssertEqual(s, "<character> hit a rat")
    }

    func testCharacterNamesAreMatchedCaseInsensitively() {
        XCTAssertEqual(BugReport.redact("zoddrick fell", names: ["Zoddrick"]), "<character> fell")
    }

    func testAWholeWordOnly() {
        // A name that is a substring of another word is not that name.
        XCTAssertEqual(BugReport.redact("Zoddricks", names: ["Zoddrick"]), "Zoddricks")
    }

    /// The one name still readable on a machine where the install could not be resolved and the
    /// app therefore knows no characters: the one the log file is named after.
    func testTheNameIsLearnedFromTheLogFileNameWhenNothingElseKnowsIt() {
        XCTAssertEqual(BugReport.redact("eqlog_Zoddrick_oggok.txt then Zoddrick said hi", names: []),
                       "eqlog_*.txt then <character> said hi")
    }

    func testRedactionIsIdempotent() {
        let once = BugReport.redact("eqlog_Zoddrick_oggok.txt by Zoddrick", names: ["Zoddrick"])
        XCTAssertEqual(BugReport.redact(once, names: ["Zoddrick"]), once)
    }

    /// The engine's `perf.snapshot` carries `mark.log` — an absolute path to the character's log —
    /// which is exactly the arrival the whole-document redaction exists to catch.
    func testTheEnginesOwnPathIsRedactedInTheFinishedFile() {
        let perf = JSONValue.object([
            "status": .string("live"),
            "mark": .object(["log": .string("/Users/x/Logs/eqlog_Zoddrick_oggok.txt")])
        ])
        let doc = BugReport.compose(what: "it stalled", savedAt: Date(timeIntervalSince1970: 0),
                                   version: "1.14.0", startup: nil, os: "macOS 26.5.2", arch: "arm64",
                                   install: nil, characterCount: 1, attached: true, health: nil,
                                   perf: perf, budgets: .null, log: ["Zoddrick attached"])
        let text = BugReport.text(doc, names: ["Zoddrick"])
        XCTAssertFalse(text.contains("Zoddrick"))
        XCTAssertTrue(text.contains("eqlog_*.txt"))
        XCTAssertTrue(text.contains("<character> attached"))
    }

    func testTheDocumentStatesWhatItIsAndWhatWasTyped() throws {
        let doc = BugReport.compose(what: "the meter froze", savedAt: Date(),
                                   version: "1.14.0", startup: nil, os: "macOS 26.5.2", arch: "arm64",
                                   install: nil, characterCount: 0, attached: false, health: nil,
                                   perf: .null, budgets: .null, log: [])
        XCTAssertEqual(doc["report"].string, "eq-companion-bug-report")
        XCTAssertEqual(doc["v"].int, BugReport.formatVersion)
        XCTAssertEqual(doc["what"].string, "the meter froze")
        XCTAssertEqual(doc["app"]["version"].string, "1.14.0")
        XCTAssertEqual(doc["install"]["found"].bool, false)
        XCTAssertTrue(doc["engine"]["health"].isNull)
    }

    func testTheStartupProfileRidesAsPhaseDurations() {
        let p = StartupProfile(startedAt: Date(), version: "1.14.0", marks: [
            StartupMark(phase: "Settings loaded", atMs: 100),
            StartupMark(phase: "Interface drawn", atMs: 900)
        ])
        let doc = BugReport.compose(what: "", savedAt: Date(), version: "1.14.0", startup: p,
                                   os: "macOS", arch: "arm64", install: nil, characterCount: 0,
                                   attached: false, health: nil, perf: .null, budgets: .null, log: [])
        XCTAssertEqual(doc["app"]["startupMs"].int, 900)
        XCTAssertEqual(doc["app"]["startupComplete"].bool, false)
        XCTAssertEqual(doc["app"]["startupPhases"]["Interface drawn"].int, 800)
    }

    func testOnlyTheLastLinesOfTheLogRide() throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bugreport-tail-\(UUID().uuidString).log")
        try (1...500).map { "line \($0)" }.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let tail = BugReport.tail(of: file, lines: 200)
        XCTAssertEqual(tail.count, 200)
        XCTAssertEqual(tail.first, "line 301")
        XCTAssertEqual(tail.last, "line 500")
    }

    func testAMissingLogFallsBackToTheInMemoryNotes() {
        let tail = BugReport.tail(of: URL(fileURLWithPath: "/nope/nothing.log"), lines: 2,
                                  fallback: ["a", "b", "c"])
        XCTAssertEqual(tail, ["b", "c"])
    }

    func testTheSuggestedFileNameIsSortableAndJson() {
        let name = BugReport.suggestedFileName(Date(timeIntervalSince1970: 1_756_500_000))
        XCTAssertTrue(name.hasPrefix("eq-companion-report-"))
        XCTAssertTrue(name.hasSuffix(".json"))
    }
}
