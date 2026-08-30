// Port of fold/src/modules/alerts_early.rs — the early-warning offset: `shared/earlyWarning.ts`'s
// pure rules plus `main/modules/alertsEarlyWarning.ts`'s scheduler.
//
// An alert that fires when a debuff LANDS can instead fire N seconds before that debuff's estimated
// end. An offset on an existing alert, not a new kind of alert, and it adds no duration tracking:
// the estimated end is the timer-row projection's, `startedTs + durationMs`.
//
// THE HONESTY LAW REACHES THIS SURFACE UNCHANGED. A row the model can put no honest number on counts
// up and has no `durationMs`, so there is no end to count backwards from and such a landing arms
// NOTHING.
//
// AN ARM RESOLVES ON THE NEXT TICK, NOT AT THE MATCH. The alerts module is registered before buffs
// and buffTimers, so at the instant a landing matches, the row it produces does not exist yet. A
// match files an arm request, and the next heartbeat resolves it against the projection. One that
// finds no row within `armResolveWindowMs` is dropped.
//
// CANCELLATION IS "THE ROW IS GONE". Every ending — death, dispel, zone, a nuke waking a mez —
// removes the row, so NO ROW, NO WARNING covers endings nobody has thought of yet. The deadline is
// re-read every tick for the same reason: the learner can raise an estimate mid-hold and a re-land
// moves the landing.
//
// A BREAK-FAMILY DEF ARMS FROM THE ROW APPEARING instead. Its arming event and its ending are the
// same line, so arming from the match would resolve against a world that event has already emptied.
// The trigger keeps its ordinary meaning: one landing yields exactly one firing. AN EARLY BREAK MUST
// NEVER BE SILENT.
import Foundation
import EQLog
import EQCompanionCore

/// The break kinds whose arrival means a tracked row has ENDED — measured against the parser rather
/// than assumed.
///
///   * `cc` — a mez/root spell's wear-off, `refresh: true`.
///   * `uncharm` — a charm spell's wear-off.
///   * `buffFade` — everything else that wore off a NAMED target: a slow, a Largo, a Pacify.
///   * `buffWearOff` — a shared-message wear-off ON YOU (`Your speed returns.`).
///   * `buffExpired` — the buffs module's derived, resolved "wore off you / your pet".
enum BreakKind: String, CaseIterable {
    case cc, uncharm, buffFade, buffWearOff, buffExpired

    /// The parser's own spelling of this kind.
    var asStr: String { rawValue }

    static func from(_ kind: String) -> BreakKind? { BreakKind(rawValue: kind) }
}

/// What a landing was about — the half of the arming event that decides which timer row it made.
///
/// `targetKey` is the canonical entity the spell landed on; absent means the PLAYER, and the two are
/// exclusive because the projection's `group` is exactly that distinction.
///
/// `spellNames` is EVERY name the line could be, not a name: the landing sentences this feature is
/// aimed at are shared across whole spell families.
struct EarlyWarnSubject {
    var targetKey: String?
    var spellNames: [String]
    init(targetKey: String? = nil, spellNames: [String] = []) {
        self.targetKey = targetKey
        self.spellNames = spellNames
    }
}

/// One hypothetical break, ready to be offered to a def's own matcher.
struct BreakProbe {
    /// The event a break of this row would be, as the parser would emit it.
    var ev: Event
    /// The spell name this probe stands for — what the break line prints.
    var spell: String
}

/// The firing an armed warning will make, built at match time so it says what the LANDING matched.
///
/// `alertId` is not on the `Fire` frame and is carried anyway, because a warning armed for a minute
/// has to re-read its own def when it comes due.
struct ArmedFire {
    var alertId: String
    var rule: String
    var sound: String
    var message: String
    /// The words the arming match took, carried across the wait rather than re-resolved at delivery.
    var captures: CaptureMap?
    /// The spell this warning is about, frozen at the arm for the same reason.
    var spell: String?
}

