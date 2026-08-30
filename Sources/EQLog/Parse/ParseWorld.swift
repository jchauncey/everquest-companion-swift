// Port of eqlog/src/parse/world.rs — consider, death, zone, instance, loot, item merge, turn-in,
// level, exp, AA. The tables of eqlog/src/parse/data.rs live here too (`ParseData`), because the
// cascade matches them by equality rather than by pattern.
import Foundation

// MARK: - data.rs

/// A Strike's landing emote, by the suffix that identifies it.
struct PoisonProcRow {
    let suffix: String
    let strikes: [String]
    let effect: String
}

/// The two tables the cascade matches against by equality rather than by pattern: the poison roster
/// and the consider-faction ladder. Both keep their source order, because both orders are semantic
/// — the consider alternation is built from the ladder in ladder order, and a poison proc's first
/// strike is the name the event carries.
enum ParseData {
    /// The exact `You coat your blades …` line to (poison name, group).
    static let poisonByCoatMsg: [(String, String, String)] = [
        ("You coat your blades in a weak paralytic.", "Weakening Poison", "utility"),
        ("You coat your blades in a thick venom.", "Hobbling Poison", "utility"),
        ("You coat your blades with a potent venom.", "Concussive Poison", "utility"),
        ("You coat your blades in a mind numbing poison.", "Befuddling Poison", "utility"),
        ("You coat your blades in a tar-like poison.", "Grounding Poison", "utility"),
        ("You coat your blades in a numbing poison.", "Clumsiness Poison", "utility"),
        ("You coat your blades with a magical poison.", "Banishing Poison", "utility"),
        ("You coat your blades in a fettering poison.", "Fettering Poison", "utility"),
        ("You coat your blades in a binding poison.", "Binding Poison", "utility"),
        ("You coat your blades in a neurotoxic poison.", "Neurotoxic Poison", "utility"),
        ("You coat your blades in a mind wracking poison.", "Mind Wrack Poison", "utility"),
        ("You coat your blades in a thought draining poison.", "Thought Drain Poison", "utility"),
        ("You coat your blades in antimagic poison.", "Antimagic Poison", "utility"),
        ("You coat your blades in mage bane poison.", "Mage Bane Poison", "utility"),
        ("You coat your blades in a paralytic poison.", "Paralytic Poison", "utility"),
        ("You coat your blades in a siphoning poison.", "Blood Siphon Venom", "combat"),
        ("You coat your blades in asp venom.", "Asp Venom", "combat"),
        ("You coat your blades with a stunning agent.", "Stunning Venom", "combat"),
        ("You coat your blades in a drawing poison.", "Blood Draw Venom", "combat"),
        ("You coat your blades in cobra venom.", "Cobra Venom", "combat"),
    ]

    /// The two wears-off lines, split by group.
    static let poisonDryMsg: [(String, String)] = [
        ("The poison dries from the blade.", "utility"),
        ("The venom drips away.", "combat"),
    ]

    static let poisonProcs: [PoisonProcRow] = [
        PoisonProcRow(suffix: "'s limbs move slower!", strikes: ["Weakening Strike"], effect: "slow"),
        PoisonProcRow(suffix: "'s fingers slow down.", strikes: ["Clumsiness Strike"], effect: "spellSlow"),
        PoisonProcRow(suffix: "'s blessings wither!", strikes: ["Banishing Strike"], effect: "dispel"),
        PoisonProcRow(suffix: "'s feet won't budge!", strikes: ["Grounding Strike"], effect: "root"),
        PoisonProcRow(suffix: "stumbles, clutching their head!", strikes: ["Befuddling Strike"], effect: "manaDrain"),
        PoisonProcRow(suffix: "begins to sway!", strikes: ["Stunning Strike"], effect: "stun"),
        PoisonProcRow(suffix: "blinks, looking confused!", strikes: ["Concussive Strike"], effect: "interrupt"),
        PoisonProcRow(suffix: "starts limping!", strikes: ["Hobbling Strike"], effect: "snare"),
        PoisonProcRow(suffix: "begins to bleed profusely!", strikes: ["Blood Siphon Strike", "Blood Draw Strike"], effect: "dot"),
        PoisonProcRow(suffix: "screams as poison burns their veins!", strikes: ["Asp Venom Strike", "Cobra Venom Strike"], effect: "damage"),
    ]

