// `src/main/data/spellDb.ts`, as the fold reads it — the per-line facts the buffs model asks the
// spell catalog for, projected into an owned table at construction.
//
// A projection rather than a borrow, because nothing in the fold borrows the parser: that is what
// lets a fold outlive, precede or be moved independently of the parser that fed it.
//
// Two facts are derived here, at projection time, because both are pure functions of a row and so
// cannot disagree with themselves later:
//
//   * nature — the fold of the DB's `spellType` vocabulary onto beneficial / detrimental / unknown.
//     It is the one answer to "buff or debuff", which never comes from the shape of the target.
//   * calmsTarget — the orthogonal question: does this spell's beneficial effect happen to an enemy
//     (Pacify, Soothe, Calm, Lull)? Derived from the landing sentences rather than typed, so a
//     re-scrape that adds a rank joins the family for free.
//
// `byKey` is keyed by the DB's own `dbCanonKey` (case-insensitive rank tail) and looked up with keys
// the modules built through `spellCanonKey` (case-sensitive rank tail). Keeping the asymmetry is
// what makes a lookup here answer exactly what the lookup there answers.
// (fold/src/spell_facts.rs)
import Foundation

/// `SpellNature` — what `spellNature` folds `spellType` onto.
public enum Nature: Sendable, Equatable {
    case beneficial
    case detrimental
    case unknown
}

/// `BENEFICIAL_TYPES`. The counts beside each are the committed spells.json's, kept so the table is
/// auditable rather than a list somebody wrote down.
private let beneficialTypes: Set<String> = [
    "Beneficial",              // 1079
    "Statistic Buff",          // 34
    "Resist Buff",             // 11
    "Pet",                     // 9 — the pet summons; a friendly cast either way
    "Utility Beneficial",      // 6
    "Heal",                    // 6
    "Heal Over Time",          // 6
    "Pet Buff",                // 6
    "Pet Heal",                // 5
    "Haste",                   // 3
    "Cure",                    // 3
    "Movement Buff",           // 3
    "Remove Curse",            // 2
    "Vision",                  // 2
    "Summon Item",             // 2
    "Beneficial (Group only)", // 1
    "Invisibility",            // 1
    "Buff",                    // 1
    "Proc Buff",               // 1 — Spirit of the Puma
    "Regen",                   // 1
    "Damage Shield",           // 1 — cast on you/your pet, not on the mob
    "Block"                    // 1
]

/// `DETRIMENTAL_TYPES`.
private let detrimentalTypes: Set<String> = [
    "Detrimental",         // 713
    "Direct Damage",       // 8
    "Damage Over Time",    // 4
    "Utility Detrimental", // 2 — Cancel Magic, Flash of Light
    "Curse",               // 2
    "Slow",                // 2
    "Stun",                // 1
    "Root",                // 1
    "Statistic Debuff",    // 1
    "DD"                   // 1
]

/// `CALM_LANDING_MESSAGES` — the three sentences the calm roster is derived from. Nothing else in
/// the committed DB prints any of them, which is why the family is enumerable rather than typed.
private let calmLandingMessages: Set<String> = [
    "Someone looks less aggressive.",
    "Someone calms down.",
    "Someone looks friendly."
]

private func natureOf(_ spellType: String?) -> Nature {
    guard let t = spellType else { return .unknown }
    if beneficialTypes.contains(t) { return .beneficial }
    if detrimentalTypes.contains(t) { return .detrimental }
    return .unknown
}

/// One catalog row, reduced to what the fold reads. Anything absent is a field the buffs model never
/// asks about, and leaving it out is what makes that claim checkable.
public struct SpellRow: Sendable {
    /// The DB's own spelling — the identity a resolved landing carries.
    public var name: String
    public var durationMs: Int64?
    /// Read verbatim and only ever compared against `"Permanent"`. `durationMs == nil` is not the
    /// same question: hundreds of rows carry a null duration and are instant nukes, while the
    /// permanents state the word.
    public var durationText: String?
    public var illusion: Bool
    public var nature: Nature
    public var calmsTarget: Bool
    public var msgCastOnYou: String?
    /// `castOnOtherSuffix(msgCastOnOther)`, precomputed — the only form the miner's verdict rule
    /// ever uses it in.
    public var msgCastOnOtherSuffix: String?
    public var msgWearsOff: String?
}

