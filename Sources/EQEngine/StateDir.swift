// The app's `userData`, read and written by the engine. Port of engined/src/state.rs.
//
// `EQFold` owns the two file SHAPES; this file owns the directory, the disk, the cadence and the
// diagnostics. Nothing here parses a format and nothing there opens a file.
//
// The directory is pushed as `session.attach`'s optional `stateDir`, never discovered — the engine
// cannot derive the app's `userData` and must not guess. Absent means no persistence at all:
// nothing read, nothing written, and the fold is the file-free one the equivalence oracle records.
// Every non-app client gets that by saying nothing.
//
// Both formats are the app's existing ones, verbatim, because both implementations have to be able
// to hold the same file — a user who turns the engine off must not lose their ledger.
//
// Every write is temp + fsync + rename, in that order: a plain write onto the live path truncates
// it first, so a process killed mid-write leaves a half-written file the reader treats as empty.
// The fsync is a step of its own — renaming a file whose bytes are only in the page cache is how an
// "atomic" write ends up truncated anyway. On failure the scratch file is taken back, because a
// whole user ledger left in `.tmp` also fills the volume that just said it had no room.
//
// A failed write is a diagnostic and nothing more. The ledger's truth is in memory, every reader
// comes through the fold, and the folded character re-derives its whole bucket from the log on the
// next attach; a snapshot is the whole cost.
//
// The cadence is the app's: every 60th beat of the live heartbeat, and nothing during a replay —
// structural rather than guarded, since `EventSink.tick` is the only path here and the historical
// scan cannot reach it. Both writes are coalesced on a fingerprint of the serialized text, because
// an app left open at the character select would otherwise rewrite hundreds of kilobytes an hour to
// say the same thing.
//
// Two app behaviours are deliberately absent: no retry backoff, so a genuinely full volume will
// re-try and re-print once a minute, and no salvage or quarantine on the resist read. The third the
// Rust also omits — a final write — is present here as `flush`, because an in-process engine has a
// detach the Rust process did not: a preempted ingest calls it on its way out. It is the same
// coalesced write, so a generation that changed nothing writes nothing.
import Foundation
import EQCompanionCore
import EQFold

public enum StateFiles {
    /// `<userData>/resist-ledger.json` — the app's spelling, and the only one either side may use.
    public static let resistLedger = "resist-ledger.json"
    /// `<userData>/message-overlay.json`.
    public static let messageOverlay = "message-overlay.json"
}

/// How many live beats between writes. The heartbeat is 1 Hz, so sixty of them is the app's minute.
public let writeEveryBeats: UInt64 = 60

/// FNV-1a over the serialized text, paired with its length — the app's own fingerprint, ported.
///
/// The pair rather than the hash alone because holding the previous JSON to compare against would
/// double the file's footprint in memory. A collision costs one snapshot of changed counts and
/// nothing durable.
///
/// The length is UTF-16 code UNITS, so this walks `utf16` rather than `unicodeScalars`: the two
/// differ on any astral character, and the app's number is the one being matched.
public func fingerprint(_ text: String) -> String {
    var hash: UInt32 = 0x811c_9dc5
    var units = 0
    for unit in text.utf16 {
        hash ^= UInt32(unit)
        hash = hash &* 0x0100_0193
        units += 1
    }
    return "\(units):\(String(hash, radix: 16))"
}

/// The app's `userData`, plus what this engine last wrote into it.
///
/// One per attach, because the coalescing fingerprint is a statement about what THIS generation has
/// written: the world was rebuilt, so the first write of a generation should land rather than be
/// declined by a memory of the last one.
public final class StateDir {
    private let dir: URL
    private var lastLedger: String?
    private var lastOverlay: String?

    public init(_ dir: URL) {
        self.dir = dir
        lastLedger = nil
        lastOverlay = nil
    }

    public convenience init(_ dir: String) { self.init(URL(fileURLWithPath: dir)) }

    /// Read both artifacts, at attach, before the first byte is folded.
    ///
    /// Never fails: a missing file, an unreadable one, a stale version or a shape from another
    /// build are all an empty seed, which is what both app readers do.
    public func read() -> PersistedState {
        let ledger = ResistLedgerFile.readLedger(slurp(StateFiles.resistLedger))
        if let notice = ledger.notice {
            diagnostic("state: \(notice)")
        }
        let overlay = OverlayFile.seedsOf(OverlayFile.readRegister(slurp(StateFiles.messageOverlay)))
        diagnostic("state: seeded \(ledger.sources.count) resist bucket(s) and "
                   + "\(overlay.count) overlay bucket(s) from \(dir.path)")
        var state = PersistedState()
        state.resist = ledger.sources
        state.overlay = overlay
        return state
    }

