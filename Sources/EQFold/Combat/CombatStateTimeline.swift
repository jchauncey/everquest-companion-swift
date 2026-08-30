// The active-state timeline — "what was on at time T", as an interval model with evidence on both
// edges (fold/src/combat/statetimeline.rs).
//
// It lives in the combat engine because `EngineState` already owns the stance/invocation pair and
// the coat slots. It is deliberately not merged with the encounter's own `stanceSpans`, which feeds
// the shipped timeline view: two lists, one shared writer, this one session-level and additive.
//
// Every edge is labeled, because the game prints a state's start and almost never its end. Only a
// printed line earns `observed`; a replacing sibling is `inferred`; a severed boundary is
// `censored` and never renders as an end time.
//
// `active` is a Set and its order is never published.
import Foundation
import EQCompanionCore

/// Memory bound only — a full log produces a few hundred commits — and drop-oldest.
public let STATE_SPAN_CAP: Int = 2_000

/// `shared/procAnalytics.ts StateKind`.
public enum StateKind: String, Sendable {
    case buff
    case invocation
    case stance
    case coat

    public var asStr: String { rawValue }
}

/// `shared/procAnalytics.ts EdgeEvidence`.
public enum EdgeEvidence: String, Sendable {
    case observed
    case inferred
    case censored
    case open
}

/// The join key a window ledger / link join uses: one string per active state.
public func stateKeyOf(_ kind: StateKind, _ key: String) -> String { "\(kind.asStr):\(key)" }

/// The span as the payload carries it — `shared/procAnalytics.ts StateSpan`.
public struct StateSpan: Sendable {
    public var kind: StateKind
    public var key: String
    public var name: String
    public var startTs: Int64
    /// Absent — never null — while the span is still open.
    public var endTs: Int64?
    public var startEvidence: EdgeEvidence
    public var endEvidence: EdgeEvidence

    public var json: JSONValue {
        var o: [String: JSONValue] = [
            "kind": .string(kind.rawValue),
            "key": .string(key),
            "name": .string(name),
            "startTs": .int(startTs),
            "startEvidence": .string(startEvidence.rawValue),
            "endEvidence": .string(endEvidence.rawValue),
        ]
        if let endTs { o["endTs"] = .int(endTs) }
        return .object(o)
    }
}

/// The engine-internal span record: the shared shape plus the exclusivity group, which is how an
/// unprinted end becomes an inferred one.
///
///   `stance` / `invocation` — mutually exclusive, so a new commit ends the previous span.
///   `coat:utility`          — one slot; a new utility coat replaces the old one.
///   `coat:combat:<line>`    — combat venoms stack, so each venom line is its own group.
///   `buff:<key>`            — a re-apply supersedes its own span; unrelated buffs coexist.
private struct SpanRecord {
    var span: StateSpan
    var group: String
}

/// Everything needed to open a span.
public struct OpenState {
    public var kind: StateKind
    /// Canonical join key, lowercased.
    public var key: String
    /// Display name, raw casing.
    public var name: String
    public var ts: Int64
    /// Exclusivity group; nil defaults to `<kind>:<key>` (self-exclusive).
    public var group: String?

    public init(kind: StateKind, key: String, name: String, ts: Int64, group: String? = nil) {
        self.kind = kind; self.key = key; self.name = name; self.ts = ts; self.group = group
    }
}

/// The session-level span ring plus its live open index.
public final class StateTimeline {
    private var spans: [SpanRecord] = []
    /// `<kind>:<key>` of every open span. Read-only to callers; mutated here only.
    public private(set) var active: Set<String> = []
    /// group → index of the one open span in that group; the exclusivity index.
    private var open: [String: Int] = [:]

    public init() {}

    public func reset() {
        spans.removeAll()
        active.removeAll()
        open.removeAll()
    }

    /// Open a span, closing whatever open span shares its exclusivity group as `inferred` — the only
    /// honest verdict when the game printed no end. Callers drop a no-op re-assert before reaching
    /// here, so this never accrues a zero-width span.
    public func noteState(_ a: OpenState) {
        let group = a.group ?? stateKeyOf(a.kind, a.key)
        if let prev = open[group] {
            finish(prev, a.ts, .inferred)
        }
        spans.append(SpanRecord(
            span: StateSpan(kind: a.kind, key: a.key, name: a.name, startTs: a.ts, endTs: nil,
                            startEvidence: .observed, endEvidence: .open),
            group: group
        ))
        if spans.count > STATE_SPAN_CAP { dropOldest() }
        open[group] = spans.count - 1
        active.insert(stateKeyOf(a.kind, a.key))
    }

    /// Close the open span for (kind, key) — the printed-end path. A close with nothing open is a
    /// no-op: the game can print a wears-off for a buff whose landing predates the replay.
    public func closeState(_ kind: StateKind, _ key: String, _ ts: Int64, _ evidence: EdgeEvidence) {
        let found = open.values.first { spans[$0].span.kind == kind && spans[$0].span.key == key }
        if let i = found { finish(i, ts, evidence) }
    }

    /// Close every open span in a group — the combat-coat dry line names the family, and the log
    /// cannot say which venom of a stack expired.
    public func closeGroupPrefix(_ prefix: String, _ ts: Int64, _ evidence: EdgeEvidence) {
        let hits = open.values.filter { spans[$0].group.hasPrefix(prefix) }
        for i in hits { finish(i, ts, evidence) }
    }

    /// A boundary severed every span: epoch, engine reset, player death. The end is unknowable, so
    /// it is `censored` and never a fabricated expiry. The spans stay in the ring.
    public func censorAll(_ ts: Int64) {
        let hits = Array(open.values)
        for i in hits { finish(i, ts, .censored) }
    }

    /// Spans that overlap `[fromTs, toTs]`, projected to the shared payload shape. An open span
    /// overlaps any window that ends after it started.
    public func spansOverlapping(_ fromTs: Int64, _ toTs: Int64) -> [StateSpan] {
        spans.filter { s in
            let endsAfter = s.span.endTs.map { $0 >= fromTs } ?? true
            return endsAfter && s.span.startTs <= toTs
        }.map(\.span)
    }

    private func finish(_ idx: Int, _ ts: Int64, _ evidence: EdgeEvidence) {
        spans[idx].span.endTs = ts
        spans[idx].span.endEvidence = evidence
        let group = spans[idx].group
        let key = stateKeyOf(spans[idx].span.kind, spans[idx].span.key)
        open.removeValue(forKey: group)
        active.remove(key)
    }

    /// Drop-oldest under the cap. A dropped span may still be the open one for its group — a
    /// permanent buff can outlive every later commit — so the open index is repaired rather than
    /// left pointing at a record no longer in the ring.
    private func dropOldest() {
        if spans.isEmpty { return }
        let gone = spans.removeFirst()
        if open[gone.group] == 0 {
            open.removeValue(forKey: gone.group)
            active.remove(stateKeyOf(gone.span.kind, gone.span.key))
        }
        for (k, i) in open { open[k] = i > 0 ? i - 1 : 0 }
    }
}