/// One armed warning as the caller files it.
struct EarlyWarnArm {
    /// The offset in seconds, already normalized.
    var sec: Int64
    /// The cooldown clock this firing belongs to — computed from the ARMING event, spent at the fire.
    var cooldownKey: String
    /// Which landing this is, so the row can be found once the world has folded it.
    var subject: EarlyWarnSubject
    /// Event ts (ms) of the landing — the clock the resolve window is measured on.
    var ts: Int64
    /// The firing this warning will make.
    var fired: ArmedFire
}

/// A warning that has come due: the firing to make, and the clock to spend for it.
struct EarlyWarnDue {
    var cooldownKey: String
    var fired: ArmedFire
    /// When the thing this warning is early for is due — the watched row's stated end. Computed as
    /// `fire instant + sec * 1000` rather than re-read off the row; the two are the same number by
    /// construction.
    var dueAt: Int64
}

/// Where a break-family def's probe comes from.
///
/// Matching an alert is the rule set's job and there must be exactly one implementation of it, so
/// this is a seam and not a second matcher.
protocol BreakWatchers: AnyObject {
    /// The break-family defs that want to be told about live rows — `(alertId, sec)` each.
    func breakWatchers() -> [(String, Int64)]
    /// Whether `breakWatchers()` would answer with anything — the same question without the
    /// allocation, asked once per beat to decide whether the timer projection is built at all.
    func hasBreakWatchers() -> Bool
    /// Would this def announce the break of this row — asked of the def's OWN matcher.
    func probeBreak(_ alertId: String, _ row: BuffTimerRow, _ nowMs: Int64) -> (ArmedFire, String)?
}

/// The pure rules of the offset, namespaced so they cannot collide with another module's.
enum AlertsEarly {
    /// The bounds on the offset, in seconds.
    ///
    /// The floor is 1 because the model's clock is a 1-second heartbeat. The ceiling is past the
    /// longest thing anybody warns about early.
    static let minEarlyWarnSec: Int64 = 1
    static let maxEarlyWarnSec: Int64 = 120

    /// How long an unresolved arm request keeps looking for its row. The row is created by the SAME
    /// event that armed it, so this is slack for a heartbeat that was busy.
    static let armResolveWindowMs: Int64 = 5_000

    /// The most warnings held at once, across every alert. Oldest-armed goes first.
    static let maxArmedWarnings = 200

    /// A NUL, which can appear in no alert id and in no row id.
    static let keySep = "\u{0}"

    /// The rank tail a spell name may carry (buff_timer_rows.rs's `rank_tail`), kept private here
    /// rather than reached for across module files.
    private static let rankTail = Re("(?i) (?:I|II|III|IV|V|VI|VII|VIII|IX|X)$")

    /// A row's spell name folded to its FAMILY, case kept. This is the spelling a wear-off line
    /// prints: a row's name comes from the ranked cast line, and `Your <X> spell has worn off of
    /// <mob>.` is rank-less.
    static func timerNameBase(_ name: String) -> String {
        JS.trim(rankTail.replaceFirst(JS.trim(name), with: ""))
    }

    /// The same fold, case-folded. What row ids are built from.
    static func timerNameKey(_ name: String) -> String { timerNameBase(name).lowercased() }

    /// A row on the player rather than on something else.
    static func isSelfRow(_ row: BuffTimerRow) -> Bool { row.group == .selfGroup }

    /// A stored offset as a number this app will act on, or nil for "no warning" — the APP's
    /// normalizer rather than a reading of it.
    ///
    /// A zero, a negative, a NaN, a non-number and an absent key all land in nil.
    static func normalizeEarlyWarnSec(_ raw: JSONValue) -> Int64? {
        guard let n = raw.double, n.isFinite else { return nil }
        // `Math.round` is round half UP, not round half away from zero. They differ only for
        // negatives, which the next line refuses anyway — spelled out so nobody "simplifies" it.
        let f = (n + 0.5).rounded(.down)
        let sec: Int64 = f >= 9.2e18 ? Int64.max : (f <= -9.2e18 ? Int64.min : Int64(f))
        if sec < minEarlyWarnSec { return nil }
        return min(sec, maxEarlyWarnSec)
    }

