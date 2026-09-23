// `src/main/data/messageOverlay.ts` — the observed-message overlay, mined as the log folds.
//
// As the buffs model folds the log, every player cast (`observeCast`) and every candidate message
// line (`observeMessage`) is fed here. The overlay counts the association between a message and the
// spell being cast when it appeared, keyed by (messageText, spellKey), and derives a per-message
// verdict:
//
//   verified         — the message consistently follows exactly one spell (n >= 2).
//   shared           — the message follows several spells, so it cannot name one on its own.
//   contradicts-wiki — the observed pairing differs from spells.json's `msg_*`.
//   unknown          — too few observations to judge.
//
// A message is associated with a cast only when exactly one distinct spell was cast in the window.
//
// Every count is filed under the source that produced it, one bucket per origin: `merge` files an
// import under its key, `beginSource(key)` discards that key's bucket and points subsequent
// observations at it, and `build` sums the buckets. That is what makes a re-fold replace a log's
// contribution instead of adding to it.
//
// Sorting is by codepoint order everywhere, never `localeCompare`.
// (fold/src/message_overlay.rs)
import Foundation
import EQLog
import EQData
import EQCompanionCore

/// Overlay schema version — bump to invalidate a stale on-disk snapshot.
public let overlayVersion: Int64 = 1

/// `OverlayCounts` — what a seed carries: a message's text, its role, and per-spell counts. A
/// verdict is never imported; it is derived, every time, from the summed buckets.
public struct OverlaySeedMessage {
    public var text: String
    public var role: String
    public var spells: [(String, Int64)]
    public init(text: String, role: String, spells: [(String, Int64)]) {
        self.text = text; self.role = role; self.spells = spells
    }
}

/// The bucket observations land in when nobody named a source.
public let overlayDefaultSource = "log"

/// The bucket the committed baseline's counts are filed under. Never a character id.
public let overlayBaselineSource = "baseline"

/// How long after a cast a message line is attributed to it. Mirrors the landing window.
private let associationWindowMs: Int64 = 6_000

/// Minimum observations before a message earns a verdict other than unknown.
private let minObservations: Int64 = 2

enum Verdict: String {
    case contradicts = "contradicts-wiki"
    case verified
    case shared
    case unknown

    /// Densest / most-informative first: contradictions, then verified, then shared, then unknown.
    var rank: Int {
        switch self {
        case .contradicts: return 0
        case .verified: return 1
        case .shared: return 2
        case .unknown: return 3
        }
    }
}

/// A pending cast the overlay may still associate messages with.
private struct RecentCast {
    var spellKey: String
    var spellDisplay: String
    var ts: Int64
}

struct SpellCount {
    var display: String
    var count: Int64
}

/// Accumulated per-message association counts. `bySpell` is keyed by canonical spell key, and its
/// insertion order is load-bearing: `verdictFor` reads the first entry unsorted and `aggregate`
/// walks it.
final class MessageRecord {
    var text: String
    var role: String
    var bySpell = JSMap<SpellCount>()
    init(text: String, role: String) { self.text = text; self.role = role }
}

/// One message's raw counts, as the register files them.
public struct OverlayMessageCounts {
    public var text: String
    /// `'landing' | 'wearsOff'`.
    public var role: String
    public var spells: [OverlaySpellCount]
}

/// One spell's count under a message. The display name, never the canon key.
public struct OverlaySpellCount {
    public var spell: String
    public var count: Int64
}

/// One source's bucket — `OverlaySourceCounts`.
public struct OverlaySourceCounts {
    /// Which origin produced these counts: a character id, or the committed baseline's key.
    public var key: String
    public var messages: [OverlayMessageCounts]
}

/// The whole register: every bucket, plus the log instant the miner has observed through.
public struct OverlayRegister {
    public var updatedAt: String
    public var sources: [OverlaySourceCounts]
}

/// The mining accumulator + verdict derivation. Dependency-free and pure over its inputs.
public final class MessageOverlayMiner {
    /// sourceKey → (messageText → record). Insertion order is merge order then fold order, and
    /// every serialization sorts.
    private var sources = JSMap<JSMap<MessageRecord>>()
    /// Which bucket `observeMessage` writes into — the log currently being folded.
    private var current = overlayDefaultSource
    /// The most-recent cast(s) still inside the association window (newest last).
    private var recentCasts: [RecentCast] = []
    /// The newest log instant this miner has observed, and the overlay's `updatedAt`. Never a wall
    /// clock. Zero before the first observation — a merged baseline carries counts and no instants.
    private var lastObservedTs: Int64 = 0
    /// The catalog, for contradiction detection only. An empty one is the TS's absent `db?.byKey`.
    private let facts: SpellFacts

