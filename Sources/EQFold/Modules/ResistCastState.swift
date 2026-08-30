// What the tailed character was doing when a cast went off (fold/src/modules/resist/cast_state.rs).
//
// Two EQ Legends mechanics move a cast's resist adjust and neither is a property of the spell: the
// upgrade rank printed on the cast line, and the invocation being recited. Every row records both.
//
// The invocation is one of nine mutually exclusive states, tri-valued and never assumed: nil means no
// line has stated one, which is where a character who logged in already overchannelling stays.
// Nothing resets it on a zone or session boundary — only a new source resets it.
//
// A proc is not a cast spell and the log has no field that says so, so joining an armed cast is the
// test.
import Foundation
import EQLog

/// The invocation name (lowercased by the parser) that carries the -150 resist adjust.
public let OVERCHANNEL_INVOCATION = "overchannel"

/// How long after a `You begin casting` a landing sentence may still be claimed by it. Comfortably
/// above the longest cast plus its slack; the buffs model uses the same window for the same join.
public let CAST_JOIN_MS: Int64 = 10_000

/// How many casts can be in flight at once before the oldest stop being reachable.
private let maxArmed = 16

/// One cast in flight, and everything an outcome line may read off it.
public struct Armed {
    public var spellKey: String
    public var display: String
    public var ts: Int64
    public var kind: ResistCasterKind
    public var level: Int64?
    /// The upgrade rank the cast line printed, 0 when it printed none.
    public var rank: Int64
    /// The invocation state at the moment of the cast, which is the moment that decides the roll.
    public var overchannel: Bool?
    /// Mobs this cast has already printed a damage line for. One cast is one roll, so a spell that
    /// both damages and emotes must not have the emote counted too.
    ///
    /// A set on the cast rather than a cancel on the emote because the game prints the damage first,
    /// every time. A DoT's first tick can land either side of its emote, so both directions are
    /// covered.
    public var damaged: Set<String>

    public init(spellKey: String, display: String, ts: Int64, kind: ResistCasterKind, level: Int64?,
                rank: Int64, overchannel: Bool?, damaged: Set<String> = []) {
        self.spellKey = spellKey; self.display = display; self.ts = ts; self.kind = kind
        self.level = level; self.rank = rank; self.overchannel = overchannel; self.damaged = damaged
    }
}

/// The casts currently in flight. Bounded: only the last handful can still be in window.
public final class ArmedCasts {
    private var casts: [Armed] = []

    public init() {}

    public func reset() { casts.removeAll() }

    public func arm(_ cast: Armed) {
        casts.append(cast)
        if casts.count > maxArmed { casts.removeFirst(casts.count - maxArmed) }
    }

    /// A fizzle or an interrupt: a cast that never happened is not a resist.
    public func disarm(_ spellKey: String) { casts.removeAll { $0.spellKey == spellKey } }

    /// The index of the most recent armed cast this line can belong to, without consuming it.
    public func peekAt(_ spellKey: String, _ ts: Int64) -> Int? {
        for i in stride(from: casts.count - 1, through: 0, by: -1) {
            let cast = casts[i]
            if cast.spellKey != spellKey { continue }
            if ts < cast.ts || ts - cast.ts > CAST_JOIN_MS { continue }
            return i
        }
        return nil
    }

    public func noteDamaged(_ i: Int, _ mobKey: String) { casts[i].damaged.insert(mobKey) }

    /// The armed cast an outcome may read its rank and invocation off — this caster's, never
    /// another's: a charmed pet throwing the same spell as you must not inherit your rank. `peekAt`
    /// matches on the spell alone, because its own reader only marks a mob as damaged.
    public func ownedBy(_ kind: ResistCasterKind, _ spellKey: String, _ ts: Int64) -> Armed? {
        guard let i = peekAt(spellKey, ts) else { return nil }
        let cast = casts[i]
        return cast.kind == kind ? cast : nil
    }

    /// The most recent armed cast this landing sentence can belong to, consumed.
    public func take(_ ts: Int64, _ candidates: [String]?) -> Armed? {
        let keys: Set<String>? = candidates.map { Set($0.map { Names.spellCanonKey($0) }) }
        for i in stride(from: casts.count - 1, through: 0, by: -1) {
            let cast = casts[i]
            if ts < cast.ts || ts - cast.ts > CAST_JOIN_MS { continue }
            if let keys, !keys.contains(cast.spellKey) { continue }
            casts.remove(at: i)
            return cast
        }
        return nil
    }
}

public final class CastState {
    private var overchannelOn: Bool?
    private var classes: Int64 = 0
    /// Song spell key to the last upgrade rank seen for it. Songs are the one family whose
    /// observations do not come through an armed cast — under the Symphonic Aura there is no cast line
    /// at all — so a pulse's rank is remembered from whichever line last printed one.
    private var songRanks: [String: Int64] = [:]

    public init() {}

    public func reset() {
        overchannelOn = nil
        classes = 0
        songRanks.removeAll()
    }

    /// `You begin reciting the <name> invocation.` The nine are mutually exclusive.
    public func noteInvocation(_ invocation: String) {
        overchannelOn = invocation == OVERCHANNEL_INVOCATION
    }

    /// The character's own `/who` row: the only line in the game that states the loadout.
    public func noteClasses(_ classes: [String]) {
        self.classes = ResistCatalog.casterClassCount(classes)
    }

    public func noteSongRank(_ spellKey: String, _ rank: Int64) {
        if rank > 0 { songRanks[spellKey] = rank }
    }

    public func songRank(_ spellKey: String) -> Int64 { songRanks[spellKey] ?? 0 }

    /// The state to arm a fresh cast of your own with — the moment that decides the roll.
    public func overchannel() -> Bool? { overchannelOn }

    /// How many non-hybrid caster classes the character runs: the -15-each half of the overchannel
    /// adjust. Zero until a `/who` row is seen, which is the honest floor.
    public func casterClasses() -> Int64 { classes }

    /// The invocation as one observation saw it. `armed` is the cast it joined, or nil when it joined
    /// none: another caster's invocation is unknowable, and an observation with no cast behind it is
    /// a proc.
    public func invocationFor(_ kind: ResistCasterKind, _ armed: Bool??) -> Bool? {
        if kind != .selfCast { return nil }
        switch armed {
        case .some(let oc): return oc
        case .none: return false
        }
    }
}
