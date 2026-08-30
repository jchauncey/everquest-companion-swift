// The view layer's own suite — the Rust `#[cfg(test)]` modules of views/mod.rs, diff.rs, loot.rs,
// combat.rs, buffs.rs, timers.rs, respawn.rs, kills.rs, progression.rs, event_feed.rs and meter.rs,
// ported.
//
// They are the oracle for everything the recorded goldens cannot pin: the three time-dependent
// sources' ordering RULES, every refusal sentence, the diff's applicability property, and the two
// roundings (`toFixed`, `jsRound`) that a k/M-scaled figure is built out of.
import XCTest
import EQLog
import EQFold
import EQCompanionCore
@testable import EQEngine

// MARK: - Shared helpers

/// Not `clock()` — that name is C's, and it is visible here through Foundation.
private func laClock() -> Clock { Clock(identifier: "America/Los_Angeles")! }

/// A fold fed hand-written events. `launchMs` is `Int64.max` so the rebirth boundary never fires
/// and the modules keep what they are given.
private func folded(_ lines: [String], live: Bool = false, prefs: JSONValue? = nil) -> Fold {
    let f = Fold(registry: registered(ClusterDeps()), launchMs: Int64.max)
    if let prefs { _ = f.registry.define(family: "respawn", payload: prefs) }
    for line in lines { f.onPrimary(Event.fromJSON(line)!, live: live) }
    return f
}

private func descriptor(_ source: String, sort: [(String, String)] = [],
                        filter: [(String, JSONValue)] = [],
                        window: (Int64, Int64)? = nil) -> RawDescriptor {
    RawDescriptor(source: source, filter: filter.sorted { $0.0 < $1.0 }, sort: sort,
                  window: window.map { (offset: $0.0, limit: $0.1) })
}

private func keys(_ rows: [Row]) -> [String] { rows.map(\.key) }

private func refusal(_ d: RawDescriptor) -> ViewError? {
    do { _ = try Views.validate(d); return nil } catch let e as ViewError { return e } catch { return nil }
}

// MARK: - mod.rs — the registry, validation and the cut

final class ViewRegistryTests: XCTestCase {
    /// A hand-built ledger row, exactly the shape `loot.ledger` declares.
    private func row(_ key: String, _ at: Int64, _ seq: Int64, _ item: String, _ zone: String?) -> SourceRow {
        SourceRow(key: key, cells: ["item": .string(item)], fields: [
            ("at", .int(at)), ("seq", .int(seq)), ("item", .text(item)),
            ("zone", zone.map { Field.text($0) } ?? .missing)
        ])
    }

    func testAnUnregisteredSourceIsNotFoundAndTheAnswerNamesWhatIsServed() {
        // `combat.encounters` is the stand-in unserved source; when it is served, move this name
        // rather than weaken the assertion.
        let error = refusal(descriptor("combat.encounters"))!
        XCTAssertEqual(error.code, "notFound")
        XCTAssertTrue(error.message.contains("loot.ledger"), error.message)
        XCTAssertTrue(error.message.contains("combat.live"), error.message)
        XCTAssertTrue(error.message.contains("timers.rows"), error.message)
        // A module id is not a source name either.
        XCTAssertEqual(refusal(descriptor("loot"))?.code, "notFound")
    }

    func testADescriptorWithNothingInItTakesTheSourcesOwnOrderAndWindow() throws {
        let view = try Views.validate(descriptor("loot.ledger"))
        let expected = Views.source("loot.ledger")!
        XCTAssertEqual(view.offset, 0)
        XCTAssertEqual(Int64(view.limit), expected.defaultLimit)
        // The default order, and the tiebreak underneath it.
        XCTAssertEqual(view.sort.first?.0, "at")
        XCTAssertEqual(view.sort.first?.1, Order.desc)
        XCTAssertEqual(view.sort.last?.0, expected.tiebreak.0)
        XCTAssertEqual(view.sort.last?.1, expected.tiebreak.1)
    }

    func testAStatedSortKeepsItsOwnTermsAndStillEndsInTheTiebreak() throws {
        let view = try Views.validate(descriptor("loot.ledger", sort: [("item", "asc")]))
        XCTAssertEqual(view.sort[0].0, "item")
        XCTAssertEqual(view.sort[0].1, Order.asc)
        XCTAssertEqual(view.sort.last?.0, "seq")
        XCTAssertEqual(view.sort.last?.1, Order.asc)
    }

    func testATermNamingAFieldTheSourceDoesNotCarryIsRefusedByName() {
        let bySort = refusal(descriptor("loot.ledger", sort: [("dps", "desc")]))!
        XCTAssertEqual(bySort.code, "badParams")
        XCTAssertTrue(bySort.message.contains("dps"), bySort.message)

        XCTAssertNotNil(refusal(descriptor("loot.ledger", sort: [("at", "sideways")])))

        // A filter naming an absent field is refused rather than served unfiltered, which would let
        // the client believe it filtered.
        let byFilter = refusal(descriptor("loot.ledger", filter: [("session", .string("current"))]))!
        XCTAssertEqual(byFilter.code, "badParams")
        XCTAssertTrue(byFilter.message.contains("session"), byFilter.message)
    }

    func testAWindowOutsideTheBudgetIsRefusedRatherThanServedSlowly() {
        for window in [(Int64(-1), Int64(10)), (0, 0), (0, Views.maxLimit + 1)] {
            XCTAssertEqual(refusal(descriptor("loot.ledger", window: window))?.code, "badParams")
        }
    }

