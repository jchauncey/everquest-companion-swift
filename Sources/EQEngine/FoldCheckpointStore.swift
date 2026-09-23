// The fold checkpoint on disk: how an attach resumes instead of replaying the whole log.
//
// One file per log under the app's stateDir, holding a small header and the whole world
// (`Fold.checkpointState()`). The from-zero scan stays canonical; this file is an ACCELERATOR,
// and every doubt about it is answered with a full rescan:
//
//   * WRONG FILE — the saved (device, inode) no longer matches the open fd. A deleted and
//     recreated log is a different history wearing the same name.
//   * REWRITTEN HISTORY — the file is shorter than the mark, or the 64 KB ending at the mark no
//     longer hashes to what was saved. EverQuest only appends, so a mismatch means someone edited
//     or trimmed the log, and the bytes the checkpoint summarizes are not the bytes on disk.
//   * DIFFERENT BUILD — the executable changed. Fold semantics can change with any build, and one
//     full rescan per update is the cheapest correctness money can buy.
//   * DIFFERENT FORMAT — `foldCheckpointVersion` moved, or the world refuses the blob.
//
// DEFINES NEED NO FINGERPRINT, by the engine's own law: a define is applied from the moment it is
// pushed, and "the events already folded were folded under what the user had said at the time"
// (Ingest, on mid-scan defines). The module codecs carry define state as of the checkpoint, and
// the app's re-push after attach lands exactly like any other define push. A resumed world under
// changed defines is the same world a running engine would have been.
//
// Every write is temp + fsync + rename — StateDir's law, restated here because this file is not
// one of the registry's two and does not go through it.
import Foundation
import Darwin
import EQCompanionCore
import EQFold

/// How often the live tail refreshes the checkpoint. Five minutes: a crash costs at most that much
/// catch-up parsing, while the encode cost (~1-2 s for a 40 MB log's world) stays rare enough that
/// the tail never feels it.
public let checkpointEvery: TimeInterval = 300

/// How much of the log, ending at the mark, is hashed into the header. Enough that a trimmed or
/// edited file cannot keep its hash by accident; small enough to cost nothing.
let checkpointTailHashBytes: UInt64 = 65_536

public enum FoldCheckpointStore {
    public struct Resume {
        public var mark: UInt64
        public var seq: Int64
        public var events: UInt64
    }

    // MARK: - Identity

