import XCTest
@testable import EQCompanionCore

final class JSONValueTests: XCTestCase {
    func testIntsStayInts() throws {
        let v = try JSONValue.parse(#"{"limit": 50, "pct": 12.5, "big": 1787944044000, "b": true, "n": null}"#)
        XCTAssertEqual(v["limit"], .int(50))
        XCTAssertEqual(v["pct"], .double(12.5))
        XCTAssertEqual(v["big"].int64, 1_787_944_044_000)
        XCTAssertEqual(v["b"], .bool(true))
        XCTAssertTrue(v["n"].isNull)
        // A window limit must serialize as an integer or the engine's i64 refuses it.
        let d = ViewDescriptor(source: "loot.ledger", sort: [("at", .desc)], window: (0, 50)).toJSON().serializedString()
        XCTAssertTrue(d.contains(#""limit":50"#), d)
        XCTAssertTrue(d.contains(#"["at","desc"]"#), d)
        XCTAssertFalse(d.contains("filter"), "an empty filter is omitted")
    }

    func testBoolIsNotANumber() throws {
        let v = try JSONValue.parse(#"{"t": true, "one": 1}"#)
        XCTAssertNil(v["t"].int)
        XCTAssertEqual(v["one"].int, 1)
        XCTAssertNil(v["one"].bool)
    }
}

final class LineFramerTests: XCTestCase {
    func testSplitsAcrossChunksAndStripsCR() {
        var f = LineFramer()
        XCTAssertEqual(f.append(Data("{\"a\":1}\n{\"b\":".utf8)).map { String(decoding: $0, as: UTF8.self) }, ["{\"a\":1}"])
        XCTAssertEqual(f.pendingBytes, 5)
        XCTAssertEqual(f.append(Data("2}\r\n\n".utf8)).map { String(decoding: $0, as: UTF8.self) }, ["{\"b\":2}"])
        XCTAssertEqual(f.pendingBytes, 0)
    }

    func testMultiByteBoundary() {
        var f = LineFramer()
        let text = "{\"s\":\"Innoruuk`s Chosen — é\"}\n"
        let bytes = Array(text.utf8)
        let cut = bytes.count - 4 // inside the multi-byte sequence
        XCTAssertTrue(f.append(Data(bytes[..<cut])).isEmpty)
        let lines = f.append(Data(bytes[cut...]))
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(String(decoding: lines[0], as: UTF8.self), String(text.dropLast()))
    }
}

final class AnnounceTests: XCTestCase {
    func testParsesTheOneLine() {
        XCTAssertEqual(Announce.parse("EQC-ENGINE PORT=51731 PROTOCOL=1"), Announce(port: 51731, protocolVersion: 1))
        XCTAssertEqual(Announce.parse("EQC-ENGINE PORT=51731 PROTOCOL=1\r"), Announce(port: 51731, protocolVersion: 1))
    }

    func testRefusesAnythingElse() {
        XCTAssertNil(Announce.parse("EQC-ENGINE PORT=0 PROTOCOL=1"))
        XCTAssertNil(Announce.parse("hello"))
        XCTAssertNil(Announce.parse("EQC-ENGINE PORT=51731 PROTOCOL=1 extra"))
        XCTAssertNil(Announce.parse(" EQC-ENGINE PORT=51731 PROTOCOL=1"))
        XCTAssertNil(Announce.parse("EQC-ENGINE PORT=99999 PROTOCOL=1"))
    }
}

final class ViewWindowTests: XCTestCase {
    private func row(_ k: String, _ v: Int) -> Row { Row(key: k, cells: ["n": .int(Int64(v))]) }

    func testResetThenDiffsApplyPositionally() {
        var s = ViewWindow.applyReset(epoch: 1, total: 3, rows: [row("a", 1), row("b", 2), row("c", 3)])
        var notes: [String]
        (s, notes) = ViewWindow.applyDiff(s, epoch: 1, total: 4, ops: [
            .insert(row: row("z", 0), before: "a", after: nil),
            .insert(row: row("y", 9), before: nil, after: "c"),
            .update(key: "b", cells: ["n": .int(20), "extra": .null]),
            .drop(key: "a")
        ])
        XCTAssertTrue(notes.isEmpty, "\(notes)")
        XCTAssertEqual(s.rows?.map(\.key), ["z", "b", "c", "y"])
        XCTAssertEqual(s.rows?[1].cells["n"], .int(20))
        XCTAssertEqual(s.rows?[1].cells["extra"], .null, "an explicit null is stored, not deleted")
        XCTAssertEqual(s.total, 4)
    }

    func testUnappliableOpsAreDroppedWithNotes() {
        let s = ViewWindow.applyReset(epoch: 1, total: 1, rows: [row("a", 1)])
        let (next, notes) = ViewWindow.applyDiff(s, epoch: 1, total: nil, ops: [
            .insert(row: row("q", 1), before: "nope", after: nil),
            .update(key: "nope", cells: [:]),
            .drop(key: "nope"),
            .insert(row: row("r", 1), before: nil, after: nil)
        ])
        XCTAssertEqual(notes.count, 4)
        XCTAssertEqual(next.rows?.map(\.key), ["a"])
        XCTAssertEqual(next.total, 1, "an absent total is unchanged")
    }

    func testDiffBeforeResetIsDropped() {
        let (s, notes) = ViewWindow.applyDiff(.loading, epoch: 1, total: 1, ops: [.drop(key: "a")])
        XCTAssertNil(s.rows)
        XCTAssertEqual(notes.count, 1)
    }

    func testAnchorlessInsertFillsAnEmptyWindow() {
        let s = ViewWindow.applyReset(epoch: 1, total: 0, rows: [])
        let (next, notes) = ViewWindow.applyDiff(s, epoch: 1, total: 1, ops: [.insert(row: row("a", 1), before: nil, after: nil)])
        XCTAssertTrue(notes.isEmpty)
        XCTAssertEqual(next.rows?.map(\.key), ["a"])
    }
}

final class EngineMessageTests: XCTestCase {
    func testParsesStreamFrames() throws {
        let reset = try JSONValue.parse(#"{"id":7,"kind":"reset","epoch":3,"total":1834,"rows":[{"key":"loot:9412","cells":{"at":"21:14","qty":1,"mine":true}}]}"#)
        guard case .reset(let id, let epoch, let total, let rows) = EngineMessage.parse(reset) else { return XCTFail() }
        XCTAssertEqual([id, epoch, total], [7, 3, 1834])
        XCTAssertEqual(rows.first?["qty"], .int(1))
        let diff = try JSONValue.parse(#"{"id":7,"kind":"diff","epoch":3,"ops":[{"op":"insert","before":"loot:9412","row":{"key":"loot:9413","cells":{}}},{"op":"update","key":"loot:9412","cells":{"qty":2}},{"op":"drop","key":"loot:1"}]}"#)
        guard case .diff(_, _, let t, let ops) = EngineMessage.parse(diff) else { return XCTFail() }
        XCTAssertNil(t)
        XCTAssertEqual(ops.count, 3)
        let epochMsg = try JSONValue.parse(#"{"kind":"epoch","epoch":2,"reason":"progress","progress":{"pct":42.5,"events":10,"offset":100,"logSize":200}}"#)
        guard case .epoch(let e, let reason, let p) = EngineMessage.parse(epochMsg) else { return XCTFail() }
        XCTAssertEqual(e, 2); XCTAssertEqual(reason, "progress"); XCTAssertEqual(p?.pct, 42.5); XCTAssertEqual(p?.live, false)
        let fire = try JSONValue.parse(#"{"kind":"fire","at":1,"rule":"Charm broke","sound":"p/s","message":"x","captures":{"target":"a rat"},"spell":"Mesmerization III"}"#)
        guard case .fire(let f) = EngineMessage.parse(fire) else { return XCTFail() }
        XCTAssertEqual(f.captures["target"], "a rat")
        XCTAssertEqual(f.spell, "Mesmerization III")
        let err = try JSONValue.parse(#"{"kind":"error","id":4,"ok":false,"error":{"code":"badParams","message":"no"}}"#)
        guard case .error(let eid, let pe) = EngineMessage.parse(err) else { return XCTFail() }
        XCTAssertEqual(eid, 4); XCTAssertEqual(pe.code, "badParams")
    }
}

final class DiscoveryTests: XCTestCase {
    private func temp() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("eqc-disc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d.appendingPathComponent("EverQuest Legends/Logs"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: d.appendingPathComponent("EverQuest Legends/Logs/eqlog_Zod_oggok.txt").path, contents: Data())
        return d
    }

    func testOverrideShapesResolveToOnePair() throws {
        let d = try temp()
        let root = d.appendingPathComponent("EverQuest Legends")
        let logs = root.appendingPathComponent("Logs")
        let file = logs.appendingPathComponent("eqlog_Zod_oggok.txt")
        for p in [root.path, logs.path, file.path, root.path + "/"] {
            let r = Discovery.normalizeOverride(p)
            XCTAssertEqual(r.root.standardizedFileURL.path, root.standardizedFileURL.path, p)
            XCTAssertEqual(r.logsDir.standardizedFileURL.path, logs.standardizedFileURL.path, p)
        }
    }

    func testDiscoverySweepsBottles() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("eqc-home-\(UUID().uuidString)")
        let root = home.appendingPathComponent("Library/Application Support/CrossOver/Bottles/EverQuest/drive_c").appendingPathComponent(Discovery.daybreakSubpath)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Logs"), withIntermediateDirectories: true)
        XCTAssertNil(Discovery.discover(home: home, environment: [:]), "no log yet, so no install")
        FileManager.default.createFile(atPath: root.appendingPathComponent("Logs/eqlog_A_b.txt").path, contents: Data())
        let r = Discovery.discover(home: home, environment: [:])
        XCTAssertEqual(r?.root.path, root.path)
        XCTAssertEqual(r?.source, "CrossOver bottle EverQuest")
        let env = Discovery.discover(home: home, environment: ["EQ_INSTALL_DIR": root.appendingPathComponent("Logs").path])
        XCTAssertEqual(env?.source, "env")
        XCTAssertEqual(env?.root.path, root.path)
    }
}

final class FormatTests: XCTestCase {
    func testBytesAndDurations() {
        XCTAssertEqual(Format.bytes(512), "512 B")
        XCTAssertEqual(Format.bytes(148_800_000), "141.9 MB")
        XCTAssertEqual(Format.duration(ms: 40_000), "40s")
        XCTAssertEqual(Format.duration(ms: 163_000), "3m")
        XCTAssertEqual(Format.duration(ms: 4_320_000), "1h 12m")
        XCTAssertEqual(Format.clock(ms: 270_000), "4m 30s")
        XCTAssertEqual(Format.compact(8_040), "8.0k")
        XCTAssertEqual(Format.compact(732), "732")
    }
}

