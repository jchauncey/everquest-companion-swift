// The Rust `#[cfg(test)]` modules of buffs_shapes.rs, buff_anchors.rs, buff_rounds.rs and
// overlay_file.rs, ported. They pin the pure rules the golden fold exercises only indirectly: the
// cluster overrule, the instance key, the percentile, the cast-anchor window, the round arithmetic,
// and the overlay register's read/write/replace contract.
import XCTest
import EQLog
import EQCompanionCore
@testable import EQFold

final class BuffsShapesTests: XCTestCase {
    /// The cluster rule reads the top three by VALUE and ignores everything shorter, which is what
    /// makes it satisfiable for a spell whose habit is being clicked off.
    func testACorroboratedClusterIsThreeAgreeingMaxima() {
        // Three cycles within a fraction of a percent.
        XCTAssertEqual(BuffsShapes.corroboratedMax([901_000, 900_000, 902_000]), 902_000)
        // One short click-off in the window neither corroborates nor breaks it.
        XCTAssertEqual(BuffsShapes.corroboratedMax([901_000, 12_000, 900_000, 902_000]), 902_000)
        // The top three disagreeing by more than 10% leaves the floor standing.
        XCTAssertNil(BuffsShapes.corroboratedMax([264_000, 101_000, 96_000]))
        // Two cycles are two click-offs of one habit.
        XCTAssertNil(BuffsShapes.corroboratedMax([900_000, 901_000]))
    }

    /// The instance key is a NUL join, and both halves come back out of it.
    func testAnInstanceKeySplitsBackIntoItsTwoHalves() {
        let k = BuffsShapes.instanceKey("mesmerization", "a wan ghoul knight")
        XCTAssertEqual(BuffsShapes.instanceSpellKey(k), "mesmerization")
        XCTAssertEqual(BuffsShapes.instanceEntityKey(k), "a wan ghoul knight")
        // A key with no separator is a spell on YOU.
        XCTAssertEqual(BuffsShapes.instanceEntityKey("clarity"), BuffsShapes.selfKey)
        XCTAssertEqual(BuffsShapes.instanceSpellKey("clarity"), "clarity")
    }

    /// The percentile interpolates, so an even sample count lands between neighbours.
    func testThePercentileInterpolatesBetweenNeighbours() {
        XCTAssertEqual(BuffsShapes.percentile([1000, 2000], 0.5), 1500.0)
        XCTAssertEqual(BuffsShapes.percentile([1000, 2000, 3000], 0.5), 2000.0)
        XCTAssertEqual(BuffsShapes.percentile([], 0.5), 0.0)
        XCTAssertEqual(BuffsShapes.percentile([7], 0.25), 7.0)
    }
}

final class BuffAnchorsTests: XCTestCase {
    /// A fizzle retracts the anchor and leaves the ever-cast knowledge standing — the property the
    /// burst narrowing depends on.
    func testAFizzleRetractsTheAnchorAndNotTheKnowledge() {
        let a = CastAnchors()
        a.noteSelfCast("Clarity II", 1000)
        XCTAssertNotNil(a.namedAnchorFor("Clarity", 2000))
        a.clearCast("Clarity")
        XCTAssertNil(a.namedAnchorFor("Clarity", 2000))
        XCTAssertEqual(a.lastCastTs("Clarity"), 1000)
    }

    /// The window is one-sided: a landing before its cast is not that cast's, and one past the
    /// window is nobody's.
    func testTheOwnCastWindowLooksForwardOnly() {
        let a = CastAnchors()
        a.noteSelfCast("Mesmerization VII", 10_000)
        XCTAssertNil(a.namedAnchorFor("Mesmerization", 9_999))
        XCTAssertNotNil(a.namedAnchorFor("Mesmerization", 20_000))
        XCTAssertNil(a.namedAnchorFor("Mesmerization", 20_001))
    }

    /// Two ranks of one line in the window flag the ambiguity, and the row is still admitted.
    func testTwoRanksInOneWindowAreFlaggedRatherThanGuessed() {
        let a = CastAnchors()
        a.noteSelfCast("Mesmerization III", 1000)
        a.noteSelfCast("Mesmerization VII", 5000)
        let at = a.namedAnchorFor("Mesmerization", 6000)
        XCTAssertEqual(at?.rankChanged, true)
        XCTAssertEqual(at?.display, "Mesmerization VII")
    }

    /// The burst admits a landing as yours and names no spell, which keeps a family a family.
    func testAQuickBuffBurstAdmitsWithoutNaming() {
        let a = CastAnchors()
        a.noteQuickBuff(1000)
        let at = a.attribute("Resist Magic", 3000)
        XCTAssertEqual(at?.unnamed, true)
        XCTAssertEqual(at?.caster, BuffsShapes.selfCaster)
        XCTAssertNil(a.namedAnchorFor("Resist Magic", 3000))
        XCTAssertNil(a.attribute("Resist Magic", 6001))
    }