    /// True when a row states an end at all — the only rows an early warning can be measured against.
    static func hasStatedEnd(_ row: BuffTimerRow) -> Bool {
        row.mode == .countdown && (row.durationMs.map { $0 > 0 } ?? false)
    }

    /// Every spell name a row answers to, rank-stripped and folded (its own, plus its family).
    static func rowNameKeys(_ row: BuffTimerRow) -> [String] {
        var out = [timerNameKey(row.name)]
        for c in row.candidates ?? [] { out.append(timerNameKey(c)) }
        return out
    }

    /// The row a landing is tracked by, or nil when the model states no end for it.
    ///
    ///  1. Only rows with a STATED end. A count-up row arms nothing.
    ///  2. The row must be on the subject's entity — the mob the line named, or the player.
    ///  3. If any of those rows answers to one of the subject's spell names, only those are
    ///     considered. Names that match nothing on that entity fall back to ALL of them rather than
    ///     to nothing.
    ///  4. Of what is left, the most recent landing.
    static func earlyWarnRowFor(_ rows: [BuffTimerRow], _ subject: EarlyWarnSubject) -> BuffTimerRow? {
        let onSubject = rows.filter { r in
            guard hasStatedEnd(r) else { return false }
            guard let key = subject.targetKey else { return isSelfRow(r) }
            return r.targetKey == key
        }
        if onSubject.isEmpty { return nil }
        let wanted = subject.spellNames.map(timerNameKey)
        let named: [BuffTimerRow] = wanted.isEmpty ? [] : onSubject.filter { r in
            rowNameKeys(r).contains { wanted.contains($0) }
        }
        let pool = named.isEmpty ? onSubject : named
        // Strictly greater, so a tie keeps the EARLIER row and the answer does not depend on a
        // sort's stability.
        return pool.reduce(nil) { (best: BuffTimerRow?, r: BuffTimerRow) in
            guard let b = best else { return r }
            return r.startedTs > b.startedTs ? r : b
        }
    }

    /// When the warning for this row is due — the row's estimated end minus the offset.
    ///
    /// Re-read on every tick rather than fixed at the landing, because both halves move.
    static func earlyWarnFireAt(_ row: BuffTimerRow, _ sec: Int64) -> Int64? {
        guard hasStatedEnd(row), let d = row.durationMs else { return nil }
        return row.startedTs + d - sec * 1000
    }

    /// The break kind one primitive condition watches for, or nil when it is not a break condition.
    ///
    /// THE `cc` KIND CARRIES BOTH HALVES, so it has to be read rather than listed: the same event is
    /// the application and the break. Either of two constraints separates them:
    ///
    ///   `refresh` — present and 'true' only on the break shape.
    ///   `spell`   — the application sentence carries `candidates` and no `spell` field at all, and
    ///               an absent field is a no-match before the candidate widening is consulted.
    ///
    /// A bare `{kind: 'cc'}` matches the application too and stays a landing-family def.
    static func breakKindOf(_ t: JSONValue, _ acceptsTrue: (String) -> Bool) -> BreakKind? {
        guard t["type"].string == "event" else { return nil }
        guard let k = t["kind"].string, let kind = BreakKind.from(k) else { return nil }
        if kind != .cc { return kind }
        let wh = t["where"].object ?? [:]
        if wh["spell"] != nil { return .cc }
        guard let refresh = wh["refresh"]?.string else { return nil }
        return acceptsTrue(refresh) ? .cc : nil
    }