    /// Phrase to rung, friendliest first. The parser builds its alternation from this list in this
    /// order, and a rung the ladder does not carry makes the line decline rather than mis-split a
    /// mob name.
    static let considerFactionRungs: [(String, String)] = [
        ("regards you as an ally", "ally"),
        ("looks upon you warmly", "warmly"),
        ("kindly considers you", "kindly"),
        ("judges you amiably", "amiably"),
        ("regards you indifferently", "indifferent"),
        ("looks your way apprehensively", "apprehensive"),
        ("glowers at you dubiously", "dubious"),
        ("glares at you threateningly", "threatening"),
        ("scowls at you, ready to attack", "scowls"),
    ]
}

/// `regex::escape` — the crate's meta set, so a table phrase is matched literally.
func reEscape(_ s: String) -> String {
    var out = ""
    for ch in s {
        if "\\.+*?()|[]{}^$#&-~".contains(ch) { out.append("\\") }
        out.append(ch)
    }
    return out
}

// MARK: - world.rs

private let YOU_DIED = "You died."
private let AA_POTION_LANDING = "You are filled with the spirit of alternate adventure."

final class WorldRes {
    let loot: Re
    let lootPlain: Re
    let lootCurrency: Re
    let lootSold: Re
    let lootStored: Re
    let lootCombine: Re
    let destroy: Re
    let zone: Re
    let pseudoZone: Re
    let instanceCreate: Re
    let slainSelf: Re
    let slainBy: Re
    let playerDeath: Re
    let mobDied: Re
    let offer: Re
    let tradeDone: Re
    let level: Re
    let exp: Re
    let aa: Re
    let aaSpend: Re
    let aaAbility: Re
    let aaImproved: Re
    let itemMerge: Re
    let itemMergeFail: Re
    let consider: Re
    let itemTier: Re

    init() {
        let s = JS.S
        let rungs = ParseData.considerFactionRungs.map { reEscape($0.0) }.joined(separator: "|")
        loot = Re("^--You have looted (?:([0-9]+) |an? )?(.+?)(?: from (.+?) corpse)?\\.--$")
        lootPlain = Re("^You have looted (?:([0-9]+) |an? )?(.+?)(?: from (.+?) corpse)?\\.$")
        lootCurrency = Re(
            "^You looted (?:([0-9]+) |an? )?(.+?) from (.+?) corpse and stored it in your currency\\.?$")
        lootSold = Re(
            "^You looted (?:([0-9]+) |an? )?(.+?) from (.+?) corpse and sold it for (?:free|[0-9,]+ (?:platinum|gold|silver|copper).*?)\\.?$")
        lootStored = Re(
            "^You looted (?:([0-9]+) |an? )?(.+?) from (.+?) corpse and stored it in your (Dragon Hoard|tradeskill depot)\\.?$")
        lootCombine = Re(
            "^You looted (?:([0-9]+) |an? )?(.+?) from (.+?) corpse to create (?:an? )?(.+?)\\.?$")
        destroy = Re("^You successfully destroyed ([0-9]+) (.+?)\\.$")
        zone = Re("^You have entered (.+?)\\.$")
        pseudoZone = Re("(?i)^an area where ")
        instanceCreate = Re("^Player (.+?) creating instance (.+?) ([0-9]+)\\.$")
        slainSelf = Re("^You have slain (.+?)!$")
        slainBy = Re("^(.+?) has been slain by (.+?)!$")
        playerDeath = Re("^You have been slain by (.+?)!$")
        mobDied = Re("^(.+?) died\\.$")
        offer = Re("^You offered [0-9,]+ (.+?) to (.+?)\\.$")
        tradeDone = Re("^You complete the trade with (.+?)\\.$")
        level = Re("^You have gained a level! Welcome to level ([0-9]+)!$")
        exp = Re("^You gain (party )?experience!(?: \\(([0-9.]+)%\\))?$")
        aa = Re("^You have gained (an|[0-9]+) ability point(?:\\(s\\))?!\(s)+You now have ([0-9]+) ability point")
        aaSpend = Re(" at a cost of ([0-9]+) ability points?\\.$")
        aaAbility = Re("gained the ability (?:\"([^\"]+)\"|to use (.+?)) at a cost of")
        aaImproved = Re("^You have improved (.+?) ([0-9]+) at a cost of")
        itemMerge = Re("^You have successfully merged two items together to create a new item: (.+)$")
        itemMergeFail = Re("^Your request to merge (.+?) with (.+?) failed\\. ")
        consider = Re("^(.+?)( - a rare creature -)? (\(rungs)) -- (.+?)\(s)*\\(Lvl: ([0-9]+)\\)$")
        itemTier = Re(" \\+([0-9]+)$")
    }
}