    /// A stranger's cast anchors nothing under the default (empty) allowlist.
    func testAnUntrustedExternalCastAnchorsNothing() {
        let a = CastAnchors()
        a.noteOtherCast("Dranix", "Clarity", 1000)
        XCTAssertNil(a.attribute("Clarity", 2000))
        XCTAssertNil(a.lastCastTs("Clarity"))
    }
}

final class BuffRoundsTests: XCTestCase {
    /// Five landings in one second on an empty group are five holds, none of them clean.
    func testARoundOfFiveIsFiveHoldsAndNothingMeasurable() {
        var g = HoldGroup(singleton: false)
        for _ in 0..<5 { g.land(1000, false) }
        XCTAssertEqual(g.count, 5)
        XCTAssertEqual(g.oldestTs, 1000)
        // Contaminated by their siblings, so a wear-off mints nothing.
        XCTAssertNil(g.closeOldest(9000)?.sampleMs)
    }

    /// A re-round of the same size refreshes rather than appending: the count is what is held.
    func testASecondRoundRefreshesInsteadOfGrowingTheCount() {
        var g = HoldGroup(singleton: false)
        for _ in 0..<3 { g.land(1000, false) }
        for _ in 0..<3 { g.land(5000, false) }
        XCTAssertEqual(g.count, 3)
        // Newest-first refresh leaves the oldest clock alone until every one is taken.
        XCTAssertEqual(g.oldestTs, 5000)
    }

    /// A lone landing on an empty group is the only shape that mints, and a singleton re-cast stays
    /// measurable because there is nothing to confuse it with.
    func testOnlyALoneLandingMintsAndASingletonRecastStillDoes() {
        var g = HoldGroup(singleton: false)
        g.land(1000, false)
        XCTAssertEqual(g.closeOldest(45_000)?.sampleMs, 44_000)

        var s = HoldGroup(singleton: true)
        s.land(1000, false)
        s.land(20_000, false)
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s.closeOldest(60_000)?.sampleMs, 40_000)
    }

    /// A close with nothing to close contaminates the group.
    func testAWearOffWithNoHoldBehindItPoisonsTheGroup() {
        var g = HoldGroup(singleton: false)
        XCTAssertNil(g.closeOldest(1000))
        g.land(2000, false)
        // The landing itself is clean: the group was empty and the round is its own.
        XCTAssertEqual(g.closeOldest(9000)?.sampleMs, 7000)
    }
}

/// A hand-written fixture in the app's exact shape, baseline bucket included.
private let appFile = """
{"version":2,"updatedAt":"2026-08-19T16:21:54.000Z","sources":[\
{"key":"baseline","messages":[{"text":"You feel different.","role":"landing","spells":[{"spell":"Illusion: Gnome","count":9}]}]},\
{"key":"primitive_freeport","messages":[\
{"text":"You feel much faster.","role":"landing","spells":[{"spell":"Alacrity","count":3},{"spell":"Swift Like the Wind","count":1}]},\
{"text":"Your Alacrity spell has worn off.","role":"wearsOff","spells":[{"spell":"Alacrity","count":2}]}\
]}]}
"""

final class BuffsOverlayFileTests: XCTestCase {
    private func miner() -> MessageOverlayMiner { MessageOverlayMiner(facts: SpellFacts()) }

    func testTheAppsOwnBytesReadAndTheBaselineBucketIsRefused() {
        let sources = OverlayFile.readRegister(appFile)
        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(sources[0].key, "primitive_freeport")
        XCTAssertEqual(sources[0].messages.count, 2)
        XCTAssertEqual(sources[0].messages[0].role, "landing")
        XCTAssertEqual(sources[0].messages[1].role, "wearsOff")
        XCTAssertEqual(sources[0].messages[0].spells[1].spell, "Swift Like the Wind")
    }

