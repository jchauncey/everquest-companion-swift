// Port of fold/src/modules/alerts_rules.rs — `src/main/modules/alerts.ts`'s matcher half: whether a
// line makes a sound, and what the firing it produces says. `AlertsCaptures.swift` bounds the words;
// `AlertsEarly.swift` schedules the ones an offset moves.
//
// `Fire` (Seams.swift) is FULLY RESOLVED HERE — the app must be able to make the identical noise
// from the frame alone, so `sound` is the key the renderer's sound cache is already keyed by. `at`
// is the LOG's clock, never the host's; the one exception is an early warning, which has no matching
// event (see `AlertRuleSet.fireWarning`).
//
// `app` triggers (bossDefeat / questComplete) are renderer-evaluated: they depend on derived boss
// state that lives in the renderer, so they compile to a condition that never matches.
//
// WHOSE REGEX ENGINE. An alert's `/regex/` spec is user-authored and was written against
// JavaScript's engine. This build compiles it with ICU (`NSRegularExpression`), which — unlike the
// Rust crate the engine uses — has lookaround and backreferences, so the SET of patterns that fail
// to compile is smaller here than on the Rust side and closer to the app's own. The failure mode is
// unchanged and is the TS's: a `where` matcher degrades to literal equality, a `raw` trigger
// compiles to a pattern that can never match.
import Foundation
import EQLog
import EQCompanionCore

/// One user-authored pattern, compiled. Case-insensitive and carrying no `g` flag, so a match is
/// stateless. `names` is the declaration order of the named groups, which is what the capture cap
/// cuts on — ICU exposes no capture-name list, so the pattern is scanned for them.
final class UserRegex {
    let body: String
    let re: NSRegularExpression
    let names: [String]

    init?(_ body: String) {
        guard let re = try? NSRegularExpression(pattern: body, options: [.caseInsensitive]) else { return nil }
        self.body = body
        self.re = re
        self.names = UserRegex.namedGroups(body)
    }

    func isMatch(_ s: String) -> Bool {
        re.firstMatch(in: s, options: [], range: NSRange(s.startIndex..., in: s)) != nil
    }

    func captures(_ s: String) -> NSTextCheckingResult? {
        re.firstMatch(in: s, options: [], range: NSRange(s.startIndex..., in: s))
    }

    /// One named group's text, or nil when it did not participate.
    func group(_ name: String, _ m: NSTextCheckingResult, in s: String) -> String? {
        let r = m.range(withName: name)
        guard r.location != NSNotFound, let rr = Range(r, in: s) else { return nil }
        return String(s[rr])
    }

    /// The named groups a pattern declares, in declaration order. `(?<=` and `(?<!` are lookbehind,
    /// not declarations.
    static func namedGroups(_ pattern: String) -> [String] {
        var out: [String] = []
        let cs = Array(pattern)
        var i = 0
        var inClass = false
        while i < cs.count {
            let c = cs[i]
            if c == "\\" { i += 2; continue }
            if inClass {
                if c == "]" { inClass = false }
                i += 1
                continue
            }
            if c == "[" { inClass = true; i += 1; continue }
            if c == "(", i + 1 < cs.count, cs[i + 1] == "?" {
                var j = i + 2
                if j < cs.count, cs[j] == "P" { j += 1 }
                if j < cs.count, cs[j] == "<" {
                    j += 1
                    if j < cs.count, cs[j] != "=", cs[j] != "!" {
                        var name = ""
                        while j < cs.count, cs[j] != ">" { name.append(cs[j]); j += 1 }
                        if j < cs.count, !name.isEmpty { out.append(name) }
                    }
                }
            }
            i += 1
        }
        return out
    }
}

/// What a def that names no cooldown gets.
private let defaultCooldownMs: Int64 = 2000

/// Max distinct cooldown clocks at once, across every alert. Eviction is least-recently-FIRED.
private let cooldownKeyCap = 500

/// Max fires kept per alert in the recent-fires ring.
private let historyCap = 20

/// Everything one match produced, before any clock has had its say.
///
/// One value because the three answers are one answer: recomputing the captures afterwards would
/// mean running the pattern again and hoping the second run agreed with the first.
struct AlertFiring {
    /// The matched text: the raw log line, or a projection sentence for a break probe.
    var text: String
    var captures: CaptureMap?
    var spell: String?
}

