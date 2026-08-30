// The op table, the con card and the budgets — proven three ways.
//
// 1. Ports of `ops.rs`'s own unit tests, over a world whose attaches start nothing: every claim
//    below is about a SHAPE rather than a fold, and a real ingest would make them depend on a file,
//    a thread and a spell DB none of them says anything about.
// 2. Ports of `concard.rs`'s and `budgets.rs`'s unit tests, which are pure functions.
// 3. The engine oracle: every fixture with a recorded `ops.json` is staged as a real install,
//    attached through a `LocalEngine` behind a real `EngineClient`, and every op the Rust engine
//    answered is asked again and deep-compared.
//
// Two fields are excluded from the deep compare and only two: `path`, which names the staging
// directory the recording ran in, and `logPath` on a `logs.list` row, for the same reason. Both are
// compared for SHAPE (`logs.list` by name, server and row count) rather than for bytes, which is
// what the brief's oracle states.
import XCTest
import EQCompanionCore
import EQEngine
import EQFold
import EQKnowledge

final class OpsTests: XCTestCase {
    static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let goldens = repo.appendingPathComponent("Goldens")
    static let fixtures = repo.appendingPathComponent("Resources/fixtures")

    // MARK: - A table with no fold in it

    /// A world whose attaches start nothing, and one connection joined to it.
    func table() -> (World, Session) {
        let world = World(ingest: { _, _, _, _ in })
        return (world, Session(listener: world.join(RecordingSink())))
    }

    /// The path an attach names in these tests. Nothing opens it.
    static let aLog = "C:/nowhere/eqlog_Primitive_freeport.txt"

    func sent(_ outcome: Outcome) -> [JSONValue] {
        switch outcome {
        case .send(let messages): return messages
        case .close(let why): XCTFail("expected messages, got a close: \(why)"); return []
        }
    }

    /// The one message a dispatch produced.
    func one(_ outcome: Outcome) -> JSONValue {
        let messages = sent(outcome)
        XCTAssertEqual(messages.count, 1, "one message")
        return messages.first ?? .null
    }

    func ask(_ world: World, _ session: Session, _ id: Int64, _ op: String,
             _ params: JSONValue = [:]) -> Outcome {
        Ops.dispatch(world, session, id: id, op: op, params: params)
    }

    func testEchoReturnsWhatItWasGiven() {
        let (world, session) = table()
        let reply = one(ask(world, session, 11, "echo", ["text": "a\nb\tc"]))
        XCTAssertEqual(reply["kind"].string, "reply")
        XCTAssertEqual(reply["id"].int64, 11)
        XCTAssertEqual(reply["ok"].bool, true)
        XCTAssertEqual(reply["result"]["text"].string, "a\nb\tc")
    }

    func testHealthReportsTheWorldsGeneration() {
        let (world, session) = table()
        _ = world.attach(Self.aLog)
        let reply = one(ask(world, session, 3, "session.health"))
        XCTAssertEqual(reply["result"]["epoch"].int64, 2)
    }

    func testAttachAnswersWithTheNewGeneration() {
        let (world, session) = table()
        let reply = one(ask(world, session, 4, "session.attach", ["logPath": .string(Self.aLog)]))
        XCTAssertEqual(reply["result"]["accepted"].bool, true)
        XCTAssertEqual(reply["result"]["epoch"].int64, 2)
    }

    func testASubscriptionAcknowledgesThenOpensWithAnEmptyReset() {
        let (world, session) = table()
        let messages = sent(ask(world, session, 7, "view.subscribe", ["source": "loot.ledger"]))
        XCTAssertEqual(messages.count, 2, "an ack then a reset, in that order")
        XCTAssertEqual(messages[0]["kind"].string, "reply")
        XCTAssertEqual(messages[0]["result"]["subscription"].int64, 7)
        XCTAssertEqual(messages[0]["result"]["subscribed"].bool, true)
        XCTAssertEqual(messages[1]["kind"].string, "reset")
        XCTAssertEqual(messages[1]["id"].int64, 7)
        XCTAssertEqual(messages[1]["total"].int64, 0)
        XCTAssertEqual(messages[1]["rows"].array?.count, 0)
    }

