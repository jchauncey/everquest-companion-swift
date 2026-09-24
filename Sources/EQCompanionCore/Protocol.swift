// The wire contract, as this client reads it. Mirrors `protocol/schema/*.json` (x-protocolVersion 1).
//
// Every client message is an object with `op` (and `id` + `params` for a request); every engine
// message is tagged on `kind`. Stream messages (`reset`/`diff`) carry the id of the subscribe that
// opened them; the connection-wide ones (`epoch`, `fire`, `conCard`, `knowledgeMiss`,
// `moduleChanged`) carry no id. Payload shapes the schema leaves open stay `JSONValue`.
import Foundation

public let protocolVersion = 1

/// One render-ready row: its key and its cells. The key lives outside the cells so a reset row and
/// a diff update apply the same way.
public struct Row: Sendable, Equatable, Identifiable {
    public var key: String
    public var cells: [String: JSONValue]

    public var id: String { key }

    public init(key: String, cells: [String: JSONValue]) {
        self.key = key
        self.cells = cells
    }

    public subscript(cell: String) -> JSONValue { cells[cell] ?? .null }

    public func string(_ cell: String) -> String { self[cell].display }

    static func parse(_ v: JSONValue) -> Row? {
        guard let key = v["key"].string, let cells = v["cells"].object else { return nil }
        return Row(key: key, cells: cells)
    }
}

public enum SortDirection: String, Sendable, Hashable {
    case asc, desc
}

/// The whole query. Filtering, sorting and windowing are stated here and performed engine-side.
public struct ViewDescriptor: Sendable, Hashable {
    public var source: String
    public var filter: [String: JSONValue]
    public var sort: [(field: String, direction: SortDirection)]
    public var window: (offset: Int, limit: Int)?

    public init(source: String,
                filter: [String: JSONValue] = [:],
                sort: [(String, SortDirection)] = [],
                window: (offset: Int, limit: Int)? = nil) {
        self.source = source
        self.filter = filter
        self.sort = sort.map { (field: $0.0, direction: $0.1) }
        self.window = window
    }

    public func toJSON() -> JSONValue {
        var o: [String: JSONValue] = ["source": .string(source)]
        if !filter.isEmpty { o["filter"] = .object(filter) }
        if !sort.isEmpty {
            o["sort"] = .array(sort.map { .array([.string($0.field), .string($0.direction.rawValue)]) })
        }
        if let w = window {
            o["window"] = .object(["offset": .int(Int64(w.offset)), "limit": .int(Int64(w.limit))])
        }
        return .object(o)
    }

    /// Identity for dedupe and hashing: the fields in a fixed order.
    public var key: String { toJSON().serializedString() }

    public static func == (a: ViewDescriptor, b: ViewDescriptor) -> Bool { a.key == b.key }
    public func hash(into hasher: inout Hasher) { hasher.combine(key) }
}

public struct FoldProgress: Sendable, Equatable {
    public var pct: Double
    public var events: Int
    public var offset: Int64
    public var logSize: Int64
    /// Absent (false) means the historical scan; true means the live tail's own frames.
    public var live: Bool

    /// The in-process engine builds these; the socket client parses them. Both need the memberwise
    /// initializer, so it is spelled rather than synthesized-internal.
    public init(pct: Double, events: Int, offset: Int64, logSize: Int64, live: Bool) {
        self.pct = pct
        self.events = events
        self.offset = offset
        self.logSize = logSize
        self.live = live
    }

    static func parse(_ v: JSONValue) -> FoldProgress? {
        guard let pct = v["pct"].double else { return nil }
        return FoldProgress(pct: pct,
                            events: v["events"].int ?? 0,
                            offset: v["offset"].int64 ?? 0,
                            logSize: v["logSize"].int64 ?? 0,
                            live: v["live"].bool ?? false)
    }
}