    public init(facts: SpellFacts) { self.facts = facts }

    private func bucket(_ key: String) -> JSMap<MessageRecord> {
        if let b = sources[key] { return b }
        let b = JSMap<MessageRecord>()
        sources.insert(key, b)
        return b
    }

    /// Start folding `key`'s log from the first byte. Whatever this source contributed before is
    /// discarded, because the fold that follows is about to state it again. Re-inserting keeps the
    /// existing key's position.
    public func beginSource(_ key: String) {
        sources.insert(key, JSMap<MessageRecord>())
        current = key
        recentCasts.removeAll()
    }

    /// Merge imported counts into one bucket, additive within that bucket. `sourceKey` is what
    /// `beginSource` needs in order to replace them when that origin is folded again.
    public func merge(_ counts: [OverlaySeedMessage], _ sourceKey: String) {
        var into = bucket(sourceKey)
        for c in counts {
            if into[c.text] == nil { into.insert(c.text, MessageRecord(text: c.text, role: c.role)) }
            if let rec = into[c.text] { addCounts(rec, c.spells) }
        }
        sources.insert(sourceKey, into)
    }

    /// Record that the player began casting a spell (the association anchor).
    public func observeCast(_ spellDisplay: String, _ ts: Int64) {
        expire(ts)
        if ts > lastObservedTs { lastObservedTs = ts }
        recentCasts.append(RecentCast(spellKey: Names.dbCanonKey(spellDisplay),
                                      spellDisplay: spellDisplay, ts: ts))
    }

    /// Record a candidate message line and associate it with the recent cast, but only when the
    /// anchor is unambiguous: exactly one distinct spell cast in the window.
    public func observeMessage(_ text: String, _ ts: Int64, _ role: String) {
        expire(ts)
        if ts > lastObservedTs { lastObservedTs = ts }
        if recentCasts.isEmpty { return }
        let first = recentCasts[0].spellKey
        if recentCasts.contains(where: { $0.spellKey != first }) { return }
        let cast = recentCasts[recentCasts.count - 1]
        let castKey = cast.spellKey
        let castDisplay = cast.spellDisplay
        var into = bucket(current)
        if into[text] == nil { into.insert(text, MessageRecord(text: text, role: role)) }
        if let rec = into[text] {
            if var s = rec.bySpell[castKey] {
                s.count += 1
                rec.bySpell.insert(castKey, s)
            } else {
                rec.bySpell.insert(castKey, SpellCount(display: castDisplay, count: 1))
            }
        }
        sources.insert(current, into)
    }

    /// Drop casts that have aged out of the association window.
    private func expire(_ now: Int64) {
        if recentCasts.isEmpty { return }
        recentCasts.removeAll { now - $0.ts > associationWindowMs }
    }

    /// Every bucket's counts, sorted — what persistence writes and re-seeds from.
    ///
    /// Three separate ordering claims: `sources` in insertion order and deliberately unsorted,
    /// `messages` by codepoint on `text`, `spells` by codepoint on `spell`.
    public func register() -> OverlayRegister {
        var out: [OverlaySourceCounts] = []
        for (key, bucket) in sources.pairs {
            var messages: [OverlayMessageCounts] = bucket.values.map { rec in
                var spells = rec.bySpell.values.map { OverlaySpellCount(spell: $0.display, count: $0.count) }
                spells.sort { BuffsShapes.codepointLess($0.spell, $1.spell) }
                return OverlayMessageCounts(text: rec.text, role: rec.role, spells: spells)
            }
            messages.sort { BuffsShapes.codepointLess($0.text, $1.text) }
            out.append(OverlaySourceCounts(key: key, messages: messages))
        }
        return OverlayRegister(updatedAt: isoUTC(lastObservedTs), sources: out)
    }

    /// All buckets summed into one accumulator — the view every verdict is derived from.
    private func aggregate() -> [MessageRecord] {
        var out = JSMap<MessageRecord>()
        for bucket in sources.values {
            for rec in bucket.values {
                if out[rec.text] == nil { out.insert(rec.text, MessageRecord(text: rec.text, role: rec.role)) }
                guard let agg = out[rec.text] else { continue }
                addCounts(agg, rec.bySpell.values.map { ($0.display, $0.count) })
            }
        }
        return out.values
    }