    /// A file's whole text, or `""` for anything that could not be read.
    ///
    /// A missing file and every other error collapse to the same answer: an empty string is not
    /// valid JSON, so it flows into the "reads as empty" arm the readers already have. A file that
    /// exists but cannot be read is worth a line, and gets one.
    private func slurp(_ name: String) -> String {
        let path = dir.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: path.path) { return "" }
        guard let data = try? Data(contentsOf: path) else {
            diagnostic("state: \(name) could not be read; starting empty")
            return ""
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Write both artifacts, coalesced. Called on every 60th live beat and never during a replay.
    public func write(_ registry: Registry) {
        // Each file's own writer states the app's field order, so the bytes on disk are the app's
        // bytes rather than a serializer's opinion about key order.
        if let resist = registry.resist() {
            put(StateFiles.resistLedger, resist.userLedgerFile().serializedString(), isLedger: true)
        }
        if let buffs = registry.buffs() {
            put(StateFiles.messageOverlay, buffs.overlayRegisterFile().serializedString(),
                isLedger: false)
        }
    }

    /// The detach write — the same coalesced write, forced by the ingest on its way out rather than
    /// by the beat. It is `write` and nothing more: a generation whose fingerprints have not moved
    /// writes nothing, so a detach that follows a beat costs a serialization and no disk.
    public func flush(_ registry: Registry) { write(registry) }

    /// One coalesced, atomic write. `isLedger` picks which fingerprint slot this file owns — two
    /// files, two memories, because one shared slot would make each write cancel the other's.
    func put(_ name: String, _ text: String, isLedger: Bool) {
        let stamp = fingerprint(text)
        if isLedger {
            if lastLedger == stamp { return }
        } else {
            if lastOverlay == stamp { return }
        }
        let path = dir.appendingPathComponent(name)
        do {
            try writeDurable(path, text)
            if isLedger { lastLedger = stamp } else { lastOverlay = stamp }
        } catch {
            // Never fatal. The fold is untouched, the in-memory ledger is the truth every reader
            // comes through, and the next attach re-derives this character's whole bucket from the
            // log. A snapshot is the whole cost.
            diagnostic("state: \(path.path) could not be written (\(error)); the fold carries on")
        }
    }
}

/// Temp + fsync + rename, in that order.
///
/// The scratch path is unique per write. One ingest thread per generation is not one writer per
/// file: a retiring generation's last flush can overlap the next one's, and two writers sharing
/// one `.tmp` would rename each other's half-written bytes into place.
///
/// The directory is created if missing, because a `stateDir` pushed before the app had created it
/// is a race the engine should absorb rather than fail on.
///
/// On any failure the scratch file is removed, and the removal's own error is dropped: the caller
/// is already being told the write failed, and a second message would bury the first.
func writeDurable(_ path: URL, _ text: String) throws {
    let parent = path.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    let tmp = scratchPath(for: path)
    do {
        try fillAndFlush(tmp, text)
    } catch {
        try? FileManager.default.removeItem(at: tmp)
        throw error
    }
    do {
        // `replaceItemAt` falls back to a plain rename when nothing is at the destination, and
        // does the atomic exchange when something is.
        if FileManager.default.fileExists(atPath: path.path) {
            _ = try FileManager.default.replaceItemAt(path, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: path)
        }
    } catch {
        try? FileManager.default.removeItem(at: tmp)
        throw error
    }
}

/// `<name>.<unique>.tmp` beside `path`: same directory, so the rename stays on one volume.
func scratchPath(for path: URL) -> URL {
    path.deletingLastPathComponent()
        .appendingPathComponent("\(path.lastPathComponent).\(UUID().uuidString.prefix(8)).tmp")
}

/// The scratch file, written and flushed to the device. `fsync` is a step of its own — see the file
/// header for why it is not a synonym for the rename.
func fillAndFlush(_ tmp: URL, _ text: String) throws {
    let fd = open(tmp.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    if fd < 0 { throw StateIOError(errno) }
    defer { close(fd) }
    var bytes = Array(text.utf8)
    var written = 0
    while written < bytes.count {
        let n = bytes.withUnsafeBytes { raw -> Int in
            Foundation.write(fd, raw.baseAddress!.advanced(by: written), raw.count - written)
        }
        if n < 0 {
            if errno == EINTR { continue }
            throw StateIOError(errno)
        }
        if n == 0 { break }
        written += n
    }
    bytes.removeAll()
    if fsync(fd) != 0 { throw StateIOError(errno) }
}

/// An `errno` a state write returned.
public struct StateIOError: Error, Equatable, CustomStringConvertible {
    public let code: Int32
    public init(_ code: Int32) { self.code = code }
    public var description: String { String(cString: strerror(code)) }
}
