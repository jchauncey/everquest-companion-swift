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
    let epochDetector: EpochDetector
    let sessionDetector = SessionDetector()
    /// Your pet inferred from your heals when the game never names it (PetInference.swift). Off
    /// unless the owner sets it — the app does; the parity oracles never do.
    public var petInference: PetInference?
    private var derived: [Event] = []
    public private(set) var events: UInt64 = 0
    public private(set) var lastTs: Int64 = 0

    /// The checkpoint's door onto the two counters — restore only, never folding.
    func restoreCounters(events: UInt64, lastTs: Int64) {
        self.events = events
        self.lastTs = lastTs
    }

    public init(registry: Registry, launchMs: Int64) {
        self.registry = registry
        epochDetector = EpochDetector(launchMs: launchMs)
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
        epochDetector.reset()
        sessionDetector.reset()
        petInference?.reset()
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
        if let d = epochDetector.observe(ev) { derived.append(d) }
        if let d = sessionDetector.observe(ev) { derived.append(d) }
        if let d = petInference?.observe(ev, roster: registry.roster()) { derived.append(d) }
    }

    /// One wall-clock tick over the whole world — live only. The combat engine declares no tick.
    public func tick(nowMs: Int64) {
        registry.tick(nowMs: nowMs, derived: &derived)
    }

    /// Fold a complete log through the scanner. Historical: `live` false throughout, never ticks.
    public func foldBytes(_ parser: Parser, _ data: Data) {
        Scan.bytes(parser, data, json: false) { _, payload in
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

// MARK: - Checkpoint

/// The version stamped into every world checkpoint. BUMP IT whenever any module's fold semantics
/// or any codec changes shape — a stale-format blob must read as "unusable, rescan", never as a
/// subtly different world. The build-identity check on top of this lives with the caller; this
/// number is for deliberate format breaks within one build lineage.
public let foldCheckpointVersion = 4

extension Fold {
    /// The whole world at this instant: the Fold's own detectors and counters, every conforming
    /// module, and the combat engine. Nil while any registered module does not conform — a world
    /// checkpoint with a hole in it is not a checkpoint, and half a world restored beside a virgin
    /// half would be exactly the divergence the oracle exists to prevent.
    public func checkpointState() -> JSONValue? {
        var modules: [String: JSONValue] = [:]
        for m in registry.mods {
            guard let cp = m as? FoldCheckpointable else { return nil }
            modules[m.id] = cp.checkpointState()
        }
        var o: [String: JSONValue] = [
            "version": .int(Int64(foldCheckpointVersion)),
            "events": .int(Int64(events)),
            "lastTs": .int(lastTs),
            "epochDetector": epochDetector.checkpointState(),
            "sessionDetector": sessionDetector.checkpointState(),
            "modules": .object(modules),
        ]
        if let combat { o["combat"] = combat.checkpointState() }
        if let petInference { o["petInference"] = petInference.checkpointState() }
        return .object(o)
    }

    /// Rebuild the whole world from a `checkpointState()` blob. The registry must be the same
    /// wiring the blob was cut from (same module ids); anything else refuses. On ANY refusal the
    /// world is left fully reset — the caller's answer is a full rescan, and a half-restored world
    /// must never survive into it.
    public func restoreCheckpoint(_ state: JSONValue) -> Bool {
        reset()
        guard state["version"].int64 == Int64(foldCheckpointVersion),
              let eventCount = state["events"].int64, let ts = state["lastTs"].int64,
              let modules = state["modules"].object else { return false }
        guard epochDetector.restoreCheckpoint(state["epochDetector"]),
              sessionDetector.restoreCheckpoint(state["sessionDetector"]) else { reset(); return false }
        for m in registry.mods {
            guard let cp = m as? FoldCheckpointable, let blob = modules[m.id],
                  cp.restoreCheckpoint(blob) else { reset(); return false }
        }
        if let combat {
            guard combat.restoreCheckpoint(state["combat"]) else { reset(); return false }
        }
        if let petInference {
            guard petInference.restoreCheckpoint(state["petInference"]) else { reset(); return false }
        }
        restoreCounters(events: UInt64(eventCount), lastTs: ts)
        return true
    }
}
