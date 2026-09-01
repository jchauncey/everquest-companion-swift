// The two derived-event producers and the announce cursor (fold/src/{epoch,session,announce}.rs).
import Foundation
import EQLog
import EQCompanionCore

public enum Epoch {
    /// The official-launch anchor: local midnight, 2026-07-28, on the parse clock's zone.
    public static func launchMs(_ clock: Clock) -> Int64 { clock.parseEQTimestamp("Tue Jul 28 00:00:00 2026") }
}

public final class EpochDetector {
    let launchMs: Int64
    private var fired = false

    public init(launchMs: Int64) { self.launchMs = launchMs }
    public func reset() { fired = false }

    public func observe(_ ev: Event) -> Event? {
        if ev.kind == "epoch" || fired || ev.ts < launchMs { return nil }
        fired = true
        return Event.fromValue(["kind": "epoch", "reason": "launch", "seq": .int(ev.seq), "ts": .int(ev.ts), "raw": .string(ev.raw)])
    }
}

public let offlineGapMinMs: Int64 = 60_000
public let campPairingMs: Int64 = 60_000

private let firstPersonKinds: Set<String> = [
    "sessionStart", "zone", "loot", "coin", "itemReceived", "purchase", "offer", "trade", "level", "expGain",
    "aaGain", "aaSpend", "aaPotion", "aaActivate", "castBegin", "castFizzle", "castInterrupted", "castResumed",
    "buffFade", "buffWearOff", "illusionFade", "playerDeath", "healUnstated", "mitigation", "campStart",
    "campAbort", "outputFile", "selfWho", "skillUp", "specialAttack", "classUnlock", "itemActivate", "itemMerge",
    "itemMergeFailed", "consider", "stanceChange", "invocationChange", "petClaim"
]

private func isYou(_ name: String?) -> Bool { name.map { Names.idKey($0) == "you" } ?? false }

private func combatNamesYou(_ ev: Event) -> Bool {
    switch ev.kind {
    case "damage", "miss": return isYou(ev.str(.attacker)) || isYou(ev.str(.target))
    case "heal": return isYou(ev.str(.healer)) || isYou(ev.str(.target))
    case "resist": return ev.bool(.incoming) || isYou(ev.str(.caster)) || isYou(ev.str(.target))
    case "death": return ev.bool(.bySelf)
    default: return false
    }
}

private func selfFormOf(_ ev: Event) -> Bool {
    switch ev.kind {
    case "buffApply": return ev.str(.target) == "self"
    case "spellEmote": return ev.str(.subject) == "self"
    case "group": return ev.str(.change) == "selfJoin" || ev.str(.change) == "selfLeave"
    default: return false
    }
}

/// A line that could only have been printed for THIS character.
public func inWorldEvidence(_ ev: Event) -> Bool {
    firstPersonKinds.contains(ev.kind) || combatNamesYou(ev) || selfFormOf(ev)
}

public final class SessionDetector {
    private var evidenceTs: Int64 = 0
    private var campTs: Int64 = 0

    public init() {}
    public func reset() { evidenceTs = 0; campTs = 0 }

    public func observe(_ ev: Event) -> Event? {
        let k = ev.kind
        if k == "offlineGap" || k == "epoch" || k == "buffExpired" { return nil }
        if ev.ts <= 0 { return nil }
        if k == "campStart" { campTs = ev.ts }
        if k == "campAbort" { campTs = 0 }
        let gap = k == "sessionStart" ? buildGap(toTs: ev.ts, seq: ev.seq, raw: ev.raw) : nil
        if inWorldEvidence(ev) { evidenceTs = ev.ts }
        return gap
    }

    private func buildGap(toTs: Int64, seq: Int64, raw: String) -> Event? {
        let fromTs = evidenceTs
        if fromTs <= 0 || toTs - fromTs <= offlineGapMinMs { return nil }
        let camped = campTs > 0 && abs(fromTs - campTs) <= campPairingMs
        return Event.fromValue(["kind": "offlineGap", "seq": .int(seq), "ts": .int(toTs), "raw": .string(raw),
                                "fromTs": .int(fromTs), "toTs": .int(toTs), "camped": .bool(camped)])
    }
}

/// The announce cursor — moves only when told, always past the fold position.
public struct Announce {
    public private(set) var cursor: Int64 = 0
    public init() {}
    public mutating func changed(_ seq: Int64) { cursor = max(cursor, seq) + 1 }
    public mutating func reset() { cursor = 0 }
    /// A checkpoint restore puts the cursor back exactly where it was: `publishedSeq` is part of
    /// what a resumed fold must reproduce, since views resume against it.
    public mutating func restore(cursor: Int64) { self.cursor = cursor }
}

// MARK: - Checkpoint

extension EpochDetector {
    /// `fired` is the whole state, and it matters completely: a resumed world that forgot it would
    /// synthesize a second launch-epoch on its first event and wipe every module's history.
    public func checkpointState() -> JSONValue { .object(["fired": .bool(fired)]) }
    public func restoreCheckpoint(_ v: JSONValue) -> Bool {
        reset()
        guard let f = v["fired"].bool else { return false }
        fired = f
        return true
    }
}

extension SessionDetector {
    /// The evidence clock and the camp instant — without them, the first `sessionStart` after
    /// resume cannot state the offline gap it closes, or states one with the wrong `camped`.
    public func checkpointState() -> JSONValue {
        .object(["evidenceTs": .int(evidenceTs), "campTs": .int(campTs)])
    }
    public func restoreCheckpoint(_ v: JSONValue) -> Bool {
        reset()
        guard let e = v["evidenceTs"].int64, let c = v["campTs"].int64 else { return false }
        evidenceTs = e
        campTs = c
        return true
    }
}
