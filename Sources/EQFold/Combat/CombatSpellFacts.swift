// The four spell tables the ownership models read (`fold/src/combat/spellfacts.rs`), built off the
// RAW rows of the committed `spells.json`:
//
//   cast times     longest `castTimeMs` per rank-folded key — the arm window.
//   durations      longest raw `durationMs` per key — the provisional-bind horizon. Raw on purpose:
//                  the parser's derived-durations pass rewrites the field and this table ignores it.
//   pet targets    `targetType === 'Pet'` — the pet-only gate.
//   charm messages charms whose cast-on-other sentence is not a charm broadcast, so they can never
//                  be what a broadcast resolved.
//
// Reading the committed file rather than the effective `SpellDb` table is what the TS does at the
// same point in the chain: one file, two readers.
//
// Every table is a pure function of a committed file — no log bytes, no character, no clock — so the
// lazy statics here are compile-time constants computed late, not cached fold state.
import Foundation
import EQCompanionCore
import EQData
import EQLog

/// One row of `spells.json`, as this file's four tables read it.
private struct SpellFactsRow {
    var name: String
    var durationMs: Int64?
    var castTimeMs: Int64?
    var targetType: String?
    var classes: String?
    var msgCastOnOther: String?
    var effects: [String]
}

private struct SpellFactsTables {
    var castMs: [String: Int64]
    var durationMs: [String: Int64]
    var petTarget: Set<String>
    var charmOtherMessage: Set<String>
    var petSummon: Set<String>
    var charmRoster: Set<String>
}

/// The three wiki `msgCastOnOther` sentences that ARE a charm broadcast: the enchanter ladder, the
/// Druid/Shaman ladder (`blinks.`) and the necromancer charm-undead ladder (`moans.`). The bard's
/// `'s eyes glaze over.` is deliberately absent — two charms and two real mezzes share it.
private let CHARM_MESSAGES: Set<String> = [
    "Someone has been charmed.",
    "Someone blinks.",
    "Someone moans.",
]

/// `spellEffectClass.ts`'s `summonPet` rule. Anchored at the head of the effect line, which is what
/// keeps `Pet Power Increase` and `Decrease Pet Size by 50%` out of the family.
private let summonPetRe = Re("(?i)^summon (?:pet|spectre pet|skeleton pet)(?-u:\\b)")

private func summonPetEffect(_ line: String) -> Bool { summonPetRe.isMatch(JS.trim(line)) }

/// The charm effect rule, reached through `Stems`'s port so this and the parser's own derived roster
/// cannot answer differently.
private func charmEffect(_ line: String) -> Bool {
    Stems.classifyEffectLineIsCharm(JS.trim(line))
}

/// The wiki's class column carries a `*` for every player-castable line.
private func playerCastable(_ s: SpellFactsRow) -> Bool {
    (s.classes ?? "").contains("*")
}

/// The longest figure any rank of a line carries, keyed by the rank-folded name. Non-positive and
/// absent figures are skipped alike.
private func longestByKey(_ rows: [SpellFactsRow], _ pick: (SpellFactsRow) -> Int64?) -> [String: Int64] {
    var m: [String: Int64] = [:]
    for s in rows {
        guard let ms = pick(s), ms > 0 else { continue }
        let key = Names.spellCanonKey(s.name)
        if let cur = m[key] { if ms > cur { m[key] = ms } } else { m[key] = ms }
    }
    return m
}

private let spellFactsTables: SpellFactsTables = buildSpellFactsTables()

private func spellFactsRows() -> [SpellFactsRow] {
    guard let text = EQData.text("spells.json"),
          let doc = try? JSONValue.parse(text),
          let arr = doc["spells"].array else {
        fatalError("spells.json is not readable")
    }
    return arr.map { r in
        SpellFactsRow(
            name: r["name"].string ?? "",
            durationMs: r["durationMs"].int64,
            castTimeMs: r["castTimeMs"].int64,
            targetType: r["targetType"].string,
            classes: r["classes"].string,
            msgCastOnOther: r["msgCastOnOther"].string,
            effects: (r["effects"].array ?? []).compactMap(\.string)
        )
    }
}

/// The corrected spelling of row `i`, or its own.
///
/// The name index is built once, before any correction runs, which matters when one correction
/// renames a row another then patches. A `name` correction writes every row of its name.
private func correctedNames(_ raw: [SpellFactsRow]) -> [String] {
    var out = raw.map(\.name)
    guard let text = EQData.text("spell-overlay.json"),
          let doc = try? JSONValue.parse(text) else {
        fatalError("spell-overlay.json is not readable")
    }
    var byName: [String: [Int]] = [:]
    for (i, s) in raw.enumerated() { byName[s.name, default: []].append(i) }
    for c in doc["corrections"].array ?? [] {
        guard c["field"].string == "name", let to = c["to"].string else { continue }
        for name in (c["spells"].array ?? []).compactMap(\.string) {
            guard let rows = byName[name] else { continue }
            for i in rows { out[i] = to }
        }
    }
    return out
}

