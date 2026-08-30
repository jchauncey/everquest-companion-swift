// Port of eqlog/src/tail.rs — following a file EverQuest is still writing: the other half of ingest,
// where `Scan` folds a complete file. Purely byte-level — it emits complete raw lines and parses
// nothing, the caller parses, and every line it emits is a live line (see `tailLive`).
//
// ## The mark law
//
// Two offsets, never to be swapped:
//
//   * `TailCore.readOffset` — the read cursor: bytes pulled off the file, including a trailing
//     partial line the game has not finished writing.
//   * `TailCore.checkpointOffset` — the mark: the end of the last complete line emitted, exactly
//     `readOffset - leftover.count`. Anything claiming "the state I hold is `fold(bytes[0, b))`"
//     needs `b` to be this. `FileTail.mark` pairs it with the log's identity, and that pair is the
//     only way this module's state is named.
//
// A line with no terminating newline is not emitted and the mark stays before it, however long the
// game takes to finish it.
//
// No wall clock appears in what this module emits. Poll timing decides when bytes are read and
// never what comes out: the same bytes, chunked any way at all, produce the same line sequence.
//
// ## The leftover is bytes, never a string
//
// Reads are sliced at a fixed byte count (`tailReadSliceBytes`), so a boundary lands mid-line and
// just as easily mid-character. Decoding a fragment that ends inside a multi-byte sequence yields
// U+FFFD and destroys the character permanently, so nothing is decoded until its terminating
// newline is in hand. That is also what makes the mark exact arithmetic.
//
// ## Truncation and rotation
//
//   1. The only trigger is a strict shrink (`size < readOffset`), tested once per poll. A file
//      truncated to exactly the byte count already read is indistinguishable from an idle one.
//   2. On a shrink the tail restarts at zero and discards the partial-line carry, so lines that
//      survived the truncation are emitted again. De-duplication would be a claim about content
//      that a byte-level tail has no business making.
//   3. A shrink that is over before it is observed is invisible: grown back past the old cursor
//      between two polls, no poll sees the shrink and the tail reads at an offset that now names
//      different bytes. Inherent to polling; stated rather than papered over.
//   4. A mid-read shrink ends the cycle early and leaves the next poll's shrink test to decide,
//      rather than treating a short read as an error.
//   5. Replacement (the path unlinked and recreated) forces a reopen, because an open handle
//      follows the file it opened and not the name; the evidence is a `stat` call that failed with
//      `ENOENT`. The reopen does not itself reset the offset — rule 1 decides that from the new
//      size. The hole that leaves: a replacement already longer than the old cursor the first time
//      it is seen is read from the middle. Unreachable in practice, and pinned by a test.
//
// ## Watching is polling, deliberately
//
// EverQuest writes through a path some watchers miss, and polling has matched the product for a
// year. The poll interval is a parameter (`FileTail.follow`) and costs one `stat` call.
import Foundation

/// The most bytes one read may ask for.
///
/// EverQuest writes its log synchronously from the game thread, so anything that delays its append
/// is a frame it did not draw. An append needs the file resource exclusively, and one uncapped read
/// of a whole delta holds it shared for the length of the read. Slicing turns one long hold into a
/// run of short ones with a yield between them.
///
/// 256 KiB is ~2500 log lines: far more than a poll interval of real play produces, and small
/// enough that a slice is a single-digit-millisecond read off a warm file.
public let tailReadSliceBytes = 256 * 1024

/// Every line this module emits is a live line. `live` is a property of the source, not of a line:
/// the scan folds history, the tail folds what is happening now. A constant rather than a field
/// because there is no configuration in which a tailed line is not live.
public let tailLive = true

public let tailDefaultPollInterval: TimeInterval = 0.4

/// An `errno` a file operation returned, carried so a caller can tell EINTR from a real failure.
public struct TailIOError: Error, Equatable, CustomStringConvertible {
    public let code: Int32
    public init(_ code: Int32) { self.code = code }
    public var description: String { String(cString: strerror(code)) }
}

/// Positional reads — the one file operation the slice loop needs, named as a protocol so the loop
/// can be proven against a source as rude as the OS.
///
/// `readAt` may return fewer bytes than asked for, and every caller treats that as normal rather
/// than as an end: a short read is the commonest thing a real file hands back under a writer.
public protocol ReadAt {
    /// Read into `out` starting at `offset`. `0` means end of file.
    func readAt(_ offset: UInt64, _ out: UnsafeMutableRawBufferPointer) throws -> Int
}