/// An alert fired against a live event.
public struct FireMessage: Sendable, Equatable, Identifiable {
    public var at: Int64
    public var rule: String
    public var sound: String
    public var message: String
    public var captures: [String: String]
    public var spell: String?
    public var dueAt: Int64?
    public var id: String { "\(at)|\(rule)|\(message)" }

    public init(at: Int64, rule: String, sound: String, message: String, captures: [String: String],
                spell: String?, dueAt: Int64?) {
        self.at = at
        self.rule = rule
        self.sound = sound
        self.message = message
        self.captures = captures
        self.spell = spell
        self.dueAt = dueAt
    }

    static func parse(_ v: JSONValue) -> FireMessage? {
        guard let rule = v["rule"].string else { return nil }
        var caps: [String: String] = [:]
        if let o = v["captures"].object {
            for (k, val) in o { caps[k] = val.display }
        }
        return FireMessage(at: v["at"].int64 ?? 0,
                           rule: rule,
                           sound: v["sound"].string ?? "",
                           message: v["message"].string ?? "",
                           captures: caps,
                           spell: v["spell"].string,
                           dueAt: v["dueAt"].int64)
    }
}

public enum DiffOp: Sendable, Equatable {
    case insert(row: Row, before: String?, after: String?)
    case update(key: String, cells: [String: JSONValue])
    case drop(key: String)

    static func parse(_ v: JSONValue) -> DiffOp? {
        switch v["op"].string {
        case "insert":
            guard let row = Row.parse(v["row"]) else { return nil }
            return .insert(row: row, before: v["before"].string, after: v["after"].string)
        case "update":
            guard let key = v["key"].string, let cells = v["cells"].object else { return nil }
            return .update(key: key, cells: cells)
        case "drop":
            guard let key = v["key"].string else { return nil }
            return .drop(key: key)
        default:
            return nil
        }
    }
}

public struct ProtocolError: Error, Sendable, Equatable, CustomStringConvertible {
    public var code: String
    public var message: String
    public init(code: String, message: String) { self.code = code; self.message = message }
    public var description: String { "\(code): \(message)" }
}

/// Every message the engine sends, tagged on `kind`.
public enum EngineMessage: Sendable {
    case hello(ok: Bool, engineVersion: String, protocolVersion: Int)
    case reply(id: Int, result: JSONValue)
    case error(id: Int, error: ProtocolError)
    case reset(id: Int, epoch: Int, total: Int, rows: [Row])
    case diff(id: Int, epoch: Int, total: Int?, ops: [DiffOp])
    case epoch(epoch: Int, reason: String, progress: FoldProgress?)
    case fire(FireMessage)
    case knowledgeMiss(domain: String, name: String)
    case conCard(JSONValue)
    case moduleChanged(module: String, seq: Int)
    case unknown(JSONValue)

    public static func parse(_ v: JSONValue) -> EngineMessage {
        switch v["kind"].string {
        case "hello":
            return .hello(ok: v["ok"].bool ?? false,
                          engineVersion: v["engineVersion"].string ?? "",
                          protocolVersion: v["protocolVersion"].int ?? 0)
        case "reply":
            guard let id = v["id"].int else { return .unknown(v) }
            return .reply(id: id, result: v["result"])
        case "error":
            guard let id = v["id"].int else { return .unknown(v) }
            let e = v["error"]
            return .error(id: id, error: ProtocolError(code: e["code"].string ?? "internal",
                                                       message: e["message"].string ?? ""))
        case "reset":
            guard let id = v["id"].int, let epoch = v["epoch"].int else { return .unknown(v) }
            let rows = (v["rows"].array ?? []).compactMap(Row.parse)
            return .reset(id: id, epoch: epoch, total: v["total"].int ?? rows.count, rows: rows)
        case "diff":
            guard let id = v["id"].int, let epoch = v["epoch"].int else { return .unknown(v) }
            let ops = (v["ops"].array ?? []).compactMap(DiffOp.parse)
            return .diff(id: id, epoch: epoch, total: v["total"].int, ops: ops)
        case "epoch":
            guard let epoch = v["epoch"].int else { return .unknown(v) }
            return .epoch(epoch: epoch, reason: v["reason"].string ?? "", progress: FoldProgress.parse(v["progress"]))
        case "fire":
            guard let f = FireMessage.parse(v) else { return .unknown(v) }
            return .fire(f)
        case "knowledgeMiss":
            return .knowledgeMiss(domain: v["domain"].string ?? "", name: v["name"].string ?? "")
        case "conCard":
            return .conCard(v)
        case "moduleChanged":
            return .moduleChanged(module: v["module"].string ?? "", seq: v["seq"].int ?? 0)
        default:
            return .unknown(v)
        }
    }
}

