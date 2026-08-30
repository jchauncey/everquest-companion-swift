// The app's side of the protocol: one connection at a time, typed requests, and subscriptions that
// hand a listener a MATERIALIZED WINDOW rather than the frames it was assembled from.
//
// THE EPOCH LAW. The epoch is the world's generation and it is connection-wide, so this client holds
// exactly one. Any bump — an `epoch` frame announcing attach/restart, or a stream frame that simply
// arrives carrying a newer epoch — drops every window, flips every subscription to loading and
// waits for the fresh reset each will be sent when the new fold lands. A frame from an older epoch
// is dropped. A new connection is the same event: attach re-hellos, drops every window and
// re-subscribes everything under fresh ids. There is no catch-up and no resume token.
import Foundation

@MainActor
public final class EngineClient {
    @MainActor
    public final class ViewHandle {
        public private(set) var state: ViewState = .loading
        fileprivate let descriptor: ViewDescriptor
        fileprivate let listener: (ViewState) -> Void
        fileprivate var wireId: Int?
        fileprivate weak var client: EngineClient?

        fileprivate init(descriptor: ViewDescriptor, listener: @escaping (ViewState) -> Void) {
            self.descriptor = descriptor
            self.listener = listener
        }

        fileprivate func set(_ s: ViewState) {
            state = s
            listener(s)
        }

        public func close() {
            client?.unsubscribe(self)
            client = nil
        }
    }

    public private(set) var state: ConnectionState = .closed
    public private(set) var epoch: Int?
    public var debug: ((String) -> Void)?

    private var connection: EngineLink?
    private var byWireId: [Int: ViewHandle] = [:]
    private var handles: [ObjectIdentifier: ViewHandle] = [:]

    private var stateListeners: [UUID: (ConnectionState) -> Void] = [:]
    private var progressListeners: [UUID: (FoldProgress) -> Void] = [:]
    private var epochListeners: [UUID: (Int, String) -> Void] = [:]
    private var fireListeners: [UUID: (FireMessage) -> Void] = [:]
    private var conCardListeners: [UUID: (JSONValue) -> Void] = [:]
    private var moduleListeners: [UUID: (String, Int) -> Void] = [:]
    private var missListeners: [UUID: (String, String) -> Void] = [:]

    public init() {}

    // MARK: - Connection

    /// Take an already-open link (the in-process engine): drop every window, re-subscribe everything.
    public func attach(link: EngineLink) {
        detach()
        connection = link
        setState(.ready)
        epoch = nil
        for h in handles.values {
            h.set(.loading)
            openOnWire(h)
        }
    }

    /// Deliver one stream frame from a link — the in-process engine's door. MAIN queue, in order.
    public func deliver(_ m: EngineMessage) { handle(m) }

    /// The link reports its own state (a socket failing, an engine restarting).
    public func linkState(_ s: ConnectionState) { connectionState(s) }

    public func detach() {
        if let c = connection {
            c.close()
            connection = nil
        }
        byWireId.removeAll()
        for h in handles.values { h.wireId = nil }
        setState(.closed)
    }

    private func connectionState(_ s: ConnectionState) {
        switch s {
        case .failed, .closed:
            if connection != nil {
                connection = nil
                byWireId.removeAll()
                for h in handles.values {
                    h.wireId = nil
                    h.set(.loading)
                }
                setState(s)
            }
        default:
            break
        }
    }

    private func setState(_ s: ConnectionState) {
        state = s
        for l in stateListeners.values { l(s) }
    }

    public var isReady: Bool { state == .ready && connection != nil }

    // MARK: - Requests

    public func request(_ op: String, _ params: JSONValue = [:],
                        deadline: TimeInterval = EngineLinkDefaults.deadline) async throws -> JSONValue {
        guard let c = connection, state == .ready else { throw EngineError.notConnected }
        return try await c.request(op, params, id: nil, deadline: deadline)
    }

    // MARK: - Subscriptions

    public func subscribe(_ descriptor: ViewDescriptor, _ listener: @escaping (ViewState) -> Void) -> ViewHandle {
        let h = ViewHandle(descriptor: descriptor, listener: listener)
        h.client = self
        handles[ObjectIdentifier(h)] = h
        openOnWire(h)
        return h
    }