/// A condition that matched, and what its named groups captured. A struct rather than a bare
/// `CaptureMap?` because "did not match" and "matched, naming nothing" are different answers.
struct AlertHit {
    var captures: CaptureMap?
}

/// One fire, as the module's published `history` ring records it.
struct FireRecord {
    var ts: Int64
    var matchedText: String
    var json: JSONValue { ["ts": .int(ts), "matchedText": .string(matchedText)] }
}

/// A compiled matcher value: a literal (compared case-insensitively) or the `/regex/` the spec was
/// written in.
enum AlertMatcher {
    /// Already lowercased, so a compare is one `lowercased()` on the field.
    case literal(String)
    case pattern(UserRegex)
}

/// One compiled `where` entry: the event field it names, its matcher, and the rank-folded key when
/// it is a LITERAL matcher on a key that NAMES A SPELL.
struct AlertField {
    var key: String
    var matcher: AlertMatcher
    /// Set only for a literal matcher on a spell-naming key, and only when the fold leaves something
    /// to compare.
    var lineKey: String?
}

/// A single PRIMITIVE condition, prepared for fast evaluation.
enum AlertCondition {
    case event(kind: String, fields: [AlertField])
    case raw(UserRegex)
    /// An `app` primitive: renderer-evaluated, so it never matches here.
    case never
}

/// Composite semantics, evaluated against the SINGLE incoming event.
enum AlertComposite {
    case single, any, all
}

/// One compiled alert.
final class AlertRule {
    let id: String
    let name: String
    let sound: String
    let cooldownMs: Int64
    /// `cooldownScope === 'target'`. Anything else reads as `alert`, which is the safe direction.
    let perTarget: Bool
    let composite: AlertComposite
    let conditions: [AlertCondition]
    /// The offset in seconds, or nil for the overwhelming majority of defs.
    let earlyWarnSec: Int64?
    /// Does this def's spoken phrase write `{target}` — compiled from the PHRASE, not the trigger.
    let wantsTarget: Bool
    /// The break kinds this def watches for, empty unless its trigger IS an ending.
    let breakKinds: [BreakKind]

    init(id: String, name: String, sound: String, cooldownMs: Int64, perTarget: Bool,
         composite: AlertComposite, conditions: [AlertCondition], earlyWarnSec: Int64?,
         wantsTarget: Bool, breakKinds: [BreakKind]) {
        self.id = id; self.name = name; self.sound = sound; self.cooldownMs = cooldownMs
        self.perTarget = perTarget; self.composite = composite; self.conditions = conditions
        self.earlyWarnSec = earlyWarnSec; self.wantsTarget = wantsTarget; self.breakKinds = breakKinds
    }

    /// Compile one stored `AlertDef`, or nil when it is switched off — the only reason this build
    /// refuses a def. An offset changes WHEN a def speaks, which is `AlertRuleSet.fire`'s business.
    static func compile(_ def: JSONValue) -> AlertRule? {
        guard def["enabled"].bool ?? false else { return nil }
        let trigger = def["trigger"]
        if trigger.isNull { return nil }
        let composite: AlertComposite
        let conditions: [AlertCondition]
        if let list = trigger["conditions"].array {
            composite = trigger["type"].string == "all" ? .all : .any
            conditions = list.map(AlertRules.compileCondition)
        } else {
            composite = .single
            conditions = [AlertRules.compileCondition(trigger)]
        }
        let sound = def["sound"]
        if sound.isNull { return nil }
        guard let id = def["id"].string else { return nil }
        var cooldown = defaultCooldownMs
        if case .int(let n) = def["cooldownMs"] { cooldown = n }
        return AlertRule(
            id: id,
            name: def["name"].string ?? "",
            sound: "\(sound["packId"].string ?? "")/\(sound["soundId"].string ?? "")",
            cooldownMs: cooldown,
            perTarget: def["cooldownScope"].string == "target",
            composite: composite,
            conditions: conditions,
            earlyWarnSec: AlertsEarly.normalizeEarlyWarnSec(def["earlyWarnSec"]),
            // Read through the same optional chain every other field of a stored def is: a def is
            // the STORE's contract and this engine states nothing about its shape.
            wantsTarget: AlertCaptures.wantsTargetToken(def["speech"]["phrase"].string),
            // Handed in rather than duplicated inside AlertsEarly: that file is the schedule and
            // this one is the matcher, and there is exactly one matcher.
            breakKinds: AlertsEarly.breakTriggerKinds(trigger) { AlertRules.matcherAccepts($0, "true") }
        )
    }

