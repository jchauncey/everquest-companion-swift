// The in-process connection: one `EngineLink` onto one `World`, with no socket, no child process
// and no token.
//
// It has no Rust twin file, because the Rust's twin is a THREAD PAIR — `conn.rs` reads frames off a
// TcpStream and a writer thread drains the connection's outbox onto it. Everything else here is
// that file's: the session is the membership receipt, subscriptions live in the world keyed by
// (listener, request id) so one connection can never unsubscribe another's stream, and a dispatch's
// messages reach the peer in the order the op table returned them.
//
// The handshake is gone rather than reimplemented. Loopback needed a token because any process
// running as this user can reach 127.0.0.1; an in-process link is reachable only by the code that
// constructed it, so the hello is implicit and a client that sends one is told its state machine
// disagrees with this one's.
//
// TWO QUEUES, because the Rust has two threads and the ordering law depends on it. `work` runs one
// dispatch at a time, which is what the reader thread does — a request that waits on the fold's
// door waits alone, and the connection stays a serial conversation. `outbox` is the writer thread:
// every frame this connection will ever send is enqueued there, replies and connection-wide
// announcements alike, so a client observes ONE ordered stream. A world broadcast must not queue
// behind a request that is waiting five seconds on a wedged fold, which is exactly why the outbox
// is not the work queue.
//
// Delivery is `DispatchQueue.main.async` from that one serial queue, which is FIFO, which is what
// reset-then-diffs needs and an unstructured `Task` does not promise.
import Foundation
import EQCompanionCore

public final class LocalEngine: EngineLink, WorldSink, @unchecked Sendable {
    /// One dispatch at a time — the reader thread.
    private let work = DispatchQueue(label: "eqcompanion.engine.local.work")
    /// Every outbound frame, in one order — the writer thread.
    private let outbox = DispatchQueue(label: "eqcompanion.engine.local.outbox")
    /// Ids and the closed flag; a plain lock rather than a queue, because `allocateId` is called
    /// from the main actor while a dispatch is in flight.
    private let state = NSLock()

    private let world: World
    private var session: Session!
    private let onMessage: @Sendable (EngineMessage) -> Void

    private var nextId = 1
    private var closed = false

    /// Join the world and open the connection. `onMessage` receives every message that is not the
    /// answer to a request — stream frames and the connection-wide ones — on the MAIN queue, in
    /// arrival order.
    public init(world: World, onMessage: @escaping @Sendable (EngineMessage) -> Void) {
        self.world = world
        self.onMessage = onMessage
        // Two steps because joining hands the world a reference to this object: the stored
        // properties are all set before `self` escapes.
        session = nil
        session = Session(listener: world.join(self))
    }

    /// The app's own door: attach this link to a client and hand it every stream frame.
    ///
    /// `assumeIsolated` rather than a `Task`, so the frames reach the client synchronously on the
    /// main queue in the order they were enqueued — the epoch law's whole premise.
    @MainActor
    @discardableResult
    public static func attach(world: World, to client: EngineClient) -> LocalEngine {
        let link = LocalEngine(world: world) { message in
            MainActor.assumeIsolated { client.deliver(message) }
        }
        client.attach(link: link)
        return link
    }

    // MARK: - EngineLink

    /// Reserve a request id. Subscriptions need the id BEFORE the reply, because the stream frames
    /// carry it.
    public func allocateId() -> Int {
        state.lock()
        defer { state.unlock() }
        let id = nextId
        nextId += 1
        return id
    }