    /// Derive a message's verdict from its per-spell counts + the DB (for contradictions).
    private func verdictFor(_ rec: MessageRecord, _ total: Int64) -> (Verdict, (String, String)?) {
        if rec.bySpell.count >= 2 { return (.shared, nil) }
        if total < minObservations { return (.unknown, nil) }
        // Exactly one spell, seen >= 2x: verified, unless it contradicts the wiki's `msg_*`.
        guard let only = rec.bySpell.values.first else { return (.verified, nil) }
        guard let dbSpell = facts.get(Names.dbCanonKey(only.display)) else { return (.verified, nil) }
        if rec.role == "landing" {
            // A landing line can be the self form or the on-other form. Matching either is
            // consistent with the wiki; only a line matching neither is a genuine inaccuracy.
            if dbSpell.msgCastOnYou == rec.text { return (.verified, nil) }
            if let suffix = dbSpell.msgCastOnOtherSuffix, messageMatchesOtherSuffix(rec.text, suffix) {
                return (.verified, nil)
            }
            // The DB has a self message and a different self-shaped line was observed: a
            // contradiction. No self message at all: a newly verified landing message.
            if let you = dbSpell.msgCastOnYou { return (.contradicts, (only.display, you)) }
            return (.verified, nil)
        }
        // The wears-off role.
        if let wiki = dbSpell.msgWearsOff, wiki != rec.text {
            return (.contradicts, (only.display, wiki))
        }
        return (.verified, nil)
    }

    /// Build the served overlay from the current accumulator.
    public func build() -> JSONValue {
        var messages: [(text: String, role: String, verdict: Verdict, spells: [OverlaySpellCount],
                        total: Int64, wikiConflict: (String, String)?)] = []
        var verified: Int64 = 0, shared: Int64 = 0, contradictions: Int64 = 0, unknown: Int64 = 0
        for rec in aggregate() {
            var spells = rec.bySpell.values.map { OverlaySpellCount(spell: $0.display, count: $0.count) }
            // `b.count - a.count || byCodepoint(a.spell, b.spell)`.
            spells.sort { a, b in
                a.count != b.count ? a.count > b.count : BuffsShapes.codepointLess(a.spell, b.spell)
            }
            let total = spells.reduce(Int64(0)) { $0 + $1.count }
            let (verdict, wikiConflict) = verdictFor(rec, total)
            switch verdict {
            case .verified: verified += 1
            case .shared: shared += 1
            case .contradicts: contradictions += 1
            case .unknown: unknown += 1
            }
            messages.append((rec.text, rec.role, verdict, spells, total, wikiConflict))
        }
        messages.sort { a, b in
            if a.verdict.rank != b.verdict.rank { return a.verdict.rank < b.verdict.rank }
            if a.total != b.total { return a.total > b.total }
            return BuffsShapes.codepointLess(a.text, b.text)
        }
        let rows: [JSONValue] = messages.map { m in
            var o: [String: JSONValue] = [
                "text": .string(m.text),
                "role": .string(m.role),
                "verdict": .string(m.verdict.rawValue),
                "spells": .array(m.spells.map { ["spell": .string($0.spell), "count": .int($0.count)] }),
                "total": .int(m.total),
            ]
            if let w = m.wikiConflict {
                o["wikiConflict"] = ["spell": .string(w.0), "wikiText": .string(w.1)]
            }
            return .object(o)
        }
        return [
            "version": .int(overlayVersion),
            // The log's clock, not the machine's.
            "updatedAt": .string(isoUTC(lastObservedTs)),
            "messages": .array(rows),
            "stats": ["verified": .int(verified), "shared": .int(shared),
                      "contradictions": .int(contradictions), "unknown": .int(unknown)],
        ]
    }

    // MARK: - Checkpoint

    /// The whole accumulator, bucket structure intact: `sources` and each bucket's insertion order
    /// are load-bearing (`verdictFor` reads the first `bySpell` entry unsorted), `current` names
    /// the bucket the next observation lands in, and `recentCasts` is the association anchor a
    /// checkpoint can land in the middle of. `facts` is a constructor dependency.
    func checkpointState() -> JSONValue {
        .object([
            "sources": sources.checkpoint { bucket in
                bucket.checkpoint { rec in
                    .object(["text": .string(rec.text), "role": .string(rec.role),
                             "bySpell": rec.bySpell.checkpoint {
                                 .object(["display": .string($0.display), "count": .int($0.count)])
                             }])
                }
            },
            "current": .string(current),
            "recentCasts": .array(recentCasts.map {
                .object(["spellKey": .string($0.spellKey), "spellDisplay": .string($0.spellDisplay),
                         "ts": .int($0.ts)])
            }),
            "lastObservedTs": .int(lastObservedTs),
        ])
    }