    /// The matched text and what it named, if this alert's trigger matches `ev`, else nil.
    ///
    /// 'all' → every condition must match this ONE event; an empty condition list is a no-match
    /// rather than a firehose. 'any' / 'single' → the first matching condition, and its captures
    /// alone.
    func matches(_ ev: Event) -> AlertHit? {
        switch composite {
        case .all:
            if conditions.isEmpty { return nil }
            var captures: CaptureMap?
            for c in conditions {
                guard let hit = AlertRules.conditionMatches(c, ev) else { return nil }
                captures = AlertCaptures.mergeCaptures(captures, hit.captures)
            }
            return AlertHit(captures: captures)
        case .any, .single:
            for c in conditions {
                if let hit = AlertRules.conditionMatches(c, ev) { return hit }
            }
            return nil
        }
    }

    /// Everything this rule's match produced, resolved. `base` is the event's own best-effort spell,
    /// computed once per firing by the caller and refined here PER ALERT.
    func firing(_ ev: Event, _ hit: AlertHit, _ base: String?, _ text: String) -> AlertFiring {
        AlertFiring(
            text: text,
            captures: AlertCaptures.withAutoCaptures(hit.captures, wantsTarget, ev),
            spell: base.map { AlertRules.matchedSpellName(self, ev, $0) }
        )
    }

    /// The cooldown clock this firing belongs to.
    ///
    /// 'alert' (and absent) → the alert's own id. 'target' → `<id>\0<idKey(target)>`. A family that
    /// names no target degrades to the alert-level clock rather than minting a bogus one.
    ///
    /// RANK-BLIND BY CONSTRUCTION: no spell name enters this key, so one def firing on rank I and
    /// rank III of its own spell shares one clock.
    func cooldownKey(_ ev: Event) -> String {
        if !perTarget { return id }
        guard let target = ev.str(Key.target) else { return id }
        let key = Names.idKey(target)
        return key.isEmpty ? id : "\(id)\u{0}\(key)"
    }

    /// The firing this rule would make, carrying everything the match produced. The alert's id rides
    /// along because a warning re-reads its own def when it comes due.
    ///
    /// THE WORDS ARE FROZEN AT THE ARM.
    func armedFire(_ firing: AlertFiring) -> ArmedFire {
        ArmedFire(alertId: id, rule: name, sound: sound, message: firing.text,
                  captures: firing.captures, spell: firing.spell)
    }
}

/// The free functions of the matcher, namespaced so they cannot collide with another module's.
enum AlertRules {
    /// Which (kind, key) pairs name a spell — the compile-time half of the rank fold. `spell` folds
    /// on every kind that has one; `damage.skill` joins it because the typed-nuke and DoT shapes put
    /// the spell name there.
    static func foldsRank(_ kind: String, _ key: String) -> Bool {
        key == "spell" || (kind == "damage" && key == "skill")
    }

    /// Whether the rank fold reaches this event — the runtime half, and it exists for one field.
    /// `damage` puts four vocabularies in `skill` and only two are spell names.
    static func foldReaches(_ field: AlertField, _ ev: Event) -> Bool {
        if field.key != "skill" { return true }
        guard ev.kind == "damage", let d = ev.str(Key.dtype) else { return false }
        return d == "spell" || d == "dot"
    }

    /// The spell names one event can honestly answer to — every name in its `candidates` list,
    /// string elements and `{name}` objects alike, or empty when it carries none.
    ///
    /// EQ's landing sentences are shared across a whole spell family, so the parser puts a
    /// BEST-EFFORT pick in `spell` and the truth in `candidates`.
    static func candidateNames(_ ev: Event) -> [String] {
        ev.anyCandidateNames(Key.candidates)
    }