extension FileHandle: ReadAt {
    public func readAt(_ offset: UInt64, _ out: UnsafeMutableRawBufferPointer) throws -> Int {
        guard let base = out.baseAddress, out.count > 0 else { return 0 }
        let n = pread(fileDescriptor, base, out.count, off_t(offset))
        if n < 0 { throw TailIOError(errno) }
        return n
    }
}

/// Fill `out` from `offset`, looping over short reads. Returns how many bytes were actually
/// available (`< out.count` means the file ended, or shrank, under us).
func readFilled(_ src: ReadAt, _ offset: UInt64, _ out: UnsafeMutableRawBufferPointer) throws -> Int {
    var got = 0
    while got < out.count {
        let n: Int
        do {
            n = try src.readAt(offset + UInt64(got), UnsafeMutableRawBufferPointer(rebasing: out[got...]))
        } catch let e as TailIOError where e.code == EINTR {
            continue
        }
        if n == 0 { break }
        got += n
    }
    return got
}

/// Split `bytes` into complete lines, handing each to `emit`, and return the offset at which the
/// trailing partial line starts (everything after the last newline, possibly empty).
///
/// The rules are `Scan`'s rules byte for byte, because the tail's acceptance is that its line
/// sequence equals the scan's.
func splitLines(_ bytes: UnsafePointer<UInt8>, _ count: Int, _ emit: (String) -> Void) -> Int {
    var start = 0
    while start < count, let hit = memchr(bytes + start, 0x0A, count - start) {
        let nl = UnsafePointer<UInt8>(OpaquePointer(hit)) - bytes
        var end = nl
        if end > start, bytes[end - 1] == 0x0D { end -= 1 }
        if end > start {
            emit(String(decoding: UnsafeBufferPointer(start: bytes + start, count: end - start), as: UTF8.self))
        }
        start = nl + 1
    }
    return start
}

/// The tail's entire state: a read cursor and the undecoded partial line under it. Pure — it knows
/// nothing about files, handles or clocks, which is what lets the byte laws above be proven by
/// feeding it one byte at a time.
public struct TailCore {
    private var offset: UInt64
    private var leftover: [UInt8]

    public init() {
        offset = 0
        leftover = []
    }

    /// A tail whose read cursor starts at `offset` and holds no partial line — the shape a handoff
    /// from the scan produces, since the scan's end offset is by definition a line boundary.
    public static func at(_ offset: UInt64) -> TailCore {
        var c = TailCore()
        c.offset = offset
        return c
    }

    /// The read cursor: bytes pulled off the file, partial trailing line included.
    public var readOffset: UInt64 { offset }

    /// The mark: the end of the last complete line emitted. See the header's mark law.
    public var checkpointOffset: UInt64 { offset - UInt64(leftover.count) }

    /// How many bytes are held back as an unfinished line. `readOffset - checkpointOffset`, named
    /// so a caller can say "the game is mid-line" without doing the subtraction itself.
    public var pendingBytes: Int { leftover.count }

    /// Fold `chunk` — the bytes at `readOffset` — emitting every line it completes, and advance the
    /// cursor by its length. The cursor advances before the split, so the mark is correct at every
    /// point a caller could observe it.
    public mutating func consume(_ chunk: UnsafeRawBufferPointer, _ emit: (String) -> Void) {
        offset += UInt64(chunk.count)
        if leftover.isEmpty {
            var rest = 0
            if let base = chunk.baseAddress, chunk.count > 0 {
                rest = splitLines(base.assumingMemoryBound(to: UInt8.self), chunk.count, emit)
            }
            // Copied, never a view: keeping a borrow of the read buffer as the carry would pin
            // 256 KiB alive for the sake of a partial line.
            if rest < chunk.count {
                leftover.append(contentsOf: UnsafeRawBufferPointer(rebasing: chunk[rest...]))
            }
        } else {
            var buf = leftover
            leftover = []
            buf.append(contentsOf: chunk)
            let keep = buf.withUnsafeBufferPointer { p in
                splitLines(p.baseAddress!, p.count, emit)
            }
            buf.removeFirst(keep)
            leftover = buf
        }
        // A burst that ended on a line boundary must not leave a 256 KiB allocation parked on a
        // field that is normally empty.
        if leftover.isEmpty && leftover.capacity > tailReadSliceBytes { leftover = [] }
    }

    public mutating func consume(_ chunk: [UInt8], _ emit: (String) -> Void) {
        chunk.withUnsafeBytes { consume($0, emit) }
    }

    /// Restart at byte 0, discarding the partial line (truncation rule 2 in the header).
    public mutating func reset() {
        offset = 0
        leftover.removeAll(keepingCapacity: true)
    }
}

