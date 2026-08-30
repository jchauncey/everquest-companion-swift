// Port of fold/src/modules/buff_timer_rows.rs — the timer-row projection: one fold over
// `buffs.active` and `buffTimers.holds`/`.ends`, producing the rows the two floating timer windows
// draw. Pure — no view, no clock.
//
// It lives in the fold because two callers need it and only one of them is a view: the serve layer
// cuts windows out of it, and the alerts evaluator needs the same rows to know when a running timer
// ENDS — the early-warning offset is `startedTs + durationMs - sec * 1000`.
//
// The rows carry no clock. Each carries its own `startedTs` and its own mode, and what a row reads
// at an instant is a separate pure function (`timerReading`), which is what lets a renderer tick at
// 1 Hz without another round trip.
//
// One divergence, stated: the final tiebreak is a CODE POINT comparison, because a host collation
// in the fold would make the answer a property of the machine. Every other term is exact.
//
// The `active` seam is the buffs module's serialized `ActiveBuff` (`activeBuffs()`), read by key:
// the Rust passes the struct, and the field set belongs to the buffs half.
import Foundation
import EQLog
import EQCompanionCore

/// How a row's time is read.
///
///   * `countdown` — the estimator states a duration: a receding bar, `durationMs` present.
///   * `elapsed` — nobody states one: time counts up from the landing, `durationMs` absent.
///   * `permanent` — a spell that never expires: no timer at all.
public enum TimerMode: String, Sendable { case countdown, elapsed, permanent }

/// Which of the two timer windows a row belongs to.
public enum TimerSurface: String, Sendable { case buffs, debuffs }

/// What kind of thing a row is about. `cc` has no `ActiveBuff` behind it — it is a hold the CC
/// ledger owns, and it is the half that knows about break lines.
public enum RowKind: String, Sendable { case buff, debuff, cc }

/// Self rows render first, then one block per target. Presentation only.
public enum RowGroup: String, Sendable { case selfGroup = "self", target = "target" }

/// One timer row.
public struct BuffTimerRow: Sendable, Equatable {
    /// Stable across ticks so keys and selectors do not churn.
    public var id: String
    public var kind: RowKind
    /// The resolved spell name, or the candidate names joined when the landing sentence is shared.
    ///
    /// For a buff/debuff row this is the DB's own name; a CC hold's is the RANKED name off its cast
    /// line. The difference is deliberate — nothing downstream of a hold matches on the string.
    public var name: String
    /// Display only: the ranked text the cast line spelled, when it differs from `name`.
    public var castName: String?
    /// Present only when the row is a FAMILY: every spell the line could be.
    public var candidates: [String]?
    /// True when `name` is a family rather than a spell — drives the `~` chip.
    public var ambiguous: Bool
    public var group: RowGroup
    /// Who it is on. Absent for a self row.
    public var target: String?
    public var targetKey: String?
    /// True when `target` is the model's inference, never a name a sentence stated.
    public var inferredTarget: Bool
    /// The event ts the instance landed. Not a wall clock: a BUFF's is shifted forward by an offline
    /// absence and a DEBUFF's is not, so elapsed and remaining are the only honest readings.
    public var startedTs: Int64
    /// True when the spell CALMS its target — the one reason a `buff` row belongs to the debuffs
    /// window.
    public var calmsTarget: Bool
    public var mode: TimerMode
    /// Only on `countdown`, and only a number the shared estimator stated.
    public var durationMs: Int64?
    /// How many entities of this row's display name are holding it. `nil` for the ordinary one;
    /// 2+ draws the count chip, and `startedTs` is then the OLDEST of them.
    public var count: Int64?
    /// The allowlisted external who cast it; `nil` for your own.
    public var caster: String?

    public init(id: String, kind: RowKind, name: String, castName: String?, candidates: [String]?,
                ambiguous: Bool, group: RowGroup, target: String?, targetKey: String?,
                inferredTarget: Bool, startedTs: Int64, calmsTarget: Bool, mode: TimerMode,
                durationMs: Int64?, count: Int64?, caster: String?) {
        self.id = id
        self.kind = kind
        self.name = name
        self.castName = castName
        self.candidates = candidates
        self.ambiguous = ambiguous
        self.group = group
        self.target = target
        self.targetKey = targetKey
        self.inferredTarget = inferredTarget
        self.startedTs = startedTs
        self.calmsTarget = calmsTarget
        self.mode = mode
        self.durationMs = durationMs
        self.count = count
        self.caster = caster
    }
}