    private func openOnWire(_ h: ViewHandle) {
        guard let c = connection, state == .ready else { return }
        let id = c.allocateId()
        h.wireId = id
        byWireId[id] = h
        Task { [weak self, weak h] in
            do {
                _ = try await c.request(Op.viewSubscribe, h?.descriptor.toJSON() ?? [:], id: id, deadline: EngineLinkDefaults.deadline)
            } catch {
                guard let self, let h, h.wireId == id else { return }
                self.byWireId[id] = nil
                h.wireId = nil
                h.set(.failed("\(error)"))
            }
        }
    }

    private func unsubscribe(_ h: ViewHandle) {
        handles[ObjectIdentifier(h)] = nil
        if let id = h.wireId {
            byWireId[id] = nil
            h.wireId = nil
            connection?.post(Op.viewUnsubscribe, ["subscription": .int(Int64(id))])
        }
    }

    // MARK: - Listeners (connection-wide)

    @discardableResult
    private func add<T>(_ dict: inout [UUID: T], _ l: T) -> () -> Void {
        let id = UUID()
        dict[id] = l
        return { [weak self] in _ = self.map { _ in } ; self?.remove(id) }
    }

    private var removers: [UUID: () -> Void] = [:]
    private func remove(_ id: UUID) {
        stateListeners[id] = nil
        progressListeners[id] = nil
        epochListeners[id] = nil
        fireListeners[id] = nil
        conCardListeners[id] = nil
        moduleListeners[id] = nil
        missListeners[id] = nil
    }

    public func onState(_ l: @escaping (ConnectionState) -> Void) -> () -> Void { add(&stateListeners, l) }
    public func onProgress(_ l: @escaping (FoldProgress) -> Void) -> () -> Void { add(&progressListeners, l) }
    public func onEpoch(_ l: @escaping (Int, String) -> Void) -> () -> Void { add(&epochListeners, l) }
    public func onFire(_ l: @escaping (FireMessage) -> Void) -> () -> Void { add(&fireListeners, l) }
    public func onConCard(_ l: @escaping (JSONValue) -> Void) -> () -> Void { add(&conCardListeners, l) }
    public func onModuleChanged(_ l: @escaping (String, Int) -> Void) -> () -> Void { add(&moduleListeners, l) }
    public func onKnowledgeMiss(_ l: @escaping (String, String) -> Void) -> () -> Void { add(&missListeners, l) }

    // MARK: - Frames

    private func bump(to e: Int, reason: String) {
        epoch = e
        for h in handles.values { h.set(.loading) }
        for l in epochListeners.values { l(e, reason) }
    }

    /// Reconcile a frame's epoch with the one held. Returns false when the frame is stale.
    private func accept(epoch e: Int) -> Bool {
        guard let held = epoch else {
            epoch = e
            return true
        }
        if e > held { bump(to: e, reason: "frame"); return true }
        if e < held { debug?("dropped a frame from epoch \(e) (holding \(held))"); return false }
        return true
    }

    private func handle(_ m: EngineMessage) {
        switch m {
        case .reset(let id, let e, let total, let rows):
            guard accept(epoch: e) else { return }
            guard let h = byWireId[id] else { debug?("reset for an unknown subscription \(id)"); return }
            h.set(ViewWindow.applyReset(epoch: e, total: total, rows: rows))
        case .diff(let id, let e, let total, let ops):
            guard accept(epoch: e) else { return }
            guard let h = byWireId[id] else { debug?("diff for an unknown subscription \(id)"); return }
            let (next, notes) = ViewWindow.applyDiff(h.state, epoch: e, total: total, ops: ops)
            for n in notes { debug?("\(h.descriptor.source): \(n)") }
            h.set(next)
        case .epoch(let e, let reason, let progress):
            if reason == "attach" || reason == "restart" {
                if epoch != e { bump(to: e, reason: reason) } else { bump(to: e, reason: reason) }
            } else if epoch == nil {
                epoch = e
            }
            if let p = progress { for l in progressListeners.values { l(p) } }
        case .fire(let f):
            for l in fireListeners.values { l(f) }
        case .conCard(let v):
            for l in conCardListeners.values { l(v) }
        case .moduleChanged(let module, let seq):
            for l in moduleListeners.values { l(module, seq) }
        case .knowledgeMiss(let domain, let name):
            for l in missListeners.values { l(domain, name) }
        case .hello, .reply, .error:
            debug?("unexpected \(m) outside a request")
        case .unknown(let v):
            debug?("unknown frame: \(v.serializedString().prefix(160))")
        }
    }
}
