// Port of fold/src/modules/output_files.rs — when the player last exported each `/outputfile` dump.
//
// Newest wins, and only the newest is kept: the log holds every export the character ever made,
// but the only one that can be a baseline is the one that wrote the file now on disk.
//
// Epoch is deliberately not handled — the file on disk outlives the epoch too, and this module
// reports when that file was written, not whose it was.
import Foundation
import EQLog
import EQCompanionCore

/// `fileKey` — the last path segment, trimmed and lowercased. EQ writes dumps into the install root
/// and prints the bare name, so the join is on that segment, case-insensitively.
private func fileKey(_ pathOrName: String) -> String {
    JS.trim(JSFn.baseName(pathOrName)).lowercased()
}

public final class OutputFilesModule: EqModule {
    public let id = "outputFiles"

    private var written = JSMap<Int64>()
    private var seq: Int64 = 0
    /// The announce cursor. It must be seq-valued, not a counter: this module is mirrored in main,
    /// and that mirror stores the snapshot's seq and drops any cursor at or below it, so a counter
    /// would freeze the mirror on its first refresh.
    private var announce = Announce()

    public init() {}

    public func reset() {
        written.clear()
        seq = 0
        announce.reset()
    }

    public func onEvent(_ ev: Event, live: Bool) {
        seq = ev.seq
        if ev.kind != "outputFile" { return }
        let key = fileKey(ev.str(.file) ?? "")
        let ts = ev.ts
        // A dump whose stamp is not newer than the one held changes nothing.
        if let prev = written[key], ts <= prev { return }
        written.insert(key, ts)
        announce.changed(seq)
    }

    /// Moves on a dump not already recorded at that instant or later. See the `announce` field.
    public var publishedSeq: Int64? { announce.cursor }

    public func snapshot() -> JSONValue { ["seq": .int(seq), "state": written.json { .int($0) }] }
}
