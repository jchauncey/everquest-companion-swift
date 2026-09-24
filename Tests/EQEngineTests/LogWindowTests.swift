// Reading a fight's own lines back from the log file.
import XCTest
import EQCompanionCore
import EQLog
@testable import EQEngine

final class LogWindowTests: XCTestCase {
    func testTheWindowHoldsOnlyItsOwnFightLines() throws {
        let clock = Clock(identifier: "America/New_York")!
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("logwindow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appendingPathComponent("eqlog_Zoddrick_oggok.txt")
        var text = ""
        // A long lead-in so the bisection has something to cut.
        for i in 0..<5000 {
            text += String(format: "[Wed Sep 23 06:%02d:%02d 2026] Somebody tells General:1, 'filler %d'\n", (i / 60) % 60, i % 60, i)
        }
        text += "[Wed Sep 23 07:04:14 2026] You slash Innoruuk, the Prince of Hate for 97 points of damage.\n"
        text += "[Wed Sep 23 07:04:15 2026] Innoruuk, the Prince of Hate hits YOU for 210 points of damage.\n"
        text += "[Wed Sep 23 07:04:16 2026] Somebody tells General:1, 'not a fight line'\n"
        text += "[Wed Sep 23 07:06:50 2026] You have slain Innoruuk, the Prince of Hate!\n"
        text += "[Wed Sep 23 07:10:00 2026] You slash a rat for 5 points of damage.\n"
        try text.write(to: log, atomically: true, encoding: .utf8)

        let from = clock.parseEQTimestamp("Wed Sep 23 07:04:14 2026")
        let to = clock.parseEQTimestamp("Wed Sep 23 07:06:50 2026")
        let got = try XCTUnwrap(LogWindow.read(log: log, from: from, to: to, limit: 100, clock: clock, character: "Zoddrick"))
        XCTAssertEqual(got.lines.map { $0["text"].string ?? "" }, [
            "You slash Innoruuk, the Prince of Hate for 97 points of damage.",
            "Innoruuk, the Prince of Hate hits YOU for 210 points of damage.",
            "You have slain Innoruuk, the Prince of Hate!",
        ], "chat inside the window is left out; the rat after it is not in it")
        XCTAssertEqual(got.lines.first?["role"].string, "you")
        XCTAssertEqual(got.lines[1]["role"].string, "enemy")
        XCTAssertEqual(got.lines.first?["cat"].string, "damage")
        XCTAssertFalse(got.truncated)

        let capped = try XCTUnwrap(LogWindow.read(log: log, from: from, to: to, limit: 2, clock: clock, character: "Zoddrick"))
        XCTAssertEqual(capped.lines.count, 2)
        XCTAssertTrue(capped.truncated)
    }
}