    func testTheWindowIsFilteredThenSortedThenSlicedAndTotalIgnoresTheSlice() throws {
        let rows = [
            row("loot:0", 100, 0, "Bone Chips", "Innothule Swamp"),
            row("loot:1", 100, 1, "Cloak of Flames", "Nagafen's Lair"),
            row("loot:2", 200, 2, "Golden Efreeti Boots", "Nagafen's Lair"),
            row("loot:3", 300, 3, "Rusty Dagger", nil)
        ]

        // Newest first, with the tiebreak resolving the two rows that share an instant: the
        // later-folded one wins.
        var cut = Views.cut(try Views.validate(descriptor("loot.ledger")), rows)
        XCTAssertEqual(keys(cut.window), ["loot:3", "loot:2", "loot:1", "loot:0"])
        XCTAssertEqual(cut.total, 4)

        // A filter shrinks the total as well as the window: it is the view's size, not the source's.
        cut = Views.cut(try Views.validate(descriptor("loot.ledger", filter: [("zone", .string("Nagafen's Lair"))])), rows)
        XCTAssertEqual(keys(cut.window), ["loot:2", "loot:1"])
        XCTAssertEqual(cut.total, 2)

        // …and a window slices without changing it.
        cut = Views.cut(try Views.validate(descriptor("loot.ledger", window: (1, 2))), rows)
        XCTAssertEqual(keys(cut.window), ["loot:2", "loot:1"])
        XCTAssertEqual(cut.total, 4, "total ignores the window")
    }

    func testAMissingValueIsAPlaceInTheOrderRatherThanAnAbsence() throws {
        let rows = [row("loot:0", 1, 0, "a", "Oasis"), row("loot:1", 2, 1, "b", nil)]
        var cut = Views.cut(try Views.validate(descriptor("loot.ledger", sort: [("zone", "asc")])), rows)
        XCTAssertEqual(keys(cut.window), ["loot:1", "loot:0"])

        // …and an explicit null filters for the rows that have none.
        cut = Views.cut(try Views.validate(descriptor("loot.ledger", filter: [("zone", .null)])), rows)
        XCTAssertEqual(keys(cut.window), ["loot:1"])
    }

    func testEverySourceDeclaresItsTiebreakAsOneOfItsOwnFields() {
        // The tiebreak is what makes every order total, so a source naming a field it does not
        // carry would refuse its own default sort.
        for source in Views.sources {
            XCTAssertTrue(source.fields.contains(source.tiebreak.0), source.id)
            for (field, _) in source.defaultSort {
                XCTAssertTrue(source.fields.contains(field), "\(source.id) sorts by \(field)")
            }
            XCTAssertTrue(source.defaultLimit > 0 && source.defaultLimit <= Views.maxLimit, source.id)
        }
    }
}

// MARK: - diff.rs

final class ViewDiffTests: XCTestCase {
    private func row(_ key: String, _ cells: [(String, JSONValue)]) -> Row {
        Row(key: key, cells: Dictionary(uniqueKeysWithValues: cells))
    }

    private func plain(_ keys: [String]) -> [Row] { keys.map { row($0, []) } }

    /// The property every case is checked for: the ops turn the held window into the next one, and
    /// the client refuses none of them.
    @discardableResult
    private func roundTrip(_ held: [Row], _ next: [Row]) -> [DiffOp] {
        let ops = ViewDiff.diff(held, next)
        let (got, refused) = ViewDiff.apply(held, ops)
        XCTAssertEqual(refused, 0, "the client would have refused an op")
        XCTAssertEqual(got.map(\.key), next.map(\.key), "the ops did not produce the next window")
        for (a, b) in zip(got, next) { XCTAssertEqual(a.cells, b.cells, "the cells of \(a.key) diverged") }
        return ops
    }

    func testAWindowThatDidNotMoveProducesNoOpsAtAll() {
        let held = plain(["a", "b", "c"])
        XCTAssertTrue(ViewDiff.diff(held, held).isEmpty)
    }

    func testAnInsertAtTheHeadNamesTheRowItGoesBefore() {
        // The loot case: a kill drops a row into a newest-first window.
        let ops = roundTrip(plain(["b", "c"]), plain(["a", "b", "c"]))
        guard ops.count == 1, case .insert(_, let before, let after) = ops[0] else {
            return XCTFail("one insert, got \(ops)")
        }
        XCTAssertEqual(before, "b")
        XCTAssertNil(after, "exactly one anchor")
    }

    func testAnInsertAndTheDropItPushesOutRideTheSameBatch() {
        // A full newest-first window: the new row enters at the head and the oldest falls out.
        let ops = roundTrip(plain(["b", "c", "d"]), plain(["a", "b", "c"]))
        guard ops.count == 2 else { return XCTFail("\(ops)") }
        // The drop goes first, so every anchor is a row still held.
        if case .drop = ops[0] {} else { XCTFail("a drop first, got \(ops)") }
        if case .insert = ops[1] {} else { XCTFail("an insert second, got \(ops)") }
    }

    func testAnAppendNamesTheRowItGoesAfter() {
        let ops = roundTrip(plain(["a"]), plain(["a", "b"]))
        guard ops.count == 1, case .insert(_, let before, let after) = ops[0] else {
            return XCTFail("one insert, got \(ops)")
        }
        XCTAssertEqual(after, "a")
        XCTAssertNil(before)
    }

    func testTheFirstRowOfAnEmptyWindowNamesNoAnchorAtAll() {
        let ops = roundTrip([], plain(["only"]))
        guard ops.count == 1, case .insert(_, let before, let after) = ops[0] else {
            return XCTFail("one insert")
        }
        XCTAssertNil(before)
        XCTAssertNil(after)
    }