    /// FNV-1a 64 over raw bytes.
    static func fnv64(_ bytes: UnsafeRawBufferPointer) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in bytes {
            hash ^= UInt64(b)
            hash &*= 0x1_0000_01b3
        }
        return hash
    }

    /// The hash of the `checkpointTailHashBytes` ending at `mark`, read with `pread` so the fd's
    /// own cursor — which the scan is about to use — never moves.
    static func tailHash(fd: Int32, mark: UInt64) -> UInt64? {
        let want = Int(min(mark, checkpointTailHashBytes))
        if want == 0 { return 0 }
        var buf = [UInt8](repeating: 0, count: want)
        let got = buf.withUnsafeMutableBytes { raw in
            pread(fd, raw.baseAddress!, want, off_t(mark - UInt64(want)))
        }
        guard got == want else { return nil }
        return buf.withUnsafeBytes { fnv64($0) }
    }

    /// This build's identity: the executable's size and mtime. Any new build invalidates every
    /// checkpoint — one rescan per update, and no cross-build state bug can exist.
    static func buildStamp() -> String {
        let path = Bundle.main.executableURL?.path ?? CommandLine.arguments.first ?? ""
        var st = stat()
        guard stat(path, &st) == 0 else { return "unknown" }
        return "\(st.st_size)-\(st.st_mtimespec.tv_sec)"
    }

    /// Where one log's checkpoint lives: the path is hashed so a log path with slashes in it makes
    /// a flat file name, and two characters' logs never share a file.
    public static func fileURL(dir: URL, log: URL) -> URL {
        let key = log.path.utf8.withContiguousStorageIfAvailable { fnv64(UnsafeRawBufferPointer($0)) }
            ?? fnv64Array(Array(log.path.utf8))
        return dir.appendingPathComponent("fold-checkpoint-\(String(key, radix: 16)).json")
    }

    private static func fnv64Array(_ bytes: [UInt8]) -> UInt64 {
        bytes.withUnsafeBytes { fnv64($0) }
    }

    // MARK: - Save

    /// Write the checkpoint, atomically. A failure is a diagnostic and nothing more — the world's
    /// truth is in memory and the log itself; a checkpoint is only ever a saved rescan.
    public static func save(dir: URL, log: URL, fd: Int32, mark: UInt64, seq: Int64,
                            world: JSONValue, events: UInt64) {
        var st = stat()
        guard fstat(fd, &st) == 0, let hash = tailHash(fd: fd, mark: mark) else {
            diagnostic("checkpoint: save skipped, could not read the log's identity")
            return
        }
        let blob: JSONValue = .object([
            "format": .int(Int64(foldCheckpointVersion)),
            "build": .string(buildStamp()),
            "log": .object([
                "path": .string(log.path),
                "dev": .int(Int64(st.st_dev)),
                "ino": .int(Int64(st.st_ino)),
                "mark": .int(Int64(mark)),
                "tailHash": .string(String(hash, radix: 16)),
            ]),
            "seq": .int(seq),
            "events": .int(Int64(events)),
            "world": world,
        ])
        let url = fileURL(dir: dir, log: log)
        let tmp = scratchPath(for: url)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = blob.serialized()
            try data.write(to: tmp)
            // fsync BEFORE rename: renaming a file whose bytes are only in the page cache is how
            // an "atomic" write ends up truncated anyway.
            let tf = open(tmp.path, O_RDONLY)
            if tf >= 0 { fsync(tf); close(tf) }
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            diagnostic("checkpoint: saved \(events) events at mark \(mark) (\(data.count) bytes)")
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            diagnostic("checkpoint: save failed: \(error)")
        }
    }

    // MARK: - Load

    /// Read, validate, and restore into the sink's world. On success the caller seeks to the mark
    /// and parses only the tail; on ANY doubt the reason is returned and the caller scans from
    /// zero with a world the failed restore left fully reset.
    public static func tryResume(dir: URL, log: URL, fd: Int32, size: UInt64,
                                 sink: FoldSink) -> Result<Resume, String> {
        let url = fileURL(dir: dir, log: log)
        guard let data = try? Data(contentsOf: url) else { return .failure("no checkpoint") }
        guard let blob = try? JSONValue.parse(data) else { return .failure("unreadable checkpoint") }
        guard blob["format"].int64 == Int64(foldCheckpointVersion) else { return .failure("format changed") }
        guard blob["build"].string == buildStamp() else { return .failure("build changed") }

        var st = stat()
        guard fstat(fd, &st) == 0 else { return .failure("cannot stat the log") }
        let saved = blob["log"]
        guard saved["dev"].int64 == Int64(st.st_dev), saved["ino"].int64 == Int64(st.st_ino) else {
            return .failure("the log is a different file")
        }
        guard let markI = saved["mark"].int64, markI >= 0 else { return .failure("no mark") }
        let mark = UInt64(markI)
        guard mark <= size else { return .failure("the log shrank below the mark") }
        guard let savedHash = saved["tailHash"].string,
              let hash = tailHash(fd: fd, mark: mark),
              String(hash, radix: 16) == savedHash else {
            return .failure("the bytes at the mark changed")
        }
        guard let seq = blob["seq"].int64, let events = blob["events"].int64, events >= 0 else {
            return .failure("no cursor")
        }
        guard sink.restoreWorld(blob["world"]) else {
            return .failure("the world refused the blob")
        }
        return .success(Resume(mark: mark, seq: seq, events: UInt64(events)))
    }
}

extension FoldSink {
    /// The whole world, or nil while any part of it cannot checkpoint yet.
    public func checkpointWorld() -> JSONValue? { fold.checkpointState() }
    /// Restore the whole world; false leaves it fully reset.
    public func restoreWorld(_ blob: JSONValue) -> Bool { fold.restoreCheckpoint(blob) }
}