    func testUnsubscribingClosesTheStreamOnceAndThenReportsNotFound() {
        let (world, session) = table()
        _ = ask(world, session, 7, "view.subscribe", ["source": "loot.ledger"])
        let first = one(ask(world, session, 8, "view.unsubscribe", ["subscription": 7]))
        XCTAssertEqual(first["result"]["subscription"].int64, 7)
        XCTAssertEqual(first["result"]["subscribed"].bool, false)
        // …and a second one is `notFound`, not a comforting `subscribed: false`.
        let second = one(ask(world, session, 9, "view.unsubscribe", ["subscription": 7]))
        XCTAssertEqual(second["kind"].string, "error")
        XCTAssertEqual(second["error"]["code"].string, "notFound")
        XCTAssertEqual(second["error"]["message"].string,
                       "no subscription 7 is open on this connection")
    }

    func testOneConnectionCannotUnsubscribeAnothersStream() {
        let (world, session) = table()
        let other = Session(listener: world.join(RecordingSink()))
        _ = ask(world, session, 7, "view.subscribe", ["source": "loot.ledger"])
        let refusal = one(ask(world, other, 8, "view.unsubscribe", ["subscription": 7]))
        XCTAssertEqual(refusal["error"]["code"].string, "notFound")
        // …and the stream is still the first connection's to close.
        let mine = one(ask(world, session, 9, "view.unsubscribe", ["subscription": 7]))
        XCTAssertEqual(mine["result"]["subscribed"].bool, false)
    }

    func testASecondHelloEndsTheConversation() {
        let (world, session) = table()
        switch ask(world, session, 1, "hello", ["token": "t", "protocolVersion": 1]) {
        case .close: break
        case .send: XCTFail("a hello ends the conversation")
        }
    }

    func testAnOpThisBuildHasNeverHeardOfIsNamedAndRefused() {
        let (world, session) = table()
        let refusal = one(ask(world, session, 5, "not.an.op"))
        XCTAssertEqual(refusal["kind"].string, "error")
        XCTAssertEqual(refusal["ok"].bool, false)
        XCTAssertEqual(refusal["error"]["code"].string, "unknownOp")
        XCTAssertEqual(refusal["error"]["message"].string, "this engine has no op named \"not.an.op\"")
    }

    /// The op the app's own `Op.sessionMarkAdd` spells, and the reason the golden records an error
    /// for it: the contract's name is `sessionMarks.add`, so `session.mark.add` is an op no engine
    /// has. Pinned rather than fixed here — the Rust answers exactly this.
    func testTheAppsSpellingOfTheMarkOpIsAnOpNoEngineHas() {
        let (world, session) = table()
        let refusal = one(ask(world, session, 79, "session.mark.add", ["at": 1_787_946_132_000]))
        XCTAssertEqual(refusal["error"]["code"].string, "unknownOp")
        XCTAssertEqual(refusal["error"]["message"].string,
                       "this engine has no op named \"session.mark.add\"")
        // …and the contract's own spelling is answered.
        let ack = one(ask(world, session, 80, "sessionMarks.add", ["at": 1_787_946_132_000]))
        XCTAssertEqual(ack["result"]["accepted"].bool, false, "nothing is folding, so nothing splits")
        XCTAssertEqual(ack["result"]["status"].string, "idle")
    }

    func testAKnownOpWithTheWrongParamsIsADifferentRefusal() {
        let (world, session) = table()
        let refusal = one(ask(world, session, 6, "echo", ["text": 12]))
        XCTAssertEqual(refusal["error"]["code"].string, "badParams")
        XCTAssertEqual(refusal["error"]["message"].string,
                       "the params of \"echo\" are not the shape this protocol version states")
    }

    func testAnUnknownMemberIsRefusedRatherThanIgnored() {
        let (world, session) = table()
        let refusal = one(ask(world, session, 6, "echo", ["text": "hi", "extra": true]))
        XCTAssertEqual(refusal["error"]["code"].string, "badParams")
    }

    /// A float where the contract states an integer is a frame the generated types refuse, so this
    /// one does too: a window limit must encode as `50`, never `50.0`.
    func testAFloatWhereAnIntegerIsStatedIsRefused() {
        let (world, session) = table()
        let refusal = one(ask(world, session, 6, "sessionMarks.add", ["at": .double(50.0)]))
        XCTAssertEqual(refusal["error"]["code"].string, "badParams")
    }

    func testAHostileOpNameCannotChooseTheLengthOfTheDiagnostic() {
        let (world, session) = table()
        let refusal = one(ask(world, session, 5, String(repeating: "z", count: 5_000)))
        let message = refusal["error"]["message"].string ?? ""
        XCTAssertTrue(message.contains(String(repeating: "z", count: 64)))
        XCTAssertFalse(message.contains(String(repeating: "z", count: 65)))
    }

