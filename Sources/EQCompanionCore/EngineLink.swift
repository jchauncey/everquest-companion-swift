// The transport seam `EngineClient` talks through, and the client's vocabulary for an engine that
// cannot answer. The only implementation is the in-process engine (`EQEngine.LocalEngine`).
import Foundation

public enum ConnectionState: Sendable, Equatable {
    case connecting
    case ready
    case closed
    case failed(String)
}

public enum EngineError: Error, CustomStringConvertible, Sendable {
    case notConnected
    case timeout(op: String)
    case refused(ProtocolError)
    case handshake(String)
    case transport(String)

    public var description: String {
        switch self {
        case .notConnected: return "the engine is not connected"
        case .timeout(let op): return "\(op) did not answer in time"
        case .refused(let e): return e.description
        case .handshake(let s): return "handshake failed: \(s)"
        case .transport(let s): return "connection failed: \(s)"
        }
    }
}

/// What `EngineClient` needs from a transport: correlated requests, fire-and-forget posts, and
/// stream frames delivered on the MAIN queue in arrival order (through `EngineClient.deliver`).
public protocol EngineLink: AnyObject {
    func allocateId() -> Int
    func request(_ op: String, _ params: JSONValue, id: Int?, deadline: TimeInterval) async throws -> JSONValue
    func post(_ op: String, _ params: JSONValue)
    func close()
}

public enum EngineLinkDefaults {
    /// A failure mechanism, not a latency budget: well above the engine's own 5 s ask patience.
    public static let deadline: TimeInterval = 20
}

public extension EngineLink {
    func request(_ op: String, _ params: JSONValue = [:], deadline: TimeInterval = EngineLinkDefaults.deadline) async throws -> JSONValue {
        try await request(op, params, id: nil, deadline: deadline)
    }
}

/// Why the engine is not answering, for the failure card.
public enum EngineFaultKind: String, Sendable {
    case startFailed = "start-failed"
    case unhealthy
}

public struct EngineFault: Sendable, Equatable {
    public var kind: EngineFaultKind
    public var attempts: Int
    public var detail: String?
    public init(kind: EngineFaultKind, attempts: Int, detail: String?) {
        self.kind = kind; self.attempts = attempts; self.detail = detail
    }
}
