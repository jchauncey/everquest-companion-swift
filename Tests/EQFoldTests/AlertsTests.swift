// The alerts evaluator's own suite — the Rust `#[cfg(test)]` modules of alerts.rs, alerts_rules.rs,
// alerts_captures.rs and alerts_early.rs, ported. Firing is live-only, so no golden fold reaches it:
// these tests ARE the oracle for everything below `spellLastCast` / `poisonSlowSeen`.
import XCTest
import EQLog
import EQCompanionCore
@testable import EQFold

// MARK: - Shared helpers

private func ev(_ line: String) -> Event { Event.fromJSON(line)! }
private func evv(_ v: JSONValue) -> Event { Event.fromValue(v) }

/// `def["x"] = y` — JSONValue has no setter subscript.
private func with(_ v: JSONValue, _ key: String, _ x: JSONValue) -> JSONValue {
    var o = v.object ?? [:]
    o[key] = x
    return .object(o)
}

private func fireNoOffset(_ rs: AlertRuleSet, _ e: Event) -> [Fire] { rs.fire(e, EarlyWarnings()) }

private func set(_ defs: [JSONValue]) -> AlertRuleSet {
    let rs = AlertRuleSet()
    rs.setDefs(defs)
    return rs
}

private func def(_ trigger: JSONValue) -> JSONValue {
    ["id": "a1", "name": "Charm break", "enabled": true,
     "sound": ["packId": "classic", "soundId": "ding"], "trigger": trigger]
}

/// A def with a phrase, so `{target}` is wanted. Everything else is `def`'s.
private func speakingDef(_ trigger: JSONValue, _ phrase: String) -> JSONValue {
    with(def(trigger), "speech", ["mode": "custom", "phrase": .string(phrase)])
}

/// A countdown row on a mob — the shape an early warning is measured against.
private func debuffRow(_ spell: String, _ target: String, _ started: Int64, _ duration: Int64?) -> BuffTimerRow {
    BuffTimerRow(id: "cc|\(target.lowercased())|\(AlertsEarly.timerNameKey(spell))",
                 kind: .debuff, name: spell, castName: nil, candidates: nil, ambiguous: false,
                 group: .target, target: target, targetKey: target.lowercased(),
                 inferredTarget: false, startedTs: started, calmsTarget: false,
                 mode: duration != nil ? .countdown : .elapsed, durationMs: duration,
                 count: nil, caster: nil)
}

/// The same, on YOU — `group: self`, no target.
private func selfRow(_ spell: String, _ started: Int64, _ duration: Int64?) -> BuffTimerRow {
    var r = debuffRow(spell, "unused", started, duration)
    r.id = "self|self|\(AlertsEarly.timerNameKey(spell))"
    r.group = .selfGroup
    r.target = nil
    r.targetKey = nil
    return r
}

// MARK: - alerts_captures.rs

final class AlertCapturesTests: XCTestCase {
    private func harvest(_ pattern: String, _ text: String) -> CaptureMap? {
        guard let re = UserRegex(pattern), let m = re.captures(text) else { return nil }
        return AlertCaptures.harvestCaptures(re, m, in: text)
    }

    func testAnOrdinaryNameSurvivesUntouched() {
        XCTAssertEqual(AlertCaptures.sanitizeCapture("Fail"), "Fail")
        XCTAssertEqual(AlertCaptures.sanitizeCapture("Coercer T`vala"), "Coercer T`vala")
    }

    /// OSC 52 writes the operator's clipboard and `ESC c` resets a terminal. Both leave whole,
    /// payload included, rather than being defanged into visible litter.
    func testAnsiSequencesLeaveWholePayloadAndAll() {
        XCTAssertEqual(AlertCaptures.sanitizeCapture("\u{1B}[31mFail\u{1B}[0m"), "Fail")
        XCTAssertEqual(AlertCaptures.sanitizeCapture("\u{1B}]52;c;cGF5bG9hZA==\u{7}Fail"), "Fail")
        XCTAssertEqual(AlertCaptures.sanitizeCapture("\u{1B}cFail"), "Fail")
        // ST-terminated rather than BEL-terminated.
        XCTAssertEqual(AlertCaptures.sanitizeCapture("\u{1B}]0;title\u{1B}\\Fail"), "Fail")
        // A malformed CSI falls out of arm 1 into arm 4 and still loses its ESC.
        XCTAssertEqual(AlertCaptures.sanitizeCapture("\u{1B}[Fail"), "ail")
        // A trailing lone ESC is consumed rather than passed through.
        XCTAssertEqual(AlertCaptures.sanitizeCapture("Fail\u{1B}"), "Fail")
    }

    /// A captured value must not be able to forge a second line on any surface that prints it.
    func testNewlinesAndControlsCannotForgeALine() {
        XCTAssertEqual(AlertCaptures.sanitizeCapture("Fail\r\nGuild Officer"), "Fail Guild Officer")
        XCTAssertEqual(AlertCaptures.sanitizeCapture("Fa\u{0}il"), "Fail")
        XCTAssertEqual(AlertCaptures.sanitizeCapture("Fa\u{9B}il"), "Fail")
    }

    /// The Trojan Source class: one string RENDERING as another.
    func testTheBidiAndInvisibleClassIsDeleted() {
        XCTAssertEqual(AlertCaptures.sanitizeCapture("Fa\u{202E}il"), "Fail")
        XCTAssertEqual(AlertCaptures.sanitizeCapture("\u{FEFF}Fail"), "Fail")
        XCTAssertEqual(AlertCaptures.sanitizeCapture("Fa\u{200B}il"), "Fail")
    }

    /// Nothing survived is nil, so the token renders literally rather than collapsing the phrase
    /// into a shorter, different sentence.
    func testAValueWithNothingLeftIsNil() {
        XCTAssertNil(AlertCaptures.sanitizeCapture(""))
        XCTAssertNil(AlertCaptures.sanitizeCapture("   "))
        XCTAssertNil(AlertCaptures.sanitizeCapture("\u{1B}[31m\u{1B}[0m"))
        XCTAssertNil(AlertCaptures.sanitizeCapture("\u{200B}\u{FEFF}"))
    }

    func testAHostilePatternCannotVacuumALineIntoTheSpeaker() {
        let long = String(repeating: "A", count: 300)
        let got = AlertCaptures.sanitizeCapture(long)!
        XCTAssertEqual(got.unicodeScalars.count, AlertCaptures.maxCaptureChars)
        // The cut is trimmed AFTER the cap.
        let padded = String(repeating: "B", count: 46) + "     tail"
        XCTAssertEqual(AlertCaptures.sanitizeCapture(padded), String(repeating: "B", count: 46))
    }

    func testAPatternThatNamesEightyThingsCarriesEight() {
        let pattern = (0..<12).map { "(?<g\($0)>[a-z])" }.joined()
        let got = harvest(pattern, "abcdefghijkl")!
        XCTAssertEqual(got.count, AlertCaptures.maxCaptureGroups)
        // The cut is declaration order, not the sorted order the map ends up in.
        XCTAssertNotNil(got["g0"])
        XCTAssertNotNil(got["g7"])
        XCTAssertNil(got["g8"])
    }