    /// Compile one matcher spec. A value wrapped in slashes is a case-insensitive regex; anything
    /// else is a case-insensitive exact match. An INVALID regex falls back to literal equality so a
    /// bad def degrades gracefully instead of matching nothing by accident.
    static func compileField(_ key: String, _ spec: String, _ kind: String) -> AlertField {
        if let body = patternBody(spec), let re = UserRegex(body) {
            return AlertField(key: key, matcher: .pattern(re), lineKey: nil)
        }
        var lineKey: String?
        if foldsRank(kind, key) {
            let folded = Names.spellCanonKey(spec)
            // A spec that is nothing but a roman numeral folds to '' and is left alone rather than
            // turned into a wildcard.
            lineKey = folded.isEmpty ? nil : folded
        }
        return AlertField(key: key, matcher: .literal(spec.lowercased()), lineKey: lineKey)
    }

    /// The body of a `/…/` spec, or nil for a literal.
    static func patternBody(_ spec: String) -> String? {
        guard spec.count >= 2, spec.hasPrefix("/"), spec.hasSuffix("/") else { return nil }
        return String(spec.dropFirst().dropLast())
    }

    /// Whether a compiled matcher accepts one piece of text — exact equality or the pattern, plus
    /// the RANK FOLD for a literal spell matcher.
    ///
    /// A spell alert fires for ALL RANKS of the spell. It WIDENS ONLY, AND ONLY FOR LITERALS: a
    /// `/regex/` spec asked a narrower question on purpose.
    static func accepts(_ field: AlertField, _ text: String, _ folds: Bool) -> Bool {
        let hit: Bool
        switch field.matcher {
        case .literal(let lower): hit = text.lowercased() == lower
        case .pattern(let re): hit = re.isMatch(text)
        }
        if hit { return true }
        guard folds, let k = field.lineKey else { return false }
        return Names.spellCanonKey(text) == k
    }

    /// Whether one compiled `where` field accepts `ev`, and what it captured.
    ///
    /// An ABSENT field is an immediate no-match. The candidate widening applies to the `spell` key
    /// and to nothing else, and it captures from the CANDIDATE NAME that satisfied the matcher.
    ///
    /// CAPTURES COME FROM THE TEXT THIS MATCHER TESTED AND FROM NOWHERE ELSE — control 3, structural
    /// rather than a rule somebody has to remember.
    static func fieldMatches(_ ev: Event, _ field: AlertField) -> AlertHit? {
        // `field.key` is a string because a def is user-authored: it may name any field, including
        // one no event carries, and that reads as absent — an immediate no-match.
        guard let text = ev.fieldText(field.key) else { return nil }
        let folds = foldReaches(field, ev)
        if accepts(field, text, folds) { return capturesFrom(field, text) }
        // Only the `spell` key widens, and only when the event carries candidates.
        if field.key != "spell" { return nil }
        guard let hit = candidateNames(ev).first(where: { accepts(field, $0, folds) }) else { return nil }
        return capturesFrom(field, hit)
    }

    /// Run a matcher's own pattern over the text it just accepted, and bound what it named.
    ///
    /// A LITERAL MATCHER CAPTURES NOTHING: it has no pattern, so it declares no names. The rank fold
    /// reaches only literals, so a value accepted through the fold takes this branch too.
    static func capturesFrom(_ field: AlertField, _ text: String) -> AlertHit {
        guard case .pattern(let re) = field.matcher else { return AlertHit(captures: nil) }
        guard let m = re.captures(text) else { return AlertHit(captures: nil) }
        return AlertHit(captures: AlertCaptures.harvestCaptures(re, m, in: text))
    }