    /// Run one request through the op table and answer with its result, or throw its refusal.
    ///
    /// The deadline is a FAILURE mechanism, not a latency budget, and it is the socket link's own:
    /// a world that accepted a question and never answered must not hold its caller forever. The op
    /// itself keeps running — the world's doors are bounded and there is nothing to cancel — so the
    /// timeout settles the bookkeeping and nothing else.
    public func request(_ op: String, _ params: JSONValue = [:], id: Int? = nil,
                        deadline: TimeInterval = EngineLinkDefaults.deadline) async throws -> JSONValue {
        let rid = Int64(id ?? allocateId())
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<JSONValue, Error>) in
            let settled = Settled(cont)
            state.lock()
            let alreadyClosed = closed
            state.unlock()
            if alreadyClosed {
                settled.fail(EngineError.notConnected)
                return
            }
            work.async { [weak self] in
                guard let self else {
                    settled.fail(EngineError.notConnected)
                    return
                }
                self.run(id: rid, op: op, params: params, settled: settled)
            }
            // On its own queue, never the work queue: a deadline that waited behind the dispatch it
            // is timing would never fire.
            DispatchQueue.global().asyncAfter(deadline: .now() + deadline) {
                settled.fail(EngineError.timeout(op: op))
            }
        }
    }

    /// Fire-and-forget (an unsubscribe on the way out). The reply is discarded; the stream frames
    /// are not.
    public func post(_ op: String, _ params: JSONValue = [:]) {
        let rid = Int64(allocateId())
        state.lock()
        let alreadyClosed = closed
        state.unlock()
        if alreadyClosed { return }
        work.async { [weak self] in
            self?.run(id: rid, op: op, params: params, settled: nil)
        }
    }

    /// Leave the world, and with it every subscription this connection held.
    ///
    /// Idempotent: a connection can end in more than one way and the tidy-up path must not care
    /// which.
    public func close() {
        state.lock()
        let wasClosed = closed
        closed = true
        state.unlock()
        if wasClosed { return }
        world.leave(session.listener)
    }

    // MARK: - WorldSink

    /// A connection-wide announcement, or a stream frame for one of this connection's
    /// subscriptions. Called from the ingest thread; the outbox is what puts it in order.
    public func deliver(_ m: EngineMessage) {
        if !isOpen { return }
        enqueue(m)
    }

    /// Still worth talking to. A closed connection is dropped at the world's next broadcast.
    public var isOpen: Bool {
        state.lock()
        defer { state.unlock() }
        return !closed
    }

    // MARK: - Internals

    /// One dispatch, on the work queue.
    private func run(id: Int64, op: String, params: JSONValue, settled: Settled?) {
        state.lock()
        let alreadyClosed = closed
        state.unlock()
        if alreadyClosed {
            settled?.fail(EngineError.notConnected)
            return
        }
        switch Ops.dispatch(world, session, id: id, op: op, params: params) {
        case .close(let why):
            // No request id to hang an error on in the Rust, because the frame that ends a
            // connection is the one that carries none. Here the caller is holding a promise, so it
            // is told why before the link goes down.
            close()
            settled?.fail(EngineError.transport(why))
        case .send(let frames):
            var answer: Result<JSONValue, Error>?
            for frame in frames {
                let message = EngineMessage.parse(frame)
                switch message {
                case .reply(let replyId, let result) where Int64(replyId) == id && answer == nil:
                    answer = .success(result)
                case .error(let errorId, let refusal) where Int64(errorId) == id && answer == nil:
                    answer = .failure(EngineError.refused(refusal))
                default:
                    // Parsed once, on the work queue: a big frame is read off the main thread.
                    enqueue(message)
                }
            }
            switch answer {
            case .success(let result): settled?.succeed(result)
            case .failure(let error): settled?.fail(error)
            // The op table always answers the id it was asked about, so this is unreachable; a
            // request that somehow produced no reply is a timeout rather than a promise nobody
            // settles.
            case nil: break
            }
        }
    }

    /// Enqueue one message for the peer. Every frame this connection sends goes through here and
    /// through nothing else, which is what makes the order one order.
    private func enqueue(_ message: EngineMessage) {
        let deliver = onMessage
        outbox.async { DispatchQueue.main.async { deliver(message) } }
    }
}

/// A continuation that is resumed exactly once, whoever gets there first — the request's own answer
/// or its deadline.
private final class Settled: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<JSONValue, Error>?

    init(_ cont: CheckedContinuation<JSONValue, Error>) { self.cont = cont }

    func succeed(_ value: JSONValue) {
        lock.lock()
        let c = cont
        cont = nil
        lock.unlock()
        c?.resume(returning: value)
    }

    func fail(_ error: Error) {
        lock.lock()
        let c = cont
        cont = nil
        lock.unlock()
        c?.resume(throwing: error)
    }
}
