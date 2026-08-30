// SwiftUI-facing observables over the client: a live view window, a module snapshot that re-fetches
// when the engine says the module moved, and the combat poller both meters share.
import Foundation
import Observation
import EQCompanionCore

/// One subscription, materialized. Bind it to a descriptor from `.task(id:)`; the window re-opens
/// when the descriptor changes and closes when the view goes away.
@MainActor
@Observable
final class LiveView {
    private(set) var state: ViewState = .loading
    private var handle: EngineClient.ViewHandle?
    private var boundKey: String?

    var rows: [Row] { state.rows ?? [] }
    var total: Int { state.total }
    var loading: Bool { state.loading }
    var error: String? { state.error }

    func bind(_ client: EngineClient, _ descriptor: ViewDescriptor) {
        if boundKey == descriptor.key, handle != nil { return }
        handle?.close()
        boundKey = descriptor.key
        state = .loading
        handle = client.subscribe(descriptor) { [weak self] s in self?.state = s }
        if let h = handle { state = h.state }
    }

    func close() {
        handle?.close()
        handle = nil
        boundKey = nil
    }
}

/// A module's published state, fetched through `module.snapshot` and refreshed on `moduleChanged`.
@MainActor
@Observable
final class ModuleSnapshot {
    private(set) var state: JSONValue = .null
    private(set) var seq: Int?
    private(set) var loading = true
    private(set) var error: String?
    private var inFlight = false
    private var again = false

    func refresh(_ model: AppModel, module: String) async {
        guard model.client.isReady else { return }
        if inFlight { again = true; return }
        inFlight = true
        defer { inFlight = false }
        do {
            let r = try await model.client.request(Op.moduleSnapshot, ["module": .string(module)], deadline: 15)
            state = r["state"]
            seq = r["seq"].int
            error = nil
        } catch {
            self.error = "\(error)"
        }
        loading = false
        if again {
            again = false
            await refresh(model, module: module)
        }
    }
}

/// The combat snapshot at 1 Hz while a meter is on screen — the same event-driven poll the Electron
/// surfaces use, pared to the engine's own answer. `selectedId` resolves the segment.
@MainActor
@Observable
final class CombatPoller {
    private(set) var snapshot: JSONValue = .null
    private(set) var now: Int64 = 0
    private(set) var error: String?
    var selectedId: String?
    var timeline = false
    var maxSegments = 60

    func tick(_ model: AppModel) async {
        guard model.client.isReady else { return }
        var opts: [String: JSONValue] = ["maxSegments": .int(Int64(maxSegments))]
        if let s = selectedId { opts["selectedId"] = .string(s) }
        if timeline { opts["timeline"] = true }
        do {
            let r = try await model.client.request(Op.combatSnapshot, ["opts": .object(opts)], deadline: 10)
            snapshot = r["snapshot"]
            now = r["now"].int64 ?? 0
            error = nil
        } catch {
            self.error = "\(error)"
        }
    }

    func run(_ model: AppModel) async {
        while !Task.isCancelled {
            await tick(model)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }
}