    /// Compile one PRIMITIVE trigger object into a matcher condition.
    static func compileCondition(_ t: JSONValue) -> AlertCondition {
        switch t["type"].string {
        case "event":
            let kind = t["kind"].string ?? ""
            var fields: [AlertField] = []
            if let w = t["where"].object {
                // serde_json's `Map` is a BTreeMap, so the Rust iterates the `where` object in
                // SORTED key order; first-writer-wins on a capture collision follows from it.
                for key in w.keys.sorted() {
                    guard let spec = w[key]?.string else { continue }
                    fields.append(compileField(key, spec, kind))
                }
            }
            return .event(kind: kind, fields: fields)
        case "raw":
            let body = t["regex"].string ?? ""
            // A bad regex must never match and never throw. `$.^` is the unmatchable pattern the TS
            // uses.
            if let re = UserRegex(body) { return .raw(re) }
            if let re = UserRegex("$.^") { return .raw(re) }
            return .never
        // 'app' triggers are renderer-evaluated, and so is anything this build cannot read.
        default:
            return .never
        }
    }

    /// Whether a `where` matcher spec accepts one value, expressed through THIS file's own compiler
    /// so the equality with the real matcher is structural rather than pinned by a test.
    ///
    /// Key-blind, and its one caller asks about `refresh`. The rank fold belongs to keys that NAME A
    /// SPELL, which is what `folds: false` says.
    static func matcherAccepts(_ spec: String, _ value: String) -> Bool {
        accepts(compileField("refresh", spec, ""), value, false)
    }

    static func conditionMatches(_ cond: AlertCondition, _ ev: Event) -> AlertHit? {
        switch cond {
        case .event(let kind, let fields):
            if ev.kind != kind { return nil }
            // Every field must match, so all their names are in scope. First writer wins on a
            // collision, which is source order.
            var captures: CaptureMap?
            for f in fields {
                guard let hit = fieldMatches(ev, f) else { return nil }
                captures = AlertCaptures.mergeCaptures(captures, hit.captures)
            }
            return AlertHit(captures: captures)
        // A raw condition tests `ev.raw` — the exact line, and the only text it ever sees. One call
        // for both the test and the groups, so the two cannot disagree.
        case .raw(let re):
            let raw = ev.raw
            guard let m = re.captures(raw) else { return nil }
            return AlertHit(captures: AlertCaptures.harvestCaptures(re, m, in: raw))
        case .never:
            return nil
        }
    }

    /// Event kind → the field on that event whose value is the triggering spell's DISPLAY name.
    static func spellFieldOf(_ kind: String) -> Key? {
        switch kind {
        case "castBegin", "castFizzle", "castInterrupted", "resist", "cc", "heal", "buffApply",
             "buffFade", "buffWearOff", "buffExpired":
            return .spell
        case "poisonProc": return .strike
        case "poisonCoat": return .poison
        default: return nil
        }
    }

    /// The spell that set this event off, display form with the rank suffix INTACT, or nil when the
    /// family names none.
    static func firingSpell(_ ev: Event) -> String? {
        if ev.kind == "damage" {
            guard let d = ev.str(Key.dtype), d == "spell" || d == "dot" else { return nil }
            let skill = JS.trim(ev.str(Key.skill) ?? "")
            return skill.isEmpty ? nil : skill
        }
        guard let field = spellFieldOf(ev.kind) else { return nil }
        let name = JS.trim(ev.str(field) ?? "")
        // 'unknown' is what a `poisonCoat` says when the line deliberately hides which poison it was.
        return (!name.isEmpty && name != "unknown") ? name : nil
    }

    /// The spell name this firing is about: `base` (the event's own best-effort pick) unless the
    /// alert matched a different candidate.
    ///
    /// It asks the same question the match did (`accepts`, same rank fold), so the two cannot split
    /// apart: a def pinned to `Elemental Maelstrom` firing on `Elemental Maelstrom II` keeps the
    /// event's own pick.
    static func matchedSpellName(_ rule: AlertRule, _ ev: Event, _ base: String) -> String {
        let names = candidateNames(ev)
        if names.isEmpty { return base }
        for cond in rule.conditions {
            guard case .event(let kind, let fields) = cond else { continue }
            if kind != ev.kind { continue }
            guard let f = fields.first(where: { $0.key == "spell" }) else { continue }
            let folds = foldReaches(f, ev)
            if accepts(f, base, folds) { continue }
            if let hit = names.first(where: { accepts(f, $0, folds) }) { return hit }
        }
        return base
    }