private func buildSpellFactsTables() -> SpellFactsTables {
    let raw = spellFactsRows()
    let corrected = correctedNames(raw)

    let castMs = longestByKey(raw) { $0.castTimeMs }
    let durationMs = longestByKey(raw) { $0.durationMs }

    var petTarget: Set<String> = []
    for s in raw where s.targetType == "Pet" { petTarget.insert(Names.spellCanonKey(s.name)) }

    // A line is a non-broadcast charm when EVERY rank stating a cast-on-other message states one
    // that is not a charm broadcast. Any rank saying a broadcast keeps the whole line eligible, so a
    // scrape that lost one rank's message cannot disqualify the spell.
    var stated: [(String, Bool)] = []
    var at: [String: Int] = [:]
    for (i, s) in raw.enumerated() {
        guard let msg = s.msgCastOnOther, !msg.isEmpty else { continue }
        let onlyOther = !CHARM_MESSAGES.contains(msg)
        for name in [s.name, corrected[i]] {
            let key = Names.spellCanonKey(name)
            if let slot = at[key] {
                stated[slot].1 = stated[slot].1 && onlyOther
            } else {
                at[key] = stated.count
                stated.append((key, onlyOther))
            }
        }
    }
    let charmOtherMessage = Set(stated.filter(\.1).map(\.0))

    // The pet-summon roster, both spellings entered. No target filter — a summon is cast on nobody,
    // so nearly every row is `Self` — but player-castable only, since NPC rows print no cast line.
    var petSummon: Set<String> = []
    for (i, s) in raw.enumerated() {
        let has = s.effects.contains(where: summonPetEffect)
        if !has || !playerCastable(s) { continue }
        petSummon.insert(Names.spellCanonKey(s.name))
        petSummon.insert(Names.spellCanonKey(corrected[i]))
    }

    // The derived charm roster: every row whose effect list charms and that is not `Self`-targeted,
    // player-castable or not.
    var charmRoster: Set<String> = []
    for (i, s) in raw.enumerated() {
        let charms = s.effects.contains(where: charmEffect)
        if !charms || s.targetType == "Self" { continue }
        charmRoster.insert(Names.spellCanonKey(s.name))
        charmRoster.insert(Names.spellCanonKey(corrected[i]))
    }

    return SpellFactsTables(castMs: castMs, durationMs: durationMs, petTarget: petTarget,
                            charmOtherMessage: charmOtherMessage, petSummon: petSummon,
                            charmRoster: charmRoster)
}

/// The arm window for one own cast of `spell`, in ms after the `You begin casting` line.
public func armWindowMs(_ spell: String) -> Int64 {
    (spellFactsTables.castMs[Names.spellCanonKey(spell)] ?? DEFAULT_CAST_MS) + CAST_SLACK_MS
}

/// How long an uncorroborated bind by `spell` may stand: the spell's own listed duration plus a
/// slack. Derived rather than tuned, because a charm cannot outlive its own spell.
public func provisionalWindowMs(_ spell: String) -> Int64 {
    (spellFactsTables.durationMs[Names.spellCanonKey(spell)] ?? DEFAULT_CHARM_DURATION_MS)
        + DURATION_SLACK_MS
}

/// The game refuses one of these on anything but your own pet, which is the whole content of the
/// pet-only inference.
public func isPetOnlySpell(_ spell: String) -> Bool {
    spellFactsTables.petTarget.contains(Names.spellCanonKey(spell))
}

/// The effect-derived charm roster, with the name stems as the fallback for a name the catalog does
/// not carry.
public func isCharmSpell(_ spell: String) -> Bool {
    spellFactsTables.charmRoster.contains(Names.spellCanonKey(spell)) || Stems.charmStemsTest(spell)
}

/// Could a cast of `spell` have printed `<mob> has been charmed.`? For the third-party join only:
/// your own binds use the wider `isCharmSpell`, since that path is gated on `You begin casting`.
public func isCharmBroadcastSpell(_ spell: String) -> Bool {
    isCharmSpell(spell) && !spellFactsTables.charmOtherMessage.contains(Names.spellCanonKey(spell))
}

/// Charm wins the overlap: a spell that charms must never read as a mez. The CC side stays the name
/// stems whether or not a DB is installed.
public func isCcSpell(_ spell: String) -> Bool {
    let key = Names.spellCanonKey(spell)
    return !isCharmSpell(key) && Stems.ccStemsTest(key)
}

/// Pet-summon membership, as the log spelled it — rank tail and all.
public func isPetSummonSpell(_ spell: String) -> Bool {
    spellFactsTables.petSummon.contains(Names.spellCanonKey(spell))
}

/// How long after a cast's nominal completion a broadcast may still be that cast's. EQ log stamps
/// truncate to whole seconds, so a cast begun at x.9s prints up to a second late.
public let CAST_SLACK_MS: Int64 = 1_500
/// Arm window for a charm/CC spell the DB has no cast time for: the longest charm cast the DB knows.
public let DEFAULT_CAST_MS: Int64 = 6_000
/// How far a charm's own duration may overrun the DB's nominal figure. The wiki's durations are
/// level-scaled headline numbers, so this slack absorbs the scaling rather than the timing.
public let DURATION_SLACK_MS: Int64 = 60_000
/// Duration for a charm the DB has no figure for — 16 minutes, which is what all but two charms in
/// the family are listed at.
public let DEFAULT_CHARM_DURATION_MS: Int64 = 960_000
/// How long an unbound charm sighting is remembered so a later `… Master.'` tell can promote that
/// name to a charmed pet. Generous because the tell is ownership-definitive.
public let PROMOTE_MS: Int64 = 600_000

private let playerShapeArticleRe = Re("(?i)^(?:a|an|the)" + JS.S)
private let playerShapeWordRe = Re("^[A-Z][A-Za-z`']*$")

/// A single capitalized word with no space in it.
///
/// The word count is the discriminator, not the capitalization: the log capitalizes a
/// sentence-initial article (`A fire giant warrior begins singing …`), so the article test and the
/// anchored single-word test are two statements of one refusal.
public func isPlayerShapedName(_ name: String) -> Bool {
    let n = JS.trim(name)
    if n.isEmpty { return false }
    // JS's `\s`, not Swift's; the two differ and `JS.S` is the JS spelling.
    if playerShapeArticleRe.isMatch(n) { return false }
    return playerShapeWordRe.isMatch(n)
}