    func testSeveralInsertsInOneBatchAnchorOnEachOther() {
        // The second insert's anchor is a row the first one put there, which works only because the
        // anchors are computed against a working copy that advances with the batch.
        roundTrip(plain(["a"]), plain(["a", "b", "c", "d"]))
        roundTrip([], plain(["a", "b", "c"]))
        roundTrip(plain(["c"]), plain(["a", "b", "c"]))
    }

    func testAnUpdateCarriesTheCellsThatMovedAndNoOthers() {
        let held = [row("ally:Primitive", [("name", .string("Primitive")), ("damage", .int(180_000)), ("dps", .double(400.0))])]
        let next = [row("ally:Primitive", [("name", .string("Primitive")), ("damage", .int(184_220)), ("dps", .double(412.6))])]
        let ops = roundTrip(held, next)
        guard ops.count == 1, case .update(_, let cells) = ops[0] else {
            return XCTFail("one update, got \(ops)")
        }
        XCTAssertEqual(cells.count, 2, "`name` did not move and was not sent")
        XCTAssertEqual(cells["damage"], .int(184_220))
        XCTAssertEqual(cells["dps"], .double(412.6))
    }

    func testACellTheRowNoLongerHasIsClearedWithAnExplicitNull() {
        let held = [row("loot:0", [("item", .string("Bone Chips")), ("zone", .string("Oasis"))])]
        let next = [row("loot:0", [("item", .string("Bone Chips"))])]
        let ops = ViewDiff.diff(held, next)
        guard ops.count == 1, case .update(_, let cells) = ops[0] else {
            return XCTFail("one update, got \(ops)")
        }
        XCTAssertEqual(cells["zone"], .null)
        // The client stores the null rather than deleting the key, so the round trip is checked
        // against that rather than against the engine's own next window.
        let (got, refused) = ViewDiff.apply(held, ops)
        XCTAssertEqual(refused, 0)
        XCTAssertEqual(got[0].cells["zone"], .null)
    }

    func testARowThatMovedLeavesAndComesBack() {
        // No move op exists. The drop precedes the insert, so the client is never asked to insert a
        // key it already holds.
        let ops = roundTrip(plain(["a", "b", "c"]), plain(["c", "a", "b"]))
        guard let first = ops.first else { return XCTFail("some ops") }
        if case .drop = first {} else { XCTFail("\(ops)") }
    }

    func testAKeyReusedForDifferentContentsIsAnUpdateRatherThanATear() {
        // The ledger cleared and refilled, so `loot:0` is a different loot under the same key; the
        // honest op is an update of every cell that moved.
        roundTrip([row("loot:0", [("item", .string("Beta Sword"))])],
                  [row("loot:0", [("item", .string("Live Sword"))])])
    }

    func testAWindowThatEmptiedDropsEveryRowItHad() {
        let ops = roundTrip(plain(["a", "b"]), [])
        XCTAssertEqual(ops.count, 2)
        for op in ops { if case .drop = op {} else { XCTFail("\(ops)") } }
    }

    func testAScrambleStillRoundTripsHoweverUnlikelyItIs() {
        // Not a shape any source produces, but the ops must be applicable whatever two windows are
        // handed over.
        let held = plain(["a", "b", "c", "d", "e"])
        for next in [plain(["e", "d", "c", "b", "a"]), plain(["c", "a", "e"]),
                     plain(["f", "a", "g", "c", "h"]), plain(["b", "a"])] {
            roundTrip(held, next)
        }
    }
}

// MARK: - loot.rs

private let A_ZONE = #"{"kind":"zone","seq":0,"ts":1787181707000,"raw":"z","zone":"Nagafen's Lair"}"#
private let A_LOOT = #"{"kind":"loot","seq":1,"ts":1787181707000,"raw":"l","item":"Cloak of Flames","source":"a fire giant warlord"}"#
private let A_STACK = #"{"kind":"loot","seq":2,"ts":1787181767000,"raw":"l","item":"Bone Chips","count":2}"#

final class ViewLootTests: XCTestCase {
    func testARowCarriesWhatTheFlatLedgerDraws() {
        let fold = folded([A_ZONE, A_LOOT])
        let built = Views.Loot.rows(fold.registry.loot()!, laClock())
        XCTAssertEqual(built.count, 1)
        XCTAssertEqual(built[0].key, "loot:0")
        let cells = built[0].cells
        XCTAssertEqual(cells["at"], .string("Aug 19, 04:21 PM"))
        XCTAssertEqual(cells["item"], .string("Cloak of Flames"))
        XCTAssertEqual(cells["from"], .string("a fire giant warlord"))
        XCTAssertEqual(cells["zone"], .string("Nagafen's Lair"))
        // Absence is null, not a dash and not a missing key: the diff protocol needs a cell to be
        // able to become null.
        XCTAssertEqual(cells["count"], .null)
        XCTAssertEqual(cells["disposition"], .null)
        XCTAssertEqual(cells["created"], .null)
    }

    func testTheStackSizeIsANumberBesideTheNameRatherThanInsideIt() {
        let fold = folded([A_ZONE, A_LOOT, A_STACK])
        let built = Views.Loot.rows(fold.registry.loot()!, laClock())
        XCTAssertEqual(built[1].cells["item"], .string("Bone Chips"))
        XCTAssertEqual(built[1].cells["count"], .int(2))
        // The field and the cell of the same name are different values: `at` renders as text and
        // sorts as an instant.
        XCTAssertEqual(built[1].fields.first { $0.0 == "at" }?.1, .int(1_787_181_767_000))
    }

