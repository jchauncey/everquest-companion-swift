// A `Map` with JavaScript's iteration order: insertion order, a re-insert keeps its place, a
// delete closes the gap (fold/src/jsmap.rs). Snapshots serialize in this order.
import Foundation
import EQCompanionCore

public struct JSMap<V> {
    private var entries: [(String, V)] = []
    private var at: [String: Int] = [:]

    public init() {}

    public var count: Int { entries.count }
    public var isEmpty: Bool { entries.isEmpty }
    public func containsKey(_ k: String) -> Bool { at[k] != nil }

    public subscript(key: String) -> V? {
        get { at[key].map { entries[$0].1 } }
        set {
            if let v = newValue { insert(key, v) } else { _ = remove(key) }
        }
    }

    public mutating func clear() { entries.removeAll(); at.removeAll() }

    public mutating func insert(_ key: String, _ value: V) {
        if let i = at[key] { entries[i].1 = value } else {
            at[key] = entries.count
            entries.append((key, value))
        }
    }

    /// Mutate in place; the closure sees nil for an absent key and returns the value to store.
    public mutating func update(_ key: String, _ f: (inout V?) -> Void) {
        var v = self[key]
        f(&v)
        self[key] = v
    }

    @discardableResult
    public mutating func remove(_ key: String) -> Bool {
        guard let i = at.removeValue(forKey: key) else { return false }
        entries.remove(at: i)
        for (k, slot) in at where slot > i { at[k] = slot - 1 }
        return true
    }

    public var keys: [String] { entries.map(\.0) }
    public var values: [V] { entries.map(\.1) }
    public var pairs: [(String, V)] { entries }

    public mutating func mutateValues(_ f: (inout V) -> Void) {
        for i in entries.indices { f(&entries[i].1) }
    }

    // MARK: - Checkpoint

    /// The map for a checkpoint: an ARRAY of [key, value] pairs, because insertion order IS state
    /// here — snapshots serialize in it, and a restore that lost it would publish rows reordered.
    /// (`json(_:)` cannot be the codec: a JSON object forgets the order.)
    public func checkpoint(_ enc: (V) -> JSONValue) -> JSONValue {
        .array(entries.map { .array([.string($0.0), enc($0.1)]) })
    }

    /// Rebuild from `checkpoint(_:)`, order intact. Nil when any pair is malformed or any value
    /// refuses to decode — a half-map is not a map.
    public static func fromCheckpoint(_ v: JSONValue, _ dec: (JSONValue) -> V?) -> JSMap<V>? {
        guard let rows = v.array else { return nil }
        var m = JSMap<V>()
        for row in rows {
            guard let key = row[0].string, let value = dec(row[1]) else { return nil }
            m.insert(key, value)
        }
        return m
    }

    /// Serialize with a per-value encoder, in JS order.
    public func json(_ enc: (V) -> JSONValue) -> JSONValue {
        // JSONValue.object is a Swift dictionary; order is lost there, which is fine: deep equality
        // is the parity bar. `orderedKeys` is kept for the views that need the JS order.
        var o: [String: JSONValue] = [:]
        for (k, v) in entries { o[k] = enc(v) }
        return .object(o)
    }
}
