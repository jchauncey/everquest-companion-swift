// The sales module on real log lines, through the real parser: the auto-sell's price read off the
// raw line, the merchant sale's coins off the parser's own `coins` object, and the checkpoint.
import XCTest
import EQLog
@testable import EQFold
import EQCompanionCore

final class SalesModuleTests: XCTestCase {
    private let lines = [
        "[Tue Aug 18 12:58:35 2026] You looted a Rusty Short Sword from a putrid skeleton's corpse and sold it for 2 silver and 1 copper.",
        "[Tue Aug 18 12:59:00 2026] You looted a Rusty Short Sword from a putrid skeleton's corpse and sold it for 1 platinum, 2 gold, 3 silver and 4 copper.",
        "[Tue Aug 18 13:00:00 2026] You looted a Bone Chip from a putrid skeleton's corpse and sold it for free.",
        "[Tue Aug 18 13:01:00 2026] You receive 1 gold 6 silver 9 copper from A Shady Swashbuckler for the Cutthroat Insignia Ring(s).",
        "[Tue Aug 18 13:01:30 2026] You looted 3 Undead Froglok Tongue from Reward Chest and sold it for 1 gold, 7 silver and 4 copper.",
        // Not sales: an ordinary loot, and coin off a corpse.
        "[Tue Aug 18 13:02:00 2026] You looted a Cloth Cap from a putrid skeleton's corpse.",
        "[Tue Aug 18 13:03:00 2026] You receive 5 copper from the corpse.",
    ]

    private func folded() -> SalesModule {
        let parser = Parser(clock: Clock(identifier: "America/New_York")!, db: nil, character: "Zoddrick")
        let ev = Ev()
        let m = SalesModule()
        var seq: Int64 = 0
        for l in lines where parser.parseEvent(l, seq: seq, into: ev) {
            m.onEvent(Event.typed(ev.payload), live: false)
            seq += 1
        }
        return m
    }

    func testAutoSellsAndMerchantSalesAreCountedInCopper() {
        let s = folded().snapshot()["state"]
        XCTAssertEqual(s["auto"]["sales"].int64, 4, "the Reward Chest sale too, unclassified by the parser")
        XCTAssertEqual(s["auto"]["items"].int64, 2 + 1 + 3)
        XCTAssertEqual(s["auto"]["copper"].int64, 21 + 1234 + 174)
        XCTAssertEqual(s["auto"]["free"].int64, 1)
        XCTAssertEqual(s["vendor"]["sales"].int64, 1)
        XCTAssertEqual(s["vendor"]["copper"].int64, 169)
        XCTAssertEqual(s["copper"].int64, 21 + 1234 + 174 + 169)
        XCTAssertEqual(s["distinctItems"].int64, 4)
        let items = s["items"].array ?? []
        XCTAssertEqual(items.first?["item"].string, "Rusty Short Sword", "most coin first")
        XCTAssertEqual(items.first?["count"].int64, 2)
        XCTAssertEqual(items.map { $0["item"].string ?? "" },
                       ["Rusty Short Sword", "Undead Froglok Tongue", "Cutthroat Insignia Ring", "Bone Chip"])
    }

    func testThePriceReaderTakesEveryShapeTheLogUses() {
        XCTAssertEqual(SalesModule.autoSellPrice("… and sold it for 7 copper."), 7)
        XCTAssertEqual(SalesModule.autoSellPrice("… and sold it for 3 platinum."), 3000)
        XCTAssertEqual(SalesModule.autoSellPrice("… and sold it for 2 platinum and 5 gold."), 2500)
        XCTAssertEqual(SalesModule.autoSellPrice("… and sold it for 1,204 platinum, 1 silver and 3 copper."), 1_204_013)
        XCTAssertEqual(SalesModule.autoSellPrice("… and sold it for free."), 0)
        XCTAssertNil(SalesModule.autoSellPrice("You looted a Cloth Cap from a corpse."))
        XCTAssertEqual(SalesModule.vendorItem("You receive 2 silver from A Merchant for the Rusty Short Sword +1(s)."),
                       "Rusty Short Sword +1")
    }

    func testTheCheckpointRestoresTheSameSnapshot() {
        let m = folded()
        let r = SalesModule()
        XCTAssertTrue(r.restoreCheckpoint(m.checkpointState()))
        XCTAssertEqual(r.snapshot(), m.snapshot())
        XCTAssertEqual(r.publishedSeq, m.publishedSeq)
        XCTAssertFalse(SalesModule().restoreCheckpoint(["auto": [:]]), "a half state is refused")
    }

    func testAnEpochForgetsTheDeadCharactersSales() {
        let m = folded()
        m.onEvent(Event.fromValue(["kind": "epoch", "seq": 99, "ts": 0, "raw": ""]), live: false)
        XCTAssertEqual(m.snapshot()["state"]["copper"].int64, 0)
        XCTAssertEqual(m.snapshot()["state"]["items"].array?.count, 0)
    }
}
