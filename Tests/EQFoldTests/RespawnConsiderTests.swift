// The Rust unit tests at the bottom of fold/src/modules/{respawn,consider}.rs, ported.
import XCTest
import EQLog
import EQFold
import EQCompanionCore

// MARK: - respawn.rs

/// The zone line the stay begins with. Every timestamp below is derived from this one, so the
/// arithmetic in the assertions reads instead of being a set of magic epochs.
private let tZone: Int64 = 1_787_181_000_000
/// The kill that starts the clock — a minute into the stay.
private let tDeath: Int64 = tZone + 60_000
/// The line that names the mob again, two minutes after it died. It moves no clock on its own.
private let tSeen: Int64 = tDeath + 120_000
/// Ten seconds later — where the ordering clock stands while the assertions read rows.
private let now: Int64 = tSeen + 10_000

/// The user's own number, so the estimate ladder answers `custom` and the countdown is a round
/// minute.
private let customSec: Int64 = 60

final class RespawnModuleTests: XCTestCase {
    private func watchingTheKnight() -> RespawnPrefs {
        RespawnPrefs(watches: [RespawnWatchPref(key: "a vis ghoul knight", display: "a vis ghoul knight", customSec: customSec)])
    }

    private func ev(_ json: String) -> Event {
        guard let e = Event.fromJSON(json) else { fatalError("a JSON object") }
        return e
    }

    private func zone(_ ts: Int64) -> String {
        #"{"kind":"zone","seq":0,"ts":\#(ts),"raw":"z","zone":"The Ruins of Old Guk"}"#
    }

    private func death(_ seq: Int64, _ ts: Int64) -> String {
        #"{"kind":"death","seq":\#(seq),"ts":\#(ts),"raw":"d","name":"a vis ghoul knight","bySelf":true}"#
    }

    /// `<Mob> hits YOU for N points of damage.` — the shape the e2e plays.
    private func hitsYou(_ seq: Int64, _ ts: Int64) -> String {
        #"{"kind":"damage","seq":\#(seq),"ts":\#(ts),"raw":"h","attacker":"a vis ghoul knight","target":"You","amount":106}"#
    }

    /// A module standing in Old Guk, one kill deep, with the mob seen alive since.
    private func seenAfterAKill() -> RespawnModule {
        let m = RespawnModule(constructionNowMs: now, prefs: watchingTheKnight())
        m.onEvent(ev(zone(tZone)), live: false)
        m.onEvent(ev(death(1, tDeath)), live: false)
        m.onEvent(ev(hitsYou(2, tSeen)), live: true)
        return m
    }

    private func onlyRow(_ m: RespawnModule) -> RespawnRow {
        let rows = m.watchRows(now)
        XCTAssertEqual(rows.count, 1, "the watch list has exactly one mob in it")
        return rows[0]
    }

    func testConfirmingASightingReBasesTheClockAndSaysThatIsWhatHappened() {
        // The app never does this by itself: the fixture lit the row with a combat line naming a
        // watched mob and the clock did not move, and this call is the person confirming it.
        let m = seenAfterAKill()

        let before = onlyRow(m)
        XCTAssertEqual(before.basis, "death", "evidence alone touches no clock")
        XCTAssertEqual(before.baseTs, tDeath)
        XCTAssertEqual(before.seenTs, tSeen)
        let revBefore = m.revision()

        XCTAssertTrue(m.confirmSighting(before.id))

        let after = onlyRow(m)
        XCTAssertGreaterThan(m.revision(), revBefore,
                             "a confirmation must advance the module revision too — it advances no log seq")
        XCTAssertEqual(after.baseTs, tSeen, "the clock now counts from the sighting")
        XCTAssertEqual(after.basis, "sighting")
        // The row leaves the seen state, because the evidence is now AT the base rather than after
        // it. Fresh evidence will mark it again, which is correct: it is up.
        XCTAssertNil(after.seenTs)
        XCTAssertNil(after.seenVia)
        // A confirmation is not a death and never a gap sample, so the ladder learned nothing.
        XCTAssertEqual(after.samples, 0)
        XCTAssertEqual(after.kills, 1)
        XCTAssertEqual(after.estimateMs, customSec * 1000)
        XCTAssertEqual(after.source, "custom")
    }