    /// The break kinds a def watches for — empty when it is not a break-family def at all.
    ///
    /// EVERY condition must be a break condition, and there must be at least one. A `raw` or `app`
    /// condition is therefore never break-family. A mixed composite keeps the landing behaviour.
    ///
    /// A LIST because the `wearsOff` template is an `any` composite over `buffExpired` +
    /// `buffWearOff`, and both halves have to be probed.
    static func breakTriggerKinds(_ trigger: JSONValue, _ acceptsTrue: (String) -> Bool) -> [BreakKind] {
        let conds = trigger["conditions"].array ?? [trigger]
        var out: [BreakKind] = []
        if conds.isEmpty { return out }
        for c in conds {
            guard let kind = breakKindOf(c, acceptsTrue) else { return [] }
            if !out.contains(kind) { out.append(kind) }
        }
        return out
    }

    /// Every spell name a running row could be announced under, as the wear-off line would print it.
    ///
    /// An unambiguous row answers to its own name; a family row answers to every candidate. Ranks
    /// stripped, deduped case-insensitively, first spelling wins.
    static func rowBreakNames(_ row: BuffTimerRow) -> [String] {
        let raw: [String]
        if let list = row.candidates, !list.isEmpty { raw = list } else { raw = [row.name] }
        var out: [String] = []
        var seen: [String] = []
        for n in raw {
            let base = timerNameBase(n)
            let key = base.lowercased()
            if base.isEmpty || seen.contains(key) { continue }
            seen.append(key)
            out.append(base)
        }
        return out
    }

    /// The projected sentence a break-armed firing carries as its matched text.
    ///
    /// NOT a log line, on purpose: this firing is a projection off the timer model. It still names
    /// the two things that tell one warning from another — the spell, and the mob.
    static func breakProbeText(_ row: BuffTimerRow, _ spell: String) -> String {
        if isSelfRow(row) { return "\(spell) is about to wear off" }
        return "\(spell) on \(row.target ?? "unknown target") is about to end"
    }

    /// What a break of this row would look like — the seam, stated in one place.
    ///
    /// A def's `where` is written against the shape of the BREAK EVENT, so the only honest way to
    /// ask "would this def announce the break of this row" is to ask the def's own matcher with the
    /// event it was written for.
    ///
    /// THE PROBE IS A FABRICATION, AND THIS IS ITS ENTIRE BLAST RADIUS: built here, handed to the
    /// rule's matcher, dropped. Never on the bus, never folded, never counted, never learned from.
    ///
    /// A kind that cannot describe this row yields NOTHING — a def that arms no warning and still
    /// fires at the break.
    static func breakProbes(_ kind: BreakKind, _ row: BuffTimerRow, _ ts: Int64) -> [BreakProbe] {
        let zelf = isSelfRow(row)
        let target = row.target ?? ""
        if !zelf && target.isEmpty { return [] }
        return rowBreakNames(row).compactMap { spell in
            let raw = breakProbeText(row, spell)
            guard let v = probeEvent(kind, zelf, target, spell, ts, raw) else { return nil }
            return BreakProbe(ev: Event.fromValue(v), spell: spell)
        }
    }

    /// The per-kind shape, split out so `breakProbes` stays one idea.
    ///
    ///   `cc`          `{ mob, spell, refresh: true }`  — no candidates: the BREAK shape carries none.
    ///   `uncharm`     `{ mob, spell }`                 — no refresh; a charm break never carries one.
    ///   `buffFade`    `{ spell, target }`              — `target` omitted for a row on you.
    ///   `buffWearOff` `{ spell, candidates, target: 'self' }` — self rows only.
    ///   `buffExpired` `{ spell, target }`              — 'self' for a self row, else the entity.
    static func probeEvent(_ kind: BreakKind, _ zelf: Bool, _ target: String, _ spell: String,
                           _ ts: Int64, _ raw: String) -> JSONValue? {
        let k = kind.asStr
        switch kind {
        case .cc:
            guard !zelf else { return nil }
            return ["kind": .string(k), "ts": .int(ts), "seq": 0, "raw": .string(raw),
                    "mob": .string(target), "spell": .string(spell), "refresh": true]
        case .uncharm:
            guard !zelf else { return nil }
            return ["kind": .string(k), "ts": .int(ts), "seq": 0, "raw": .string(raw),
                    "mob": .string(target), "spell": .string(spell)]
        case .buffFade:
            if zelf {
                return ["kind": .string(k), "ts": .int(ts), "seq": 0, "raw": .string(raw),
                        "spell": .string(spell)]
            }
            return ["kind": .string(k), "ts": .int(ts), "seq": 0, "raw": .string(raw),
                    "spell": .string(spell), "target": .string(target)]
        case .buffWearOff:
            guard zelf else { return nil }
            return ["kind": .string(k), "ts": .int(ts), "seq": 0, "raw": .string(raw),
                    "spell": .string(spell), "candidates": .array([.string(spell)]),
                    "target": "self"]
        case .buffExpired:
            return ["kind": .string(k), "ts": .int(ts), "seq": 0, "raw": .string(raw),
                    "spell": .string(spell), "target": .string(zelf ? "self" : target)]
        }
    }