    /// Replace every field wholesale — the miner has no `reset()`, and the module's own does not
    /// clear it (mining is game knowledge), so the blob being the whole truth is enforced HERE.
    /// Decode-then-apply: a malformed blob mutates nothing.
    func restoreCheckpoint(_ v: JSONValue) -> Bool {
        guard let src = JSMap<JSMap<MessageRecord>>.fromCheckpoint(v["sources"], { bucketV in
            JSMap<MessageRecord>.fromCheckpoint(bucketV) { recV in
                guard let text = recV["text"].string, let role = recV["role"].string,
                      let by = JSMap<SpellCount>.fromCheckpoint(recV["bySpell"], { s in
                          guard let display = s["display"].string, let count = s["count"].int64
                          else { return nil }
                          return SpellCount(display: display, count: count)
                      }) else { return nil }
                let rec = MessageRecord(text: text, role: role)
                rec.bySpell = by
                return rec
            }
        }),
        let cur = v["current"].string, let last = v["lastObservedTs"].int64,
        let castRows = v["recentCasts"].array else { return false }
        var casts: [RecentCast] = []
        casts.reserveCapacity(castRows.count)
        for c in castRows {
            guard let key = c["spellKey"].string, let display = c["spellDisplay"].string,
                  let ts = c["ts"].int64 else { return false }
            casts.append(RecentCast(spellKey: key, spellDisplay: display, ts: ts))
        }
        sources = src
        current = cur
        recentCasts = casts
        lastObservedTs = last
        return true
    }
}

/// Add per-spell counts into a record, keyed canonically. The one place counts are combined.
private func addCounts(_ rec: MessageRecord, _ spells: [(String, Int64)]) {
    for (spell, count) in spells {
        let key = Names.dbCanonKey(spell)
        if var cur = rec.bySpell[key] {
            cur.count += count
            rec.bySpell.insert(key, cur)
        } else {
            rec.bySpell.insert(key, SpellCount(display: spell, count: count))
        }
    }
}

/// `new Date(ms).toISOString()` — UTC, always three fractional digits, always the `Z` suffix.
/// The civil-from-days algorithm is Howard Hinnant's; days are floored rather than truncated.
public func isoUTC(_ ms: Int64) -> String {
    let days = Rust.divEuclid(ms, 86_400_000)
    let rem = ms - days * 86_400_000
    let (y, m, d) = civilFromDays(days)
    let h = rem / 3_600_000
    let min = rem / 60_000 % 60
    let s = rem / 1000 % 60
    let milli = rem % 1000
    return String(format: "%04lld-%02lld-%02lldT%02lld:%02lld:%02lld.%03lldZ", y, m, d, h, min, s, milli)
}

/// Days since 1970-01-01 → (year, month, day), Gregorian.
private func civilFromDays(_ z0: Int64) -> (Int64, Int64, Int64) {
    let z = z0 + 719_468
    let era = Rust.divEuclid(z, 146_097)
    let doe = z - era * 146_097
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
    let y = yoe + era * 400
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
    let mp = (5 * doy + 2) / 153
    let d = doy - (153 * mp + 2) / 5 + 1
    let m = mp < 10 ? mp + 3 : mp - 9
    return (m <= 2 ? y + 1 : y, m, d)
}

/// The role vocabulary is closed at two values; anything else in the file would be a shape the
/// serializer could not round-trip.
public func overlayRoleOf(_ role: String) -> String { role == "wearsOff" ? "wearsOff" : "landing" }

/// `buffsMining.ts messageTextOf` — strip the `[timestamp] ` prefix from a raw line.
public func messageTextOf(_ raw: String) -> String {
    guard let r = raw.range(of: "] ") else { return raw }
    return String(raw[r.upperBound...])
}

/// The committed baseline, read from the bundled data. The baseline alone is what the parity
/// harness seeds, because the user's own mined overlay lives in userData.
public func overlayBaselineCounts() -> [OverlaySeedMessage] {
    guard let text = EQData.text("messageOverlay.baseline.json"),
          let doc = try? JSONValue.parse(text) else { return [] }
    return (doc["messages"].array ?? []).map { m in
        OverlaySeedMessage(
            text: m["text"].string ?? "",
            role: overlayRoleOf(m["role"].string ?? ""),
            spells: (m["spells"].array ?? []).map { ($0["spell"].string ?? "", $0["count"].int64 ?? 0) })
    }
}
