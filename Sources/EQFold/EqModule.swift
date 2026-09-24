// The extension contract (fold/src/lib.rs `EqModule`): one class per module, a registry that
// preserves wiring order, and the pull seams a view or the engine reads through.
import Foundation
import EQCompanionCore

/// What a module does with app knowledge: an idempotent full-set replace, one family per module.
public protocol Defines: AnyObject {
    var family: String { get }
    func define(_ payload: JSONValue)
}

public protocol EqModule: AnyObject {
    /// Stable id, matching the TS module's `id` exactly (the golden's join key).
    var id: String { get }
    /// Called on character (re)load, before the historical replay begins.
    func reset()
    /// Fold one event. `live` gates nothing here — the registry gates the push.
    func onEvent(_ ev: Event, live: Bool)
    /// Optional wall-clock heartbeat, ~1×/sec on the live tail only.
    func onTick(nowMs: Int64, timerRows: [BuffTimerRow])
    /// Would this module read the timer projection on the next beat?
    var wantsTimerRows: Bool { get }
    /// `{ "seq": n, "state": … }`.
    func snapshot() -> JSONValue
    /// The derived events this module synthesized while folding the event it was just handed.
    func takeDerived() -> [Event]
    /// The module's published cursor, or nil for a module that does not announce.
    var publishedSeq: Int64? { get }
    func takeCons() -> [ConEvent]
    func takeFires() -> [Fire]
    func installKnowledge(_ k: Knowledge)

    // Pull seams: a module is known by what it can answer.
    var asRoster: RosterSource? { get }
    var asLoot: LootModule? { get }
    var asBuffs: BuffsModule? { get }
    var asBuffTimers: BuffTimersModule? { get }
    var asRespawn: RespawnModule? { get }
    var asResist: ResistModule? { get }
    var asProgression: ProgressionModule? { get }
    var asEventFeed: EventFeedModule? { get }
    var asDefines: Defines? { get }
    var asOwnLoot: OwnLoot? { get }
}

public extension EqModule {
    func onTick(nowMs: Int64, timerRows: [BuffTimerRow]) {}
    var wantsTimerRows: Bool { false }
    func takeDerived() -> [Event] { [] }
    var publishedSeq: Int64? { nil }
    func takeCons() -> [ConEvent] { [] }
    func takeFires() -> [Fire] { [] }
    func installKnowledge(_ k: Knowledge) {}
    var asRoster: RosterSource? { nil }
    var asLoot: LootModule? { nil }
    var asBuffs: BuffsModule? { nil }
    var asBuffTimers: BuffTimersModule? { nil }
    var asRespawn: RespawnModule? { nil }
    var asResist: ResistModule? { nil }
    var asProgression: ProgressionModule? { nil }
    var asEventFeed: EventFeedModule? { nil }
    var asDefines: Defines? { nil }
    var asOwnLoot: OwnLoot? { nil }
}

/// Registration order is bus delivery order — `wiring.ts ordered`, verbatim.
public let wiringOrder: [String] = [
    "combo", "roster", "loot", "turnins", "classUnlocks", "kills", "respawn", "progression", "leveling",
    "character", "outputFiles", "spellSets", "itemTiers", "observedSpellRanks", "alerts", "buffs",
    "buffTimers", "consider", "resist", "eventFeed",
    // Not upstream's: the one Swift-only module (SalesModule), after every ported one.
    "sales"
]

/// The registered modules, in delivery order, and the dispatch loop over them.
public final class Registry {
    public private(set) var mods: [EqModule] = []

    public init() {}

    public func register(_ m: EqModule) { mods.append(m) }

    public func reset() { for m in mods { m.reset() } }

    /// Deliver one event to every module, in order, appending whatever any synthesized.
    public func dispatch(_ ev: Event, live: Bool, derived: inout [Event]) {
        for m in mods {
            m.onEvent(ev, live: live)
            let out = m.takeDerived()
            if !out.isEmpty { derived.append(contentsOf: out) }
        }
    }

    /// The wall-clock heartbeat, fanned over every module in wiring order.
    public func tick(nowMs: Int64, derived: inout [Event]) {
        let rows = timerRows()
        for m in mods {
            m.onTick(nowMs: nowMs, timerRows: rows)
            let out = m.takeDerived()
            if !out.isEmpty { derived.append(contentsOf: out) }
        }
    }

    /// The timer-row projection — empty when either half is absent or nobody asked.
    public func timerRows() -> [BuffTimerRow] {
        guard mods.contains(where: \.wantsTimerRows), let b = buffs(), let t = buffTimers() else { return [] }
        return buildTimerRows(active: b.activeBuffs(), holds: t.holds(), ends: t.ends())
    }

    public func ids() -> [String] { mods.map(\.id) }
    public func roster() -> RosterSource? { mods.lazy.compactMap(\.asRoster).first }
    public func loot() -> LootModule? { mods.lazy.compactMap(\.asLoot).first }
    public func buffs() -> BuffsModule? { mods.lazy.compactMap(\.asBuffs).first }
    public func buffTimers() -> BuffTimersModule? { mods.lazy.compactMap(\.asBuffTimers).first }
    public func respawn() -> RespawnModule? { mods.lazy.compactMap(\.asRespawn).first }
    public func resist() -> ResistModule? { mods.lazy.compactMap(\.asResist).first }
    public func progression() -> ProgressionModule? { mods.lazy.compactMap(\.asProgression).first }
    public func eventFeed() -> EventFeedModule? { mods.lazy.compactMap(\.asEventFeed).first }
    public func ownLoot() -> OwnLoot? { mods.lazy.compactMap(\.asOwnLoot).first }

    /// Seed the persisted knowledge, then name this fold's own source — one call, order load-bearing.
    public func seedPersisted(key: String, state: PersistedState) {
        if let r = resist() {
            r.seed(state.resist)
            r.beginSource(key)
        }
        if let b = buffs() {
            for (source, counts) in state.overlay { b.seedOverlay(source: source, counts: counts) }
            b.beginOverlaySource(key)
        }
    }

    public func installKnowledge(_ k: Knowledge) { for m in mods { m.installKnowledge(k) } }

    public func publishedSeqs() -> [(String, Int64)] { mods.compactMap { m in m.publishedSeq.map { (m.id, $0) } } }

    public func takeCons() -> [ConEvent] { mods.flatMap { $0.takeCons() } }
    public func takeFires() -> [Fire] { mods.flatMap { $0.takeFires() } }

    public func snapshotOf(_ id: String) -> JSONValue? { mods.first { $0.id == id }?.snapshot() }

    /// Push one family of app knowledge into the module that owns it. False for an unclaimed family.
    public func define(family: String, payload: JSONValue) -> Bool {
        for m in mods {
            if let d = m.asDefines, d.family == family {
                d.define(payload)
                return true
            }
        }
        return false
    }

    public func missing() -> [String] {
        let have = Set(ids())
        return wiringOrder.filter { !have.contains($0) }
    }

    /// `{ "modules": [ { "id", "snapshot": {seq, state} } ], "skipped": [...] }` — the golden's shape.
    public func snapshots() -> JSONValue {
        ["modules": .array(mods.map { ["id": .string($0.id), "snapshot": $0.snapshot()] }),
         "skipped": .array(missing().map { .string($0) })]
    }
}