    func testAKillOfTheSeenMobResumesTheNormalDeathDrivenClock() {
        // The later of (death, confirmation) wins by arithmetic, so the next kill takes the base back
        // with no code anywhere that undoes a confirmation.
        let m = seenAfterAKill()
        let id = onlyRow(m).id
        XCTAssertTrue(m.confirmSighting(id))
        XCTAssertEqual(onlyRow(m).basis, "sighting")

        let tSecondDeath = tDeath + 420_000
        m.onEvent(ev(death(3, tSecondDeath)), live: true)

        let row = onlyRow(m)
        XCTAssertEqual(row.basis, "death")
        XCTAssertEqual(row.baseTs, tSecondDeath)
        XCTAssertEqual(row.kills, 2)
        XCTAssertNil(row.seenTs)
        // The gap is measured between the two deaths, never from the confirmation.
        XCTAssertEqual(row.samples, 1)
        XCTAssertEqual(row.observedMs, 420_000)
    }

    func testAConfirmationWithNothingToConfirmIsRefusedRatherThanInvented() {
        // Neither refusal may move a clock, and neither may move the revision — a push carrying no
        // change would make every dedupe downstream a lie.
        let m = RespawnModule(constructionNowMs: now, prefs: watchingTheKnight())
        m.onEvent(ev(zone(tZone)), live: false)
        m.onEvent(ev(death(1, tDeath)), live: false)

        let row = onlyRow(m)
        let rev = m.revision()
        XCTAssertFalse(m.confirmSighting(row.id), "the row is due, but nothing has been seen")
        XCTAssertFalse(m.confirmSighting("no such row"))
        XCTAssertEqual(m.revision(), rev, "a refusal publishes nothing")
        XCTAssertEqual(onlyRow(m).basis, "death")
    }

    /// The watch list arrives over IPC and is normalized here rather than trusted
    /// (`RespawnPrefs::read`).
    func testAPushedWatchListIsNormalizedRatherThanTrusted() {
        let m = RespawnModule(constructionNowMs: now, prefs: RespawnPrefs())
        let rev = m.revision()
        (m as EqModule).asDefines?.define([
            "watches": .array([
                ["key": "  A Vis Ghoul Knight  ", "display": "A Vis Ghoul Knight", "customSec": 60],
                // A duplicate key, an empty key, and an out-of-range number are all dropped.
                ["key": "a vis ghoul knight", "display": "again"],
                ["key": "   "],
                ["key": "a zol ghoul knight", "customSec": 0]
            ])
        ])
        XCTAssertGreaterThan(m.revision(), rev, "a watch edit advances no log seq, so it must move the revision")
        let state = m.snapshot()["state"]
        let watches = state["prefs"]["watches"].array ?? []
        XCTAssertEqual(watches.count, 2)
        XCTAssertEqual(watches[0]["key"].string, "a vis ghoul knight")
        XCTAssertEqual(watches[0]["customSec"].int64, 60)
        XCTAssertEqual(watches[1]["key"].string, "a zol ghoul knight")
        XCTAssertEqual(watches[1]["display"].string, "a zol ghoul knight", "an absent display falls back to the key")
        XCTAssertNil(watches[1]["customSec"].int64, "a zero reads as 'use what you learn', never as zero")
    }
}

// MARK: - consider.rs

/// A lookup that answers everything and remembers who asked. What it answers with does not matter
/// here; whether it was called at all is the claim.
private final class Recorder: Knowledge, @unchecked Sendable {
    private let lock = NSLock()
    private var _asked: [String] = []
    var asked: [String] { lock.lock(); defer { lock.unlock() }; return _asked }