    /// The identity a warning and its break share — `<entity>|<spell family>`, folded on both sides.
    ///
    /// RANK-BLIND BY CONSTRUCTION: the row's name comes from the ranked cast line while the break
    /// line prints the bare name.
    static func breakIdentityKeys(_ entityKey: String, _ names: [String]) -> [String] {
        var out: [String] = []
        for n in names {
            let key = "\(entityKey)|\(timerNameKey(n))"
            if !out.contains(key) { out.append(key) }
        }
        return out
    }

    /// The identity keys a live row would be broken under. `'self'` is the entity key for a row on
    /// the player — the model's own word for it, and the one `buffWearOff`/`buffExpired` already
    /// spell in their `target` field.
    static func rowBreakIdentity(_ row: BuffTimerRow) -> [String] {
        let entity = isSelfRow(row) ? "self" : (row.targetKey ?? row.target ?? "")
        return breakIdentityKeys(entity, rowBreakNames(row))
    }

    /// What a landing was about, from the event that carried it.
    ///
    /// The entity is read dynamically from `mob` (the CC/charm families) then `target` (the buff
    /// families). `buffApply` spells a self-landing as the literal 'self', so it maps to NO entity
    /// key rather than to a mob called self. The loop breaks on the first non-empty field, even when
    /// that field maps to nothing.
    static func earlyWarnSubject(_ ev: Event, _ spellNames: [String]) -> EarlyWarnSubject {
        var targetKey: String?
        for field in ["mob", "target"] {
            guard let v = ev.str(field) else { continue }
            let t = JS.trim(v)
            if t.isEmpty { continue }
            if t.lowercased() != "self" { targetKey = Names.idKey(t) }
            break
        }
        return EarlyWarnSubject(targetKey: targetKey, spellNames: spellNames)
    }

    /// The identity a break event carries — the other half of `rowBreakIdentity`.
    ///
    /// 'self' is KEPT as the literal key rather than mapped away, because a row on the player is
    /// what it has to match.
    ///
    /// THE EVENT'S OWN `spell` IS READ HERE rather than taken from the caller's list, because that
    /// list is the SPEECH one and claims only the kinds a spoken alert names a spell for.
    static func breakEventIdentity(_ ev: Event, _ spellNames: [String]) -> [String] {
        var entity = "self"
        for field in ["mob", "target"] {
            guard let v = ev.str(field) else { continue }
            let t = JS.trim(v)
            if t.isEmpty { continue }
            entity = t.lowercased() == "self" ? "self" : Names.idKey(t)
            break
        }
        var names: [String] = []
        if let s = ev.str(Key.spell), !JS.trim(s).isEmpty { names.append(s) }
        names.append(contentsOf: spellNames)
        return breakIdentityKeys(entity, names)
    }
}

/// An arm that has found its row. `rowId` is the whole identity — its absence is the cancellation.
private struct ArmedRow {
    var arm: EarlyWarnArm
    var rowId: String
}

