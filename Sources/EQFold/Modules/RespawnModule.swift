// Port of fold/src/modules/respawn.rs — `src/main/modules/respawn.ts` plus the pure vocabulary it
// publishes through and the committed wiki floor it numbers rows from (`data/respawns.json`):
// DEATH LINES IN, LIVE COUNTDOWNS OUT.
//
// The fold owns three things the pure code cannot:
//
//   1. The ZONE STAY. A death→death gap is a respawn sample only if you never left the zone between
//      the two deaths. `zoneSince` is the timestamp of the `You have entered` line that started the
//      current stay, and a gap qualifies when the EARLIER death also falls inside it. A zone line
//      ends the stay even when it names the same zone — you left and came back. That same zone
//      scopes the display, one piece of state serving both jobs.
//   2. The LRU. A long replay walks past thousands of distinct mob names, so the history is capped
//      at `maxHistory` and evicted by last death. The map is re-inserted on every death, so
//      iteration order IS LRU order.
//   3. Its own revision number. Three inputs advance no log seq — the watch list edited over IPC, a
//      zone line and a confirmed sighting — so reporting the last event's `seq` would let a reader's
//      `d.seq <= knownSeq` dedupe swallow the push that carries them.
//
// The 60-second floor is measured, not chosen: across the 394 respawns the committed floor states a
// duration for, the shortest is 78 s and the median is 22 minutes. Two deaths of one name inside a
// minute are two mobs dying in one pull, and the sample is refused outright.
//
// No wall clock is read here, ever: one is handed in by `onTick`, the live tail's heartbeat, which a
// historical fold never calls. `constructionNowMs` is seeded at construction and again at `reset()`.
// Because nothing advances it during a historical fold it survives into `snapshot()`.
import Foundation
import EQLog
import EQData
import EQCompanionCore

/// `shared/respawn.ts RESPAWN_SHAPE_VERSION`.
private let respawnShapeVersion: Int64 = 4
/// The shortest death→death gap this module will read as a spawn cycle (header).
private let minGapMs: Int64 = 60_000
/// Distinct (zone, mob) pairs the history keeps before evicting the least recently killed.
private let maxHistory = 800
/// How often a continuing sighting re-publishes. A fight prints several lines a second and every one
/// names the mob, so recording a sighting is free but pushing it is not.
private let seenRefreshMs: Int64 = 5_000
private let respawnMaxRows = 60
private let respawnMaxRecent = 40
/// The working the Running entry prints — the last six qualifying gaps.
private let respawnMaxGaps = 6
/// Beyond this a sighting has gone stale and a clock has stopped meaning anything.
private let respawnLingerMs: Int64 = 30 * 60 * 1000

/// One row of `data/respawns.json`. `seconds` is absent on roughly a fifth of the rows: the grammar
/// is a whitelist, so anything it cannot fully consume ("Triggered", "6-8 hours", "?") keeps its
/// verbatim text and states no number.
private struct WikiRespawn {
    var page: String
    var text: String
    var seconds: Int64?
}

/// Read straight out of `EQData`: exactly one copy of the committed floor, so a re-scrape reaches
/// both readers at once.
private let respawnWiki: [String: WikiRespawn] = {
    guard let text = EQData.text("respawns.json"), let v = try? JSONValue.parse(text) else { return [:] }
    var out: [String: WikiRespawn] = [:]
    for r in v["rows"].array ?? [] {
        guard let key = r["key"].string else { continue }
        out[key] = WikiRespawn(page: r["page"].string ?? "", text: r["text"].string ?? "", seconds: r["seconds"].int64)
    }
    return out
}()