    /// A group that matched nothing does not spend a slot.
    func testAGroupThatCapturedNothingIsSkippedAndCostsNoSlot() {
        let got = harvest(#"(?<a>x)?(?<b>y)"#, "y")!
        XCTAssertEqual(got["b"], "y")
        XCTAssertNil(got["a"])
    }

    func testAPatternThatNamesNothingCarriesNothing() {
        XCTAssertNil(harvest(#"(\w+) on (\w+)"#, "Puma on Fail"))
    }

    func testFirstWriterWinsOnAMerge() {
        let a = harvest(#"(?<who>\w+)"#, "Fail")
        let b = harvest(#"(?<who>\w+) (?<what>\w+)"#, "Rowel Puma")
        let merged = AlertCaptures.mergeCaptures(a, b)!
        XCTAssertEqual(merged["who"], "Fail")
        XCTAssertEqual(merged["what"], "Puma")
        // Either side being absent is not a loss of the other.
        XCTAssertEqual(AlertCaptures.mergeCaptures(nil, a), a)
        XCTAssertEqual(AlertCaptures.mergeCaptures(a, nil), a)
        XCTAssertNil(AlertCaptures.mergeCaptures(nil, nil))
    }

    func testTheTableReadsTheFieldEachFamilyActuallyUses() {
        XCTAssertEqual(AlertCaptures.resolveTarget(evv(["kind": "buffApply", "target": "King Tranix"])), "King Tranix")
        // The hold lanes spell it `mob`, which is the whole reason the table exists.
        XCTAssertEqual(AlertCaptures.resolveTarget(evv(["kind": "cc", "mob": "a young puma"])), "a young puma")
        XCTAssertEqual(AlertCaptures.resolveTarget(evv(["kind": "spellEmote", "subject": "Rowel"])), "Rowel")
    }

    /// Speaking an item as the mob a spell is affecting would be a wrong answer wearing the right
    /// field name, and a con names a mob no spell is touching.
    func testTheExcludedKindsNameNobody() {
        XCTAssertNil(AlertCaptures.resolveTarget(evv(["kind": "itemMergeFailed", "target": "Coldain Prayer Shawl"])))
        XCTAssertNil(AlertCaptures.resolveTarget(evv(["kind": "consider", "mob": "a fire giant warlord"])))
        // …and a family with no entity field at all.
        XCTAssertNil(AlertCaptures.resolveTarget(evv(["kind": "zone"])))
    }

    func testTheParsersSentinelsAreSpokenAsEnglish() {
        XCTAssertEqual(AlertCaptures.resolveTarget(evv(["kind": "buffFade", "target": "self"])), "you")
        XCTAssertEqual(AlertCaptures.resolveTarget(evv(["kind": "buffFade", "target": "pet"])), "your pet")
        // An absent `buffFade.target` is the self form — the one entry where absence is a statement.
        XCTAssertEqual(AlertCaptures.resolveTarget(evv(["kind": "buffFade"])), "you")
        // …and an EMPTY field is as absent as a missing one.
        XCTAssertEqual(AlertCaptures.resolveTarget(evv(["kind": "buffFade", "target": "  "])), "you")
        // A player named `Self` is spoken as `Self`: the sentinels are matched exactly, never folded.
        XCTAssertEqual(AlertCaptures.resolveTarget(evv(["kind": "buffApply", "target": "Self"])), "Self")
        // Every other family's absent field is an absent answer, not a self form.
        XCTAssertNil(AlertCaptures.resolveTarget(evv(["kind": "buffApply"])))
    }

    func testOnlyAPhraseThatWritesTheTokenWantsIt() {
        XCTAssertTrue(AlertCaptures.wantsTargetToken("Mez broke on {target}"))
        XCTAssertFalse(AlertCaptures.wantsTargetToken("Mez broke"))
        XCTAssertFalse(AlertCaptures.wantsTargetToken(nil))
        // The grammar admits no whitespace and no modifiers, so neither of these is the token.
        XCTAssertFalse(AlertCaptures.wantsTargetToken("{ target }"))
        XCTAssertFalse(AlertCaptures.wantsTargetToken("{target.capitalize}"))
    }

    func testTheAutoTokenRidesOnlyWhenThePhraseAsked() {
        let event = evv(["kind": "cc", "mob": "King Tranix"])
        XCTAssertNil(AlertCaptures.withAutoCaptures(nil, false, event))
        XCTAssertEqual(AlertCaptures.withAutoCaptures(nil, true, event)?["target"], "King Tranix")
    }

    /// A group the pattern declared under that name is more specific than the table, and wins.
    func testADeclaredGroupBeatsTheAutoToken() {
        let event = evv(["kind": "cc", "mob": "King Tranix"])
        let declared = harvest(#"(?<target>\w+)"#, "Rowel")
        XCTAssertEqual(AlertCaptures.withAutoCaptures(declared, true, event)?["target"], "Rowel")
    }

    /// The cap is a property of the firing, so a def cannot buy a ninth value another way.
    func testAFullFiringTakesNoAutoToken() {
        let event = evv(["kind": "cc", "mob": "King Tranix"])
        let pattern = (0..<AlertCaptures.maxCaptureGroups).map { "(?<g\($0)>[a-z])" }.joined()
        let full = harvest(pattern, "abcdefgh")
        let got = AlertCaptures.withAutoCaptures(full, true, event)!
        XCTAssertEqual(got.count, AlertCaptures.maxCaptureGroups)
        XCTAssertNil(got["target"])
    }

    /// A family the table does not carry leaves the token unresolved.
    func testAFamilyThatNamesNobodyAddsNoKey() {
        XCTAssertNil(AlertCaptures.withAutoCaptures(nil, true, evv(["kind": "zone", "zone": "Freeport"])))
    }
}

// MARK: - alerts_rules.rs

final class AlertRulesTests: XCTestCase {
    func testAnEventTriggerFiresAndTheFrameIsFullyResolved() {
        let rules = set([def(["type": "event", "kind": "uncharm"])])
        let fires = fireNoOffset(rules, ev(#"{"kind":"uncharm","seq":1,"ts":1000,"raw":"Your charm spell has worn off.","mob":"a rat"}"#))
        XCTAssertEqual(fires.count, 1)
        XCTAssertEqual(fires[0].at, 1000)
        XCTAssertEqual(fires[0].rule, "Charm break")
        XCTAssertEqual(fires[0].sound, "classic/ding")
        XCTAssertEqual(fires[0].message, "Your charm spell has worn off.")
        // The three speech fields are absent, and that is the claim: this def declares no capture
        // group, writes no `{target}` phrase, matched a family that names no spell, carries no
        // offset — so its frame is the one it sent before the fields existed.
        XCTAssertNil(fires[0].captures)
        XCTAssertNil(fires[0].spell)
        XCTAssertNil(fires[0].dueAt)
    }

    func testADisabledAlertCompilesToNothing() {
        let off = with(def(["type": "event", "kind": "uncharm"]), "enabled", false)
        let rules = set([off])
        XCTAssertTrue(fireNoOffset(rules, ev(#"{"kind":"uncharm","seq":1,"ts":1,"raw":"x"}"#)).isEmpty)
        // …and the store's list still carries it: `defs` is the store's contract.
        XCTAssertEqual(rules.defs.count, 1)
    }

    /// The offset MOVES the one fire; it does not add a second — so a matching line makes no sound
    /// here and files an arm instead.
    func testADefWhoseFireTheOffsetMovesArmsInsteadOfSounding() {
        let early = with(def(["type": "event", "kind": "buffApply"]), "earlyWarnSec", 10)
        let rules = set([early])
        let sched = EarlyWarnings()
        let fires = rules.fire(ev(#"{"kind":"buffApply","seq":1,"ts":1000,"raw":"x","spell":"Dazzle","target":"a rat"}"#), sched)
        XCTAssertTrue(fires.isEmpty, "nothing sounds at the match")
        XCTAssertFalse(sched.idle, "…and a warning is waiting for its row")
        // The clock is not spent — a cooldown belongs to a sound, and no sound has been made.
        _ = rules.fire(ev(#"{"kind":"buffApply","seq":2,"ts":1100,"raw":"x","spell":"Dazzle","target":"a bat"}"#), sched)
        XCTAssertFalse(sched.idle)
    }

    /// An offset def still appears in the published set: `defs` is the STORE's contract.
    func testAnOffsetDefIsPublishedLikeAnyOther() {
        let early = with(def(["type": "event", "kind": "uncharm"]), "earlyWarnSec", 10)
        let rules = set([early])
        XCTAssertEqual(rules.defs.count, 1)
        // An `uncharm` trigger IS an ending, so this def watches rows rather than arming from its
        // own match.
        let w = rules.breakWatchers()
        XCTAssertEqual(w.count, 1)
        XCTAssertEqual(w.first?.0, "a1")
        XCTAssertEqual(w.first?.1, 10)
    }

    /// The normalizer is the app's: a zero, a negative, a string and an absent key all mean "no
    /// warning", while an out-of-range number is CLAMPED rather than read as absent.
    func testTheOffsetIsNormalizedTheWayTheAppNormalizesIt() {
        for absent: JSONValue in [0, -5, "10", .null] {
            XCTAssertNil(AlertsEarly.normalizeEarlyWarnSec(absent), "\(absent)")
        }
        XCTAssertEqual(AlertsEarly.normalizeEarlyWarnSec(10), 10)
        // Round, then the ceiling — never a refusal.
        XCTAssertEqual(AlertsEarly.normalizeEarlyWarnSec(9.6), 10)
        XCTAssertEqual(AlertsEarly.normalizeEarlyWarnSec(5000), 120)
        // …and the floor is a refusal rather than a clamp, because 0 means "no warning".
        XCTAssertNil(AlertsEarly.normalizeEarlyWarnSec(0.4))
    }

    func testAWhereMatcherNarrowsAndAnAbsentFieldNeverMatches() {
        let rules = set([def(["type": "event", "kind": "death", "where": ["name": "a fire giant"]])])
        XCTAssertEqual(fireNoOffset(rules, ev(#"{"kind":"death","seq":1,"ts":1,"raw":"d","name":"A Fire Giant"}"#)).count, 1)
        XCTAssertTrue(fireNoOffset(rules, ev(#"{"kind":"death","seq":2,"ts":9000,"raw":"d","name":"a rat"}"#)).isEmpty)
        XCTAssertTrue(fireNoOffset(rules, ev(#"{"kind":"death","seq":3,"ts":18000,"raw":"d"}"#)).isEmpty)
    }

    func testALiteralSpellMatcherIsRankBlindAndARegexOneIsNot() {
        let literal = set([def(["type": "event", "kind": "castBegin", "where": ["spell": "Elemental Maelstrom"]])])
        XCTAssertEqual(fireNoOffset(literal, ev(#"{"kind":"castBegin","seq":1,"ts":1,"raw":"c","spell":"Elemental Maelstrom III"}"#)).count, 1)
        let pattern = set([def(["type": "event", "kind": "castBegin", "where": ["spell": "/^Elemental Maelstrom$/"]])])
        XCTAssertTrue(fireNoOffset(pattern, ev(#"{"kind":"castBegin","seq":1,"ts":1,"raw":"c","spell":"Elemental Maelstrom III"}"#)).isEmpty)
    }

    func testTheRankFoldReachesADamageSkillOnlyForTheTwoSpellDtypes() {
        let rules = set([def(["type": "event", "kind": "damage", "where": ["skill": "Harm Touch"]])])
        XCTAssertEqual(fireNoOffset(rules, ev(#"{"kind":"damage","seq":1,"ts":1,"raw":"d","dtype":"spell","skill":"Harm Touch III"}"#)).count, 1)
        // The gate is on the dtype rather than a measurement.
        XCTAssertTrue(fireNoOffset(rules, ev(#"{"kind":"damage","seq":2,"ts":9000,"raw":"d","dtype":"ds","skill":"Harm Touch III"}"#)).isEmpty)
    }

    func testASpellMatcherTestsTheWholeCandidateFamily() {
        let rules = set([def(["type": "event", "kind": "buffApply", "where": ["spell": "Shiftless Deeds"]])])
        // The parser's best-effort pick is another member of the family; the truth is in
        // `candidates`, and an alert on any one of them is an alert on the family.
        let fires = fireNoOffset(rules, ev(#"{"kind":"buffApply","seq":1,"ts":1,"raw":"a mob slows down.","spell":"Forlorn Deeds","candidates":[{"name":"Forlorn Deeds"},{"name":"Shiftless Deeds"}]}"#))
        XCTAssertEqual(fires.count, 1)
    }

    func testARawTriggerReadsTheLineAndACompositeReadsOneEvent() {
        let raw = set([def(["type": "raw", "regex": "you have been slain"])])
        XCTAssertEqual(fireNoOffset(raw, ev(#"{"kind":"unknown","seq":1,"ts":1,"raw":"You have been slain by a rat!"}"#)).count, 1)
        let all = set([def(["type": "all", "conditions": [
            ["type": "event", "kind": "damage", "where": ["dtype": "spell"]],
            ["type": "event", "kind": "damage", "where": ["target": "Primitive"]]
        ]])])
        XCTAssertEqual(fireNoOffset(all, ev(#"{"kind":"damage","seq":1,"ts":1,"raw":"d","dtype":"spell","target":"Primitive"}"#)).count, 1)
        XCTAssertTrue(fireNoOffset(all, ev(#"{"kind":"damage","seq":2,"ts":9000,"raw":"d","dtype":"melee","target":"Primitive"}"#)).isEmpty)
    }

    func testTheCooldownIsPerAlertUnlessTheDefAsksForPerTarget() {
        let a = #"{"kind":"death","seq":1,"ts":1000,"raw":"d","target":"a rat"}"#
        let b = #"{"kind":"death","seq":2,"ts":1500,"raw":"d","target":"a fire giant"}"#
        let plain = set([def(["type": "event", "kind": "death"])])
        XCTAssertEqual(fireNoOffset(plain, ev(a)).count, 1)
        XCTAssertTrue(fireNoOffset(plain, ev(b)).isEmpty, "one clock silences both")

        let scoped = with(def(["type": "event", "kind": "death"]), "cooldownScope", "target")
        let perTarget = set([scoped])
        XCTAssertEqual(fireNoOffset(perTarget, ev(a)).count, 1)
        XCTAssertEqual(fireNoOffset(perTarget, ev(b)).count, 1, "the first match on a new mob always fires")
        XCTAssertTrue(fireNoOffset(perTarget, ev(a)).isEmpty, "and only re-lands on THAT mob are quiet")
    }

    func testAFireIsRecordedInTheAlertsOwnRing() {
        let rules = set([def(["type": "event", "kind": "uncharm"])])
        _ = fireNoOffset(rules, ev(#"{"kind":"uncharm","seq":1,"ts":1000,"raw":"broke!"}"#))
        XCTAssertEqual(rules.history(), ["a1": .array([["ts": 1000, "matchedText": "broke!"]])])
    }

    func testAFullSetReplaceForgetsThePreviousSet() {
        let rules = set([def(["type": "event", "kind": "uncharm"])])
        let other = with(def(["type": "event", "kind": "death"]), "id", "a2")
        rules.setDefs([other])
        XCTAssertEqual(rules.defs.count, 1)
        XCTAssertTrue(fireNoOffset(rules, ev(#"{"kind":"uncharm","seq":1,"ts":1,"raw":"x"}"#)).isEmpty)
        XCTAssertEqual(fireNoOffset(rules, ev(#"{"kind":"death","seq":2,"ts":2,"raw":"d"}"#)).count, 1)
    }

    func testAnAppTriggerNeverFiresHere() {
        let rules = set([def(["type": "app", "signal": "bossDefeat"])])
        XCTAssertTrue(fireNoOffset(rules, ev(#"{"kind":"death","seq":1,"ts":1,"raw":"d"}"#)).isEmpty)
    }

    /// A pattern the engine cannot compile degrades exactly as the TS handles one V8 cannot: a
    /// `where` matcher falls back to LITERAL equality on the spec, slashes and all, and a `raw`
    /// trigger compiles to a pattern nothing can satisfy.
    ///
    /// DIVERGENCE FROM THE RUST BUILD, STATED: this build compiles user patterns with ICU, which has
    /// lookaround and backreferences, so the SET of patterns falling into this path is SMALLER here
    /// than on the Rust side — and the same as the app's own V8. The Rust suite pins this with
    /// `(?<=a )rat`, which ICU compiles; an unbalanced group is what neither engine accepts.
    func testARegexThisEngineCannotCompileDegradesTheWayTheAppDoes() {
        let field = set([def(["type": "event", "kind": "death", "where": ["name": "/(a rat/"]])])
        XCTAssertTrue(fireNoOffset(field, ev(#"{"kind":"death","seq":1,"ts":1,"raw":"d","name":"a rat"}"#)).isEmpty)
        let raw = set([def(["type": "raw", "regex": "(a rat"])])
        XCTAssertTrue(fireNoOffset(raw, ev(#"{"kind":"unknown","seq":1,"ts":1,"raw":"a rat"}"#)).isEmpty)
        // …and the lookbehind the Rust build refuses is honoured here, as V8 honours it.
        let look = set([def(["type": "raw", "regex": "(?<=a )rat"])])
        XCTAssertEqual(fireNoOffset(look, ev(#"{"kind":"unknown","seq":1,"ts":1,"raw":"a rat"}"#)).count, 1)
    }

    // Everything above asks whether a line makes a sound. What follows asks what that sound says.

    /// A `raw` condition captures from `ev.raw` — the exact line it just tested.
    func testADeclaredGroupRidesOutOnTheFiring() {
        let rules = set([def(["type": "raw",
                              "regex": .string(#"^\[[^\]]*\] (?<player>[A-Za-z' `]{1,48}) growls with the spirit of the puma\."#)])])
        let fires = fireNoOffset(rules, ev(#"{"kind":"spellEmote","seq":1,"ts":1000,"raw":"[Sat Aug 01 18:38:10 2026] Fail growls with the spirit of the puma."}"#))
        XCTAssertEqual(fires.count, 1)
        XCTAssertEqual(fires[0].captures?["player"], "Fail")
    }

    /// An `event` condition's `/regex/` matcher captures from the value of the one field it tested,
    /// on the one kind the trigger names — control 3, structurally.
    func testAWhereMatcherCapturesFromTheFieldItTested() {
        let rules = set([def(["type": "event", "kind": "cc",
                              "where": ["mob": .string(#"/^(?<mob>a \w+ puma)$/"#)]])])
        let fires = fireNoOffset(rules, ev(#"{"kind":"cc","seq":1,"ts":1000,"raw":"a young puma is mesmerized.","mob":"a young puma","spell":"Mesmerization III"}"#))
        XCTAssertEqual(fires[0].captures?["mob"], "a young puma")
        // …and a literal matcher declares no names, so it captures nothing.
        let literal = set([def(["type": "event", "kind": "cc", "where": ["mob": "a young puma"]])])
        XCTAssertNil(fireNoOffset(literal, ev(#"{"kind":"cc","seq":2,"ts":2000,"raw":"a young puma is mesmerized.","mob":"a young puma"}"#))[0].captures)
    }

    /// The one token filled in without a group, and the gate that keeps it off every firing that
    /// never asked.
    func testTheTargetTokenRidesOnlyWhenThePhraseWritesIt() {
        let line = #"{"kind":"cc","seq":1,"ts":1000,"raw":"a young puma is mesmerized.","mob":"a young puma"}"#
        let asked = set([speakingDef(["type": "event", "kind": "cc"], "Mez broke on {target}")])
        XCTAssertEqual(fireNoOffset(asked, ev(line))[0].captures?["target"], "a young puma")
        // The same def with no phrase carries nothing.
        let silent = set([def(["type": "event", "kind": "cc"])])
        XCTAssertNil(fireNoOffset(silent, ev(line))[0].captures)
    }

    /// The sentinels are the parser's vocabulary, not names.
    func testASelfFormSpeaksEnglish() {
        let rules = set([speakingDef(["type": "event", "kind": "buffFade"], "{target} lost it")])
        let fires = fireNoOffset(rules, ev(#"{"kind":"buffFade","seq":1,"ts":1000,"raw":"Your Clarity spell has worn off.","spell":"Clarity"}"#))
        XCTAssertEqual(fires[0].captures?["target"], "you")
    }

    /// The spell, rank INTACT. Stripping is the speaker's job.
    func testTheFiringNamesItsSpellWithTheRankLeftOn() {
        let rules = set([def(["type": "event", "kind": "castBegin"])])
        let fires = fireNoOffset(rules, ev(#"{"kind":"castBegin","seq":1,"ts":1000,"raw":"You begin casting Mesmerization III.","spell":"Mesmerization III"}"#))
        XCTAssertEqual(fires[0].spell, "Mesmerization III")
    }

    /// The name reported is the candidate that satisfied the def's OWN matcher.
    func testTheSpellReportedIsTheOneTheAlertMatchedOn() {
        let rules = set([def(["type": "event", "kind": "buffApply", "where": ["spell": "Shiftless Deeds"]])])
        let fires = fireNoOffset(rules, ev(#"{"kind":"buffApply","seq":1,"ts":1000,"raw":"King Tranix slows down.","spell":"Forlorn Deeds","candidates":["Forlorn Deeds","Shiftless Deeds"],"target":"King Tranix"}"#))
        XCTAssertEqual(fires[0].spell, "Shiftless Deeds")
    }

    /// A family that names no spell says so, rather than inventing one.
    func testAFamilyWithNoSpellNamesNone() {
        let rules = set([def(["type": "event", "kind": "uncharm"])])
        let fires = fireNoOffset(rules, ev(#"{"kind":"uncharm","seq":1,"ts":1000,"raw":"Your charm spell has worn off.","mob":"a rat"}"#))
        XCTAssertNil(fires[0].spell)
    }

    /// Values are defanged before they reach the frame — control 1 asked of the whole evaluator.
    /// The line carries an OSC 52 and a BiDi override; neither survives, and the name does.
    func testAnAttackerInfluencedCaptureArrivesDefanged() {
        let rules = set([def(["type": "raw", "regex": "^(?<who>.+) tells you"])])
        let hostile = "\u{1B}]52;c;cGF5bG9hZA==\u{7}Ro\u{202E}wel tells you hello"
        let fires = fireNoOffset(rules, evv(["kind": "tell", "seq": 1, "ts": 1000, "raw": .string(hostile)]))
        XCTAssertEqual(fires[0].captures?["who"], "Rowel")
    }

    /// An ordinary fire warns about nothing, so it carries no deadline.
    func testAnOrdinaryFireCarriesNoDeadline() {
        let rules = set([def(["type": "event", "kind": "uncharm"])])
        let fires = fireNoOffset(rules, ev(#"{"kind":"uncharm","seq":1,"ts":1000,"raw":"Your charm spell has worn off.","mob":"a rat"}"#))
        XCTAssertNil(fires[0].dueAt)
    }
}

// MARK: - alerts_early.rs

/// A scheduler with no break-family def watching — every landing-path test.
private final class NoWatchers: BreakWatchers {
    func breakWatchers() -> [(String, Int64)] { [] }
    func hasBreakWatchers() -> Bool { false }
    func probeBreak(_ alertId: String, _ row: BuffTimerRow, _ nowMs: Int64) -> (ArmedFire, String)? { nil }
}

/// A break-family watcher that says yes to everything, so the schedule is what is under test.
private final class AlwaysWatching: BreakWatchers {
    let sec: Int64
    init(_ sec: Int64) { self.sec = sec }
    func breakWatchers() -> [(String, Int64)] { [("a1", sec)] }
    func hasBreakWatchers() -> Bool { true }
    func probeBreak(_ alertId: String, _ row: BuffTimerRow, _ nowMs: Int64) -> (ArmedFire, String)? {
        (ArmedFire(alertId: alertId, rule: "Slow wore off a mob", sound: "classic/ding",
                   message: AlertsEarly.breakProbeText(row, row.name), captures: nil,
                   // A stand-in for a def's own matcher; the real one puts the probe's spell on the
                   // arm (`AlertRuleSet.probeBreak`).
                   spell: nil), alertId)
    }
}

final class AlertsEarlyTests: XCTestCase {
    private func armedFire(_ id: String) -> ArmedFire {
        ArmedFire(alertId: id, rule: "Mez landed", sound: "classic/ding",
                  message: "a turmoil toad has been mesmerized.", captures: nil, spell: nil)
    }

    private func arm(_ id: String, _ sec: Int64, _ target: String?, _ names: [String], _ ts: Int64) -> EarlyWarnArm {
        EarlyWarnArm(sec: sec, cooldownKey: id,
                     subject: EarlyWarnSubject(targetKey: target, spellNames: names),
                     ts: ts, fired: armedFire(id))
    }

    func testTheDeadlineIsTheRowsStatedEndMinusTheOffset() {
        let row = debuffRow("Dazzle", "a turmoil toad", 1_000, 48_000)
        XCTAssertEqual(AlertsEarly.earlyWarnFireAt(row, 10), 1_000 + 48_000 - 10_000)
        // A count-up row states no end, so silence is the answer rather than an invented duration.
        XCTAssertNil(AlertsEarly.earlyWarnFireAt(debuffRow("Dazzle", "a turmoil toad", 1_000, nil), 10))
    }

    func testALandingIsTrackedByTheNewestRowOnItsOwnEntity() {
        let rows = [
            debuffRow("Dazzle", "a turmoil toad", 1_000, 48_000),
            debuffRow("Dazzle", "a fire giant", 5_000, 48_000),
            debuffRow("Languid Pace", "a turmoil toad", 3_000, 60_000)
        ]
        let subject = EarlyWarnSubject(targetKey: "a turmoil toad")
        XCTAssertEqual(AlertsEarly.earlyWarnRowFor(rows, subject)?.name, "Languid Pace")
        // …and a named subject narrows to the rows that answer to that name, older or not.
        let named = EarlyWarnSubject(targetKey: "a turmoil toad", spellNames: ["Dazzle"])
        XCTAssertEqual(AlertsEarly.earlyWarnRowFor(rows, named)?.name, "Dazzle")
    }

    /// A subject whose names match nothing falls back to all of them, never to nothing.
    func testAnUnmatchedNameFallsBackToTheEntitysRows() {
        let rows = [debuffRow("Dazzle", "a turmoil toad", 1_000, 48_000)]
        let subject = EarlyWarnSubject(targetKey: "a turmoil toad", spellNames: ["Something Else Entirely"])
        XCTAssertNotNil(AlertsEarly.earlyWarnRowFor(rows, subject))
    }

    /// A self landing and a mob landing are exclusive.
    func testASelfSubjectNeverMatchesAMobsRow() {
        XCTAssertNil(AlertsEarly.earlyWarnRowFor([debuffRow("Dazzle", "a turmoil toad", 1_000, 48_000)],
                                                 EarlyWarnSubject()))
        XCTAssertNotNil(AlertsEarly.earlyWarnRowFor([selfRow("Clarity", 1_000, 60_000)], EarlyWarnSubject()))
    }

    /// A row with no stated end is not a candidate at all — the honesty law, at the entry point.
    func testACountUpRowIsNeverTheRowALandingIsTrackedBy() {
        let rows = [debuffRow("Dazzle", "a turmoil toad", 1_000, nil)]
        XCTAssertNil(AlertsEarly.earlyWarnRowFor(rows, EarlyWarnSubject(targetKey: "a turmoil toad")))
    }

    func testAnArmResolvesOnTheNextTickAndSpeaksAtItsDeadline() {
        let early = EarlyWarnings()
        let w = NoWatchers()
        early.arm(arm("a1", 10, "a turmoil toad", ["Dazzle"], 1_000))
        let rows = [debuffRow("Dazzle", "a turmoil toad", 1_000, 48_000)]

        // The resolve tick: the row exists now, so the arm attaches — and says nothing.
        XCTAssertTrue(early.tick(2_000, rows, w).isEmpty)
        XCTAssertFalse(early.idle, "the warning is armed and waiting")
        // …and one second before the deadline it is still silent.
        XCTAssertTrue(early.tick(38_000, rows, w).isEmpty)
        // At the deadline it speaks, exactly once, and the schedule is then empty.
        let due = early.tick(39_000, rows, w)
        XCTAssertEqual(due.count, 1)
        XCTAssertEqual(due[0].fired.alertId, "a1")
        XCTAssertEqual(due[0].cooldownKey, "a1")
        XCTAssertTrue(early.idle, "a warning that spoke is spent")
    }

    /// No row, no warning.
    func testAWarningWhoseRowHasGoneIsCancelledRatherThanFired() {
        let early = EarlyWarnings()
        let w = NoWatchers()
        early.arm(arm("a1", 10, "a turmoil toad", ["Dazzle"], 1_000))
        _ = early.tick(2_000, [debuffRow("Dazzle", "a turmoil toad", 1_000, 48_000)], w)
        XCTAssertFalse(early.idle)
        // The row is gone. Long past the deadline, nothing speaks.
        XCTAssertTrue(early.tick(99_000, [], w).isEmpty)
        XCTAssertTrue(early.idle)
    }

    /// The deadline is re-read every tick, because both halves move.
    func testAReStatedDurationMovesTheDeadlineUnderALiveWarning() {
        let early = EarlyWarnings()
        let w = NoWatchers()
        early.arm(arm("a1", 10, "a turmoil toad", ["Dazzle"], 1_000))
        _ = early.tick(2_000, [debuffRow("Dazzle", "a turmoil toad", 1_000, 48_000)], w)
        let long = [debuffRow("Dazzle", "a turmoil toad", 1_000, 90_000)]
        XCTAssertTrue(early.tick(39_000, long, w).isEmpty)
        XCTAssertEqual(early.tick(81_000, long, w).count, 1)
    }

    /// An offset longer than the debuff fires at once.
    func testAnOverlongOffsetSpeaksOnTheFirstTickItCan() {
        let early = EarlyWarnings()
        early.arm(arm("a1", 30, "a turmoil toad", ["Dazzle"], 1_000))
        XCTAssertEqual(early.tick(2_000, [debuffRow("Dazzle", "a turmoil toad", 1_000, 24_000)], NoWatchers()).count, 1)
    }

    /// An arm that never finds a row is dropped at the window.
    func testAnArmThatFindsNoRowIsDroppedAtTheWindow() {
        let early = EarlyWarnings()
        let w = NoWatchers()
        early.arm(arm("a1", 10, "a turmoil toad", ["Dazzle"], 1_000))
        _ = early.tick(1_000 + AlertsEarly.armResolveWindowMs, [], w)
        XCTAssertFalse(early.idle)
        _ = early.tick(1_000 + AlertsEarly.armResolveWindowMs + 1, [], w)
        XCTAssertTrue(early.idle)
    }

    /// Re-arming the same (alert, row) replaces.
    func testAReLandOnAWatchedRowMovesTheWarningRatherThanAddingOne() {
        let early = EarlyWarnings()
        let w = NoWatchers()
        let rows = [debuffRow("Dazzle", "a turmoil toad", 1_000, 48_000)]
        early.arm(arm("a1", 10, "a turmoil toad", ["Dazzle"], 1_000))
        _ = early.tick(2_000, rows, w)
        early.arm(arm("a1", 10, "a turmoil toad", ["Dazzle"], 3_000))
        _ = early.tick(4_000, rows, w)
        XCTAssertEqual(early.tick(39_000, rows, w).count, 1, "one warning, not two")
    }

    func testALandingsSubjectReadsMobThenTargetAndMapsSelfToThePlayer() {
        let mez = ev(#"{"kind":"cc","seq":1,"ts":1,"raw":"m","mob":"A Turmoil Toad"}"#)
        XCTAssertEqual(AlertsEarly.earlyWarnSubject(mez, []).targetKey, "a turmoil toad",
                       "canonicalized, so two spellings are one entity")
        let mine = ev(#"{"kind":"buffApply","seq":1,"ts":1,"raw":"b","target":"self"}"#)
        XCTAssertNil(AlertsEarly.earlyWarnSubject(mine, []).targetKey,
                     "'self' is the model's word for the player, not a mob called self")
    }

    /// A warning and its break share an identity, rank-blind on both sides.
    func testARowAndItsBreakLineFoldToTheSameIdentity() {
        let row = debuffRow("Mesmerization VII", "a turmoil toad", 1_000, 48_000)
        let brk = ev(#"{"kind":"cc","seq":1,"ts":1,"raw":"b","mob":"a turmoil toad","spell":"Mesmerization","refresh":true}"#)
        let fromRow = AlertsEarly.rowBreakIdentity(row)
        let fromEv = AlertsEarly.breakEventIdentity(brk, [])
        XCTAssertTrue(fromRow.contains { fromEv.contains($0) }, "\(fromRow) vs \(fromEv)")
    }

    /// A self row's entity key is the literal 'self'.
    func testASelfRowsIdentityIsTheWordTheWearOffLineUses() {
        let row = selfRow("Clarity", 1_000, 60_000)
        let brk = ev(#"{"kind":"buffExpired","seq":1,"ts":1,"raw":"b","spell":"Clarity","target":"self"}"#)
        let fromEv = AlertsEarly.breakEventIdentity(brk, [])
        XCTAssertTrue(AlertsEarly.rowBreakIdentity(row).contains { fromEv.contains($0) })
    }

    /// Which triggers are endings. A bare `{kind:'cc'}` matches the application too.
    func testATriggerIsABreakOnlyWhenItCanOnlyBeOne() {
        let acceptsTrue: (String) -> Bool = { $0.lowercased() == "true" }
        func brk(_ t: JSONValue) -> [BreakKind] { AlertsEarly.breakTriggerKinds(t, acceptsTrue) }
        XCTAssertEqual(brk(["type": "event", "kind": "uncharm"]), [.uncharm])
        XCTAssertEqual(brk(["type": "event", "kind": "buffFade"]), [.buffFade])
        XCTAssertTrue(brk(["type": "event", "kind": "cc"]).isEmpty, "a bare cc is a landing")
        XCTAssertEqual(brk(["type": "event", "kind": "cc", "where": ["refresh": "true"]]), [.cc])
        XCTAssertEqual(brk(["type": "event", "kind": "cc", "where": ["spell": "Dazzle"]]), [.cc],
                       "the application sentence names no spell, so a spell matcher can only be a break")
        // A `raw` condition can describe no hypothetical line, and a mixed composite keeps the
        // landing behaviour rather than half of each.
        XCTAssertTrue(brk(["type": "raw", "regex": "anything"]).isEmpty)
        XCTAssertTrue(brk(["type": "any", "conditions": [
            ["type": "event", "kind": "uncharm"],
            ["type": "event", "kind": "buffApply"]
        ]]).isEmpty)
        // …and the `wearsOff` template's two halves are both probed, which is why this is a list.
        XCTAssertEqual(brk(["type": "any", "conditions": [
            ["type": "event", "kind": "buffExpired"],
            ["type": "event", "kind": "buffWearOff"]
        ]]), [.buffExpired, .buffWearOff])
    }

    /// The probe is the measured shape per kind, and a kind that cannot describe this row yields
    /// nothing.
    func testAProbeIsTheBreakEventThisRowWouldProduce() {
        let row = debuffRow("Dazzle", "a turmoil toad", 1_000, 48_000)
        let probes = AlertsEarly.breakProbes(.cc, row, 9_000)
        XCTAssertEqual(probes.count, 1)
        XCTAssertEqual(probes[0].spell, "Dazzle")
        XCTAssertEqual(probes[0].ev.kind, "cc")
        XCTAssertEqual(probes[0].ev.str(Key.mob), "a turmoil toad")
        XCTAssertTrue(probes[0].ev.bool(Key.refresh))
        // Not a log-shaped line, on purpose.
        XCTAssertEqual(probes[0].ev.raw, "Dazzle on a turmoil toad is about to end")
        // …and a self row has no `cc` break at all.
        XCTAssertTrue(AlertsEarly.breakProbes(.cc, selfRow("Clarity", 1, 2), 9).isEmpty)
        // The self-only kind is the mirror of it.
        XCTAssertEqual(AlertsEarly.breakProbes(.buffWearOff, selfRow("Clarity", 1_000, 60_000), 9_000).count, 1)
        XCTAssertTrue(AlertsEarly.breakProbes(.buffWearOff, row, 9_000).isEmpty)
    }

    func testABreakFamilyDefArmsFromTheRowAndSpeaksBeforeTheBreak() {
        let early = EarlyWarnings()
        let rows = [debuffRow("Shiftless Deeds", "King Tranix", 1_000, 60_000)]
        let watchers = AlwaysWatching(5)

        // The row exists; the deadline is 55 s in. Nothing yet.
        XCTAssertTrue(early.tick(2_000, rows, watchers).isEmpty)
        XCTAssertFalse(early.idle, "the row is watched")

        let due = early.tick(56_000, rows, watchers)
        XCTAssertEqual(due.count, 1)
        XCTAssertEqual(due[0].fired.message, "Shiftless Deeds on King Tranix is about to end")
        // A spoken watch is kept, not deleted. It also does not speak twice.
        XCTAssertTrue(early.tick(57_000, rows, watchers).isEmpty)
        XCTAssertFalse(early.idle)

        // …and the break arriving now is swallowed. One landing, one firing.
        let brk = ev(#"{"kind":"buffFade","seq":1,"ts":61000,"raw":"b","spell":"Shiftless Deeds","target":"King Tranix"}"#)
        XCTAssertTrue(early.breakSpoken("a1", AlertsEarly.breakEventIdentity(brk, [])))
        // The watch is consumed by the break it pre-empted, so a re-land can warn again.
        XCTAssertFalse(early.breakSpoken("a1", AlertsEarly.breakEventIdentity(brk, [])))
    }

    /// An early break is never silent.
    func testAHoldThatBreaksEarlySuppressesNothing() {
        let early = EarlyWarnings()
        let rows = [debuffRow("Shiftless Deeds", "King Tranix", 1_000, 60_000)]
        _ = early.tick(2_000, rows, AlwaysWatching(5))
        let brk = ev(#"{"kind":"buffFade","seq":1,"ts":20000,"raw":"b","spell":"Shiftless Deeds","target":"King Tranix"}"#)
        XCTAssertFalse(early.breakSpoken("a1", AlertsEarly.breakEventIdentity(brk, [])),
                       "nothing spoke, so nothing is spent")
    }

    /// A deadline already in the past never arms on the break path.
    func testARowAlreadyPastItsDeadlineArmsNoBreakWarning() {
        let early = EarlyWarnings()
        let rows = [debuffRow("Shiftless Deeds", "King Tranix", 1_000, 60_000)]
        XCTAssertTrue(early.tick(90_000, rows, AlwaysWatching(5)).isEmpty)
        XCTAssertTrue(early.idle, "nothing was armed at all")
    }

    /// A watch retires with its row, or with the def that wanted it.
    func testAWatchDiesWithItsRowAndWithItsDef() {
        let early = EarlyWarnings()
        let rows = [debuffRow("Shiftless Deeds", "King Tranix", 1_000, 60_000)]
        _ = early.tick(2_000, rows, AlwaysWatching(5))
        XCTAssertFalse(early.idle)
        _ = early.tick(3_000, [], AlwaysWatching(5))
        XCTAssertTrue(early.idle, "the hold ended, however it ended")

        _ = early.tick(4_000, rows, AlwaysWatching(5))
        XCTAssertFalse(early.idle)
        // The alert was deleted, disabled, or had its offset removed while the watch was pending.
        _ = early.tick(5_000, rows, NoWatchers())
        XCTAssertTrue(early.idle)
    }
}

// MARK: - alerts.rs (the module and its heartbeat)

final class AlertsModuleTests: XCTestCase {
    /// `group:slow:mob`, copied verbatim out of `src/shared/alertGroups.ts` — the dev profile's own
    /// def. `buffFade` is where `classifyWornOff` routes a slow's `Your <X> spell has worn off of
    /// <mob>.`, and because `buffFade` IS an ending this def is BREAK-FAMILY.
    private static let slowSpellsMob =
        "/^(Languid Pace|Tepid Deeds|Shiftless Deeds|Forlorn Deeds|Drowsy|Walking Sleep|"
        + "Tagar.s Insects|Togor.s Insects|Turgur.s Insects|Tigir.s Insects|"
        + "Largo.s Melodic Binding|Largo.s Assonant Binding)"
        + "(?: (?:I|II|III|IV|V|VI|VII|VIII|IX|X))?$/"

    private func slowWoreOffAMob(_ earlyWarnSec: Int64?) -> JSONValue {
        let d: JSONValue = [
            "id": "group:slow:mob",
            "name": "Slow wore off a mob",
            "enabled": true,
            "cooldownMs": 5000,
            "sound": ["packId": "alan-rickman", "soundId": "slow-expired"],
            "trigger": ["type": "event", "kind": "buffFade",
                        "where": ["spell": .string(Self.slowSpellsMob)]]
        ]
        guard let sec = earlyWarnSec else { return d }
        return with(d, "earlyWarnSec", .int(sec))
    }

    /// One live countdown row for a slow on a mob, as `buildTimerRows` produces it.
    private func slowRow(_ started: Int64, _ duration: Int64?) -> BuffTimerRow {
        BuffTimerRow(id: "debuff|king tranix|shiftless deeds", kind: .debuff, name: "Shiftless Deeds",
                     castName: nil, candidates: nil, ambiguous: false, group: .target,
                     target: "King Tranix", targetKey: "king tranix", inferredTarget: false,
                     startedTs: started, calmsTarget: false,
                     mode: duration != nil ? .countdown : .elapsed, durationMs: duration,
                     count: nil, caster: nil)
    }

    /// The real wear-off line, as `classifyWornOff` routes it.
    private static let woreOff = #"{"kind":"buffFade","seq":9,"ts":61000,"raw":"Your Shiftless Deeds spell has worn off of King Tranix.","spell":"Shiftless Deeds","target":"King Tranix"}"#

    private func module(_ earlyWarnSec: Int64?) -> AlertsModule {
        let m = AlertsModule()
        m.define(.array([slowWoreOffAMob(earlyWarnSec)]))
        return m
    }

    /// A def with `earlyWarnSec: 5` arms off the timer projection and fires five seconds before the
    /// row's stated end.
    func testTheOwnersSlowAlertWithAnOffsetArmsAndFiresEarly() {
        let m = module(5)
        let rows = [slowRow(1_000, 60_000)]

        // The heartbeat sees the live row and files a watch. 55 s to go, so nothing sounds.
        m.onTick(nowMs: 2_000, timerRows: rows)
        XCTAssertTrue(m.takeFires().isEmpty)
        // …and one second short of the deadline, still nothing.
        m.onTick(nowMs: 55_000, timerRows: rows)
        XCTAssertTrue(m.takeFires().isEmpty)

        // Five seconds before the stated end, it speaks.
        m.onTick(nowMs: 56_000, timerRows: rows)
        let fires = m.takeFires()
        XCTAssertEqual(fires.count, 1, "an early warning fired")
        XCTAssertEqual(fires[0].rule, "Slow wore off a mob")
        XCTAssertEqual(fires[0].sound, "alan-rickman/slow-expired")
        // The matched text is the projection sentence, because no line has been printed.
        XCTAssertEqual(fires[0].message, "Shiftless Deeds on King Tranix is about to end")
        // `at` is the heartbeat's instant: an early warning has no matching event.
        XCTAssertEqual(fires[0].at, 56_000)
        // `dueAt` is the row's stated end, 1,000 + 60,000.
        XCTAssertEqual(fires[0].dueAt, 61_000)
        // The spoken spell is the probe's rank-less name.
        XCTAssertEqual(fires[0].spell, "Shiftless Deeds")

        // It does not speak twice for one landing.
        m.onTick(nowMs: 57_000, timerRows: rows)
        XCTAssertTrue(m.takeFires().isEmpty)

        // …and the break line that follows is swallowed. One landing, one firing.
        m.onEvent(ev(Self.woreOff), live: true)
        XCTAssertTrue(m.takeFires().isEmpty)
    }

    /// An early warning speaks the mob it armed on, on the path where that is hardest: a
    /// break-family def has no event to ask, so `{target}` comes off the probe's hypothetical event.
    func testAnEarlyWarningSpeaksTheMobItArmedOn() {
        let d = with(slowWoreOffAMob(5), "speech", ["mode": "custom", "phrase": "Slow breaking on {target}"])
        let m = AlertsModule()
        m.define(.array([d]))
        let rows = [slowRow(1_000, 60_000)]

        m.onTick(nowMs: 2_000, timerRows: rows)
        m.onTick(nowMs: 56_000, timerRows: rows)
        let fires = m.takeFires()
        XCTAssertEqual(fires.count, 1)
        XCTAssertEqual(fires[0].captures?["target"], "King Tranix")
    }

    /// An early break is never silent.
    func testASlowThatBreaksEarlyStillFiresAtTheBreak() {
        let m = module(5)
        m.onTick(nowMs: 2_000, timerRows: [slowRow(1_000, 60_000)])
        XCTAssertTrue(m.takeFires().isEmpty)
        m.onEvent(ev(Self.woreOff), live: true)
        let fires = m.takeFires()
        XCTAssertEqual(fires.count, 1, "the break is not suppressed by a silence")
        XCTAssertEqual(fires[0].message, "Your Shiftless Deeds spell has worn off of King Tranix.")
        XCTAssertEqual(fires[0].at, 61_000, "a real line is stamped by the LOG")
    }

    /// The offset MOVES the one fire; it does not add a second.
    func testTheSameDefWithoutAnOffsetFiresAtTheLine() {
        let m = module(nil)
        m.onTick(nowMs: 56_000, timerRows: [slowRow(1_000, 60_000)])
        XCTAssertTrue(m.takeFires().isEmpty, "no offset, nothing to arm")
        m.onEvent(ev(Self.woreOff), live: true)
        XCTAssertEqual(m.takeFires().count, 1)
    }

    /// A row the model puts no honest number on arms nothing.
    func testACountUpRowArmsNoWarning() {
        let m = module(5)
        let rows = [slowRow(1_000, nil)]
        m.onTick(nowMs: 2_000, timerRows: rows)
        m.onTick(nowMs: 999_000, timerRows: rows)
        XCTAssertTrue(m.takeFires().isEmpty)
        m.onEvent(ev(Self.woreOff), live: true)
        XCTAssertEqual(m.takeFires().count, 1)
    }

    /// A historical fold reaches none of it: the boundary law is one gate above the matcher.
    func testAReplayedWearOffNeitherFiresNorArms() {
        let m = module(5)
        m.onEvent(ev(Self.woreOff), live: false)
        XCTAssertTrue(m.takeFires().isEmpty)
        // …and nothing was armed either, so a later tick has nothing to deliver.
        m.onTick(nowMs: 999_000, timerRows: [slowRow(1_000, 60_000)])
        XCTAssertTrue(m.takeFires().isEmpty)
    }

    /// The projection is only built when something will read it.
    func testAModuleWithNoOffsetNeverAsksForTheTimerProjection() {
        XCTAssertFalse(module(nil).wantsTimerRows, "no offset, nothing to measure")
        // …a break-family def with an offset watches the ROWS themselves, so it asks from the moment
        // it is pushed — before anything has been armed.
        XCTAssertTrue(module(5).wantsTimerRows)
        // …and a module with no defs at all — every world this build constructs on its own.
        XCTAssertFalse(AlertsModule().wantsTimerRows)
    }

    /// A character switch forgets the armed warnings.
    func testAResetDropsTheArmedWarningsAndKeepsTheDefs() {
        let m = module(5)
        let rows = [slowRow(1_000, 60_000)]
        m.onTick(nowMs: 2_000, timerRows: rows)
        m.reset()
        // The deadline the dropped warning would have spoken at. Nothing arms in its place either.
        m.onTick(nowMs: 56_000, timerRows: rows)
        XCTAssertTrue(m.takeFires().isEmpty, "the warning went with the character")
        // The defs stay, so the alert still fires at its own trigger.
        m.onEvent(ev(Self.woreOff), live: true)
        XCTAssertEqual(m.takeFires().count, 1)
    }

    /// The two maps that fold on REPLAY as well as live, and the snapshot shape they publish.
    func testTheRecencyMapsFoldOnReplayAndThePoisonKeyIsOmittedUntilSeen() {
        let m = AlertsModule()
        m.onEvent(ev(#"{"kind":"castBegin","seq":1,"ts":1000,"raw":"c","spell":"Mesmerization III"}"#), live: false)
        // A stamp that went backwards moves neither the recency nor the key's position.
        m.onEvent(ev(#"{"kind":"castBegin","seq":2,"ts":500,"raw":"c","spell":"Mesmerization III"}"#), live: false)
        var snap = m.snapshot()
        XCTAssertEqual(snap["state"]["spellLastCast"]["Mesmerization III"], .int(1000))
        XCTAssertEqual(snap["state"]["defs"], .array([]))
        XCTAssertEqual(snap["state"]["history"], .object([:]))
        // Omitted rather than null until a slow is actually observed.
        XCTAssertTrue(snap["state"]["poisonSlowSeen"].isNull)
        XCTAssertNil(snap["state"].object?["poisonSlowSeen"])

        m.onEvent(ev(#"{"kind":"poisonProc","seq":3,"ts":2000,"raw":"p","effect":"slow","target":"King Tranix"}"#), live: false)
        m.onEvent(ev(#"{"kind":"poisonProc","seq":4,"ts":3000,"raw":"p","effect":"slow","target":"a rat"}"#), live: false)
        snap = m.snapshot()
        XCTAssertEqual(snap["seq"], .int(4))
        XCTAssertEqual(snap["state"]["poisonSlowSeen"],
                       ["lastAt": 3000, "count": 2, "lastTarget": "a rat"])
    }
}
