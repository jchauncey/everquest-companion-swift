// Port of eqlog/src/parse/who.rs + group.rs + session.rs — the four statements about the character
// (its own `/who` row, a skill tick, the active special attack, a primary-class unlock) plus the
// item-activation line, the lines that say who you are grouped with, and the three lines that say
// whether the character is in the world at all with the `/outputfile` receipt.
import Foundation

private let classUnlockPrefix = "You have completed achievement: Primary Class Unlock - "

final class WhoRes {
    let whoRow: Re
    let whoZoneShortname: Re
    let corpseSuffix: Re
    let skillUp: Re
    let specialAttack: Re
    let itemActivate: Re

    init() {
        let s = JS.S
        whoRow = Re("^\(s)*(?:\\* RIP \\*\(s)*)?(?:AFK\(s)+)?\\[([0-9]+) ([A-Z]{3}(?:/[A-Z]{3})*)\\] (.+?)(?: \\(([^)]*)\\))?(?: <([^>]*)>)?\(s)+ZONE: (.+?)\(s)*$")
        whoZoneShortname = Re("\(s)*\\([a-z0-9_]+\\)$")
        corpseSuffix = Re(#"['`\u{2019}]s corpse$"#)
        skillUp = Re(#"^You have become better at (.+?)!(?: \(([0-9]+)\))?$"#)
        specialAttack = Re(#"^You will now use (.+?)(?: instead of (.+?))? while (auto )?attacking\.$"#)
        itemActivate = Re(#"^Your (.+?) (shimmers briefly|feels alive with power)\.$"#)
    }
}

/// The character's own `/who` row. The self-name check is the whole guard.
func classifySelfWho(_ r: WhoRes, _ character: String?, _ c: Ctx, _ out: Ev) -> Bool {
    guard let selfName = character, !selfName.isEmpty else { return false }
    if !c.text.contains("ZONE: ") { return false }
    guard let m = r.whoRow.captures(c.text) else { return false }
    let name = r.corpseSuffix.replaceFirst(JS.trim(m.s(3)), with: "")
    if name.lowercased() != JS.trim(selfName).lowercased() { return false }
    out.begin(.selfWho)
    out.envelope(c.seq, c.ts, c.raw)
    out.i(.level, Int64(m.s(1)) ?? 0)
    out.strs(.classes, m.s(2).split(separator: "/", omittingEmptySubsequences: false).map(String.init))
    let race = m[4].map { JS.trim($0) } ?? ""
    if !race.isEmpty { out.s(.race, race) }
    let zone = JS.trim(r.whoZoneShortname.replaceFirst(m.s(6), with: ""))
    if !zone.isEmpty { out.s(.zone, zone) }
    return true
}

/// Skill ticks. The skill string is kept exactly as the client prints it.
func classifySkillUp(_ r: WhoRes, _ c: Ctx, _ out: Ev) -> Bool {
    if !c.text.hasPrefix("You have become better at ") { return false }
    guard let m = r.skillUp.captures(c.text) else { return false }
    out.begin(.skillUp)
    out.envelope(c.seq, c.ts, c.raw)
    out.s(.skill, JS.trim(m.s(1)))
    if let v = m[2] { out.i(.value, Int64(v) ?? 0) }
    return true
}

/// The active special attack. A blank skill is refused rather than emitted.
func classifySpecialAttack(_ r: WhoRes, _ c: Ctx, _ out: Ev) -> Bool {
    if !c.text.hasPrefix("You will now use ") { return false }
    guard let m = r.specialAttack.captures(c.text) else { return false }
    let skill = JS.trim(m.s(1))
    if skill.isEmpty { return false }
    out.begin(.specialAttack)
    out.envelope(c.seq, c.ts, c.raw)
    out.s(.skill, skill)
    out.b(.autoAttack, m[3] != nil)
    let replaces = m[2].map { JS.trim($0) } ?? ""
    if !replaces.isEmpty { out.s(.replaces, replaces) }
    return true
}

/// A class unlocked: self only, and anchored at the start of the message.
func classifyClassUnlock(_ c: Ctx, _ out: Ev) -> Bool {
    if c.text.utf8.first != UInt8(ascii: "Y") || !c.text.hasPrefix(classUnlockPrefix) { return false }
    let className = JS.trim(c.text.dropFirst(classUnlockPrefix.count))
    if className.isEmpty { return false }
    out.begin(.classUnlock)
    out.envelope(c.seq, c.ts, c.raw)
    out.s(.className, className)
    return true
}

/// An item cast something: `Your <item> shimmers briefly.` / `… feels alive with power.`
func classifyItemActivate(_ r: WhoRes, _ c: Ctx, _ out: Ev) -> Bool {
    if !c.text.hasPrefix("Your ") { return false }
    guard let m = r.itemActivate.captures(c.text) else { return false }
    let item = JS.trim(m.s(1))
    if item.isEmpty { return false }
    out.begin(.itemActivate)
    out.envelope(c.seq, c.ts, c.raw)
    out.s(.item, item)
    out.s(.effect, m.s(2) == "shimmers briefly" ? "shimmer" : "alive")
    return true
}

// MARK: - group.rs
//
// Field order: a group event writes `change` (and `name` where it has one) before the
// `seq`/`ts`/`raw` envelope. It is the only kind in the stream that does, and it is why
// `Ev.envelope` is a separate call rather than part of `begin`.

private let selfJoinLine = "You have joined the group."
private let selfLeaveLine = "You have been removed from the group."
private let selfLeaderLine = "You are now the leader of your group."
private let selfTellPrefix = "You tell your party, '"

/// A player name as the subject — deliberately not `.+?`, so a chat line quoting one of these
/// sentences cannot satisfy the pattern with the speaker's whole prefix as the "name".
private let groupName = #"([A-Za-z][A-Za-z`'-]*)"#

final class GroupRes {
    /// The pattern table for the shapes that name someone, tried in order.
    let named: [(Re, String)]

    init() {
        let n = groupName
        named = [
            (Re(#"^\#(n) has joined the group\.$"#), "join"),
            (Re(#"^\#(n) has (?:left|been removed from) the group\.$"#), "leave"),
            (Re(#"^You remove \#(n) from the group\.$"#), "leave"),
            (Re(#"^\#(n) is now the leader of your group\.$"#), "leader"),
            (Re(#"^You invite \#(n) to join your group\.$"#), "invite"),
            (Re(#"^\#(n) invites you to join a group\.$"#), "invite"),
            (Re(#"^\#(n) tells the group, '"#), "confirm")
        ]
    }
}

func classifyGroup(_ r: GroupRes, _ c: Ctx, _ out: Ev) -> Bool {
    let text = c.text
    if !text.contains("group") && !text.contains("party") { return false }
    // The two exact self lines are compared before any regex runs, so `You have joined the group.`
    // can never be read as a member named "You".
    if text == selfJoinLine {
        out.begin(.group)
        out.s(.change, "selfJoin")
        out.envelope(c.seq, c.ts, c.raw)
        return true
    }
    if text == selfLeaveLine {
        out.begin(.group)
        out.s(.change, "selfLeave")
        out.envelope(c.seq, c.ts, c.raw)
        return true
    }
    // Named here so the next reader knows they were seen and dismissed, not missed.
    if text == selfLeaderLine || text.hasPrefix(selfTellPrefix) { return false }
    for (re, change) in r.named {
        if let m = re.captures(text) {
            out.begin(.group)
            out.s(.change, change)
            out.s(.name, m.s(1))
            out.envelope(c.seq, c.ts, c.raw)
            return true
        }
    }
    return false
}

// MARK: - session.rs

private let welcomeLine = "Welcome to EverQuest Legends!"
private let campStartLine = "It will take you about 30 seconds to prepare your camp."
private let campAbortLine = "You abandon your preparations to camp."
private let outputFilePrefix = "Outputfile Complete: "

/// Gated on the leading `W` before the string compare, so the hot path pays one character test.
func classifySessionStart(_ c: Ctx, _ out: Ev) -> Bool {
    if c.text.utf8.first != UInt8(ascii: "W") || c.text != welcomeLine { return false }
    out.begin(.sessionStart)
    out.envelope(c.seq, c.ts, c.raw)
    return true
}

/// Camp initiation and cancellation — one fact with two outcomes.
func classifyCamp(_ c: Ctx, _ out: Ev) -> Bool {
    if !c.text.hasSuffix("camp.") { return false }
    if c.text == campStartLine {
        out.begin(.campStart)
        out.envelope(c.seq, c.ts, c.raw)
        return true
    }
    if c.text == campAbortLine {
        out.begin(.campAbort)
        out.envelope(c.seq, c.ts, c.raw)
        return true
    }
    return false
}

/// `Outputfile Complete: <file>` — a dump with an empty name declines rather than emitting nothing.
func classifyOutputFile(_ c: Ctx, _ out: Ev) -> Bool {
    if c.text.utf8.first != UInt8(ascii: "O") || !c.text.hasPrefix(outputFilePrefix) { return false }
    let file = JS.trim(c.text.dropFirst(outputFilePrefix.count))
    if file.isEmpty { return false }
    out.begin(.outputFile)
    out.envelope(c.seq, c.ts, c.raw)
    out.s(.file, file)
    return true
}