/// One live respawn clock. Every optional field is absent rather than null when the fold has nothing
/// to say — the published shape came through `JSON.stringify`.
public struct RespawnRow: Sendable {
    /// `<zone key>::<mob key>` — stable across ticks, and the same id the fold keys history by.
    public var id: String
    /// Canonical mob key.
    public var key: String
    /// The name the row draws.
    public var display: String
    /// The zone the clock is for. A mob is watched per zone.
    public var zone: String
    /// The instant the clock counts from — a death, or a sighting.
    public var baseTs: Int64
    /// Which of those two it was: `death` or `sighting`.
    public var basis: String
    /// Where the estimate came from: `custom`, `observed`, `wiki` or `none`.
    public var source: String
    /// How many gaps the estimate was learned from.
    public var samples: Int64
    /// Kills recorded for this mob in this zone.
    public var kills: Int64
    /// When it was last SEEN alive, if it has been.
    public var seenTs: Int64?
    /// How it was seen: `combat`, `consider`, `hold` or `spell`.
    public var seenVia: String?
    /// The respawn this row is counting toward.
    public var estimateMs: Int64?
    /// What the log itself has measured.
    public var observedMs: Int64?
    /// The recent gaps behind `observedMs`, newest first.
    public var gapsMs: [Int64]?
    /// The number the user typed, when they typed one.
    public var customMs: Int64?
    /// What the committed wiki data says, verbatim.
    public var wikiText: String?
    /// The same, in milliseconds, when it could be read as a duration.
    public var wikiMs: Int64?
    /// The wiki page the text came from.
    public var wikiPage: String?

    var json: JSONValue {
        var o: [String: JSONValue] = [
            "id": .string(id), "key": .string(key), "display": .string(display), "zone": .string(zone),
            "baseTs": .int(baseTs), "basis": .string(basis), "source": .string(source),
            "samples": .int(samples), "kills": .int(kills)
        ]
        if let seenTs { o["seenTs"] = .int(seenTs) }
        if let seenVia { o["seenVia"] = .string(seenVia) }
        if let estimateMs { o["estimateMs"] = .int(estimateMs) }
        if let observedMs { o["observedMs"] = .int(observedMs) }
        if let gapsMs { o["gapsMs"] = .array(gapsMs.map { .int($0) }) }
        if let customMs { o["customMs"] = .int(customMs) }
        if let wikiText { o["wikiText"] = .string(wikiText) }
        if let wikiMs { o["wikiMs"] = .int(wikiMs) }
        if let wikiPage { o["wikiPage"] = .string(wikiPage) }
        return .object(o)
    }
}

/// A mob you recently killed, offered in the view as a one-click watch.
private struct RespawnCandidate {
    var key: String
    var display: String
    var zone: String
    var lastTs: Int64
    var kills: Int64
    var watched: Bool
    var wikiText: String?
    var wikiMs: Int64?

    var json: JSONValue {
        var o: [String: JSONValue] = [
            "key": .string(key), "display": .string(display), "zone": .string(zone),
            "lastTs": .int(lastTs), "kills": .int(kills), "watched": .bool(watched)
        ]
        if let wikiText { o["wikiText"] = .string(wikiText) }
        if let wikiMs { o["wikiMs"] = .int(wikiMs) }
        return .object(o)
    }
}

/// What the fold knows about one mob in one zone.
private struct MobHistory {
    var key: String
    var display: String
    var zone: String
    /// The most recent death, ms.
    var lastTs: Int64
    /// The smallest qualifying gap seen — an upper bound on the respawn, never the respawn.
    var minGapMs: Int64?
    /// How many qualifying gaps back `minGapMs`.
    var samples: Int64
    /// The gaps themselves, oldest first, capped at `respawnMaxGaps`. Kept beside `samples` and
    /// `minGapMs` rather than replacing them: those two are computed over EVERY qualifying gap.
    var gaps: [Int64]
    /// Deaths counted, qualifying or not.
    var kills: Int64
    /// The last event that named this mob while the fold stood in this zone. Never a death.
    var seenTs: Int64?
    var seenVia: String?
    /// The last `seenTs` a delta actually carried — see `seenRefreshMs`.
    var seenPubTs: Int64?
    /// A sighting the user confirmed as the spawn. Competes with `lastTs` for the clock's base and
    /// the LATER one wins, which is why a death needs no code to undo it.
    var confirmedTs: Int64?
}

