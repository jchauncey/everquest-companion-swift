// Deep equality over JSON with a readable first-divergence path — the fold's parity bar. Numbers
// compare by value (an int and an integral double are equal); floats that differ within 1e-9
// relative are reported as `approx` rather than as a mismatch.
import Foundation
import EQCompanionCore

public enum SnapshotDiff {
    public struct Report {
        public var mismatches: [String] = []
        public var approx: [String] = []
        public var isEqual: Bool { mismatches.isEmpty }
    }

    public static func compare(golden: JSONValue, ours: JSONValue, path: String = "$", limit: Int = 20) -> Report {
        var r = Report()
        walk(golden, ours, path, &r, limit)
        return r
    }

    private static func walk(_ g: JSONValue, _ o: JSONValue, _ path: String, _ r: inout Report, _ limit: Int) {
        if r.mismatches.count >= limit { return }
        switch (g, o) {
        case (.null, .null): return
        case (.bool(let a), .bool(let b)): if a != b { r.mismatches.append("\(path): golden \(a) ours \(b)") }
        case (.string(let a), .string(let b)): if a != b { r.mismatches.append("\(path): golden \(short(a)) ours \(short(b))") }
        case (.int, .int), (.int, .double), (.double, .int), (.double, .double):
            let a = g.double!, b = o.double!
            if a == b { return }
            let scale = max(abs(a), abs(b), 1e-300)
            if abs(a - b) / scale < 1e-9 { r.approx.append("\(path): \(a) vs \(b)") } else { r.mismatches.append("\(path): golden \(a) ours \(b)") }
        case (.array(let a), .array(let b)):
            if a.count != b.count { r.mismatches.append("\(path): golden has \(a.count) items, ours \(b.count)") }
            for i in 0..<min(a.count, b.count) { walk(a[i], b[i], "\(path)[\(i)]", &r, limit) }
        case (.object(let a), .object(let b)):
            for k in Set(a.keys).union(b.keys).sorted() {
                switch (a[k], b[k]) {
                case (nil, let v?): r.mismatches.append("\(path).\(k): ours has an extra key (\(short(v.display)))")
                case (let v?, nil): r.mismatches.append("\(path).\(k): missing in ours (golden \(short(v.display)))")
                case (let x?, let y?): walk(x, y, "\(path).\(k)", &r, limit)
                default: break
                }
            }
        default:
            r.mismatches.append("\(path): golden \(short(g.serializedString())) ours \(short(o.serializedString()))")
        }
    }

    private static func short(_ s: String) -> String { s.count > 120 ? String(s.prefix(117)) + "..." : s }
}
