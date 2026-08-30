// The registry plus the derived-event producers beside it on the bus (fold/src/lib.rs `Fold`).
//
// Delivery is dispatch, observe, drain: a primary event reaches every module in registration
// order, then the combat engine, then the two detectors; anything anyone derived is queued and
// delivered through the same loop, shift-until-empty. No module reads a wall clock: the live tail
// hands one in through `tick`, and a historical fold never ticks.
import Foundation
import EQLog
import EQCompanionCore

public final class Fold {
    public let registry: Registry
    public var combat: CombatEngine?
    private let epoch: EpochDetector
    private let sessions = SessionDetector()
    private var derived: [Event] = []
    public private(set) var events: UInt64 = 0
    public private(set) var lastTs: Int64 = 0

    public init(registry: Registry, launchMs: Int64) {
        self.registry = registry
        epoch = EpochDetector(launchMs: launchMs)
        reset()
    }

    /// Subscribe the combat engine behind the registry. Resets only the engine it installs.
    public func withCombat(_ engine: CombatEngine) -> Fold {
        combat = engine
        engine.reset()
        return self
    }

    public func reset() {
        registry.reset()
        combat?.reset()
        epoch.reset()
        sessions.reset()
        derived.removeAll()
        events = 0
        lastTs = 0
    }

    /// One primary event: deliver it, then drain whatever anybody queued through the same delivery.
    public func onPrimary(_ ev: Event, live: Bool) {
        events += 1
        lastTs = max(lastTs, ev.ts)
        observe(ev, live: live)
        var i = 0
        while i < derived.count {
            let d = derived[i]
            i += 1
            observe(d, live: live)
        }
        derived.removeAll(keepingCapacity: true)
    }

    private func observe(_ ev: Event, live: Bool) {
        registry.dispatch(ev, live: live, derived: &derived)
        combat?.onEvent(ev, live: live, roster: registry.roster())
        if let d = epoch.observe(ev) { derived.append(d) }
        if let d = sessions.observe(ev) { derived.append(d) }
    }

    /// One wall-clock tick over the whole world — live only. The combat engine declares no tick.
    public func tick(nowMs: Int64) {
        registry.tick(nowMs: nowMs, derived: &derived)
    }

    /// Fold a complete log through the scanner. Historical: `live` false throughout, never ticks.
    public func foldBytes(_ parser: Parser, _ data: Data) {
        Scan.bytes(parser, data) { _, payload in
            self.onPrimary(Event.typed(payload), live: false)
        }
    }

    /// Fold a golden NDJSON stream (one JSON event per line) — the module harness's input.
    public func foldNDJSON(_ text: String) {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if let ev = Event.fromJSON(String(line)) { onPrimary(ev, live: false) }
        }
    }
}