/// The clock's base for one history entry: the death, or a later confirmed sighting.
private func baseOf(_ h: MobHistory) -> Int64 {
    if let c = h.confirmedTs, c > h.lastTs { return c }
    return h.lastTs
}

/// `resolveRespawn` — the estimate ladder. Rung 2 is FLOORED by rung 3 rather than averaged with it
/// (the smallest gap you measured is an upper bound, so the wiki lifting it is a correction); rung 1
/// is never floored, because the user is looking at the spawn and the wiki describes another server.
private func resolveRespawn(_ customMs: Int64?, _ observedMs: Int64?, _ samples: Int64, _ wikiMs: Int64?) -> (Int64?, String) {
    if let c = customMs, c > 0 { return (c, "custom") }
    if let o = observedMs, o > 0, samples > 0 {
        let floored = wikiMs.map { max(o, $0) } ?? o
        return (floored, "observed")
    }
    if let w = wikiMs, w > 0 { return (w, "wiki") }
    return (nil, "none")
}

/// The names a typed event states, and which family stated them. The groups ARE the four
/// `RespawnSeenVia` values, so the factoring and the vocabulary agree.
private func seenNamesOf(_ ev: Event) -> ([String?], String)? {
    // Somebody swung at it, or it swung at somebody. `attacker` is null on caster-less DoT lines.
    switch ev.kind {
    case "damage", "miss": return ([ev.str(.attacker), ev.str(.target)], "combat")
    case "heal": return ([ev.str(.healer), ev.str(.target)], "combat")
    case "consider": return ([ev.str(.mob)], "consider")
    // A mez / root / charm landed on it, broke on it, or wore off it.
    case "cc", "ccWake", "charm", "uncharm": return ([ev.str(.mob)], "hold")
    // A spell named it — as a resister, as a caster, or as the thing something landed on.
    case "resist": return ([ev.str(.caster), ev.str(.target)], "spell")
    case "otherCastBegin": return ([ev.str(.caster)], "spell")
    case "buffApply", "poisonProc": return ([ev.str(.target)], "spell")
    default: return nil
    }
}

/// `main/log/reducers.ts isCountedKill` — self-slain always counts; slain-by counts only when the
/// killer isn't you.
private func isCountedKill(_ ev: Event) -> Bool {
    if ev.bool(.bySelf) { return true }
    if let killer = ev.str(.killer), !killer.isEmpty { return !JSFn.startsWithYouWord(killer) }
    return true
}

/// Rust's `str::cmp` is byte-wise over UTF-8; Swift's `<` is not. Ordering is a claim in a snapshot.
private func respawnLexLess(_ a: String, _ b: String) -> Bool {
    var x = a.utf8.makeIterator(), y = b.utf8.makeIterator()
    while true {
        switch (x.next(), y.next()) {
        case (nil, nil): return false
        case (nil, _): return true
        case (_, nil): return false
        case (let p?, let q?): if p != q { return p < q }
        }
    }
}

public final class RespawnModule: EqModule {
    public let id = "respawn"

    private var history = JSMap<MobHistory>()
    private var zone = ""
    /// When the current continuous stay in `zone` began. Zero before any zone line, and a zero start
    /// qualifies nothing — a stay that never began is not a stay.
    private var zoneSince: Int64 = 0
    private var prefs: RespawnPrefs
    /// The module's own revision — see the header. Never a LogEvent seq.
    private var rev: Int64 = 0
    /// The pinned construction instant (see the header). Re-read at `reset()` to the same value,
    /// because the fold advances no clock.
    private let constructionNowMs: Int64
    private var nowMsValue: Int64
    /// The watch list as a lookup. Not a micro-optimization: every damage and miss line asks this two
    /// questions, and a linear scan of up to 200 entries per name would be tens of millions of string
    /// comparisons before the app finished starting.
    private var watchIndex: [String: RespawnWatchPref] = [:]