/// The shared loot capture layout: optional stack count, item, source, disposition.
private func loot(
    _ c: Ctx, _ out: Ev, _ item: Substring, _ source: String?, _ disposition: String?,
    _ countStr: Substring?
) {
    out.begin(.loot)
    out.envelope(c.seq, c.ts, c.raw)
    out.s(.item, JS.trim(item))
    out.sOpt(.source, source)
    if let d = disposition {
        out.s(.disposition, d)
    }
    if let n = countStr {
        out.i(.count, Int64(String(n)) ?? 0)
    }
}

func classifyConsider(_ r: WorldRes, _ c: Ctx, _ out: Ev) -> Bool {
    if !c.text.contains("(Lvl: ") {
        return false
    }
    guard let m = r.consider.captures(c.text) else {
        return false
    }
    let rung = m.s(3)
    guard let faction = ParseData.considerFactionRungs.first(where: { $0.0 == rung })?.1 else {
        return false
    }
    out.begin(.consider)
    out.envelope(c.seq, c.ts, c.raw)
    out.s(.mob, JS.trim(m.s(1)))
    out.b(.rare, m[2] != nil)
    out.i(.level, Int64(m.s(5)) ?? 0)
    out.s(.faction, faction)
    out.s(.difficulty, JS.trim(m.s(4)))
    return true
}

func classifyDeath(_ r: WorldRes, _ c: Ctx, _ out: Ev) -> Bool {
    let text = c.text
    if text == YOU_DIED {
        out.begin(.playerDeath)
        out.envelope(c.seq, c.ts, c.raw)
        return true
    }
    if text.contains("slain") {
        if let pd = r.playerDeath.captures(text) {
            out.begin(.playerDeath)
            out.envelope(c.seq, c.ts, c.raw)
            out.s(.killer, JS.trim(pd.s(1)))
            return true
        }
        if let m = r.slainSelf.captures(text) {
            out.begin(.death)
            out.envelope(c.seq, c.ts, c.raw)
            out.s(.name, Names.norm(m.s(1)))
            out.b(.bySelf, true)
            return true
        }
        if let m = r.slainBy.captures(text) {
            out.begin(.death)
            out.envelope(c.seq, c.ts, c.raw)
            out.s(.name, Names.norm(m.s(1)))
            out.b(.bySelf, false)
            out.s(.killer, JS.trim(m.s(2)))
            return true
        }
    }
    // The killerless mob death: `bySelf:false` with no killer is the honest shape.
    if text.hasSuffix(" died.") {
        if let m = r.mobDied.captures(text) {
            out.begin(.death)
            out.envelope(c.seq, c.ts, c.raw)
            out.s(.name, Names.norm(m.s(1)))
            out.b(.bySelf, false)
            return true
        }
    }
    return false
}

func classifyZone(_ r: WorldRes, _ c: Ctx, _ out: Ev) -> Bool {
    if !c.text.contains("entered") {
        return false
    }
    guard let m = r.zone.captures(c.text) else {
        return false
    }
    if r.pseudoZone.isMatch(m.s(1)) {
        return false
    }
    out.begin(.zone)
    out.envelope(c.seq, c.ts, c.raw)
    out.s(.zone, JS.trim(m.s(1)))
    return true
}