    func item(_ name: String) -> KnowledgeAnswer {
        KnowledgeAnswer(record: ["name": .string(name)], found: true)
    }
    func identityKeys(_ mob: String) -> [String] { [mobKey(mob)] }
    func mob(_ name: String, loot: OwnLoot) -> KnowledgeAnswer {
        lock.lock(); _asked.append(name); lock.unlock()
        let seen = loot.dropsAcross(identityKeys(name))
        return KnowledgeAnswer(record: ["name": .string(name), "dropsSeen": .int(Int64(seen.count))], found: true)
    }
    /// Stands in for a catalog, so it says yes — and the point is that nothing on this module's path
    /// asks.
    func knownMob(_ name: String) -> Bool { true }
    func takeMisses() -> [KnowledgeMiss] { [] }
}

final class ConsiderModuleTests: XCTestCase {
    private func ev(_ json: String) -> Event {
        guard let e = Event.fromJSON(json) else { fatalError("a JSON object") }
        return e
    }

    private func con(_ seq: Int64, _ mob: String) -> String {
        #"{"kind":"consider","mob":"\#(mob)","rare":false,"level":38,"faction":"dubious","difficulty":"Looks kind of dangerous.","seq":\#(seq),"ts":1787181707000,"raw":"x"}"#
    }

    private func rows(_ module: ConsiderModule) -> [JSONValue] {
        module.snapshot()["state"].array ?? []
    }

    func testWithNoLookupInstalledKnowledgeIsAbsentFromEveryRow() {
        // The default construction has no lookup, so `knowledge` is missing from every row — never an
        // empty record meaning "we checked".
        let module = ConsiderModule()
        module.onEvent(ev(con(1, "a sand giant")), live: false)
        module.onEvent(ev(con(2, "a sand giant")), live: true)
        module.onTick(nowMs: 1_787_181_708_000, timerRows: [])
        for row in rows(module) { XCTAssertNil(row.object?["knowledge"], "\(row)") }
    }

    func testALiveConEnrichesInsideTheSameFoldAndAHistoricalOneDoesNot() {
        let recorder = Recorder()
        let module = ConsiderModule()
        module.installKnowledge(recorder)

        module.onEvent(ev(con(1, "a hill giant")), live: false)
        XCTAssertNil(rows(module)[0].object?["knowledge"], "a replay probes nothing")
        XCTAssertTrue(recorder.asked.isEmpty)

        module.onEvent(ev(con(2, "a sand giant")), live: true)
        let r = rows(module)
        XCTAssertEqual(r[1]["knowledge"]["name"].string, "a sand giant")
        XCTAssertEqual(recorder.asked, ["a sand giant"], "asked with the row's DISPLAY name")
    }

    func testAReConKeepsWhatWasLearnedAndAsksNothingTwice() {
        // Enrichment is per-MOB, not per-con: the row carries the previous knowledge forward and
        // `probe` returns early on a row that already has one.
        let recorder = Recorder()
        let module = ConsiderModule()
        module.installKnowledge(recorder)
        module.onEvent(ev(con(1, "a sand giant")), live: true)
        module.onEvent(ev(con(2, "a sand giant")), live: true)
        let r = rows(module)
        XCTAssertEqual(r.count, 1, "one row per mob")
        XCTAssertEqual(r[0]["cons"].int64, 2)
        XCTAssertNotNil(r[0]["knowledge"].object)
        XCTAssertEqual(recorder.asked.count, 1)
    }

    func testTheFirstLiveTickBackfillsTheNewestRowsAndOnlyTheNewest() {
        // The replay is over, so enrich what the user is about to look at. Bounded at
        // considerBackfill, and once — the second tick does nothing.
        let recorder = Recorder()
        let module = ConsiderModule()
        module.installKnowledge(recorder)
        for seq in 0..<Int64(considerBackfill + 5) {
            module.onEvent(ev(con(seq, "mob number \(seq)")), live: false)
        }
        XCTAssertTrue(recorder.asked.isEmpty)

        module.onTick(nowMs: 1_787_181_708_000, timerRows: [])
        XCTAssertEqual(recorder.asked.count, considerBackfill, "the newest handful, not the whole ring")
        let r = rows(module)
        XCTAssertNil(r[0].object?["knowledge"], "the oldest rows resolve on demand")
        XCTAssertNotNil(r[r.count - 1]["knowledge"].object)

        module.onTick(nowMs: 1_787_181_709_000, timerRows: [])
        XCTAssertEqual(recorder.asked.count, considerBackfill, "the edge is an edge")
    }