    public init(constructionNowMs: Int64, prefs: RespawnPrefs) {
        self.constructionNowMs = constructionNowMs
        self.nowMsValue = constructionNowMs
        self.prefs = prefs
        reindexWatches()
    }

    private func reindexWatches() {
        watchIndex = [:]
        for w in prefs.watches { watchIndex[w.key] = w }
    }

    /// Is this mob watched? nil for every mob, until the player says otherwise.
    ///
    /// The watch list is the only admission rule. EQ's names are duplicated across zones and spawn
    /// points, so a clock nobody asked for is a clock about a mob the app cannot identify. The wiki
    /// still numbers a watched row and still floors it; it does not decide that a row exists.
    ///
    /// The outer optional is "watched at all", the inner "with a number of their own".
    private func watchOf(_ key: String) -> Int64?? {
        guard let explicit = watchIndex[key] else { return nil }
        return .some(explicit.customSec.map { $0 * 1000 })
    }

    /// The log named something. Mark it seen if — and only if — it is a mob the user watches AND this
    /// fold has a clock for it in the zone it is standing in.
    ///
    /// Both guards matter: an unwatched name is dropped before it costs anything, which is what makes
    /// running this over every combat line acceptable, and the entry is looked up under the CURRENT
    /// zone's id, so a sighting can only light a row for where you are standing.
    private func markSeen(_ name: String?, _ via: String, _ ts: Int64) {
        // Nobody is watching anything: the answer is the same for every name, before it costs a fold.
        if watchIndex.isEmpty { return }
        guard let name, !name.isEmpty else { return }
        let key = Names.idKey(name)
        guard watchOf(key) != nil else { return }
        let id = "\(Names.idKey(zone))::\(key)"
        guard var h = history[id] else { return }
        let base = baseOf(h)
        // A mention from before the clock started is not a sighting of the spawn it is about, so the
        // transition is judged against the BASE rather than the previous `seenTs`.
        let wasSeen = (h.seenTs.map { $0 > base }) ?? false
        if let s = h.seenTs, ts < s { return }
        h.seenTs = ts
        h.seenVia = via
        if wasSeen && ts - (h.seenPubTs ?? 0) < seenRefreshMs {
            history.insert(id, h)
            return
        }
        h.seenPubTs = ts
        history.insert(id, h)
        rev += 1
    }

    /// "That sighting was the spawn — start the clock there", `respawn.ts confirmSighting` line for
    /// line.
    ///
    /// The one thing a sighting may never do on its own. Everything else here records evidence; this
    /// MOVES a clock, so only a person can ask for it.
    ///
    /// Two refusals, both about the row rather than about the world: false when the id names no
    /// entry, and false when the entry is not CURRENTLY seen — the same test `rowFor` uses to let a
    /// row open in the seen state, so a click can only confirm a sighting the screen was drawing.
    /// Nothing needs to undo a confirmation either: the base is the later of `confirmedTs` and
    /// `lastTs`, so the next death wins by arithmetic.
    @discardableResult
    public func confirmSighting(_ id: String) -> Bool {
        guard var h = history[id] else { return false }
        let base = baseOf(h)
        guard let seen = h.seenTs, seen > base else { return false }
        h.confirmedTs = seen
        history.insert(id, h)
        // The revision moves: a confirmation advances no log seq, so a reader deduping on `seq` would
        // swallow the very push that carries it.
        rev += 1
        return true
    }

    private func recordDeath(_ key: String, _ display: String, _ ts: Int64) {
        let id = "\(Names.idKey(zone))::\(key)"
        var h: MobHistory
        if let prior = history[id] {
            h = prior
            // Re-insert so the map's iteration order is LRU order (oldest first).
            history.remove(id)
            let gap = ts - h.lastTs
            if zoneSince > 0 && h.lastTs >= zoneSince && gap >= minGapMs {
                h.minGapMs = h.minGapMs.map { min($0, gap) } ?? gap
                h.samples += 1
                // Oldest first here and reversed on the way out, so the cap drops the oldest rather
                // than the freshest evidence.
                h.gaps.append(gap)
                if h.gaps.count > respawnMaxGaps { h.gaps.removeFirst() }
            }
        } else {
            h = MobHistory(key: key, display: display, zone: zone, lastTs: 0, minGapMs: nil, samples: 0,
                           gaps: [], kills: 0, seenTs: nil, seenVia: nil, seenPubTs: nil, confirmedTs: nil)
        }
        h.lastTs = ts
        h.kills += 1
        h.display = display
        history.insert(id, h)
        while history.count > maxHistory {
            guard let oldest = history.keys.first else { break }
            history.remove(oldest)
        }
        rev += 1
    }