/// Where a tail begins reading.
public enum TailStart: Equatable, Sendable {
    /// At the end of the file as it stands: only what the game writes from now on.
    case eof
    /// At byte 0 — the whole file, as lines.
    case fromStart
    /// At an explicit byte offset: the gapless handoff from the scan. The tail picks up exactly
    /// where the scan stopped, so bytes appended during the scan are read rather than skipped and
    /// none are read twice. Clamped to the current size in case the file shrank in between.
    case at(UInt64)
}

/// Why a handle had to be opened. Counted rather than timed — see the header on wall clocks.
public enum ReopenReason: Equatable, Sendable {
    /// There isn't one yet.
    case first
    /// The path vanished and came back; the handle follows the file it opened, not the name.
    case replaced
    /// The file is smaller than the read cursor (truncate/rotate in place).
    case shrunk
    /// A read on the handle failed, so the handle is suspect and gets dropped.
    case error
}

/// What one poll did. Counts only, no durations: poll timing must never leak into anything a caller
/// can fold, and a stats struct is exactly the place that leak would start.
public struct PollStats: Equatable, Sendable {
    /// Bytes read this cycle.
    public var bytes: UInt64 = 0
    /// Slices the read took. `ceil(bytes / tailReadSliceBytes)` in the happy case.
    public var slices: Int = 0
    /// Set when this cycle opened a handle, and why.
    public var reopened: ReopenReason?
    /// The file shrank and the tail restarted at byte 0.
    public var restarted = false
    /// The path did not exist at all this cycle. Not an error: the game may not have made the file
    /// yet, and a rotation is exactly this followed by an `add`.
    public var missing = false

    public init() {}
}

/// A coordinate: which log, and how far into it the emitted lines reach. Every cache key over tail
/// state is built from this pair and nothing else — no wall time, no "current".
public struct TailMark: Equatable, Sendable {
    /// The log's identity.
    public let log: URL
    /// The checkpoint: the end of the last complete line emitted.
    public let offset: UInt64
}

/// A stop flag `follow` honours. The Rust is an `AtomicBool`; this is the same fact, locked.
public final class TailStop: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    public init() {}
    public var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    public func stop() { lock.lock(); flag = true; lock.unlock() }
}

/// A tail over one growing file: a persistent read handle, a poll cycle, and `TailCore` under it.
///
/// The handle is held open on a file another process is appending to, deliberately. Opening and
/// closing around every read — up to ~2/sec in combat — negotiates share mode against EQ's own
/// handle on a file that is routinely hundreds of MB. A shared read handle never blocks an append.
/// The cases that force a reopen are exactly the ones where the handle stops describing the file at
/// the path — see `ReopenReason`.
public final class FileTail {
    public let path: URL
    private var core: TailCore
    private var fh: FileHandle?
    /// The reason the NEXT open will carry, or `nil` when the handle in hand is trusted.
    private var pendingOpen: ReopenReason?
    /// A poll saw the path missing; whatever answers to the name next is a different file.
    private var vanished: Bool
    private var sliceBytes: Int

    /// Point a tail at a path. Does not open the file — the first poll that finds bytes does that —
    /// and does not fail when the path is not there yet: an absent file starts the cursor at the
    /// requested offset, and the first poll that finds the file applies the shrink rule to it.
    public init(_ path: URL, _ start: TailStart) {
        self.path = path
        let size = FileTail.sizeOf(path)
        let offset: UInt64
        switch (start, size) {
        case (.at(let at), .some(let size)): offset = min(at, size)
        case (.at(let at), .none): offset = at
        case (.fromStart, _): offset = 0
        case (.eof, .some(let size)): offset = size
        case (.eof, .none): offset = 0
        }
        core = TailCore.at(offset)
        fh = nil
        pendingOpen = .first
        vanished = false
        sliceBytes = tailReadSliceBytes
    }

    public convenience init(_ path: String, _ start: TailStart) {
        self.init(URL(fileURLWithPath: path), start)
    }

    /// Shrink the read slice. Tests only: proving the multi-slice path otherwise needs a
    /// quarter-megabyte of log per assertion.
    @discardableResult
    public func withSliceBytes(_ bytes: Int) -> FileTail {
        sliceBytes = max(1, bytes)
        return self
    }

    /// The read cursor. See the header's mark law before using this for anything.
    public var readOffset: UInt64 { core.readOffset }

    /// The mark: the end of the last complete line emitted.
    public var checkpointOffset: UInt64 { core.checkpointOffset }

    /// The mark as an addressable coordinate.
    public var mark: TailMark { TailMark(log: path, offset: core.checkpointOffset) }