    /// The names this line could answer to — the event's own resolved pick plus the candidate list,
    /// which is the truth when one sentence is a whole family.
    static func armingNames(_ rule: AlertRule, _ ev: Event) -> [String] {
        var names: [String] = []
        if let base = firingSpell(ev) { names.append(matchedSpellName(rule, ev, base)) }
        names.append(contentsOf: candidateNames(ev))
        return names
    }

    /// Whether the early-warning offset claims this match — true when nothing sounds right now.
    ///
    /// THE OFFSET MOVES THE ONE FIRE; IT DOES NOT ADD A SECOND ONE. The cooldown is deliberately not
    /// spent here — the clock belongs to the sound, and no sound has been made.
    ///
    /// …unless the def's trigger IS the ending, in which case there is nothing left to arm against.
    /// A break-family def arms from the row appearing instead and still fires on its own trigger,
    /// except for the one landing whose warning already spoke, which `breakSpoken` swallows.
    static func earlyWarnTakesIt(_ rule: AlertRule, _ ev: Event, _ cooldownKey: String,
                                 _ firing: AlertFiring, _ early: EarlyWarnings) -> Bool {
        guard let sec = rule.earlyWarnSec else { return false }
        let names = armingNames(rule, ev)
        if rule.breakKinds.isEmpty {
            early.arm(EarlyWarnArm(sec: sec, cooldownKey: cooldownKey,
                                   subject: AlertsEarly.earlyWarnSubject(ev, names),
                                   ts: ev.ts, fired: rule.armedFire(firing)))
            return true
        }
        return early.breakSpoken(rule.id, AlertsEarly.breakEventIdentity(ev, names))
    }
}

/// The compiled rule set and its clocks — everything `alerts.define` installs, plus what firing
/// leaves behind.
final class AlertRuleSet: BreakWatchers {
    /// The definitions VERBATIM, as the store holds them, and published as the module's `defs`.
    private(set) var defs: [JSONValue] = []
    private var rules: [AlertRule] = []
    /// Cooldown clock → last fire timestamp. `def.id` for an alert-scoped clock and
    /// `def.id\0<targetKey>` for a per-target one; one map holds both because a NUL can appear in no
    /// alert id and in no mob name. Bounded, least-recently-fired first.
    private var lastFire = JSMap<Int64>()
    /// Per-alert ring of recent fires, newest last — the module's published `history`.
    private var historyRing = JSMap<[FireRecord]>()

    init() {}

    /// Full-set replace. Everything about the previous set goes except the clocks and the history: a
    /// cooldown is a statement about a sound already made, and the fires ledger is user-facing
    /// history.
    func setDefs(_ defs: [JSONValue]) {
        rules = defs.compactMap(AlertRule.compile)
        self.defs = defs
    }

    /// The recent-fires ring as a plain object for the snapshot.
    func history() -> JSONValue {
        historyRing.json { .array($0.map(\.json)) }
    }

    /// A character switch: the defs stay (user prefs, not log state) while the per-character firing
    /// bookkeeping goes.
    func reset() {
        lastFire.clear()
    }

    /// Evaluate one LIVE event. The caller has already established that; this is never reached for a
    /// historical one, which is the boundary law kept in one gate above the loop.
    func fire(_ ev: Event, _ early: EarlyWarnings) -> [Fire] {
        var out: [Fire] = []
        var hits: [(Int, String, AlertHit)] = []
        for (i, rule) in rules.enumerated() {
            if let hit = rule.matches(ev) { hits.append((i, rule.cooldownKey(ev), hit)) }
        }
        // Resolved once per firing and refined per alert below — and lazily, so an event that
        // matched no rule pays nothing for a field only a match can use.
        let base = hits.isEmpty ? nil : AlertRules.firingSpell(ev)
        for (i, key, hit) in hits {
            let rule = rules[i]
            let firing = rule.firing(ev, hit, base, ev.raw)
            if AlertRules.earlyWarnTakesIt(rule, ev, key, firing, early) { continue }
            if onCooldown(key, rule.cooldownMs, ev.ts) { continue }
            let f = Fire(at: ev.ts, rule: rule.name, sound: rule.sound, message: firing.text,
                         captures: firing.captures, spell: firing.spell,
                         // An ordinary fire warns about nothing: it IS the thing happening.
                         dueAt: nil)
            noteFire(key, ev.ts)
            record(rule.id, ev.ts, firing.text)
            out.append(f)
        }
        return out
    }