/// The client → engine envelope.
public enum ClientMessage {
    public static func hello(token: String) -> JSONValue {
        ["op": "hello", "token": .string(token), "protocolVersion": .int(Int64(protocolVersion))]
    }

    public static func request(id: Int, op: String, params: JSONValue) -> JSONValue {
        ["id": .int(Int64(id)), "op": .string(op), "params": params.isNull ? [:] : params]
    }
}

/// The op names this client uses, spelled once.
public enum Op {
    public static let echo = "echo"
    public static let sessionAttach = "session.attach"
    public static let sessionHealth = "session.health"
    public static let sessionProgress = "session.progress"
    public static let sessionMarkAdd = "sessionMarks.add"
    public static let moduleSnapshot = "module.snapshot"
    public static let perfSnapshot = "perf.snapshot"
    public static let perfBudgets = "perf.budgets"
    public static let perfTimeline = "perf.timeline"
    public static let viewSubscribe = "view.subscribe"
    public static let viewUnsubscribe = "view.unsubscribe"
    public static let alertsDefine = "alerts.define"
    public static let buffTrustDefine = "buffTrust.define"
    public static let respawnDefine = "respawn.define"
    public static let respawnConfirmSighting = "respawn.confirmSighting"
    public static let comboDefine = "combo.define"
    public static let rosterDefine = "roster.define"
    public static let combatSnapshot = "combat.snapshot"
    public static let combatSearchFights = "combat.searchFights"
    public static let logWindow = "log.window"
    public static let combatReplay = "combat.replay"
    public static let combatRewards = "combat.rewards"
    public static let combatPetLog = "combat.petLog"
    public static let combatLaneClasses = "combat.laneClasses"
    public static let knowledgeItem = "knowledge.item"
    public static let knowledgeMob = "knowledge.mob"
    public static let knowledgeSpell = "knowledge.spell"
    public static let knowledgeSearch = "knowledge.search"
    public static let knowledgeDefine = "knowledge.define"
    public static let resistLevels = "resist.levels"
    public static let resistSpell = "resist.spell"
    public static let spellsSearch = "spells.search"
    public static let logsSetDir = "logs.setDir"
    public static let logsList = "logs.list"
}

/// The announce line the engine prints on stdout: `EQC-ENGINE PORT=<port> PROTOCOL=<version>`.
public struct Announce: Sendable, Equatable {
    public var port: UInt16
    public var protocolVersion: Int

    /// Anchored and total: a binary that prints anything else on stdout is not the engine we asked
    /// for. A literal `PORT=0` is refused — the kernel never hands out port 0.
    public static func parse(_ line: String) -> Announce? {
        var s = line
        if s.hasSuffix("\r") { s.removeLast() }
        let parts = s.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "EQC-ENGINE",
              parts[1].hasPrefix("PORT="), parts[2].hasPrefix("PROTOCOL=") else { return nil }
        let portText = parts[1].dropFirst("PORT=".count)
        let protoText = parts[2].dropFirst("PROTOCOL=".count)
        guard portText.count <= 5, protoText.count <= 9,
              portText.allSatisfy(\.isNumber), protoText.allSatisfy(\.isNumber),
              let port = UInt16(portText), port > 0, let proto = Int(protoText) else { return nil }
        return Announce(port: port, protocolVersion: proto)
    }
}
