// Your pet inferred from your heals when the game never names it.
import XCTest
import EQLog
import EQCompanionCore
@testable import EQFold

final class PetInferenceTests: XCTestCase {
    private func heal(_ target: String, at ts: Int64, by healer: String = "You") -> Event {
        Event.fromValue(["kind": "heal", "healer": .string(healer), "target": .string(target), "amount": 255,
                         "seq": .int(ts), "ts": .int(ts), "raw": "heal"])
    }
    private func hit(_ attacker: String, _ target: String, at ts: Int64) -> Event {
        Event.fromValue(["kind": "damage", "attacker": .string(attacker), "target": .string(target), "amount": 36,
                         "seq": .int(ts), "ts": .int(ts), "raw": "hit"])
    }

    func testAPetYouHealThatFightsIsClaimed() {
        let p = PetInference()
        XCTAssertNil(p.observe(heal("Liber", at: 1_000), roster: nil), "a heal alone is not enough")
        let claim = p.observe(hit("Liber", "a fire giant warrior", at: 400_000), roster: nil)
        XCTAssertEqual(claim?.kind, "petClaim")
        XCTAssertEqual(claim?.str(.name), "Liber")
        XCTAssertEqual(claim?.str(.via), "inferred")
        XCTAssertNil(p.observe(hit("Liber", "a fire giant warrior", at: 401_000), roster: nil), "once")
    }

    func testTheOrderDoesNotMatter() {
        let p = PetInference()
        XCTAssertNil(p.observe(hit("Garn", "a rat", at: 1_000), roster: nil))
        XCTAssertEqual(p.observe(heal("Garn", at: 2_000), roster: nil)?.str(.name), "Garn")
    }

    func testTooFarApartIsNotEvidence() {
        let p = PetInference()
        _ = p.observe(heal("Liber", at: 0), roster: nil)
        XCTAssertNil(p.observe(hit("Liber", "a rat", at: PetInference.windowMs + 1), roster: nil))
    }

    func testRefusals() {
        let p = PetInference()
        // Something that hits you is not your pet.
        _ = p.observe(hit("Vox", "YOU", at: 0), roster: nil)
        _ = p.observe(heal("Vox", at: 1), roster: nil)
        XCTAssertNil(p.observe(hit("Vox", "a rat", at: 2), roster: nil))
        // A mob's name carries an article.
        _ = p.observe(heal("a fire giant warrior", at: 3), roster: nil)
        XCTAssertNil(p.observe(hit("a fire giant warrior", "a rat", at: 4), roster: nil))
        // Someone else's heal is not yours.
        _ = p.observe(heal("Karn", at: 5, by: "Dostya"), roster: nil)
        XCTAssertNil(p.observe(hit("Karn", "a rat", at: 6), roster: nil))
        // Another player's pet.
        _ = p.observe(Event.fromValue(["kind": "allyPetLeader", "pet": "Zober", "owner": "Dostya",
                                       "seq": 7, "ts": 7, "raw": "leader"]), roster: nil)
        _ = p.observe(heal("Zober", at: 8), roster: nil)
        XCTAssertNil(p.observe(hit("Zober", "a rat", at: 9), roster: nil))
    }

    func testAGameClaimedPetIsLeftAloneAndADeathReleasesTheName() {
        let p = PetInference()
        _ = p.observe(Event.fromValue(["kind": "petClaim", "name": "Kaber", "via": "tell", "seq": 1, "ts": 1, "raw": "tell"]), roster: nil)
        _ = p.observe(heal("Kaber", at: 2), roster: nil)
        XCTAssertNil(p.observe(hit("Kaber", "a rat", at: 3), roster: nil), "already bound by the game")
        _ = p.observe(Event.fromValue(["kind": "death", "name": "Kaber", "seq": 4, "ts": 4, "raw": "died"]), roster: nil)
        _ = p.observe(heal("Kaber", at: 5), roster: nil)
        XCTAssertEqual(p.observe(hit("Kaber", "a rat", at: 6), roster: nil)?.str(.name), "Kaber", "a new summon of the name")
    }

    func testCheckpointRoundTrip() {
        let p = PetInference()
        _ = p.observe(heal("Liber", at: 1_000), roster: nil)
        let q = PetInference()
        XCTAssertTrue(q.restoreCheckpoint(p.checkpointState()))
        XCTAssertEqual(q.observe(hit("Liber", "a rat", at: 2_000), roster: nil)?.str(.name), "Liber")
    }
}