    func testAMissingOrCorruptOrStaleOrMisshapenFileReadsAsEmpty() {
        XCTAssertTrue(OverlayFile.readRegister("").isEmpty)
        XCTAssertTrue(OverlayFile.readRegister("{oh no").isEmpty)
        XCTAssertTrue(OverlayFile.readRegister(#"{"version":1,"updatedAt":"x","sources":[{"key":"a","messages":[]}]}"#).isEmpty)
        XCTAssertTrue(OverlayFile.readRegister(#"{"version":2,"updatedAt":"x"}"#).isEmpty)
        XCTAssertTrue(OverlayFile.readRegister(#"{"version":2,"updatedAt":"x","sources":[{"key":"a","messages":{}}]}"#).isEmpty)
    }

    func testASeededRegisterIsWrittenBackByteForByte() {
        let m = miner()
        for (key, counts) in OverlayFile.seeds(OverlayFile.readRegister(appFile)) {
            m.merge(counts, key)
        }
        // The miner has no observations, only merged counts, and a merge carries no instants, so
        // `updatedAt` is the epoch here. The file writer takes whichever stamp the register states.
        var register = m.register()
        register.updatedAt = "2026-08-19T16:21:54.000Z"
        let written = OverlayFile.registerFileOf(register)
        XCTAssertEqual(written.serializedString(), #"{"version":2,"updatedAt":"2026-08-19T16:21:54.000Z","sources":[{"key":"primitive_freeport","messages":[{"text":"You feel much faster.","role":"landing","spells":[{"spell":"Alacrity","count":3},{"spell":"Swift Like the Wind","count":1}]},{"text":"Your Alacrity spell has worn off.","role":"wearsOff","spells":[{"spell":"Alacrity","count":2}]}]}]}"#)
        let file = written.json
        XCTAssertEqual(file["version"].int64, 2)
        XCTAssertEqual(file["updatedAt"].string, "2026-08-19T16:21:54.000Z")
        let sources = file["sources"].array ?? []
        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(sources[0]["key"].string, "primitive_freeport")
        let messages = sources[0]["messages"].array ?? []
        XCTAssertEqual(messages.map { $0["text"].string },
                       ["You feel much faster.", "Your Alacrity spell has worn off."])
        XCTAssertEqual(messages[0]["spells"].array?.map { $0["spell"].string },
                       ["Alacrity", "Swift Like the Wind"])
        XCTAssertEqual(messages[0]["spells"][0]["count"].int64, 3)
        XCTAssertEqual(messages[1]["role"].string, "wearsOff")
    }

    func testMessagesAndSpellsAreSortedByCodepointAndSourcesAreNot() {
        let m = miner()
        // Two buckets, merged in an order that is not alphabetical, each holding messages and spells
        // that are not in codepoint order.
        m.merge([OverlaySeedMessage(text: "zeta", role: "landing", spells: [("Zephyr", 1), ("Alacrity", 2)])],
                "zzz_source")
        m.merge([OverlaySeedMessage(text: "beta", role: "landing", spells: [("B", 1)]),
                 OverlaySeedMessage(text: "alpha", role: "landing", spells: [("A", 1)])],
                "aaa_source")
        let register = m.register()
        // Sources in insertion order, which is the opposite of what a sort would give.
        XCTAssertEqual(register.sources.map(\.key), ["zzz_source", "aaa_source"])
        // …and messages sorted, the opposite of the order they were merged in.
        XCTAssertEqual(register.sources[1].messages.map(\.text), ["alpha", "beta"])
        // …and spells sorted within a message, likewise reversed from the merge order.
        XCTAssertEqual(register.sources[0].messages[0].spells.map(\.spell), ["Alacrity", "Zephyr"])
    }

    func testBeginSourceMakesARefoldReplaceASeededBucketRatherThanDoubleIt() {
        let fresh = miner()
        for (key, counts) in OverlayFile.seeds(OverlayFile.readRegister(appFile)) {
            fresh.merge(counts, key)
        }
        XCTAssertEqual(fresh.register().sources[0].messages[0].spells[0].count, 3)

        // The cold-launch shape: seed from the file the last run wrote, then fold the same log
        // again. Without `beginSource` the counts double; with it, the bucket is re-stated.
        let again = miner()
        for (key, counts) in OverlayFile.seeds(OverlayFile.readRegister(appFile)) {
            again.merge(counts, key)
        }
        again.beginSource("primitive_freeport")
        for ts in [Int64(1), 2, 3] {
            again.observeCast("Alacrity", ts * 10_000)
            again.observeMessage("You feel much faster.", ts * 10_000 + 1, "landing")
        }
        let bucket = again.register().sources.first { $0.key == "primitive_freeport" }
        XCTAssertEqual(bucket?.messages.count, 1,
                       "the wears-off count was discarded with the bucket, and the log re-states it")
        XCTAssertEqual(bucket?.messages[0].spells.count, 1)
        XCTAssertEqual(bucket?.messages[0].spells[0].count, 3, "replaced, not 3 + 3")
    }

    func testTheWriteDropsTheBaselineBucket() {
        let m = miner()
        m.merge([OverlaySeedMessage(text: "x", role: "landing", spells: [("Y", 1)])], overlayBaselineSource)
        m.merge([OverlaySeedMessage(text: "x", role: "landing", spells: [("Y", 1)])], "mine_freeport")
        let file = OverlayFile.registerFileOf(m.register()).json
        XCTAssertEqual((file["sources"].array ?? []).map { $0["key"].string }, ["mine_freeport"])
    }

    /// `new Date(ms).toISOString()` — the register's own stamp, and a pre-epoch instant floors.
    func testTheIsoStampIsUtcWithThreeFractionalDigits() {
        XCTAssertEqual(isoUTC(0), "1970-01-01T00:00:00.000Z")
        XCTAssertEqual(isoUTC(1_785_641_386_000), "2026-08-02T03:29:46.000Z")
        XCTAssertEqual(isoUTC(-1), "1969-12-31T23:59:59.999Z")
    }
}