    /// One history entry as a row, or nil when the mob is not watched — the only reason this returns
    /// nil. It never sweeps stale rows, and it takes no clock: nothing it computes depends on `now`.
    private func rowFor(_ h: MobHistory) -> RespawnRow? {
        guard let customMs = watchOf(h.key) else { return nil }
        let wikiRow = respawnWiki[h.key]
        let wikiMs = wikiRow?.seconds.map { $0 * 1000 }
        let (estimateMs, source) = resolveRespawn(customMs, h.minGapMs, h.samples, wikiMs)
        let base = baseOf(h)
        var row = RespawnRow(
            id: "\(Names.idKey(h.zone))::\(h.key)", key: h.key, display: h.display, zone: h.zone,
            baseTs: base, basis: base == h.lastTs ? "death" : "sighting", source: source,
            samples: h.samples, kills: h.kills, seenTs: nil, seenVia: nil, estimateMs: estimateMs,
            observedMs: h.minGapMs, gapsMs: nil, customMs: customMs, wikiText: wikiRow?.text,
            // The page those words came from, so the edit modal can link to it: quoting a source the
            // reader cannot open is half a provenance.
            wikiMs: wikiMs, wikiPage: wikiRow?.page)
        // A mention from the fight that KILLED the mob is not a sighting of the spawn that follows, so
        // a row must never open in the seen state.
        if let s = h.seenTs, s > base {
            row.seenTs = h.seenTs
            row.seenVia = h.seenVia
        }
        // Newest first on the wire, and a COPY, so a reader holding a snapshot never sees the fold
        // mutate it.
        if !h.gaps.isEmpty { row.gapsMs = Array(h.gaps.reversed()) }
        return row
    }

    /// The fields of `respawnReading` the ordering asks about. `fraction`/`due`/`overdueMs` are
    /// display-only and no caller of this function reads them.
    private static func reading(_ row: RespawnRow, _ nowMs: Int64) -> (Bool, Int64, Bool, Int64?) {
        let elapsed = max(nowMs - row.baseTs, 0)
        var ago: Int64?
        if let s = row.seenTs, s > row.baseTs {
            let a = max(nowMs - s, 0)
            if a <= respawnLingerMs { ago = a }
        }
        let seen = ago != nil
        if let est = row.estimateMs, est > 0 {
            let left = est - elapsed
            return (seen, ago ?? 0, !seen && -left > respawnLingerMs, max(left, 0))
        }
        // No estimate to elapse, so the elapsed time is what goes stale.
        return (seen, ago ?? 0, !seen && elapsed > respawnLingerMs, nil)
    }

    /// `orderRespawnRows` — SEEN first, then live clocks by soonest due, then the ones with no
    /// estimate, and STALE last. Ties break on display name so the list never shuffles under a
    /// re-render.
    ///
    /// Seen outranks every countdown because it is a different KIND of fact: every other row is an
    /// estimate of when something might happen, and a seen row is the log saying it already has.
    /// Stale sinks for the mirror reason.
    private static func orderRows(_ rows: inout [RespawnRow], _ nowMs: Int64) {
        // `sort_by` is stable over there; Swift's `sort` is not, so the original index is the last
        // tiebreak.
        let decorated = rows.enumerated().map { (i: $0.offset, row: $0.element, r: reading($0.element, nowMs)) }
        rows = decorated.sorted { a, b in
            let (sa, agoa, stalea, lefta) = a.r
            let (sb, agob, staleb, leftb) = b.r
            if sa != sb { return sa }
            if sa && sb, agoa != agob { return agoa < agob }
            if stalea != staleb { return !stalea }
            let la = lefta ?? Int64.max, lb = leftb ?? Int64.max
            if la != lb { return la < lb }
            if a.row.display != b.row.display { return respawnLexLess(a.row.display, b.row.display) }
            return a.i < b.i
        }.map(\.row)
    }