    func testAModuleSnapshotWithNoFoldIsUnavailableRatherThanNotFound() {
        let (world, session) = table()
        let refusal = one(ask(world, session, 12, "module.snapshot", ["module": "loot"]))
        XCTAssertEqual(refusal["error"]["code"].string, "unavailable")
        XCTAssertEqual(refusal["error"]["message"].string,
                       "no log is attached, so there is no fold to ask")
    }

    func testAResistLevelsNamingMoreCreaturesThanTheBoundIsRefusedByName() {
        let (world, session) = table()
        let names = (0..<40).map { JSONValue.string("mob \($0)") }
        let refusal = one(ask(world, session, 13, "resist.levels", ["mobs": .array(names)]))
        XCTAssertEqual(refusal["error"]["code"].string, "badParams")
        XCTAssertEqual(refusal["error"]["message"].string,
                       "resist.levels takes between 1 and 32 names; this request named 40")
    }

    func testAResistLevelsNamingNobodyIsRefusedRatherThanAnsweredEmptily() {
        let (world, session) = table()
        let refusal = one(ask(world, session, 14, "resist.levels", ["mobs": .array([])]))
        XCTAssertEqual(refusal["error"]["code"].string, "badParams")
    }

    func testAResistLevelsWithNoFoldIsUnavailable() {
        let (world, session) = table()
        let refusal = one(ask(world, session, 15, "resist.levels", ["mobs": .array(["a rat"])]))
        XCTAssertEqual(refusal["error"]["code"].string, "unavailable")
    }

    func testASpellsSearchWithNothingAttachedIsUnavailable() {
        let (world, session) = table()
        for op in ["spells.search", "resist.spell"] {
            let params: JSONValue = op == "resist.spell" ? ["name": "Tashani"] : [:]
            let refusal = one(ask(world, session, 16, op, params))
            XCTAssertEqual(refusal["error"]["code"].string, "unavailable", op)
            XCTAssertEqual(refusal["error"]["message"].string, ClientSpells.noInstallSentence, op)
        }
    }

    func testALogsListBeforeAnybodyNamedADirectoryIsUnavailable() {
        let (world, session) = table()
        let refusal = one(ask(world, session, 17, "logs.list"))
        XCTAssertEqual(refusal["error"]["code"].string, "unavailable")
        XCTAssertTrue((refusal["error"]["message"].string ?? "").contains("logs.setDir"))
    }

    func testThePushedDirectoryIsAcknowledgedAndThenEnumerated() throws {
        let (world, session) = table()
        let staged = try stage("opslist")
        let ack = one(ask(world, session, 18, "logs.setDir", ["dir": .string(staged.log.deletingLastPathComponent().path)]))
        XCTAssertEqual(ack["result"]["applied"].bool, true)
        XCTAssertNil(ack["result"]["count"].int64, "one directory is not a list")

        let list = one(ask(world, session, 19, "logs.list"))
        XCTAssertEqual(list["result"]["readable"].string, "ok")
        XCTAssertEqual(list["result"]["characters"].array?.count, 1)
        XCTAssertEqual(list["result"]["characters"][0]["name"].string, "Primitive")
        XCTAssertEqual(list["result"]["characters"][0]["server"].string, "freeport")

        // …and a second push replaces the first; a missing folder is an answer, not a refusal.
        _ = ask(world, session, 20, "logs.setDir", ["dir": "/nowhere/at/all"])
        let missing = one(ask(world, session, 21, "logs.list"))
        XCTAssertEqual(missing["result"]["readable"].string, "missing")
        XCTAssertEqual(missing["result"]["characters"].array?.count, 0)
    }

    func testAPerfSnapshotWithNoFoldAnswersRatherThanRefusing() {
        let (world, session) = table()
        let reply = one(ask(world, session, 22, "perf.snapshot"))
        XCTAssertEqual(reply["kind"].string, "reply")
        XCTAssertEqual(reply["result"]["status"].string, "idle")
        XCTAssertEqual(reply["result"]["serve"].array?.count, 0)
    }