    private static func sizeOf(_ path: URL) -> UInt64? {
        var st = stat()
        if stat(path.path, &st) != 0 { return nil }
        return UInt64(st.st_size)
    }

    /// One poll: look at the file, read whatever is new, emit the lines it completes.
    ///
    /// Idempotent when nothing changed — an idle poll opens nothing, reads nothing and emits
    /// nothing. Errors leave the tail running (the handle is dropped so the next cycle opens a fresh
    /// one under `ReopenReason.error`) and the offset is untouched, so a failed read costs bytes
    /// nobody has read, never bytes nobody will read.
    @discardableResult
    public func poll(_ emit: (String) -> Void) throws -> PollStats {
        var stats = PollStats()

        var st = stat()
        if stat(path.path, &st) != 0 {
            let e = errno
            if e == ENOENT {
                vanished = true
                stats.missing = true
                return stats
            }
            throw TailIOError(e)
        }
        let size = UInt64(st.st_size)

        if vanished {
            vanished = false
            pendingOpen = .replaced
        }
        if size < core.readOffset {
            core.reset()
            pendingOpen = .shrunk
            stats.restarted = true
        }
        if size <= core.readOffset {
            // Nothing new, and deliberately no handle opened to prove it: the steady-state poll on
            // an idle log must cost one stat call and nothing else.
            return stats
        }

        try ensureHandle(&stats)
        guard let file = fh else { fatalError("ensureHandle left a handle") }
        fh = nil
        do {
            try readSlices(file, size, sliceBytes, &core, &stats, emit)
            fh = file
            return stats
        } catch {
            // The handle is the prime suspect for anything that failed in there — drop it and let
            // the next cycle open a fresh one under a counted reason rather than hiding the reopen
            // inside a retry.
            try? file.close()
            pendingOpen = .error
            throw error
        }
    }

    /// Poll forever at `interval`, until `stop` is set. Errors do not end the loop: they go to
    /// `onError` and the next cycle opens a fresh handle.
    ///
    /// The sleep is broken into short naps so `stop` is honoured promptly instead of after a whole
    /// interval; nothing about the pacing reaches `emit`.
    public func follow(_ interval: TimeInterval, _ stop: TailStop,
                       _ emit: (String) -> Void, _ onError: (Error) -> Void) {
        let nap = min(interval, 0.025)
        while !stop.isStopped {
            do { _ = try poll(emit) } catch { onError(error) }
            var slept: TimeInterval = 0
            while slept < interval && !stop.isStopped {
                Thread.sleep(forTimeInterval: nap)
                slept += nap
            }
        }
    }

    /// Open only if there is no trusted handle; record why under the reason that forced it.
    private func ensureHandle(_ stats: inout PollStats) throws {
        if fh != nil && pendingOpen == nil { return }
        let reason = pendingOpen ?? .first
        fh = nil
        let fd = open(path.path, O_RDONLY)
        if fd < 0 { throw TailIOError(errno) }
        fh = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        pendingOpen = nil
        stats.reopened = reason
    }
}

/// Read `[core.readOffset, size)` in bounded slices, folding each into `core`.
///
/// Free function over `ReadAt` rather than a method so the loop is provable against a source that
/// hands back one byte per call — the shape a real file under a live writer produces.
func readSlices(_ src: ReadAt, _ size: UInt64, _ sliceBytes: Int,
                _ core: inout TailCore, _ stats: inout PollStats,
                _ emit: (String) -> Void) throws {
    if core.readOffset >= size { return }
    var buf = [UInt8](repeating: 0, count: max(1, min(sliceBytes, Int(size - core.readOffset))))
    while core.readOffset < size {
        let want = min(sliceBytes, Int(size - core.readOffset))
        if buf.count < want { buf.append(contentsOf: repeatElement(0, count: want - buf.count)) }
        let at = core.readOffset
        var got = 0
        try buf.withUnsafeMutableBytes { raw in
            got = try readFilled(src, at, UnsafeMutableRawBufferPointer(rebasing: raw[..<want]))
        }
        if got == 0 {
            // The file shrank under us; the NEXT poll's shrink test says what that means. A short
            // read is not an error.
            break
        }
        stats.slices += 1
        stats.bytes += UInt64(got)
        buf.withUnsafeBytes { raw in
            core.consume(UnsafeRawBufferPointer(rebasing: raw[..<got]), emit)
        }
        if core.readOffset < size {
            // The slice boundary's whole point: give the game's synchronous append a gap to take
            // the file resource in.
            sched_yield()
        }
    }
}
