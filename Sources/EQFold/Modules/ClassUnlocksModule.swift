// Port of fold/src/modules/class_unlocks.rs — the classes this character may run as a primary, as
// the LOG stated them, in the order it stated them.
//
// Deduped by class, first sighting wins (law 2: keys are case-folded, displays are raw). The
// achievement fires once per class per character, so the first instant is the fact worth keeping.
import Foundation
import EQLog
import EQCompanionCore

public final class ClassUnlocksModule: EqModule {
    public let id = "classUnlocks"

    private struct ClassUnlockRow {
        var ts: Int64
        var className: String
        var json: JSONValue { ["ts": .int(ts), "className": .string(className)] }
    }

    private var unlocks: [ClassUnlockRow] = []
    private var seen: Set<String> = []
    private var seq: Int64 = 0
    /// The announce cursor. A second `classUnlock` line for a class publishes nothing, so it
    /// announces nothing.
    private var announce = Announce()

    public init() {}

    public func reset() {
        unlocks.removeAll()
        seen.removeAll()
        seq = 0
        announce.reset()
    }

    public func onEvent(_ ev: Event, live: Bool) {
        seq = ev.seq
        if ev.kind == "epoch" {
            unlocks.removeAll()
            seen.removeAll()
            announce.changed(seq)
            return
        }
        if ev.kind != "classUnlock" { return }
        let name = ev.str(.className) ?? ""
        if !seen.insert(name.lowercased()).inserted { return }
        unlocks.append(ClassUnlockRow(ts: ev.ts, className: name))
        announce.changed(seq)
    }

    /// Moves on a class this character had not unlocked before. See the `announce` field.
    public var publishedSeq: Int64? { announce.cursor }

    public func snapshot() -> JSONValue { ["seq": .int(seq), "state": .array(unlocks.map(\.json))] }
}