    private func build(_ nowMs: Int64) -> JSONValue {
        let (rows, recent) = collect(nowMs)
        return ["v": .int(respawnShapeVersion), "zone": .string(zone),
                "rows": .array(rows.map(\.json)), "recent": .array(recent.map(\.json)),
                "prefs": prefs.json]
    }

    /// The watch-row pull seam — the rows the Timers surface draws, in the order it draws them, typed
    /// rather than serialized.
    ///
    /// It goes through `collect` rather than re-walking the history, at the cost of a candidate list
    /// this caller throws away, so there is no second opinion about which mobs are on a clock.
    public func watchRows(_ nowMs: Int64) -> [RespawnRow] { collect(nowMs).0 }

    /// The ordering clock this module was last advanced to — the log's own `ts` while folding, and
    /// the wall clock once a live tail is ticking it. The view layer needs it because respawn order
    /// is a function of `now`.
    public func nowMs() -> Int64 { nowMsValue }

    /// The change signal — the private revision counter this module publishes as its `seq`, because a
    /// watch advances no log seq.
    public func revision() -> Int64 { rev }

    /// The rows and the candidates, walked once. Both halves of `build`.
    private func collect(_ nowMs: Int64) -> ([RespawnRow], [RespawnCandidate]) {
        var rows: [RespawnRow] = []
        var recent: [RespawnCandidate] = []
        // The map iterates oldest-first (LRU order), so sort for "most recent". `sort_by` is stable
        // and so is `Array.prototype.sort`, which keeps ties in LRU order on both sides.
        let entries = history.values.enumerated()
            .sorted { a, b in a.element.lastTs != b.element.lastTs ? a.element.lastTs > b.element.lastTs : a.offset < b.offset }
            .map(\.element)
        for h in entries {
            if let row = rowFor(h), rows.count < respawnMaxRows { rows.append(row) }
            if recent.count < respawnMaxRecent {
                let wikiRow = respawnWiki[h.key]
                recent.append(RespawnCandidate(key: h.key, display: h.display, zone: h.zone, lastTs: h.lastTs,
                                               kills: h.kills, watched: watchOf(h.key) != nil,
                                               wikiText: wikiRow?.text, wikiMs: wikiRow?.seconds.map { $0 * 1000 }))
            }
        }
        RespawnModule.orderRows(&rows, nowMs)
        return (rows, recent)
    }

    // MARK: - EqModule

    public func reset() {
        history.clear()
        zone = ""
        zoneSince = 0
        // Re-read the "wall clock", which here is the pinned construction instant — see the header.
        nowMsValue = constructionNowMs
        rev += 1
    }

    public func onEvent(_ ev: Event, live: Bool) {
        switch ev.kind {
        case "epoch":
            // A character rebirth invalidates the live clocks and takes the learned gaps with them,
            // because the gaps are recomputed by the same fold replaying past this line: nothing is
            // lost that the log still states.
            history.clear()
            rev += 1
        case "zone":
            zone = ev.str(.zone) ?? ""
            zoneSince = ev.ts
            // The revision moves, because the zone is part of what the screen shows.
            rev += 1
        case "death":
            if isCountedKill(ev) {
                let name = ev.str(.name) ?? ""
                recordDeath(Names.idKey(name), name, ev.ts)
            }
        default:
            // Everything else is possible evidence that a watched mob is up. A death is checked first
            // and returns, so a corpse can never mark its own row seen.
            if let (names, via) = seenNamesOf(ev) {
                let ts = ev.ts
                for name in names { markSeen(name, via, ts) }
            }
        }
    }