    func testTheDefinesAcknowledgeAndOnlyTheListsCarryACount() {
        let (world, session) = table()
        let alerts = one(ask(world, session, 23, "alerts.define",
                             ["defs": .array([.object(["id": "a1"]), .object(["id": "a2"])])]))
        XCTAssertEqual(alerts["result"]["applied"].bool, true)
        XCTAssertEqual(alerts["result"]["count"].int64, 2)

        let respawn = one(ask(world, session, 24, "respawn.define",
                              ["prefs": ["watches": .array([])]]))
        XCTAssertEqual(respawn["result"]["applied"].bool, true)
        XCTAssertNil(respawn["result"]["count"].int64, "one object is not a list")

        let trust = one(ask(world, session, 25, "buffTrust.define",
                            ["trust": ["externals": .array(["Zoddrick"])]]))
        XCTAssertNil(trust["result"]["count"].int64)
    }

    func testEveryOpTheContractNamesIsAnOpThisBuildKnows() {
        let named = ["echo", "session.attach", "session.health", "session.progress",
                     "module.snapshot", "perf.snapshot", "perf.budgets", "perf.timeline",
                     "view.subscribe", "view.unsubscribe", "alerts.define", "buffTrust.define",
                     "respawn.define", "respawn.confirmSighting", "combo.define", "roster.define",
                     "sessionMarks.add", "combat.snapshot", "combat.searchFights",
                     "knowledge.item", "knowledge.mob", "knowledge.spell", "knowledge.search",
                     "knowledge.define", "resist.levels", "resist.spell", "spells.search",
                     "logs.setDir", "logs.list", "hello"]
        for op in named { XCTAssertTrue(Ops.isKnownOp(op), op) }
        XCTAssertFalse(Ops.isKnownOp("session.mark.add"))
        XCTAssertFalse(Ops.isKnownOp(""))
    }

    // MARK: - The con card (concard.rs)

    func testTheCardCarriesTheHeaderTheOverlayDraws() {
        let card = ConCard.card(con("a fire giant warlord"), corpus())
        XCTAssertEqual(card?["id"].string, "a fire giant warlord")
        XCTAssertEqual(card?["name"].string, "a fire giant warlord")
        XCTAssertEqual(card?["level"].int64, 52)
        XCTAssertEqual(card?["zone"].string, "Nagafen's Lair")
        XCTAssertTrue(card?["rare"].isNull ?? false, "absent rather than false")
        XCTAssertEqual(card?["at"].int64, 1_787_181_707_000)
        XCTAssertEqual(card?["kind"].string, "conCard")
    }

    func testTheRareInfixIsPresentOnlyWhenItWasOnTheLine() {
        var ev = con("a lava guardian")
        ev.rare = true
        XCTAssertEqual(ConCard.card(ev, corpus())?["rare"].bool, true)
    }

    func testTheQueueIdentityIsTheMobKeySoAReconRefreshesOneCard() {
        let a = ConCard.card(con("Innoruuk`s Chosen"), corpus())
        let b = ConCard.card(con("innoruuk's chosen (2)"), corpus())
        XCTAssertEqual(a?["id"].string, b?["id"].string)
        XCTAssertEqual(a?["name"].string, "Innoruuk`s Chosen", "the display name is untouched")
    }

    func testALineThatNamesNothingGetsNoCard() {
        XCTAssertNil(ConCard.card(con(""), corpus()))
        XCTAssertNil(ConCard.card(con("   "), corpus()))
    }

    func testAPlayerShapedNameTheCatalogDoesNotKnowGetsNoCard() {
        XCTAssertNil(ConCard.card(con("Lasershark"), corpus()))
        XCTAssertNil(ConCard.card(con("Primitive"), corpus()))
        // The residual, pinned so it is a choice rather than a surprise.
        XCTAssertNil(ConCard.card(con("Blugurg"), corpus()))
    }

    func testAProperNamedNpcTheCatalogKnowsStillGetsACard() {
        for name in ["Innoruuk", "Aaryonar", "Abigail"] {
            XCTAssertEqual(ConCard.card(con(name), corpus())?["name"].string, name, name)
        }
    }

    func testAnArticleNamedCreatureNeedsNoCatalogAtAll() {
        XCTAssertFalse(ConCard.isPlayer("a fire giant warlord", knownMob: { _ in false }))
        XCTAssertFalse(ConCard.isPlayer("A Fire Giant Warlord", knownMob: { _ in false }))
        XCTAssertTrue(ConCard.isPlayer("Lasershark", knownMob: { _ in false }))
        XCTAssertFalse(ConCard.isPlayer("Lasershark", knownMob: { _ in true }))
    }

