// The Rust tail's unit tests (eqlog/src/tail.rs `mod tests`), kept as the port's acceptance: the
// byte laws are proven by feeding `TailCore` one byte at a time.
import XCTest
@testable import EQLog

final class TailTests: XCTestCase {
    /// Collect what a core emits for a whole input handed over in `chunk` sizes.
    private func linesInChunks(_ bytes: [UInt8], _ chunk: Int) -> ([String], TailCore) {
        var core = TailCore()
        var out: [String] = []
        var i = 0
        while i < bytes.count {
            let end = min(i + chunk, bytes.count)
            core.consume(Array(bytes[i..<end])) { out.append($0) }
            i = end
        }
        return (out, core)
    }

    private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    func testALineIsEmittedOnlyWhenItsNewlineArrivesAndTheMarkWaitsWithIt() {
        var core = TailCore()
        var out: [String] = []
        core.consume(bytes("[ts] first\n[ts] unfinis")) { out.append($0) }
        XCTAssertEqual(out, ["[ts] first"])
        XCTAssertEqual(core.readOffset, 23)
        // The mark law: the cursor is past the partial line, the mark is not.
        XCTAssertEqual(core.checkpointOffset, 11)
        XCTAssertEqual(core.pendingBytes, 12)

        core.consume(bytes("hed\n")) { out.append($0) }
        XCTAssertEqual(out, ["[ts] first", "[ts] unfinished"])
        XCTAssertEqual(core.checkpointOffset, core.readOffset)
        XCTAssertEqual(core.checkpointOffset, 27)
    }

    func testOneByteAtATimeIsTheSameLineSequenceAsOneChunk() {
        let b = bytes("[a] one\r\n[b] two\n\n[c] three\r\n")
        let (whole, wholeCore) = linesInChunks(b, b.count)
        XCTAssertEqual(whole, ["[a] one", "[b] two", "[c] three"])
        for chunk in [1, 2, 3, 5, 7, 13] {
            let (got, core) = linesInChunks(b, chunk)
            XCTAssertEqual(got, whole, "chunk size \(chunk)")
            XCTAssertEqual(core.checkpointOffset, wholeCore.checkpointOffset)
        }
    }

    func testAMultiByteCharacterCutInHalfByAChunkBoundarySurvivesWhole() {
        // Authored bytes, not a log claim: the committed corpus is scrubbed ASCII, so it cannot
        // exercise a mid-character cut on its own.
        let b = bytes("[ts] Sh\u{e0}dow \u{2014} \u{1f600} done\n")
        for chunk in 1..<b.count {
            let (got, _) = linesInChunks(b, chunk)
            XCTAssertEqual(got, ["[ts] Sh\u{e0}dow \u{2014} \u{1f600} done"], "chunk size \(chunk)")
        }
    }

    func testAChunkEndingOnTheNewlineByteAndOneEndingMidCRLF() {
        // Ends exactly on the newline: the line is complete and the mark reaches the cursor.
        var core = TailCore()
        var out: [String] = []
        core.consume(bytes("[a] one\r\n")) { out.append($0) }
        XCTAssertEqual(out, ["[a] one"])
        XCTAssertEqual(core.checkpointOffset, 9)

        // Ends between the CR and the LF: nothing is emitted, and the CR is still a byte rather than
        // a decoded character, so the next chunk's LF can still strip it.
        core = TailCore()
        out = []
        core.consume(bytes("[a] one\r")) { out.append($0) }
        XCTAssertTrue(out.isEmpty)
        XCTAssertEqual(core.checkpointOffset, 0)
        core.consume(bytes("\n[b] two\r\n")) { out.append($0) }
        XCTAssertEqual(out, ["[a] one", "[b] two"])
        XCTAssertEqual(core.checkpointOffset, 18)
    }

    func testAnEmptyLineIsDroppedByTheSplitterAndALoneCRLineWithIt() {
        let (got, core) = linesInChunks(bytes("\n\r\n[a] one\n\n"), 3)
        XCTAssertEqual(got, ["[a] one"])
        // Dropped lines still move the mark — they were read, they are just not lines.
        XCTAssertEqual(core.checkpointOffset, 12)
    }

    func testAResetDiscardsThePartialLineTheTruncationAte() {
        var core = TailCore.at(500)
        core.consume(bytes("[a] half-writ")) { _ in XCTFail("no line completes here") }
        XCTAssertEqual(core.checkpointOffset, 500)
        core.reset()
        XCTAssertEqual(core.readOffset, 0)
        XCTAssertEqual(core.checkpointOffset, 0)
        var out: [String] = []
        core.consume(bytes("ten\n")) { out.append($0) }
        XCTAssertEqual(out, ["ten"], "the orphaned prefix must not be re-attached")
    }

    /// A source as rude as the OS: one byte per `readAt`, whatever was asked for.
    private struct OneByteAtATime: ReadAt {
        let data: [UInt8]
        func readAt(_ offset: UInt64, _ out: UnsafeMutableRawBufferPointer) throws -> Int {
            let at = Int(offset)
            if out.count == 0 || at >= data.count { return 0 }
            out[0] = data[at]
            return 1
        }
    }