    func testTheDefaultOrderIsTheReverseOfTheLedger() throws {
        let fold = folded([A_ZONE, A_LOOT, A_STACK])
        let built = Views.Loot.rows(fold.registry.loot()!, laClock())
        let (window, total) = Views.cut(try Views.validate(descriptor("loot.ledger")), built)
        XCTAssertEqual(total, 2)
        XCTAssertEqual(keys(window), ["loot:1", "loot:0"])
    }

    func testTheDisplayedTimeIsTheWallClockThePlayersMachineWouldShow() {
        // The corpus's own first line, in the zone the goldens were recorded under.
        XCTAssertEqual(Views.Loot.displayTime(laClock(), 1_787_181_707_000), "Aug 19, 04:21 PM")
        // Midnight and noon are 12, never 00.
        let c = laClock()
        XCTAssertEqual(Views.Loot.displayTime(c, c.parseEQTimestamp("Wed Aug 19 00:05:00 2026")), "Aug 19, 12:05 AM")
        XCTAssertEqual(Views.Loot.displayTime(c, c.parseEQTimestamp("Wed Aug 19 12:05:00 2026")), "Aug 19, 12:05 PM")
        // An unknown instant renders empty, matching the app's falsy-ts rule.
        XCTAssertEqual(Views.Loot.displayTime(c, 0), "")
    }
}

// MARK: - combat.rs

final class ViewCombatTests: XCTestCase {
    /// One segment view, stated with only the fields the row builder reads; the real one carries
    /// twenty more.
    private func selected(_ entities: [JSONValue]) -> JSONValue {
        ["id": "e1", "kind": "fight", "name": "a sand giant", "entities": .array(entities)]
    }

    private func entity(_ id: String, _ name: String, _ kind: String, _ total: Int64,
                        _ dps: Double, _ pct: Double) -> JSONValue {
        ["id": .string(id), "name": .string(name), "kind": .string(kind), "total": .int(total),
         "dps": .double(dps), "pct": .double(pct), "hits": .int(10), "crits": .int(0),
         "critPct": .double(0), "ambiguousHits": .int(0), "ambiguousTotal": .int(0),
         "misses": .int(0), "hitPct": .double(100), "resists": .int(0), "resistPct": .double(0)]
    }

    private func with(_ e: JSONValue, _ patch: [String: JSONValue]) -> JSONValue {
        var o = e.object!
        for (k, v) in patch { o[k] = v }
        return .object(o)
    }

    func testARowCarriesWhatALevelOneBarPrints() {
        let built = Views.Combat.rows(selected([entity("you", "You", "you", 21_712, 723.7, 100)]))
        XCTAssertEqual(built.count, 1)
        XCTAssertEqual(built[0].key, "you", "the key is the source's own id")
        let cells = built[0].cells
        XCTAssertEqual(cells["rank"], .int(1))
        XCTAssertEqual(cells["name"], .string("You"))
        XCTAssertEqual(cells["kind"], .string("you"))
        // `you` gets no word after its name on either surface.
        XCTAssertEqual(cells["tag"], .null)
        XCTAssertEqual(cells["total"], .string("21.7k"))
        // Under a thousand the app's spelling is a rounded integer with no unit scaling.
        XCTAssertEqual(cells["dps"], .string("724 dps"))
        // A badge whose gate is shut is null, not an empty string and not a zero.
        XCTAssertEqual(cells["crit"], .null)
        XCTAssertEqual(cells["hit"], .null)
        XCTAssertEqual(cells["resist"], .null)
        XCTAssertEqual(cells["ambiguous"], .null)
    }

    func testTheOneWordAfterANameIsTheRenderersWordAndNotTheKind() {
        // `member` prints `group`, `allyPet` prints `ally`, and `enemy` prints nothing, like `you`.
        let built = Views.Combat.rows(selected([
            entity("pet:3", "Gybrush", "pet", 900, 30, 40),
            entity("member:rowel", "Rowel", "member", 800, 26.6, 35),
            entity("ally:vex", "Vex's pet", "allyPet", 700, 23.3, 30),
            entity("other:kez", "Kez", "other", 600, 20, 26),
            entity("enemy:giant", "a sand giant", "enemy", 500, 16.6, 22)
        ]))
        XCTAssertEqual(built.map { $0.cells["tag"]! },
                       [.string("pet"), .string("group"), .string("ally"), .string("other"), .null])
    }

    func testABadgeAppearsExactlyWhereItsGateSaysItDoes() {
        let e = with(entity("you", "You", "you", 21_712, 723.7, 100), [
            "critPct": .double(34.4), "misses": .int(7), "hitPct": .double(58.82),
            "resists": .int(2), "resistPct": .double(16.6), "ambiguousHits": .int(3)
        ])
        let cells = Views.Combat.rows(selected([e]))[0].cells
        XCTAssertEqual(cells["crit"], .string("34% crit"))
        XCTAssertEqual(cells["hit"], .string("59% hit"))
        XCTAssertEqual(cells["resist"], .string("17% resist"))
        XCTAssertEqual(cells["ambiguous"], .int(3))

        // …and the crit gate is `>= 1`, not `> 0`, so a rounded `0% crit` cannot appear.
        let shy = Views.Combat.rows(selected([with(e, ["critPct": .double(0.4)])]))
        XCTAssertEqual(shy[0].cells["crit"], .null)
    }