/// `Player <Name> creating instance <Zone> <Id>.`
///
/// The zone line is the only sentence that states a difficulty, and it marks an instance only two
/// ways: an adjective parenthetical (d1-d4) or a `- Solo`/`- Group` suffix (d0). A base-difficulty
/// raid or personal instance prints neither — the zone line is byte-identical to the open-world
/// entry — so this notice is the only evidence that an instance of that zone exists. It is not a
/// statement about your position, and the kills fold that reads it is careful about that.
///
/// The id is the last number, which is what anchoring the trailing digits buys: a zone whose name
/// ends in an ordinal backtracks into the zone capture rather than splitting the name.
func classifyInstanceCreate(_ r: WorldRes, _ c: Ctx, _ out: Ev) -> Bool {
    if !c.text.hasPrefix("Player ") {
        return false
    }
    guard let m = r.instanceCreate.captures(c.text) else {
        return false
    }
    out.begin(.instanceCreate)
    out.envelope(c.seq, c.ts, c.raw)
    out.s(.player, JS.trim(m.s(1)))
    out.s(.zone, JS.trim(m.s(2)))
    out.i(.instance, Int64(m.s(3)) ?? 0)
    return true
}

/// Self-loot, the auto-disposition variants, and the destroy (which is the negative).
func classifyLoot(_ r: WorldRes, _ c: Ctx, _ out: Ev) -> Bool {
    let text = c.text
    if text.hasPrefix("You successfully destroyed ") {
        if let d = r.destroy.captures(text) {
            loot(c, out, d[2] ?? "", nil, "destroyed", d[1])
            return true
        }
    }
    if !text.contains("looted") {
        return false
    }
    if let m = r.loot.captures(text) ?? r.lootPlain.captures(text) {
        loot(c, out, m[2] ?? "", Names.cleanMob(m[3].map(String.init)), nil, m[1])
        return true
    }
    if let m = r.lootCurrency.captures(text) {
        loot(c, out, m[2] ?? "", Names.cleanMob(m[3].map(String.init)), "currency", m[1])
        return true
    }
    if let m = r.lootSold.captures(text) {
        loot(c, out, m[2] ?? "", Names.cleanMob(m[3].map(String.init)), "sold", m[1])
        return true
    }
    if let m = r.lootStored.captures(text) {
        let disposition = m.s(4) == "Dragon Hoard" ? "hoard" : "depot"
        loot(c, out, m[2] ?? "", Names.cleanMob(m[3].map(String.init)), disposition, m[1])
        return true
    }
    if let m = r.lootCombine.captures(text) {
        loot(c, out, m[2] ?? "", Names.cleanMob(m[3].map(String.init)), "combined", m[1])
        // The shared loot fields first, then the one added key.
        out.s(.created, JS.trim(m.s(4)))
        return true
    }
    return false
}

func classifyItemMerge(_ r: WorldRes, _ c: Ctx, _ out: Ev) -> Bool {
    let text = c.text
    if !(text.contains("merge") || text.hasPrefix("The item you are trying to add")) {
        return false
    }
    if let m = r.itemMerge.captures(text) {
        let item = JS.trim(m.s(1))
        // A ` +N` tail is an item level; a Roman-rank tail is a merged spell scroll and has no tier.
        let tier = r.itemTier.captures(JS.trim(item)).flatMap { Int64($0.s(1)) }
        out.begin(.itemMerge)
        out.envelope(c.seq, c.ts, c.raw)
        out.s(.item, item)
        out.iOpt(.tier, tier)
        return true
    }
    if let f = r.itemMergeFail.captures(text) {
        out.begin(.itemMergeFailed)
        out.envelope(c.seq, c.ts, c.raw)
        out.s(.reason, "mismatch")
        out.s(.target, JS.trim(f.s(1)))
        out.s(.component, JS.trim(f.s(2)))
        return true
    }
    let reason: String?
    switch text {
    case "The item you are trying to add will not work, this mote is not sufficiently powerful to upgrade this item.":
        reason = "weakMote"
    case "The item you are trying to add will not work, you cannot fuse an item to itself.":
        reason = "selfFuse"
    case "The item you are trying to add will not work, you cannot merge two different types of items.":
        reason = "wrongType"
    case "Request to merge items canceled, both items remain unmodified.":
        reason = "canceled"
    default:
        reason = nil
    }
    guard let reason else { return false }
    out.begin(.itemMergeFailed)
    out.envelope(c.seq, c.ts, c.raw)
    out.s(.reason, reason)
    return true
}