/// What a row reads right now. `fraction` is 1 at the landing and 0 at or after the stated end.
public struct TimerReading: Sendable, Equatable {
    /// How long since the landing, never negative.
    public var elapsedMs: Int64
    /// Present only for a countdown; clamped at 0 — a countdown never reads negative.
    public var remainingMs: Int64?
    /// Bar fill in [0,1]: remaining share for a countdown, 0 for elapsed/permanent (no bar).
    public var fraction: Double
    /// True when a countdown has run past its stated end and the log has not yet cleared it.
    public var overdue: Bool
}

/// Read one row against an instant. The clock is always the caller's; nothing here reads one.
public func timerReading(_ row: BuffTimerRow, _ nowMs: Int64) -> TimerReading {
    let elapsedMs = max(nowMs - row.startedTs, 0)
    guard let duration = row.durationMs, duration > 0, row.mode == .countdown else {
        return TimerReading(elapsedMs: elapsedMs, remainingMs: nil, fraction: 0.0, overdue: false)
    }
    let left = duration - elapsedMs
    // A bar fill: the ratio of two millisecond counts, drawn at pixel resolution.
    let fraction = min(max(Double(left) / Double(duration), 0.0), 1.0)
    return TimerReading(elapsedMs: elapsedMs, remainingMs: max(left, 0), fraction: fraction,
                        overdue: left <= 0)
}

/// When a running countdown ends, on the log's own clock — or `nil` for a row stating no duration.
///
/// The early-warning fire instant is this minus the user's offset. It is spelled here rather than in
/// the alerts evaluator so the instant a row ends has one definition on this side of the boundary.
public func timerEndsAt(_ row: BuffTimerRow) -> Int64? {
    guard row.mode == .countdown else { return nil }
    return row.durationMs.map { row.startedTs + $0 }
}

/// The rank tail a spell name may carry.
private let rowRankTail = Re("(?i) (?:I|II|III|IV|V|VI|VII|VIII|IX|X)$")

/// A row's spell name folded to its FAMILY, case kept.
///
/// This is the spelling a wear-off line prints: a row's name comes from the ranked cast line, and
/// `Your <X> spell has worn off of <mob>.` is rank-less. Casing is kept because an alert speaks it.
public func timerNameBase(_ name: String) -> String {
    JS.trim(rowRankTail.replaceFirst(JS.trim(name), with: ""))
}

/// The same fold, case-folded. What row ids are built from.
public func timerNameKey(_ name: String) -> String { timerNameBase(name).lowercased() }

/// The rank a row may print — the numeral off the cast line, or nothing.
///
/// Two refusals. The two strings must fold to the SAME line, or the chip would be a rank belonging
/// to another spell; and a `castName` with no rank tail yields nothing, because "the cast line
/// spelled it differently" is not by itself a rank.
public func rowRankLabel(_ name: String, _ castName: String?) -> String? {
    guard let cast = castName else { return nil }
    if timerNameKey(cast) != timerNameKey(name) { return nil }
    let trimmed = JS.trim(cast)
    guard let m = rowRankTail.find(trimmed) else { return nil }
    return JS.trim(String(trimmed[m])).uppercased()
}

/// Canonical entity key.
private func entityKeyOf(_ name: String) -> String { JS.trim(name).lowercased() }

/// Which window a row belongs to — the whole split, as one function.
///
/// `buff` goes to the buffs window and `debuff`/`cc` to the debuffs window. `group` is NOT the
/// discriminator: a Symbol on your pet and a Valor on the cleric you buffed are `target` and are
/// still buffs. The one exception is a spell that CALMS its target — a Pacify is beneficial in the
/// committed catalog, so its class is `buff`, but the aggro clock belongs beside the other mob-state
/// timers. Nothing here may read `group`, `target` or `disposition`.
public func timerRowSurface(_ row: BuffTimerRow) -> TimerSurface {
    (row.kind == .buff && !row.calmsTarget) ? .buffs : .debuffs
}