    func testTheRankIsTheFoldsOrderAndAClientSortDoesNotRenumberIt() throws {
        let built = Views.Combat.rows(selected([
            entity("you", "You", "you", 900, 30, 100),
            entity("pet:3", "Gybrush", "pet", 100, 3.3, 11)
        ]))
        // The default order is the meter's: total desc.
        var cut = Views.cut(try Views.validate(descriptor("combat.live")), built)
        XCTAssertEqual(keys(cut.window), ["you", "pet:3"])
        XCTAssertEqual(cut.total, 2)

        // …and asking for it by name reorders the window while every row keeps the rank the meter
        // gave it. A rank that moved with the window would be a second, disagreeing ranking.
        cut = Views.cut(try Views.validate(descriptor("combat.live", sort: [("name", "asc")])), built)
        XCTAssertEqual(keys(cut.window), ["pet:3", "you"])
        XCTAssertEqual(cut.window[0].cells["rank"], .int(2))
    }

    func testASelectionThatResolvedToNothingIsAnEmptyWindowRatherThanACrash() {
        // `selected: null` is what a session with no fights publishes.
        XCTAssertTrue(Views.Combat.rows(.null).isEmpty)
        XCTAssertTrue(Views.Combat.rows(["id": "zone", "kind": "zone"]).isEmpty)
    }

    func testTheTotalIsTheAppsOwnSpellingOfADamageFigure() {
        XCTAssertEqual(Views.Combat.formatNum(0), "0")
        XCTAssertEqual(Views.Combat.formatNum(999), "999")
        XCTAssertEqual(Views.Combat.formatNum(1_000), "1.0k")
        XCTAssertEqual(Views.Combat.formatNum(21_712), "21.7k")
        XCTAssertEqual(Views.Combat.formatNum(2_300_000), "2.30M")
        XCTAssertEqual(Views.Combat.formatRate(723.7), "724 dps")
        XCTAssertEqual(Views.Combat.formatRate(21_712), "21.7k dps")
    }

    func testATieRoundsTheWayJavaScriptRoundsIt() {
        // `1250 / 1000` is exactly 1.25, a true tie: `toFixed(1)` answers "1.3" and `%.1f` answers
        // "1.2".
        XCTAssertEqual(Views.Combat.toFixed(1.25, 1), "1.3")
        XCTAssertEqual(Views.Combat.formatNum(1_250), "1.3k")
        XCTAssertEqual(Views.Combat.toFixed(1.125, 2), "1.13")
        XCTAssertEqual(Views.Combat.toFixed(8.25, 1), "8.3")
        // …and a value that only looks like a tie is not one: the nearest double to 21.65 is
        // 21.64999999999999857…, so both the app and this answer 21.6.
        XCTAssertEqual(Views.Combat.toFixed(21.65, 1), "21.6")
        XCTAssertEqual(Views.Combat.formatNum(21_650), "21.6k")
        XCTAssertEqual(Views.Combat.toFixed(1.45, 1), "1.4", "1.45 is really 1.4499999…")
        XCTAssertEqual(Views.Combat.toFixed(1.35, 1), "1.4", "1.35 is really 1.3500000…88")
        // The carry, all the way out of the number it started in.
        XCTAssertEqual(Views.Combat.toFixed(9.99, 1), "10.0")
        XCTAssertEqual(Views.Combat.formatNum(999_999), "1000.0k")
    }

    func testTheFieldAndTheCellOfOneNameAreDifferentValues() {
        // `total` renders as `21.7k` and sorts as 21,712; sorting the strings would put 9 after 2.
        let built = Views.Combat.rows(selected([entity("you", "You", "you", 21_712, 723.7, 100)]))
        XCTAssertEqual(built[0].cells["total"], .string("21.7k"))
        XCTAssertEqual(built[0].fields.first { $0.0 == "total" }?.1, .int(21_712))
    }
}

// MARK: - buffs.rs

final class ViewBuffsTests: XCTestCase {
    func testTheEnumWordsAreTheModelsOwnSpelling() {
        XCTAssertEqual(BuffClass.debuff.rawValue, "debuff")
        // The two that a hand-written match would most easily get wrong.
        XCTAssertEqual(EstimatorSource.deathBound.rawValue, "deathBound")
        XCTAssertEqual(Disposition.zelf.rawValue, "self")
        XCTAssertEqual(Views.Buffs.yesNo(true), "true")
    }

    func testTheSourceIsRegisteredAndItsTermsResolve() throws {
        let view = try Views.validate(descriptor("buffs.active", sort: [("spell", "asc")]))
        XCTAssertEqual(view.sort.last?.0, Views.Buffs.active.tiebreak.0)
        XCTAssertEqual(view.sort.last?.1, Views.Buffs.active.tiebreak.1)
    }
}

// MARK: - timers.rs

final class ViewTimersTests: XCTestCase {
    private func landing(_ seq: Int64, _ ts: Int64, _ spell: String, _ target: String?) -> String {
        guard let t = target else {
            return #"{"kind":"buffLanded","seq":\#(seq),"ts":\#(ts),"raw":"l","spell":"\#(spell)","self":true}"#
        }
        return #"{"kind":"buffLanded","seq":\#(seq),"ts":\#(ts),"raw":"l","spell":"\#(spell)","target":"\#(t)"}"#
    }

    private func built(_ f: Fold) -> [SourceRow] {
        Views.Timers.rows(f.registry.buffs()!, f.registry.buffTimers()!)
    }

