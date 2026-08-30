// The value types that cross between modules, the engine, and the world — ports of the small
// shapes in fold/src/{knowledge.rs, combat/roster.rs, modules/consider.rs, modules/alerts_rules.rs,
// modules/resist/ledger_file.rs, message_overlay.rs}.
import Foundation
import EQCompanionCore

// MARK: - Roster (combat/roster.rs) — a shape and a pull seam; the roster module implements it.

public struct RosterMember: Sendable {
    public var key: String
    public var name: String
    public var source: String
    public var sinceTs: Int64
    public init(key: String, name: String, source: String, sinceTs: Int64) {
        self.key = key; self.name = name; self.source = source; self.sinceTs = sinceTs
    }
    public var json: JSONValue { ["key": .string(key), "name": .string(name), "source": .string(source), "sinceTs": .int(sinceTs)] }
}

public struct RosterSnap: Sendable {
    public var members: [RosterMember]
    public var seen: Bool
    public var lastSignalTs: Int64
    public init(members: [RosterMember], seen: Bool, lastSignalTs: Int64) {
        self.members = members; self.seen = seen; self.lastSignalTs = lastSignalTs
    }
    public static let empty = RosterSnap(members: [], seen: false, lastSignalTs: 0)
    public var json: JSONValue { ["members": .array(members.map(\.json)), "seen": .bool(seen), "lastSignalTs": .int(lastSignalTs)] }
}

public protocol RosterSource: AnyObject {
    func snap() -> RosterSnap
    func members() -> [String]
    func admitted() -> [String]
    func nameOf(_ key: String) -> String?
}

public extension RosterSource {
    func members() -> [String] { [] }
    func admitted() -> [String] { [] }
    func nameOf(_ key: String) -> String? { snap().members.first { $0.key == key }?.name }
}

// MARK: - Knowledge (knowledge.rs)

public struct SeenDrop: Equatable, Sendable {
    public var item: String
    public var count: Int64
    public var lastTs: Int64
    public init(item: String, count: Int64, lastTs: Int64) { self.item = item; self.count = count; self.lastTs = lastTs }
}

public protocol OwnLoot: AnyObject {
    func dropsAcross(_ spellings: [String]) -> [SeenDrop]
}

public final class NoOwnLoot: OwnLoot {
    public init() {}
    public func dropsAcross(_ spellings: [String]) -> [SeenDrop] { [] }
}

public struct KnowledgeAnswer: Sendable {
    public var record: JSONValue
    public var found: Bool
    public init(record: JSONValue, found: Bool) { self.record = record; self.found = found }
}

public struct KnowledgeMiss: Equatable, Sendable {
    public var domain: String
    public var name: String
    public init(domain: String, name: String) { self.domain = domain; self.name = name }
}

/// What a module may ask of the corpora. The concrete corpus lives in EQKnowledge.
public protocol Knowledge: AnyObject, Sendable {
    func item(_ name: String) -> KnowledgeAnswer
    func identityKeys(_ mob: String) -> [String]
    func mob(_ name: String, loot: OwnLoot) -> KnowledgeAnswer
    func knownMob(_ name: String) -> Bool
    func takeMisses() -> [KnowledgeMiss]
}

// MARK: - Live products the ingest drains (consider.rs ConEvent, alerts_rules.rs Fire)

public struct ConEvent: Sendable {
    public var ts: Int64
    public var mob: String
    public var level: Int64?
    public var rare: Bool
    public var zone: String?
    public init(ts: Int64, mob: String, level: Int64?, rare: Bool, zone: String?) {
        self.ts = ts; self.mob = mob; self.level = level; self.rare = rare; self.zone = zone
    }
}

public struct Fire: Sendable {
    public var at: Int64
    public var rule: String
    public var sound: String
    public var message: String
    public var captures: [String: String]?
    public var spell: String?
    public var dueAt: Int64?
    public init(at: Int64, rule: String, sound: String, message: String, captures: [String: String]?, spell: String?, dueAt: Int64?) {
        self.at = at; self.rule = rule; self.sound = sound; self.message = message; self.captures = captures; self.spell = spell; self.dueAt = dueAt
    }
}

// MARK: - Persisted knowledge (resist ledger + message overlay), as JSON the owners read/write.

/// One source's resist rows, as the ledger file stores them (`{key, rows:[...]}`).
public struct LedgerSource: Sendable {
    public var key: String
    public var rows: [JSONValue]
    public init(key: String, rows: [JSONValue]) { self.key = key; self.rows = rows }
}

/// One seed message for the overlay register, as the persisted file stores it.
public typealias SeedMessage = JSONValue

public struct PersistedState: Sendable {
    public var resist: [LedgerSource] = []
    public var overlay: [(String, [SeedMessage])] = []
    public init() {}
}