/// One landing being watched: which row, which landing of it, and whether the warning has spoken.
private final class BreakWatch {
    let alertId: String
    let rowId: String
    /// The row's `startedTs` when this watch was filed — a LATER one is a new landing, and re-arms.
    let landedTs: Int64
    let sec: Int64
    let cooldownKey: String
    let fired: ArmedFire
    /// `<entity>|<spell family>` for every name this row answers to.
    let identity: [String]
    /// True once the early warning has fired for this landing — the at-break firing is then spent.
    var spoken = false

    init(alertId: String, rowId: String, landedTs: Int64, sec: Int64, cooldownKey: String,
         fired: ArmedFire, identity: [String]) {
        self.alertId = alertId; self.rowId = rowId; self.landedTs = landedTs; self.sec = sec
        self.cooldownKey = cooldownKey; self.fired = fired; self.identity = identity
    }
}

/// The armed early warnings, advanced by the alerts module's heartbeat.
final class EarlyWarnings {
    /// Arms still looking for their row.
    private var pending: [EarlyWarnArm] = []
    /// Warnings tracking a live row, keyed `<alertId>\0<rowId>` — one per alert per row.
    private var armed = JSMap<ArmedRow>()
    /// Break-family watches, keyed the same way. Filed from the ROW APPEARING rather than from an
    /// event, and kept after the warning speaks so the break line it pre-empted can be suppressed.
    private var breaks = JSMap<BreakWatch>()

    init() {}

    func reset() {
        pending.removeAll()
        armed.clear()
        breaks.clear()
    }

    /// True when nothing is waiting — the caller skips reading the projection entirely.
    var idle: Bool { pending.isEmpty && armed.isEmpty && breaks.isEmpty }

    /// File a warning for a landing that just matched an alert with an offset.
    func arm(_ req: EarlyWarnArm) {
        pending.append(req)
        if pending.count > AlertsEarly.maxArmedWarnings { pending.removeFirst() }
    }

    /// True when the at-break firing for a landing this alert already warned about is spent.
    ///
    /// A watch is CONSUMED by the break it pre-empted (one landing, one firing), so a re-land on the
    /// same mob can warn again; and a break with no matching spoken watch is suppressed by nothing.
    func breakSpoken(_ alertId: String, _ identity: [String]) -> Bool {
        let hit = breaks.pairs.first { pair in
            let w = pair.1
            return w.spoken && w.alertId == alertId && w.identity.contains { identity.contains($0) }
        }
        guard let key = hit?.0 else { return false }
        breaks.remove(key)
        return true
    }

    /// Advance to `nowMs`: resolve what can be resolved, cancel what has ended, and hand back the
    /// warnings that have come due.
    func tick(_ nowMs: Int64, _ rows: [BuffTimerRow], _ watchers: BreakWatchers) -> [EarlyWarnDue] {
        let watching = watchers.breakWatchers()
        if idle && watching.isEmpty { return [] }
        resolve(rows, nowMs)
        watchBreaks(rows, watching, watchers, nowMs)
        var due = advance(rows, nowMs)
        due.append(contentsOf: advanceBreaks(rows, nowMs))
        return due
    }

    /// Turn arm requests into armed warnings, discarding the ones the model states no end for.
    private func resolve(_ rows: [BuffTimerRow], _ nowMs: Int64) {
        if pending.isEmpty { return }
        var keep: [EarlyWarnArm] = []
        let taken = pending
        pending = []
        for p in taken {
            guard let row = AlertsEarly.earlyWarnRowFor(rows, p.subject) else {
                if nowMs - p.ts <= AlertsEarly.armResolveWindowMs { keep.append(p) }
                continue
            }
            // Re-arming the same (alert, row) replaces: a fresh landing on a row already being
            // watched is the same warning moved, never a second one.
            let key = "\(p.fired.alertId)\(AlertsEarly.keySep)\(row.id)"
            armed.remove(key)
            armed.insert(key, ArmedRow(arm: p, rowId: row.id))
            if armed.count > AlertsEarly.maxArmedWarnings, let oldest = armed.keys.first {
                armed.remove(oldest)
            }
        }
        pending = keep
    }