    func testTheSourceServesTheProjectionsOrderAndNamesTheFlatOneBesideIt() throws {
        // Two orders over one row set: what this pins is that the source cuts windows in the order
        // the descriptor names and that both names resolve.
        let source = built(folded([landing(0, 1_000, "Clarity", nil)], live: true))
        let (a, totalA) = Views.cut(try Views.validate(descriptor("timers.rows")), source)
        let (b, totalB) = Views.cut(try Views.validate(descriptor("timers.rows", sort: [("flat", "asc")])), source)
        XCTAssertEqual(totalA, totalB, "the same rows, two orders")
        XCTAssertEqual(a.count, b.count)
        // Both orders are total — every key appears exactly once in each.
        XCTAssertEqual(keys(a).sorted(), keys(b).sorted())
    }

    func testTheSurfaceIsAFieldSoOneWindowAsksForItsOwnRows() throws {
        let source = built(folded([landing(0, 1_000, "Clarity", nil)], live: true))
        for surface in ["buffs", "debuffs"] {
            let view = try Views.validate(descriptor("timers.rows", filter: [("surface", .string(surface))]))
            let (window, total) = Views.cut(view, source)
            XCTAssertEqual(Int64(window.count), total)
            for row in window { XCTAssertEqual(row.cells["surface"], .string(surface)) }
        }
        // …and the two partitions add up to the whole source, which is what makes it one model
        // rather than two.
        let whole = Views.cut(try Views.validate(descriptor("timers.rows")), source).total
        func count(_ s: String) throws -> Int64 {
            Views.cut(try Views.validate(descriptor("timers.rows", filter: [("surface", .string(s))])), source).total
        }
        XCTAssertEqual(try count("buffs") + count("debuffs"), whole)
    }

    func testAFieldTheSourceDoesNotCarryIsRefusedByName() {
        // `candidates` is a real property of a row and deliberately neither a cell nor a field,
        // because a cell is a scalar.
        let error = refusal(descriptor("timers.rows", sort: [("candidates", "asc")]))!
        XCTAssertTrue(error.message.contains("candidates"), error.message)
        XCTAssertTrue(error.message.contains("endsAt"), error.message)
    }
}

// MARK: - respawn.rs

final class ViewRespawnTests: XCTestCase {
    private let ZONE = #"{"kind":"zone","seq":0,"ts":1787181707000,"raw":"z","zone":"Nagafen's Lair"}"#
    private let DEATH = #"{"kind":"death","seq":1,"ts":1787181707000,"raw":"d","name":"King Tranix","bySelf":true}"#

    func testAWatchedMobBecomesARowAndAnUnwatchedOneDoesNot() {
        // Tracking is opt-in per mob, so the define is what puts this mob on a clock.
        let watched = folded([ZONE, DEATH], prefs: ["watches": [["key": "king tranix", "display": "King Tranix", "customSec": 1080]]])
        let built = Views.Respawn.rows(watched.registry.respawn()!)
        XCTAssertEqual(built.count, 1)
        XCTAssertEqual(built[0].cells["display"], .string("King Tranix"))
        XCTAssertEqual(built[0].cells["zone"], .string("Nagafen's Lair"))
        XCTAssertEqual(built[0].cells["customMs"], .int(1_080_000))
        // The user typed the number, so the row says the estimate is theirs as an answer rather than
        // as a comparison the client has to make.
        XCTAssertEqual(built[0].cells["source"], .string("custom"))
        XCTAssertEqual(built[0].cells["overridden"], .bool(true))
        // …and the key is the compound one, because a mob watched in two zones is two clocks.
        XCTAssertTrue(built[0].key.contains("::"), built[0].key)

        let unwatched = folded([ZONE, DEATH], prefs: ["watches": []])
        XCTAssertTrue(Views.Respawn.rows(unwatched.registry.respawn()!).isEmpty)
    }

    func testTheWindowIsCutInTheModulesOwnOrder() throws {
        let f = folded([ZONE, DEATH], prefs: ["watches": [["key": "king tranix", "display": "King Tranix"]]])
        let built = Views.Respawn.rows(f.registry.respawn()!)
        let (window, total) = Views.cut(try Views.validate(descriptor("respawn.watches")), built)
        XCTAssertEqual(total, Int64(built.count))
        // `order` is 0..n in the served order, which is what makes the sort total without a second
        // unique column.
        for (i, row) in window.enumerated() { XCTAssertEqual(row.cells["order"], .int(Int64(i))) }
    }
}

// MARK: - kills.rs

private let K_ZONE = #"{"kind":"zone","seq":0,"ts":1787181707000,"raw":"z","zone":"Nagafen's Lair"}"#
/// An experience line, then the kill it belongs to — the order the game writes them in.
private let K_EXP = #"{"kind":"expGain","seq":1,"ts":1787181707000,"raw":"e","pct":1.5}"#
private let K_KILL = #"{"kind":"death","seq":2,"ts":1787181707000,"raw":"d","name":"a fire giant warlord","bySelf":true}"#
private let K_BARE = #"{"kind":"death","seq":3,"ts":1787181767000,"raw":"d","name":"a lava guardian","bySelf":true}"#

final class ViewKillsTests: XCTestCase {
    private func built(_ f: Fold) -> [SourceRow] { Views.Kills.rows(f.registry.progression()!) }