    /// `respawn.ts onTick` — one assignment and, deliberately, nothing else.
    ///
    /// It publishes nothing and the revision does NOT move. The set of rows changes only when a
    /// death, a watch edit, a zone line or a sighting changes it, and each already bumps `rev`; the
    /// clock only buys the ORDER `build` publishes in.
    public func onTick(nowMs: Int64, timerRows: [BuffTimerRow]) {
        nowMsValue = nowMs
    }

    /// The same cursor `snapshot` publishes, without building the state to read it.
    public var publishedSeq: Int64? { rev }

    public func snapshot() -> JSONValue { ["seq": .int(rev), "state": build(nowMsValue)] }

    public var asDefines: Defines? { self }
    /// The view pull seam.
    public var asRespawn: RespawnModule? { self }
}

extension RespawnModule: Defines {
    public var family: String { "respawn" }

    /// `respawnModule.setPrefs(next)` — the watch list, replaced whole.
    ///
    /// The revision must move: a watch advances no log seq, so a renderer deduping on `seq` would
    /// drop the very push that carries it.
    public func define(_ payload: JSONValue) {
        guard let next = RespawnPrefs.read(payload) else { return }
        prefs = next
        reindexWatches()
        rev += 1
    }
}

// MARK: - Checkpoint

extension RespawnModule: FoldCheckpointable {
    /// `watchIndex` is derived from `prefs` and rebuilt, not carried — two copies of one fact.
    /// `nowMsValue` is the wall clock and is NOT state: reset pins it back to the construction
    /// instant, exactly where an unbroken historical fold holds it, and the first live tick after
    /// a real resume refreshes it. `rev` IS carried: it is the published seq.
    public func checkpointState() -> JSONValue {
        .object([
            "history": history.checkpoint { h in
                var o: [String: JSONValue] = [
                    "key": .string(h.key), "display": .string(h.display), "zone": .string(h.zone),
                    "lastTs": .int(h.lastTs), "samples": .int(h.samples),
                    "gaps": .array(h.gaps.map { .int($0) }), "kills": .int(h.kills),
                ]
                if let m = h.minGapMs { o["minGapMs"] = .int(m) }
                if let t = h.seenTs { o["seenTs"] = .int(t) }
                if let v = h.seenVia { o["seenVia"] = .string(v) }
                if let p = h.seenPubTs { o["seenPubTs"] = .int(p) }
                if let c = h.confirmedTs { o["confirmedTs"] = .int(c) }
                return .object(o)
            },
            "zone": .string(zone),
            "zoneSince": .int(zoneSince),
            "prefs": prefs.json,
            "rev": .int(rev),
        ])
    }

    public func restoreCheckpoint(_ state: JSONValue) -> Bool {
        reset()
        guard let m = JSMap<MobHistory>.fromCheckpoint(state["history"], { v in
            guard let key = v["key"].string, let display = v["display"].string,
                  let zone = v["zone"].string, let lastTs = v["lastTs"].int64,
                  let samples = v["samples"].int64, let gapsArr = v["gaps"].array,
                  let kills = v["kills"].int64 else { return nil }
            var gaps: [Int64] = []
            for g in gapsArr { guard let n = g.int64 else { return nil }; gaps.append(n) }
            return MobHistory(key: key, display: display, zone: zone, lastTs: lastTs,
                              minGapMs: v["minGapMs"].int64, samples: samples, gaps: gaps,
                              kills: kills, seenTs: v["seenTs"].int64, seenVia: v["seenVia"].string,
                              seenPubTs: v["seenPubTs"].int64, confirmedTs: v["confirmedTs"].int64)
        }),
        let zoneV = state["zone"].string, let since = state["zoneSince"].int64,
        let savedRev = state["rev"].int64,
        let savedPrefs = RespawnPrefs.read(state["prefs"]) else { return false }
        history = m
        zone = zoneV
        zoneSince = since
        prefs = savedPrefs
        reindexWatches()
        rev = savedRev
        return true
    }
}