    func testTheSliceLoopSurvivesASourceThatHandsBackOneBytePerRead() throws {
        let b = bytes("[a] one\r\n[b] two\r\n[c] partial")
        let src = OneByteAtATime(data: b)
        var core = TailCore()
        var stats = PollStats()
        var out: [String] = []
        try readSlices(src, UInt64(b.count), 8, &core, &stats) { out.append($0) }
        XCTAssertEqual(out, ["[a] one", "[b] two"])
        XCTAssertEqual(core.readOffset, UInt64(b.count))
        XCTAssertEqual(core.checkpointOffset, 18)
        XCTAssertEqual(stats.bytes, UInt64(b.count))
        XCTAssertEqual(stats.slices, 4, "29 bytes in 8-byte slices")
    }

    func testASourceThatEndsEarlyEndsTheCycleRatherThanErroring() throws {
        // `size` claims more than the source holds: the mid-read shrink of truncation rule 4.
        let src = OneByteAtATime(data: bytes("[a] one\n"))
        var core = TailCore()
        var stats = PollStats()
        var out: [String] = []
        try readSlices(src, 4096, 8, &core, &stats) { out.append($0) }
        XCTAssertEqual(out, ["[a] one"])
        XCTAssertEqual(core.readOffset, 8)
    }

    // The file-level laws the pure core cannot state: the handle, the shrink rule, the reopen.

    func testAFileTailFollowsAppendsAndRestartsOnATruncation() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appendingPathComponent("eqlog_Primitive_test.txt")
        try Data("[a] one\n[b] two\n[c] par".utf8).write(to: log)

        let tail = FileTail(log, .fromStart)
        var out: [String] = []
        var stats = try tail.poll { out.append($0) }
        XCTAssertEqual(out, ["[a] one", "[b] two"])
        XCTAssertEqual(stats.reopened, .first)
        XCTAssertEqual(tail.checkpointOffset, 16)
        XCTAssertEqual(tail.readOffset, 23)
        XCTAssertEqual(tail.mark.offset, 16)
        XCTAssertEqual(tail.mark.log, log)

        // An idle poll opens nothing, reads nothing, emits nothing.
        stats = try tail.poll { out.append($0) }
        XCTAssertEqual(stats, PollStats())

        // Truncation: strictly smaller than the cursor, so the tail restarts at zero.
        try Data("[z] fresh\n".utf8).write(to: log)
        out = []
        stats = try tail.poll { out.append($0) }
        XCTAssertTrue(stats.restarted)
        XCTAssertEqual(stats.reopened, .shrunk)
        XCTAssertEqual(out, ["[z] fresh"])
        XCTAssertEqual(tail.checkpointOffset, 10)
    }

    func testAMissingPathIsNotAnErrorAndItsReturnForcesAReopen() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appendingPathComponent("eqlog_Primitive_test.txt")

        let tail = FileTail(log, .fromStart)
        var out: [String] = []
        var stats = try tail.poll { out.append($0) }
        XCTAssertTrue(stats.missing)
        XCTAssertTrue(out.isEmpty)

        try Data("[a] one\n".utf8).write(to: log)
        stats = try tail.poll { out.append($0) }
        XCTAssertEqual(out, ["[a] one"])
        XCTAssertEqual(stats.reopened, .replaced, "the path vanished before it answered")
    }

    func testTailStartAtIsClampedToTheSizeAndEofSkipsHistory() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appendingPathComponent("eqlog_Primitive_test.txt")
        try Data("[a] one\n[b] two\n".utf8).write(to: log)

        let handoff = FileTail(log, .at(8))
        var out: [String] = []
        try handoff.poll { out.append($0) }
        XCTAssertEqual(out, ["[b] two"], "the gapless handoff reads exactly what the scan did not")

        let late = FileTail(log, .at(1_000_000))
        XCTAssertEqual(late.readOffset, 16, "clamped to the size")

        let atEof = FileTail(log, .eof)
        out = []
        try atEof.poll { out.append($0) }
        XCTAssertTrue(out.isEmpty)
        let fh = try FileHandle(forWritingTo: log)
        try fh.seekToEnd()
        try fh.write(contentsOf: Data("[c] three\n".utf8))
        try fh.close()
        try atEof.poll { out.append($0) }
        XCTAssertEqual(out, ["[c] three"])
    }

    func testTheSliceLoopOverARealFileEmitsTheSameLinesAsOneRead() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appendingPathComponent("eqlog_Primitive_test.txt")
        var text = ""
        for i in 0..<500 { text += "[ts] line \(i)\r\n" }
        try Data(text.utf8).write(to: log)

        let whole = FileTail(log, .fromStart)
        var a: [String] = []
        try whole.poll { a.append($0) }

        let sliced = FileTail(log, .fromStart).withSliceBytes(7)
        var b: [String] = []
        let stats = try sliced.poll { b.append($0) }
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 500)
        XCTAssertEqual(sliced.checkpointOffset, whole.checkpointOffset)
        XCTAssertGreaterThan(stats.slices, 1)
    }
}