    func testARowCarriesWhatTheCardDrawsAndTheBitfieldNeverReachesIt() {
        let rows = built(folded([K_ZONE, K_EXP, K_KILL]))
        XCTAssertEqual(rows.count, 1)
        let cells = rows[0].cells
        XCTAssertEqual(cells["name"], .string("a fire giant warlord"))
        XCTAssertEqual(cells["zone"], .string("Nagafen's Lair"))
        XCTAssertEqual(cells["pet"], .bool(false))
        XCTAssertEqual(cells["expLine"], .bool(true))
        XCTAssertEqual(cells["expStated"], .bool(true))
        XCTAssertEqual(cells["expParty"], .bool(false))
        XCTAssertEqual(cells["expPct"], .double(1.5))
        // The bitfield itself is not on the wire; the three flags already say what it says.
        XCTAssertNil(cells["expFlag"])
    }

    func testAKillWithNoExperienceLineSaysSoRatherThanSayingZero() {
        let rows = built(folded([K_ZONE, K_EXP, K_KILL, K_BARE]))
        let bare = rows.first { $0.key == "kill:1" }!
        XCTAssertEqual(bare.cells["expLine"], .bool(false))
        XCTAssertEqual(bare.cells["expPct"], .null)
        // …and `expStated` is false too: nothing stated a percentage because nothing stated anything.
        XCTAssertEqual(bare.cells["expStated"], .bool(false))
    }

    func testTheDefaultWindowIsNewestFirst() throws {
        let rows = built(folded([K_ZONE, K_EXP, K_KILL, K_BARE]))
        let (window, total) = Views.cut(try Views.validate(descriptor("kills.recent")), rows)
        XCTAssertEqual(total, 2)
        XCTAssertEqual(keys(window), ["kill:1", "kill:0"])
    }
}

// MARK: - progression.rs

private let P_DING = #"{"kind":"level","seq":0,"ts":1787181707000,"raw":"d","level":52}"#
private let P_AA = #"{"kind":"aaGain","seq":1,"ts":1787181767000,"raw":"a","amount":2}"#

final class ViewProgressionTests: XCTestCase {
    private func built(_ f: Fold) -> [SourceRow] { Views.Progression.rows(f.registry.progression()!, laClock()) }

    func testBothColumnsReadAsOneNewestFirstList() throws {
        let rows = built(folded([P_DING, P_AA]))
        let (window, total) = Views.cut(try Views.validate(descriptor("progression.recent")), rows)
        XCTAssertEqual(total, 2)
        // The AA gain is a minute later, so it leads.
        XCTAssertEqual(keys(window), ["aa:0", "level:0"])
        XCTAssertEqual(window[0].cells["label"], .string("+2 AA"))
        XCTAssertEqual(window[1].cells["label"], .string("Level 52"))
        // The instant is drawn, and the comparable one is the field underneath it.
        XCTAssertEqual(window[1].cells["at"], .string("Aug 19, 04:21 PM"))
    }

    func testOneKindCanBeAskedForOnItsOwn() throws {
        let rows = built(folded([P_DING, P_AA]))
        let view = try Views.validate(descriptor("progression.recent", filter: [("kind", .string("level"))]))
        let (window, total) = Views.cut(view, rows)
        XCTAssertEqual(total, 1)
        XCTAssertEqual(window[0].cells["value"], .int(52))
    }

    func testTheTwoColumnsAreKeyedSeparatelySoAKeySurvivesAnInterleaving() {
        // A level landing between two AA gains must not renumber them.
        XCTAssertEqual(built(folded([P_AA, P_DING])).map(\.key), ["level:0", "aa:0"])
    }
}

// MARK: - event_feed.rs

final class ViewEventFeedTests: XCTestCase {
    private func aQuest() -> FeedEvent {
        FeedEvent(id: "f1", kind: "quest", ts: 1_787_181_707_000, title: "Coldain Ring 3",
                  detail: "Handed in to Corflunk", page: "Coldain_Ring_War", con: nil)
    }

    private func aCon() -> FeedEvent {
        FeedEvent(id: "f2", kind: "con", ts: 1_787_181_767_000, title: "a fire giant warlord",
                  detail: nil, page: nil,
                  con: FeedConsider(faction: "threateningly", level: 52, rare: true,
                                    difficulty: "looks like quite a gamble"))
    }

    func testTheConBlockIsFlattenedIntoScalars() {
        let built = Views.EventFeed.rowsOf([aQuest(), aCon()])
        XCTAssertEqual(built[0].key, "f1", "the entry's own minted id")
        XCTAssertEqual(built[0].cells["detail"], .string("Handed in to Corflunk"))
        XCTAssertEqual(built[1].cells["conFaction"], .string("threateningly"))
        XCTAssertEqual(built[1].cells["conLevel"], .int(52))
        XCTAssertEqual(built[1].cells["conRare"], .bool(true))
        XCTAssertEqual(built[1].cells["conDifficulty"], .string("looks like quite a gamble"))
        // An entry with no con block says null for each of its cells rather than dropping them: a
        // diff needs a cell to be able to become null.
        XCTAssertEqual(built[0].cells["conFaction"], .null)
        XCTAssertEqual(built[0].cells["conLevel"], .null)
        // …and is not rare rather than unknown, which is this source's one absent-equals-false.
        XCTAssertEqual(built[0].cells["conRare"], .bool(false))
        // A row that carries neither detail nor page says so as null too.
        XCTAssertEqual(built[1].cells["detail"], .null)
        XCTAssertEqual(built[1].cells["page"], .null)
    }

    func testTheDefaultWindowIsNewestFirst() throws {
        let built = Views.EventFeed.rowsOf([aQuest(), aCon()])
        let (window, total) = Views.cut(try Views.validate(descriptor("eventFeed.recent")), built)
        XCTAssertEqual(total, 2)
        XCTAssertEqual(keys(window), ["f2", "f1"])
    }