/// The row a CC hold projects to.
private func ccRow(_ h: CcHold) -> BuffTimerRow {
    let family = h.candidates.isEmpty ? "Crowd control" : h.candidates.joined(separator: " / ")
    let idTail: String
    if let spell = h.spell {
        idTail = timerNameKey(spell)
    } else {
        idTail = h.candidates.map { timerNameKey($0) }.joined(separator: "+")
    }
    return BuffTimerRow(
        id: "cc|\(h.key)|\(idTail)",
        kind: .cc,
        name: h.spell ?? family,
        castName: nil,
        candidates: h.spell == nil ? h.candidates : nil,
        ambiguous: h.spell == nil,
        group: .target,
        target: h.target,
        targetKey: h.key,
        inferredTarget: false,
        startedTs: h.startedTs,
        calmsTarget: false,
        mode: h.durationMs != nil ? .countdown : .elapsed,
        durationMs: h.durationMs,
        count: h.count.flatMap { $0 > 1 ? $0 : nil },
        caster: h.caster)
}

/// Only the estimator's duration — max(DB floor, recent observed max) — earns a receding countdown.
/// A permanent buff never counts down, and a buff the model can put no honest number on counts UP
/// carrying no duration at all, so nothing downstream can draw a bar from it.
private func timerModeOf(_ b: JSONValue) -> (TimerMode, Int64?) {
    if b["permanent"].bool == true { return (.permanent, nil) }
    if let d = b["overlayDurationMs"].int64, d > 0 { return (.countdown, d) }
    return (.elapsed, nil)
}

/// The row an `ActiveBuff` projects to.
private func buffRow(_ b: JSONValue) -> BuffTimerRow {
    let isSelf = b["self"].bool ?? false
    let rawTarget = b["target"].string
    let targetKey: String? = isSelf ? nil : (rawTarget.map(entityKeyOf) ?? "unknown")
    let (mode, durationMs) = timerModeOf(b)
    let spell = b["spell"].string ?? ""
    let candidates = b["candidates"].array.map { $0.compactMap(\.string) }
    return BuffTimerRow(
        id: "\(isSelf ? "self" : "target")|\(targetKey ?? "self")|\(timerNameKey(spell))",
        kind: b["cls"].string == "debuff" ? .debuff : .buff,
        name: spell,
        // A raw string comparison rather than a folded one: the chip exists to show a DIFFERENCE.
        castName: b["castName"].string.flatMap { $0 != spell ? $0 : nil },
        candidates: candidates,
        ambiguous: candidates != nil,
        group: isSelf ? .selfGroup : .target,
        target: isSelf ? nil : (rawTarget ?? "unknown target"),
        targetKey: targetKey,
        inferredTarget: b["inferredTarget"].bool == true,
        startedTs: b["startedTs"].int64 ?? 0,
        calmsTarget: b["calmsTarget"].bool == true,
        mode: mode,
        durationMs: durationMs,
        count: b["count"].int64.flatMap { $0 > 1 ? $0 : nil },
        caster: b["caster"].string)
}

/// True when the CC ledger has recorded an END for this active instance at or after it landed.
///
/// `Your <mez> spell has worn off of <mob>.` routes to the CC half rather than to `buffFade`, so the
/// buffs model never clears the instance and it would linger to the 90-minute hygiene cap.
/// Correcting it in the instance store would also mint a land→fade duration sample, so the
/// correction lives in the projection and is exactly one rule wide.
private func endedByCc(_ b: JSONValue, _ ends: [CcEnd]) -> Bool {
    if b["self"].bool == true { return false }
    guard let target = b["target"].string else { return false }
    let key = entityKeyOf(target)
    let spell = timerNameKey(b["spell"].string ?? "")
    let startedTs = b["startedTs"].int64 ?? 0
    return ends.contains { e in
        e.key == key && e.ts >= startedTs && (e.spell.map { timerNameKey($0) == spell } ?? true)
    }
}