    /// Make an early warning's firing, if the alert behind it still wants it.
    ///
    /// The def is RE-READ rather than trusted: a warning can be armed for a minute, and an alert the
    /// user deleted or switched off in the meantime must not speak.
    ///
    /// The cooldown is spent here, on the clock the ARMING event chose, and against `nowMs`.
    ///
    /// `at` IS THE HEARTBEAT'S CLOCK — the one fire frame whose `at` is not the log's.
    func fireWarning(_ due: EarlyWarnDue, _ nowMs: Int64) -> Fire? {
        guard let rule = rules.first(where: { $0.id == due.fired.alertId }) else { return nil }
        if onCooldown(due.cooldownKey, rule.cooldownMs, nowMs) { return nil }
        noteFire(due.cooldownKey, nowMs)
        record(due.fired.alertId, nowMs, due.fired.message)
        return Fire(at: nowMs, rule: due.fired.rule, sound: due.fired.sound,
                    message: due.fired.message,
                    // The words the arming match took, carried across the wait.
                    captures: due.fired.captures, spell: due.fired.spell,
                    // The row's stated end, so the gap between it and `at` IS the lead time.
                    dueAt: due.dueAt)
    }

    /// Whether clock `key` is still inside `cooldownMs` at `ts`.
    private func onCooldown(_ key: String, _ cooldownMs: Int64, _ ts: Int64) -> Bool {
        guard let last = lastFire[key] else { return false }
        return ts - last < cooldownMs
    }

    /// Stamp a fire on clock `key`, keeping the map bounded and its iteration order
    /// least-recently-fired first (remove-then-insert re-inserts at the tail).
    private func noteFire(_ key: String, _ ts: Int64) {
        lastFire.remove(key)
        lastFire.insert(key, ts)
        if lastFire.count > cooldownKeyCap, let oldest = lastFire.keys.first {
            lastFire.remove(oldest)
        }
    }

    /// Append a fire to an alert's ring buffer, capping at `historyCap` (newest last).
    private func record(_ id: String, _ ts: Int64, _ matchedText: String) {
        let rec = FireRecord(ts: ts, matchedText: matchedText)
        if var ring = historyRing[id] {
            ring.append(rec)
            if ring.count > historyCap { ring.removeFirst(ring.count - historyCap) }
            historyRing.insert(id, ring)
            return
        }
        historyRing.insert(id, [rec])
    }

    // MARK: - BreakWatchers

    /// Rebuilt each tick rather than cached with the compile, because `enabled` and the offset can
    /// change under it. A disabled def never compiled, so `enabled` is answered structurally here.
    func breakWatchers() -> [(String, Int64)] {
        rules.compactMap { r in
            guard !r.breakKinds.isEmpty, let sec = r.earlyWarnSec else { return nil }
            return (r.id, sec)
        }
    }

    /// The same question without the allocation — asked once per beat by `wantsTimerRows`.
    func hasBreakWatchers() -> Bool {
        rules.contains { !$0.breakKinds.isEmpty && $0.earlyWarnSec != nil }
    }

    /// Would this def announce the break of this row — asked of the def's OWN matcher, never of a
    /// second one written to guess at the same question.
    ///
    /// The probe's hypothetical event carries the row's subject, so `{target}` resolves off it
    /// exactly as it would off the line that never got printed; and the spoken spell is the probe's
    /// rank-less name, because the name the alert matched on is the name it should say.
    func probeBreak(_ alertId: String, _ row: BuffTimerRow, _ nowMs: Int64) -> (ArmedFire, String)? {
        guard let rule = rules.first(where: { $0.id == alertId }) else { return nil }
        for kind in rule.breakKinds {
            for p in AlertsEarly.breakProbes(kind, row, nowMs) {
                guard let hit = rule.matches(p.ev) else { continue }
                let firing = AlertFiring(
                    text: p.ev.raw,
                    captures: AlertCaptures.withAutoCaptures(hit.captures, rule.wantsTarget, p.ev),
                    spell: p.spell
                )
                return (rule.armedFire(firing), rule.cooldownKey(p.ev))
            }
        }
        return nil
    }
}