    func testTheOwnLootIndexReadsBackWhatItFoldedAndRefusesADestroy() {
        let module = ConsiderModule()
        func loot(_ seq: Int64, _ item: String, _ source: String, _ count: Int64, _ ts: Int64) -> String {
            #"{"kind":"loot","item":"\#(item)","source":"\#(source)","count":\#(count),"seq":\#(seq),"ts":\#(ts),"raw":"x"}"#
        }
        module.onEvent(ev(loot(1, "Giant Toe", "a sand giant", 2, 100)), live: false)
        module.onEvent(ev(loot(2, "giant toe", "A Sand Giant", 1, 300)), live: false)
        module.onEvent(ev(loot(3, "Amber", "a sand giant", 1, 200)), live: false)
        // A destroy names no mob and is not a drop.
        module.onEvent(ev(#"{"kind":"loot","item":"Bone Chips","disposition":"destroyed","count":38,"seq":4,"ts":400,"raw":"x"}"#), live: false)

        guard let index = module.asOwnLoot else { return XCTFail("consider owns the index") }
        XCTAssertEqual(index.dropsAcross(["a sand giant"]),
                       [SeenDrop(item: "Giant Toe", count: 3, lastTs: 300),
                        SeenDrop(item: "Amber", count: 1, lastTs: 200)],
                       "case-folded onto one key, counts added, newest ts kept, most-looted first")
        XCTAssertTrue(index.dropsAcross(["nothing at all"]).isEmpty)

        // …and a character rebirth drops the history with the ring: it belonged to a dead same-name
        // character.
        module.onEvent(ev(#"{"kind":"epoch","seq":5,"ts":500,"raw":"x"}"#), live: false)
        XCTAssertTrue(module.asOwnLoot!.dropsAcross(["a sand giant"]).isEmpty)
    }

    func testTheUnionAcrossTwoSpellingsIsOneCreaturesHistory() {
        // The index files a drop under the corpse's LOG name while a boss card asks with the ROSTER
        // name. Counts ADD and `lastTs` takes the later.
        let module = ConsiderModule()
        for (seq, source, ts) in [(Int64(1), "Cazic-Thule", Int64(100)), (Int64(2), "Cazic Thule", Int64(400))] {
            module.onEvent(ev(#"{"kind":"loot","item":"Glowing Black Stone","source":"\#(source)","seq":\#(seq),"ts":\#(ts),"raw":"x"}"#), live: false)
        }
        guard let index = module.asOwnLoot else { return XCTFail("the index") }
        let seen = index.dropsAcross(["cazic thule", "cazic-thule"])
        XCTAssertEqual(seen.count, 1)
        XCTAssertEqual(seen[0].count, 2)
        XCTAssertEqual(seen[0].lastTs, 400)
    }

    /// `mob_key`'s three folds, each of which stops one creature becoming two keys.
    func testTheMobKeyFolds() {
        XCTAssertEqual(mobKey("  A Sand Giant  "), "a sand giant")
        XCTAssertEqual(mobKey("a sand giant (2)"), "a sand giant")
        XCTAssertEqual(mobKey("Innoruuk`s Chosen"), "innoruuk's chosen")
        XCTAssertEqual(mobKey("Innoruuk\u{2019}s Chosen"), "innoruuk's chosen")
        // A parenthesized WORD is part of the name.
        XCTAssertEqual(mobKey("Cazic Thule (Awakened)"), "cazic thule (awakened)")
    }
}