/// Soonest-to-expire first; countdowns ahead of count-ups; then oldest first, then by name.
///
/// Rows with no number go AFTER the timed ones: a row counting up cannot be placed on a
/// soonest-to-expire axis at all. Permanent rows come last, one step further. The final term is a
/// code point comparison — see the file header for the divergence.
public func compareRows(_ a: BuffTimerRow, _ b: BuffTimerRow) -> Int {
    func rank(_ r: BuffTimerRow) -> Int {
        switch r.mode {
        case .countdown: return 0
        case .elapsed: return 1
        case .permanent: return 2
        }
    }
    if rank(a) != rank(b) { return rank(a) < rank(b) ? -1 : 1 }
    if a.mode == .countdown && b.mode == .countdown {
        let ea = a.startedTs + (a.durationMs ?? 0)
        let eb = b.startedTs + (b.durationMs ?? 0)
        if ea != eb { return ea < eb ? -1 : 1 }
    } else if a.startedTs != b.startedTs {
        return a.startedTs < b.startedTs ? -1 : 1
    }
    return rowsCodePointCompare(a.name, b.name)
}

/// Rust's `str::cmp` — UTF-8 byte order, which is code point order. Swift's `<` on `String` is a
/// canonical-equivalence collation, so it is spelled out rather than borrowed.
func rowsCodePointCompare(_ a: String, _ b: String) -> Int {
    var i = a.utf8.makeIterator()
    var j = b.utf8.makeIterator()
    while true {
        switch (i.next(), j.next()) {
        case (nil, nil): return 0
        case (nil, _): return -1
        case (_, nil): return 1
        case (let x?, let y?): if x != y { return x < y ? -1 : 1 }
        }
    }
}

/// Rust's `sort_by`, which is stable — and the group order below depends on that.
func rowsStableSorted<T>(_ xs: [T], _ cmp: (T, T) -> Int) -> [T] {
    xs.enumerated().sorted { a, b in
        let c = cmp(a.element, b.element)
        return c != 0 ? c < 0 : a.offset < b.offset
    }.map(\.element)
}

/// The projection: self rows first, then one block per target with that target's rows together,
/// targets ordered by their soonest row.
///
/// A CC hold and an `ActiveBuff` can describe the same mez — a landing sentence the catalog matcher
/// saw becomes an `ActiveBuff` while its `<mob> has been …` siblings become holds. Where both exist
/// for one (mob, spell) the HOLD WINS: it is the half that knows about break lines.
public func buildTimerRows(active: [JSONValue], holds: [CcHold], ends: [CcEnd]) -> [BuffTimerRow] {
    var heldBySpell = Set<String>()
    for h in holds {
        if let s = h.spell { heldBySpell.insert("\(h.key)|\(timerNameKey(s))") }
    }

    var rows: [BuffTimerRow] = []
    for b in active {
        if endedByCc(b, ends) { continue }
        let row = buffRow(b)
        if row.group == .target
            && heldBySpell.contains("\(row.targetKey ?? "")|\(timerNameKey(row.name))") {
            continue
        }
        rows.append(row)
    }
    for h in holds { rows.append(ccRow(h)) }

    var selfRows: [BuffTimerRow] = []
    // Insertion-ordered groups. The group order is re-sorted below, but two groups whose first rows
    // compare equal keep the order they were first seen in — which a map keyed by target would
    // silently change to alphabetical.
    var order: [String] = []
    var byTarget: [String: [BuffTimerRow]] = [:]
    for row in rows {
        if row.group == .selfGroup {
            selfRows.append(row)
            continue
        }
        let key = row.targetKey ?? "unknown"
        if byTarget[key] == nil { order.append(key) }
        byTarget[key, default: []].append(row)
    }
    selfRows = rowsStableSorted(selfRows, compareRows)

    var groups: [[BuffTimerRow]] = order.compactMap { byTarget.removeValue(forKey: $0) }
        .map { rowsStableSorted($0, compareRows) }
    // A STABLE sort over the groups, which is what makes the insertion order above load-bearing.
    groups = rowsStableSorted(groups) { compareRows($0[0], $1[0]) }

    var out = selfRows
    for g in groups { out.append(contentsOf: g) }
    return out
}

/// The row order one window draws — the presentation choice on top of `buildTimerRows`, which stays
/// the model's order because both windows are folded from it. Grouping by target hands the
/// projection back untouched; otherwise the same rows are re-sorted into one flat soonest-first
/// list, which is what the debuffs window opens on.
public func orderTimerRows(_ rows: [BuffTimerRow], groupByTarget: Bool) -> [BuffTimerRow] {
    groupByTarget ? rows : rowsStableSorted(rows, compareRows)
}