    func testRefusingAPlayersCardAnnouncesNothingToFetch() {
        let corpus = corpus()
        _ = corpus.takeMisses()
        XCTAssertNil(ConCard.card(con("Lasershark"), corpus))
        XCTAssertTrue(corpus.takeMisses().isEmpty,
                      "a refusal must never send this process off to scrape a person's name")
    }

    func testAHostileNameCannotPushTheCardOffTheScreen() {
        let long = "a " + String(repeating: "giant ", count: 400)
        let name = ConCard.card(con(long), corpus())?["name"].string ?? ""
        XCTAssertEqual(name.unicodeScalars.count, 96)
        XCTAssertEqual(ConCard.cappedName("  a   fire   giant  "), "a fire giant")
    }

    func testTheChipsAreTheFiveEmptyOnesInDisplayOrder() {
        let chips = ConCard.chips()
        XCTAssertEqual(chips.map { $0["axis"].string }, ["magic", "fire", "cold", "poison", "disease"])
        for chip in chips {
            XCTAssertTrue(chip["tag"].isNull)
            XCTAssertTrue(chip["benchmark"].isNull)
            XCTAssertTrue(chip["fit"].isNull)
            XCTAssertEqual(chip["n"].int64, 0)
            XCTAssertEqual(chip["nTotal"].int64, 0)
            XCTAssertEqual(chip["pinned"].bool, false)
            XCTAssertEqual(chip["npcOnly"].bool, false)
            XCTAssertEqual(chip["empirical"]["total"].int64, 0)
            XCTAssertEqual(chip["empirical"]["resisted"].int64, 0)
        }
        XCTAssertEqual(ConCard.card(con("a fire giant warlord"), corpus())?["spellData"].bool, false)
    }

    func con(_ mob: String) -> ConEvent {
        ConEvent(ts: 1_787_181_707_000, mob: mob, level: 52, rare: false, zone: "Nagafen's Lair")
    }

    // MARK: - The budgets (budgets.rs)

    func budget(_ readings: Budgets.Readings, _ id: PerfBudgetId) -> PerfBudget {
        Budgets.budgets(readings).first { $0.id == id }!
    }

    func testAnEngineThatHasMeasuredNothingSaysUnmeasuredRatherThanPassing() {
        let rows = Budgets.budgets(Budgets.Readings())
        XCTAssertEqual(rows.count, 2, "a budget is never omitted")
        for row in rows {
            XCTAssertEqual(row.verdict, .unmeasured)
            XCTAssertNil(row.measured, "absent, never zero")
            XCTAssertFalse(row.limit.isEmpty)
            XCTAssertFalse(row.note.isEmpty)
        }
    }

    func testAFoldAtTheMeasuredRatePassesAndSaysWhatItDid() {
        let row = budget(Budgets.Readings(scanMs: 1_030, scanBytes: 8 * 1024 * 1024), .foldRate)
        XCTAssertEqual(row.verdict, .pass)
        XCTAssertEqual(row.measured, "8.1 MB/s")
        XCTAssertTrue(row.limit.contains("at least"))
        XCTAssertTrue(row.limit.contains("1.0 MB/s"))
    }

    func testADebugBuildRateFailsTheFloor() {
        let row = budget(Budgets.Readings(scanMs: 1_000, scanBytes: 450_000), .foldRate)
        XCTAssertEqual(row.verdict, .fail)
        XCTAssertEqual(row.measured, "450 kB/s")
    }

    func testTheFoldRowStatesTheUnmetGoalRatherThanHidingBehindAPass() {
        let row = budget(Budgets.Readings(scanMs: 1_000, scanBytes: 8_000_000), .foldRate)
        XCTAssertEqual(row.verdict, .pass)
        XCTAssertTrue(row.note.contains("NOT met"))
        XCTAssertTrue(row.note.contains("52.5 s"))
    }

    func testAScanTooFastToTimeIsNotAFoldThatFailed() {
        let row = budget(Budgets.Readings(scanMs: 0, scanBytes: 4_096), .foldRate)
        XCTAssertEqual(row.verdict, .pass)
        XCTAssertEqual(row.measured, "4.1 MB/s")
    }

    func testTheServeRowPassesTheMeasuredBeatAndCarriesItsCaveat() {
        let row = budget(Budgets.Readings(worstServeUs: 56_000), .serveLatency)
        XCTAssertEqual(row.verdict, .pass)
        XCTAssertEqual(row.measured, "56.0 ms")
        XCTAssertTrue(row.limit.contains("2.0 s"))
        XCTAssertTrue(row.note.contains("wedge detector"))
    }

