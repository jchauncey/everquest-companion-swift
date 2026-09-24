// A pet's own side of a fight, read back from the log by its name.
import XCTest
import EQCompanionCore
import EQLog
@testable import EQEngine

final class PetLogTests: XCTestCase {
    func testThePetsCastsHitsTakenHealsAndBuffs() throws {
        let clock = Clock(identifier: "America/New_York")!
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("petlog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appendingPathComponent("eqlog_Zoddrick_oggok.txt")
        try """
        [Fri Aug 28 15:07:00 2026] Kaber begins casting Lifedraw.
        [Fri Aug 28 15:07:01 2026] A wan ghoul knight hits Kaber for 42 points of damage.
        [Fri Aug 28 15:07:02 2026] A wan ghoul knight tries to hit Kaber, but misses!
        [Fri Aug 28 15:07:03 2026] Kaber healed itself for 18 (105) hit points by Lifedraw.
        [Fri Aug 28 15:07:04 2026] Kaber begins casting Negation of Life.
        [Fri Aug 28 15:07:05 2026] A zol ghoul knight resisted Kaber's Negation of Life!
        [Fri Aug 28 15:07:06 2026] Kaber begins casting Lifedraw.
        [Fri Aug 28 15:07:07 2026] Draxiz N`Ryt begins casting Celerity.

        """.write(to: log, atomically: true, encoding: .utf8)

        let from = clock.parseEQTimestamp("Fri Aug 28 15:07:00 2026")
        let r = try XCTUnwrap(PetLog.read(log: log, from: from, to: from + 60_000, pet: "kaber", clock: clock, character: "Zoddrick"))
        XCTAssertEqual(r["casts"].array?.map { "\($0["spell"].string ?? "") \($0["casts"].int ?? 0)/\($0["resisted"].int ?? 0)" },
                       ["Lifedraw 2/0", "Negation of Life 1/1"], "another caster's spell is not the pet's")
        XCTAssertEqual(r["taken"].array?.first?["attacker"].string, "A wan ghoul knight")
        XCTAssertEqual(r["taken"].array?.first?["total"].int, 42)
        XCTAssertEqual(r["taken"].array?.first?["misses"].int, 1)
        XCTAssertEqual(r["healed"].array?.first?["healer"].string, "itself")
        XCTAssertEqual(r["healed"].array?.first?["total"].int, 18)
    }
}