func classifyTurnIn(_ r: WorldRes, _ c: Ctx, _ out: Ev) -> Bool {
    if c.text.contains("offered") {
        if let m = r.offer.captures(c.text) {
            out.begin(.offer)
            out.envelope(c.seq, c.ts, c.raw)
            out.s(.item, JS.trim(m.s(1)))
            out.s(.npc, JS.trim(m.s(2)))
            return true
        }
    }
    if c.text.contains("complete the trade") {
        if let m = r.tradeDone.captures(c.text) {
            out.begin(.trade)
            out.envelope(c.seq, c.ts, c.raw)
            out.s(.npc, JS.trim(m.s(1)))
            return true
        }
    }
    return false
}

func classifyLevel(_ r: WorldRes, _ c: Ctx, _ out: Ev) -> Bool {
    if !c.text.contains("gained a level") {
        return false
    }
    guard let m = r.level.captures(c.text) else {
        return false
    }
    out.begin(.level)
    out.envelope(c.seq, c.ts, c.raw)
    out.i(.level, Int64(m.s(1)) ?? 0)
    return true
}

/// Experience gains. `pct` is omitted, never 0, when the line stated no percentage.
func classifyExp(_ r: WorldRes, _ c: Ctx, _ out: Ev) -> Bool {
    if !c.text.hasPrefix("You gain ") {
        return false
    }
    guard let m = r.exp.captures(c.text) else {
        return false
    }
    out.begin(.expGain)
    out.envelope(c.seq, c.ts, c.raw)
    out.b(.party, m[1] != nil)
    if let pct = m[2] {
        out.f(.pct, Double(String(pct)) ?? Double.nan)
    }
    return true
}

func classifyAA(_ r: WorldRes, _ c: Ctx, _ out: Ev) -> Bool {
    if !c.text.contains("ability point") {
        return false
    }
    if let g = r.aa.captures(c.text) {
        let amount: Int64 = g.s(1) == "an" ? 1 : (Int64(g.s(1)) ?? 0)
        out.begin(.aaGain)
        out.envelope(c.seq, c.ts, c.raw)
        out.i(.amount, amount)
        out.i(.nowHave, Int64(g.s(2)) ?? 0)
        return true
    }
    guard let costM = r.aaSpend.captures(c.text) else {
        return false
    }
    let cost = Int64(costM.s(1)) ?? 0
    if let imp = r.aaImproved.captures(c.text) {
        let rank = Int64(imp.s(2)) ?? 0
        out.begin(.aaSpend)
        out.envelope(c.seq, c.ts, c.raw)
        out.s(.ability, "\(JS.trim(imp.s(1))) \(rank)")
        out.i(.cost, cost)
        out.i(.rank, rank)
        return true
    }
    let ability =
        r.aaAbility.captures(c.text).flatMap { a in (a[1] ?? a[2]).map(String.init) } ?? "ability"
    out.begin(.aaSpend)
    out.envelope(c.seq, c.ts, c.raw)
    out.s(.ability, JS.trim(ability))
    out.i(.cost, cost)
    return true
}

func classifyAAPotion(_ c: Ctx, _ out: Ev) -> Bool {
    if c.text != AA_POTION_LANDING {
        return false
    }
    out.begin(.aaPotion)
    out.envelope(c.seq, c.ts, c.raw)
    return true
}
