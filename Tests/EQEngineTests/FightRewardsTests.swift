// A fight's kills, experience, loot and corpse coin, read back from the log.
import XCTest
import EQCompanionCore
import EQLog
@testable import EQEngine

final class FightRewardsTests: XCTestCase {
    func testTheWindowsRewardsAreReadWithTheirStamps() throws {
        let clock = Clock(identifier: "America/New_York")!
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rewards-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appendingPathComponent("eqlog_Zoddrick_oggok.txt")
        try """
        [Mon Aug 03 23:02:30 2026] You slash Lord of Ire for 97 points of damage.
        [Mon Aug 03 23:02:44 2026] You gain experience! (2.080%)
        [Mon Aug 03 23:02:44 2026] You receive 6 platinum, 1 gold, 6 silver and 2 copper from the corpse.
        [Mon Aug 03 23:02:44 2026] You have slain Lord of Ire!
        [Mon Aug 03 23:02:45 2026] You have gained 2 ability point(s)!  You now have 6 ability point(s).
        [Mon Aug 03 23:02:50 2026] You looted a Crystallized Sulfur from Lord of Ire's corpse and sold it for 1 gold, 1 silver and 8 copper.
        [Mon Aug 03 23:02:51 2026] --You have looted a Mote of Potential from Lord of Ire's corpse.--
        [Mon Aug 03 23:09:00 2026] You have slain a rat!

        """.write(to: log, atomically: true, encoding: .utf8)

        let from = clock.parseEQTimestamp("Mon Aug 03 23:02:30 2026")
        let r = try XCTUnwrap(FightRewards.read(log: log, from: from, to: from + 60_000, clock: clock, character: "Zoddrick"))
        XCTAssertEqual(r["deaths"].array?.map { $0["name"].string ?? "" }, ["Lord of Ire"], "the rat is past the window")
        XCTAssertEqual(r["exp"].array?.first?["pct"].double, 2.08)
        XCTAssertEqual(r["aa"].array?.first?["amount"].int, 2)
        XCTAssertEqual(r["coin"].array?.first?["copper"].int, 6162)
        XCTAssertEqual(r["loot"].array?.map { $0["item"].string ?? "" }, ["Crystallized Sulfur", "Mote of Potential"])
        XCTAssertEqual(r["loot"].array?.first?["disposition"].string, "sold")
        XCTAssertEqual(r["loot"].array?.last?["source"].string, "Lord of Ire")
    }
}