    func testAHistoricalFoldServesAnEmptyWindowAndThatIsTheHydrationRule() {
        // The feed admits nothing historical, which is what stops a startup replay spamming the
        // overlay with hours-old events.
        let f = folded([
            #"{"kind":"zone","seq":0,"ts":1787181707000,"raw":"z","zone":"Nagafen's Lair"}"#,
            #"{"kind":"loot","seq":1,"ts":1787181707000,"raw":"l","item":"Cloak of Flames","source":"a fire giant warlord"}"#,
            #"{"kind":"consider","seq":2,"ts":1787181717000,"raw":"c","mob":"a fire giant warlord","level":52,"faction":"threateningly","difficulty":"even"}"#
        ])
        XCTAssertTrue(Views.EventFeed.rows(f.registry.eventFeed()!).isEmpty)
    }
}

// MARK: - meter.rs

final class ViewMeterTests: XCTestCase {
    /// Ten seconds — `Views.timelineCadence` in the unit the ring's clock is in.
    private let CADENCE_MS: UInt64 = 10_000

    /// Serve one frame of `bytes`, timed or not. The ring's tests care about counts, not sources.
    private func served(_ meter: Meter, _ bytes: Int, _ timed: Bool) {
        meter.frame("loot.ledger", .diff, 0, 1, bytes, timed ? Instant.now() : nil)
    }

    func testTheFirstTickOpensAWindowRatherThanReportingTheBootAsOne() {
        // A first moment measured from process start would report launch time as a serve window.
        let meter = Meter()
        let ring = Timeline()
        served(meter, 400, true)
        ring.tick(30_000, meter)
        XCTAssertTrue(ring.peek().isEmpty, "the baseline is not a moment")
        ring.tick(30_000 + CADENCE_MS, meter)
        let moments = ring.peek()
        XCTAssertEqual(moments.count, 1)
        XCTAssertEqual(moments[0].atMs, 40_000)
        XCTAssertEqual(moments[0].spanMs, CADENCE_MS)
        XCTAssertEqual(moments[0].frames, 0, "the frame belonged to the baseline")
        XCTAssertNil(moments[0].worstUs, "and so did its timing")
    }

    func testAMomentReportsTheIntervalAndNotARunningTotal() {
        // Two busy windows in a row must read as two equal windows, not as one and then two.
        let meter = Meter()
        let ring = Timeline()
        ring.tick(0, meter)
        served(meter, 100, false)
        served(meter, 100, false)
        ring.tick(CADENCE_MS, meter)
        served(meter, 100, false)
        served(meter, 100, false)
        ring.tick(CADENCE_MS * 2, meter)
        let moments = ring.peek()
        XCTAssertEqual(moments.count, 2)
        XCTAssertEqual(moments[0].frames, 2)
        XCTAssertEqual(moments[0].bytes, 200)
        XCTAssertEqual(moments[1].frames, 2, "the second window is 2 frames, not the cumulative 4")
        XCTAssertEqual(moments[1].bytes, 200)
        // …and the cumulative view is untouched: the ring reads the meter, it does not spend it.
        XCTAssertEqual(meter.peek()[0].frames, 4)
        XCTAssertEqual(meter.peek()[0].bytes, 400)
    }

    func testTheRingDropsTheOldestRatherThanGrowing() {
        let meter = Meter()
        let ring = Timeline()
        for i in 0...(UInt64(Views.timelineCapacity) + 5) { ring.tick(i * CADENCE_MS, meter) }
        XCTAssertEqual(ring.peek().count, Views.timelineCapacity)
        // Oldest first, and the oldest is the one that survived the drops.
        XCTAssertEqual(ring.peek().first!.atMs,
                       (UInt64(Views.timelineCapacity) + 5 - UInt64(Views.timelineCapacity) + 1) * CADENCE_MS)
    }

    func testATickInsideTheCadenceSamplesNothing() {
        let meter = Meter()
        let ring = Timeline()
        ring.tick(0, meter)
        ring.tick(CADENCE_MS - 1, meter)
        XCTAssertTrue(ring.peek().isEmpty)
        ring.tick(CADENCE_MS, meter)
        XCTAssertEqual(ring.peek().count, 1)
    }

    func testAFrameWithNoFoldBehindItIsCountedButNotTimed() {
        let meter = Meter()
        meter.frame("loot.ledger", .reset, 50, 0, 900, nil)
        let row = meter.peek()[0]
        XCTAssertEqual(row.frames, 1)
        XCTAssertEqual(row.resets, 1)
        XCTAssertEqual(row.rows, 50)
        XCTAssertEqual(row.timed, 0)
        // Absent, never zero: a zero would claim the serve path was instantaneous.
        XCTAssertNil(row.latencyMeanUs)
        XCTAssertNil(row.latencyMaxUs)
        XCTAssertEqual(row.widest, 900)
    }

    func testPeekDrainsNothingAndTakeReportDrainsItsCadenceFlag() {
        let meter = Meter()
        meter.frame("loot.ledger", .diff, 0, 3, 120, nil)
        XCTAssertEqual(meter.peek().count, 1)
        XCTAssertEqual(meter.peek().count, 1, "peek is a read")
        XCTAssertFalse(meter.takeReport(true).isEmpty)
        // Nothing has been counted since, so there is nothing owed however hard it is asked.
        XCTAssertTrue(meter.takeReport(true).isEmpty)
    }

    func testASourceThatNeverServedAFrameIsAbsentRatherThanARowOfZeros() {
        XCTAssertTrue(Meter().peek().isEmpty)
    }
}