/// The projected catalog. An empty one is exactly the TS's absent `db?`: every read answers nothing,
/// so the fold has one code path where the TS has an optional.
public struct SpellFacts: Sendable {
    private var byKey: [String: SpellRow]
    /// `byKey[k]?.durationMs`, kept apart: the buffs hygiene sweep asks it for every active row on
    /// every event, and reading it through `get` copies the whole row to read one number.
    private var durations: [String: Int64]

    public init() { byKey = [:]; durations = [:] }
    private init(byKey: [String: SpellRow]) {
        self.byKey = byKey
        durations = byKey.compactMapValues(\.durationMs)
    }

    /// Project `db.byKey` — the first row per canonical name, which is what `build` keeps.
    public static func project(_ db: SpellDb) -> SpellFacts {
        var byKey: [String: SpellRow] = [:]
        for s in db.byKeyValues() {
            byKey[Names.dbCanonKey(s.name)] = SpellRow(
                name: s.name,
                durationMs: s.durationMs,
                durationText: s.durationText,
                illusion: s.illusion,
                nature: natureOf(s.spellType),
                calmsTarget: s.msgCastOnOther.map { calmLandingMessages.contains($0) } ?? false,
                msgCastOnYou: s.msgCastOnYou,
                msgCastOnOtherSuffix: s.msgCastOnOther.flatMap(castOnOtherSuffix),
                msgWearsOff: s.msgWearsOff)
        }
        return SpellFacts(byKey: byKey)
    }

    /// `db.byKey.get(key)`.
    public func get(_ key: String) -> SpellRow? { byKey[key] }

    /// `get(key)?.durationMs`, without the row.
    public func durationMs(_ key: String) -> Int64? { durations[key] }

    public var isEmpty: Bool { byKey.isEmpty }

    public var count: Int { byKey.count }
}

private let youWordRe = Re("(?i)(?-u:\\b)you(?-u:\\b)|(?-u:\\b)your(?-u:\\b)")

private let castingSystemRe = Re("(?i)can't use that command|regain your concentration|change your invocation"
    + "|begin reciting|cannot see your target|Auto attack|mend your wounds"
    + "|shimmers briefly|feels alive with power|begins casting|begin singing|You must"
    + "|Insufficient|You do not|not ready yet|too far|out of range|You have entered"
    + "|received any tells|cannot reply|mostly successful|has been overwritten"
    + "|You forget |memoriz|You can(not| ?'?t)|Your target|Your spell|Your .* spell"
    + "|You have finished|Beginning to|You are (?:no longer|now)|not enough"
    + "|you cannot reply")

/// `hasNonLandingMarker` — the chat, combat and system markers that disqualify an otherwise
/// landing-shaped line.
private func hasNonLandingMarker(_ text: String) -> Bool {
    if text.contains("' told you") || text.contains(" tells ") || text.contains(" says") { return true }
    if text.contains(" by ") || text.contains(" from ") { return true }
    // Combat cast spam.
    if text.contains(" spell ") || text.contains("attention") { return true }
    return castingSystemRe.isMatch(text)
}

/// `buffsShapes.ts looksLandingMessage` — is an un-catalogued line plausibly a self spell-landing
/// flavor message the DB missed?
///
/// It must be about the caster (contain "you"/"your"), a short sentence ending in a period, with no
/// digits, no chat/tell/`by`/`from` markers, and not a casting-system or UI line.
///
/// The length bounds count UTF-16 units rather than bytes, because `text.length` does.
public func looksLandingMessage(_ text: String) -> Bool {
    let len = text.utf16.count
    if !(6...90).contains(len) { return false }
    if text.utf8.last != UInt8(ascii: ".") { return false }
    if text.utf8.contains(where: { $0 >= 0x30 && $0 <= 0x39 }) { return false }
    if !youWordRe.isMatch(text) { return false }
    return !hasNonLandingMarker(text)
}