    func testAWedgedServePathFailsTheCeiling() {
        let row = budget(Budgets.Readings(worstServeUs: Budgets.maxServeLatencyUs + 1), .serveLatency)
        XCTAssertEqual(row.verdict, .fail)
        XCTAssertEqual(row.measured, "2.0 s")
    }

    func testAMeasurementExactlyOnTheLimitPassesOnBothBudgets() {
        let readings = Budgets.Readings(scanMs: 1_000,
                                        scanBytes: Budgets.minFoldBytesPerSec,
                                        worstServeUs: Budgets.maxServeLatencyUs)
        for row in Budgets.budgets(readings) { XCTAssertEqual(row.verdict, .pass, "\(row.id)") }
    }

    func testTheRowsArriveInTheOrderThePanelDrawsThem() {
        XCTAssertEqual(Budgets.budgets(Budgets.Readings()).map(\.id), [.foldRate, .serveLatency])
    }

    // MARK: - Staging

    /// A scratch install of this test's own: `<tmp>/<tag>/Logs/eqlog_Primitive_freeport.txt`.
    func stage(_ tag: String, _ fixture: String = "w1-current-session") throws -> (root: URL, log: URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("eqops-\(tag)-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.removeItem(at: root)
        let logs = root.appendingPathComponent("Logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let log = logs.appendingPathComponent("eqlog_Primitive_freeport.txt")
        try FileManager.default.copyItem(at: Self.fixtures.appendingPathComponent("\(fixture).log"), to: log)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, log)
    }

    // MARK: - The engine oracle

    /// Every fixture the Rust engine recorded, replayed through a real fold behind a real client.
    ///
    /// One `LocalEngine` per fixture, attached to an `EngineClient` exactly as the app attaches
    /// one, so the answers travel the whole path the app's do: op table, world, ingest thread,
    /// outbox, main queue.
    @MainActor
    func testEveryRecordedOpIsAnsweredTheSameWay() async throws {
        guard FileManager.default.fileExists(atPath: Self.goldens.path) else { throw XCTSkip("no Goldens/") }
        // The recording ran in America/Los_Angeles, and the ingest builds its parser off the HOST
        // zone: an EQ stamp is a wall-clock reading and the zone is the whole of what turns it into
        // an instant. Every timestamped cell would otherwise be off by this machine's offset from
        // the recorder's — which is exactly what the fold's own oracle pins with `meta.tz`.
        let priorTZ = getenv("TZ").map { String(cString: $0) }
        setenv("TZ", "America/Los_Angeles", 1)
        tzset()
        NSTimeZone.resetSystemTimeZone()
        addTeardownBlock {
            if let priorTZ { setenv("TZ", priorTZ, 1) } else { unsetenv("TZ") }
            tzset()
            NSTimeZone.resetSystemTimeZone()
        }
        XCTAssertEqual(TimeZone.current.identifier, "America/Los_Angeles",
                       "the oracle needs the recorder's zone")

        let names = try FileManager.default.contentsOfDirectory(atPath: Self.goldens.path)
            .filter { !$0.hasPrefix("_") && !$0.hasPrefix(".") }
            .filter { FileManager.default.fileExists(atPath: Self.goldens.appendingPathComponent("\($0)/ops.json").path) }
            .sorted()
        // A subset is honest when the whole set is slow: `EQOPS_FIXTURES` names how many to run and
        // `EQOPS_ONLY` names a substring of the ones to keep.
        let env = ProcessInfo.processInfo.environment
        let only = env["EQOPS_ONLY"].map { $0.split(separator: ",").map(String.init) } ?? []
        let picked = only.isEmpty ? names : names.filter { n in only.contains { n.contains($0) } }
        let cap = env["EQOPS_FIXTURES"].flatMap(Int.init) ?? picked.count
        var tally: [String: (asked: Int, agreed: Int)] = [:]
        var firstDiff: [String: String] = [:]
        func note(_ key: String, _ report: SnapshotDiff.Report, _ fixture: String) {
            var e = tally[key] ?? (0, 0)
            e.asked += 1
            if report.isEqual { e.agreed += 1 } else {
                let line = "\(fixture): \(report.mismatches.first ?? "")"
                firstDiff[key] = (firstDiff[key].map { $0 + "\n    " } ?? "") + line
            }
            tally[key] = e
        }

        for name in picked.prefix(cap) {
            let gold = try JSONValue.parse(try Data(contentsOf: Self.goldens.appendingPathComponent("\(name)/ops.json")))
            let staged = try stage("oracle", name)
            let stateDir = staged.root.appendingPathComponent("state")
            try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)

            let world = World(ingest: starter(foldingSinks()))
            let client = EngineClient()
            let link = LocalEngine.attach(world: world, to: client)
            defer { link.close() }

            // The recording's own order: the directory is named, enumerated, and only then attached.
            _ = try await client.request(Op.logsSetDir, ["dir": .string(staged.log.deletingLastPathComponent().path)])
            let list = try await client.request(Op.logsList)
            note("logs.list", compareLogsList(gold["logs.list"]["result"], list), name)

            _ = try await client.request(Op.sessionAttach,
                                         ["logPath": .string(staged.log.path),
                                          "stateDir": .string(stateDir.path)])
            let live = await waitForLive(client)
            XCTAssertTrue(live, "\(name): the fold never went live")
            // One `combat.snapshot`, for the same reason the recorder's answers carry: a search is
            // READ-ONLY — `fightSummaries` never finalizes a fight, deliberately, so that typing in
            // a search box cannot close one — and it is `snapshot()` that runs the closure sweeps
            // against the wall clock. The recording opened `combat.live` under a fifteen-second
            // subscription loop before it asked anything, so its corpus was always a corpus some
            // reader had already looked at. One call here is that same preamble, stated out loud.
            _ = try await client.request(Op.combatSnapshot, ["opts": [:]])
            note("session.health.status",
                 SnapshotDiff.compare(golden: gold["session.health.status"], ours: .string(live ? "live" : "not live")),
                 name)

            let fightQueries: [JSONValue] = [["query": "ghoul", "limit": 5],
                                             ["query": "  "],
                                             ["query": "fire giant", "limit": 3]]
            for (i, query) in fightQueries.enumerated() {
                let ours = try await client.request(Op.combatSearchFights, query)
                note("combat.searchFights", SnapshotDiff.compare(golden: gold["combat.searchFights"][i]["result"], ours: ours), name)
            }

            for (op, key) in [(Op.knowledgeItem, "knowledge.item"),
                              (Op.knowledgeMob, "knowledge.mob"),
                              (Op.knowledgeSpell, "knowledge.spell")] {
                for (askedName, recorded) in (gold[key].object ?? [:]).sorted(by: { $0.key < $1.key }) {
                    let ours = try await client.request(op, ["name": .string(askedName)])
                    note(key, SnapshotDiff.compare(golden: recorded["result"], ours: ours), name)
                }
            }

            let searches: [JSONValue] = [["query": "mithril", "limit": 5],
                                         ["query": "ghoul", "domain": "mob", "limit": 5],
                                         ["query": "  "],
                                         ["query": "spirit", "domain": "spell", "limit": 3]]
            for (i, query) in searches.enumerated() {
                let ours = try await client.request(Op.knowledgeSearch, query)
                note("knowledge.search", SnapshotDiff.compare(golden: gold["knowledge.search"][i]["result"], ours: ours), name)
            }

            let spellSearches: [JSONValue] = [["text": "haste", "limit": 3],
                                              ["classes": .array(["NEC"]), "sort": "name",
                                               "limit": 5, "offset": 2],
                                              ["category": "Pet", "limit": 2]]
            for (i, query) in spellSearches.enumerated() {
                let ours = try await client.request(Op.spellsSearch, query)
                note("spells.search",
                     SnapshotDiff.compare(golden: without("path", gold["spells.search"][i]["result"]),
                                          ours: without("path", ours)), name)
            }

            for (askedName, recorded) in (gold["resist.spell"].object ?? [:]).sorted(by: { $0.key < $1.key }) {
                let ours = try await client.request(Op.resistSpell, ["name": .string(askedName)])
                note("resist.spell",
                     SnapshotDiff.compare(golden: without("path", recorded["result"]), ours: without("path", ours)), name)
            }

            let budgets = try await client.request(Op.perfBudgets)
            note("perf.budgets.ids",
                 SnapshotDiff.compare(golden: gold["perf.budgets.ids"],
                                      ours: .array((budgets["budgets"].array ?? []).map { $0["id"] })), name)

            note("module.snapshot.unknown",
                 SnapshotDiff.compare(golden: gold["module.snapshot.unknown"]["error"],
                                      ours: await refusal(client, "module.snapshot", ["module": "nope"])), name)
            note("session.mark.add",
                 SnapshotDiff.compare(golden: gold["session.mark.add"]["error"],
                                      ours: await refusal(client, "session.mark.add", ["at": 1_787_946_132_000])), name)

            let alerts = try await client.request(Op.alertsDefine,
                ["defs": .array([["id": "a1", "name": "T", "enabled": true,
                                  "trigger": ["type": "raw", "regex": "x"],
                                  "sound": ["packId": "p", "soundId": "s"]]])])
            note("alerts.define", SnapshotDiff.compare(golden: gold["alerts.define"]["result"], ours: alerts), name)

            let respawn = try await client.request(Op.respawnDefine,
                ["prefs": ["watches": .array([["key": "a froglok guard", "display": "a froglok guard"]])]])
            note("respawn.define", SnapshotDiff.compare(golden: gold["respawn.define"]["result"], ours: respawn), name)

            // Time-DEPENDENT: the recorded rows were cut against the Rust's wall clock, so the
            // oracle here is the row COUNT and the key SET, never the cells.
            if !gold["respawn.watches.after.define"].isNull {
                let reset = await firstReset(client, ViewDescriptor(source: "respawn.watches"))
                let goldenKeys = (gold["respawn.watches.after.define"]["rows"].array ?? []).map { $0["key"].string ?? "" }.sorted()
                note("respawn.watches.after.define",
                     SnapshotDiff.compare(golden: .object(["total": gold["respawn.watches.after.define"]["total"],
                                                           "keys": .array(goldenKeys.map(JSONValue.string))]),
                                          ours: .object(["total": .int(Int64(reset.total)),
                                                         "keys": .array(reset.keys.sorted().map(JSONValue.string))])), name)
            }

            client.detach()
        }

        let table = tally.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value.agreed)/\($0.value.asked)" }.joined(separator: ", ")
        let bad = tally.filter { $0.value.asked != $0.value.agreed }
        XCTAssertTrue(bad.isEmpty,
                      "Per op: \(table)\n"
                      + firstDiff.sorted { $0.key < $1.key }.map { "\($0.key) — \($0.value)" }.joined(separator: "\n"))
        print("engine ops oracle — \(table)")
    }

    // MARK: - Oracle helpers

    /// `logs.list` rows carry the staging directory's path and mtime, so the oracle is the name, the
    /// server, the verdict and the row count — never the paths.
    func compareLogsList(_ golden: JSONValue, _ ours: JSONValue) -> SnapshotDiff.Report {
        func shape(_ v: JSONValue) -> JSONValue {
            .object(["readable": v["readable"],
                     "characters": .array((v["characters"].array ?? []).map {
                         .object(["name": $0["name"], "server": $0["server"]])
                     })])
        }
        return SnapshotDiff.compare(golden: shape(golden), ours: shape(ours))
    }

    /// One object without one member — the two fields that name the recording's own scratch
    /// directory.
    func without(_ key: String, _ v: JSONValue) -> JSONValue {
        guard var o = v.object else { return v }
        o[key] = nil
        return .object(o)
    }

    @MainActor
    func waitForLive(_ client: EngineClient, _ seconds: TimeInterval = 30) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let health = try? await client.request(Op.sessionHealth),
               health["status"].string == "live" { return true }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        return false
    }

    /// The `error` object one refused request produced.
    @MainActor
    func refusal(_ client: EngineClient, _ op: String, _ params: JSONValue) async -> JSONValue {
        do {
            let ok = try await client.request(op, params)
            XCTFail("\(op) was answered rather than refused: \(ok.serializedString().prefix(120))")
            return .null
        } catch EngineError.refused(let e) {
            return .object(["code": .string(e.code), "message": .string(e.message)])
        } catch {
            XCTFail("\(op): \(error)")
            return .null
        }
    }

    /// Subscribe, keep the LAST reset seen inside a short quiet window, then unsubscribe — the
    /// recording's own rule, because the ack's reset is empty by law and the fold's arrives one
    /// tail nap later.
    @MainActor
    func firstReset(_ client: EngineClient, _ descriptor: ViewDescriptor) async -> (total: Int, keys: [String]) {
        var latest: (total: Int, keys: [String]) = (0, [])
        let handle = client.subscribe(descriptor) { state in
            guard let rows = state.rows else { return }
            latest = (state.total, rows.map(\.key))
        }
        // 0.6 s, the recorder's own quiet window: long enough for the tail to serve one boundary.
        try? await Task.sleep(nanoseconds: 900_000_000)
        handle.close()
        return latest
    }
}