    /// Cancel the warnings whose row has gone, and collect the ones that are due.
    ///
    /// A deadline already in the past fires on this very tick — the honest degradation for an offset
    /// longer than the debuff: as early as the spell allows, rather than silently never arriving.
    private func advance(_ rows: [BuffTimerRow], _ nowMs: Int64) -> [EarlyWarnDue] {
        var due: [EarlyWarnDue] = []
        var retire: [String] = []
        for (key, a) in armed.pairs {
            // No row: the hold ended, however it ended. Nothing left to warn about.
            let at = rows.first { $0.id == a.rowId }.flatMap { AlertsEarly.earlyWarnFireAt($0, a.arm.sec) }
            guard let at else {
                retire.append(key)
                continue
            }
            if nowMs < at { continue }
            retire.append(key)
            due.append(EarlyWarnDue(cooldownKey: a.arm.cooldownKey, fired: a.arm.fired,
                                    dueAt: at + a.arm.sec * 1000))
        }
        for key in retire { armed.remove(key) }
        return due
    }

    /// File a watch for every (def, live row) pair the def would announce the break of.
    ///
    /// A row is watched ONCE PER LANDING: `landedTs` is the row's own clock, so a re-mez is a new
    /// landing and re-arms, while an unchanged row is left as it is.
    ///
    /// A DEADLINE ALREADY IN THE PAST NEVER ARMS HERE, unlike the landing path. The arming is the
    /// row's mere EXISTENCE, and rows are rebuilt from history on every character load.
    private func watchBreaks(_ rows: [BuffTimerRow], _ watching: [(String, Int64)],
                             _ watchers: BreakWatchers, _ nowMs: Int64) {
        // Drop what is no longer watchable: the row is gone, or the alert was deleted, disabled, or
        // had its offset removed while a warning was pending.
        let dead = breaks.pairs.filter { pair in
            let w = pair.1
            return !rows.contains { $0.id == w.rowId } || !watching.contains { $0.0 == w.alertId }
        }.map { $0.0 }
        for key in dead { breaks.remove(key) }
        for row in rows {
            for (alertId, sec) in watching {
                watchRow(row, alertId, sec, watchers, nowMs)
            }
        }
    }

    /// One (def, row) pair.
    private func watchRow(_ row: BuffTimerRow, _ alertId: String, _ sec: Int64,
                          _ watchers: BreakWatchers, _ nowMs: Int64) {
        let key = "\(alertId)\(AlertsEarly.keySep)\(row.id)"
        if let held = breaks[key], held.landedTs >= row.startedTs, held.sec == sec { return }
        guard let at = AlertsEarly.earlyWarnFireAt(row, sec) else { return }
        if at <= nowMs { return }
        guard let (fired, cooldownKey) = watchers.probeBreak(alertId, row, nowMs) else { return }
        breaks.remove(key)
        breaks.insert(key, BreakWatch(alertId: alertId, rowId: row.id, landedTs: row.startedTs,
                                      sec: sec, cooldownKey: cooldownKey, fired: fired,
                                      identity: AlertsEarly.rowBreakIdentity(row)))
        if breaks.count > AlertsEarly.maxArmedWarnings, let oldest = breaks.keys.first {
            breaks.remove(oldest)
        }
    }

    /// The break warnings that have come due. A watch is NOT deleted when it fires — it stays,
    /// marked `spoken`, so the break line ending that same hold can be suppressed against it.
    private func advanceBreaks(_ rows: [BuffTimerRow], _ nowMs: Int64) -> [EarlyWarnDue] {
        var due: [EarlyWarnDue] = []
        for w in breaks.values {
            if w.spoken { continue }
            let at = rows.first { $0.id == w.rowId }.flatMap { AlertsEarly.earlyWarnFireAt($0, w.sec) }
            guard let at else { continue }
            if nowMs < at { continue }
            w.spoken = true
            due.append(EarlyWarnDue(cooldownKey: w.cooldownKey, fired: w.fired,
                                    dueAt: at + w.sec * 1000))
        }
        return due
    }
}
