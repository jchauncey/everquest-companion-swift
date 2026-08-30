// The two small tools the corpora need and the shared Swift does not carry: a mutable JSON object
// write, and a thread-safe build-once box.
import Foundation
import EQCompanionCore

extension JSONValue {
    /// `value[key] = v` on an object, as `serde_json::Value`'s `IndexMut` spells it. A non-object is
    /// left alone rather than replaced: every record this crate writes to is an object by
    /// construction, and silently growing one out of a scalar would hide the bug that got us here.
    mutating func set(_ key: String, _ v: JSONValue) {
        guard case .object(var o) = self else { return }
        o[key] = v
        self = .object(o)
    }

    /// `map.entry(key).or_insert(v)` — states the omitted default and never overwrites a stated one.
    mutating func orInsert(_ key: String, _ v: JSONValue) {
        guard case .object(var o) = self, o[key] == nil else { return }
        o[key] = v
        self = .object(o)
    }

    mutating func remove(_ key: String) {
        guard case .object(var o) = self else { return }
        o.removeValue(forKey: key)
        self = .object(o)
    }

    /// True when the key is present at all, null included — `Value::get(k).is_some()`.
    func has(_ key: String) -> Bool {
        if case .object(let o) = self { return o[key] != nil }
        return false
    }
}

/// A build-once, read-many box: `OnceLock` with the same law — the closure runs at most once, every
/// reader after the first pays a lock and a read.
///
/// Every index in this crate hangs off one, because an attach must not pay for a corpus no client
/// has queried (the item corpus alone is 8.7 MB of JSON).
final class Lazy<T>: @unchecked Sendable {
    private let make: () -> T
    private var value: T?
    private let lock = NSLock()

    init(_ make: @escaping () -> T) { self.make = make }

    var get: T {
        lock.lock()
        defer { lock.unlock() }
        if let v = value { return v }
        let v = make()
        value = v
        return v
    }
}

/// Byte-wise `<` over two strings — Rust's `Ord for String`, which orders by UTF-8 bytes.
///
/// Swift's own `<` orders by canonical equivalence, which agrees for ASCII and does not in general;
/// the search ranking and the item index's key order are both ports of a Rust total order, so the
/// comparison is spelled the way Rust spells it.
func bytesLess(_ a: String, _ b: String) -> Bool {
    var ai = a.utf8.makeIterator(), bi = b.utf8.makeIterator()
    while true {
        switch (ai.next(), bi.next()) {
        case (nil, nil): return false
        case (nil, _): return true
        case (_, nil): return false
        case (let x?, let y?): if x != y { return x < y }
        }
    }
}
