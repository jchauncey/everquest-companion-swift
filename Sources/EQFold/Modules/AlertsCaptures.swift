// Port of fold/src/modules/alerts_captures.rs — `shared/alertCaptures.ts` and
// `shared/alertTargets.ts`: what an alert firing may SAY. `AlertsRules.swift` decides WHETHER a
// line makes a sound; this decides the words.
//
// THE THREAT MODEL. Alert definitions are shareable and log lines are attacker-influenced, so a
// capture group is a channel with a third party at each end: a pattern the user may not have
// written, selecting text a stranger did write, which the app then SPEAKS ALOUD. Three controls
// answer it, and the first two are enforced here as well as app-side:
//
//   1. The sanitizer is unconditional (`sanitizeCapture`): ANSI/VT sequences leave WHOLE, every
//      C0/C1/DEL control is deleted, CR/LF/TAB collapse to one space, and the invisible + BiDi
//      override class (Trojan Source) is deleted.
//   2. A value is capped at `maxCaptureChars` and a firing at `maxCaptureGroups`.
//   3. A value may only come from the text the def's OWN condition just tested. That one is
//      structural: `AlertsRules.swift` is the only caller of `harvestCaptures` and hands it the one
//      regex that just matched and the one text it matched against.
//
// The cap counts Unicode SCALARS, as the Rust counts chars, where JS counts UTF-16 code units.
import Foundation
import EQLog
import EQCompanionCore

/// The captures a firing carries. Key order is not a claim (consumers look a token up by name), but
/// WHICH keys survived the group cap is — and that is decided in declaration order.
typealias CaptureMap = [String: String]

enum AlertCaptures {
    /// Longest a single captured value may be, in scalars — control 2.
    static let maxCaptureChars = 48

    /// Most named groups carried from one firing. Groups past the bound are DROPPED, so their tokens
    /// render literally (visible) rather than resolving to something unbounded (not).
    static let maxCaptureGroups = 8

    /// Whether `c` is a C0 control, DEL, or a C1 control. Nothing in this class is content.
    static func isControl(_ c: Unicode.Scalar) -> Bool {
        (c.value <= 0x1F) || (c.value >= 0x7F && c.value <= 0x9F)
    }

    /// Whether `c` renders as nothing, or reorders what renders around it.
    ///
    /// ZWSP/ZWNJ/ZWJ and the LRM/RLM marks; LINE and PARAGRAPH SEPARATOR plus the BiDi embeddings
    /// and overrides (Trojan Source); the word joiner and invisible operators; the BiDi isolates;
    /// the BOM/ZWNBSP. Same ranges in the same order as the TS.
    static func isInvisible(_ c: Unicode.Scalar) -> Bool {
        let v = c.value
        return (v >= 0x200B && v <= 0x200F)
            || (v >= 0x2028 && v <= 0x202E)
            || (v >= 0x2060 && v <= 0x2064)
            || (v >= 0x2066 && v <= 0x2069)
            || v == 0xFEFF
    }

    /// These three become a single space; every other control is deleted. A captured value must not
    /// be able to forge a second line on any surface that prints it.
    static func isSpaceControl(_ c: Unicode.Scalar) -> Bool {
        c == "\t" || c == "\n" || c == "\r"
    }

    /// Strip ANSI/VT escape sequences WHOLE, so the payload (`[31m`, `]0;title`) leaves with the ESC
    /// instead of being left behind as visible litter.
    ///
    /// Four ordered arms, and the order is the design:
    ///   1. CSI            `ESC [` params intermediates final
    ///   2. string-openers `ESC ] P ^ _ X` … BEL|ST — OSC (including OSC 52), DCS, PM, APC, SOS
    ///   3. nF             `ESC <0x20..0x2F>+ <0x30..0x7E>`
    ///   4. anything else  `ESC <one printable>`
    ///
    /// Arm 4 is the catch-all on purpose: an ESC this function does not recognise must still lose
    /// its ESC. A trailing lone ESC and the C1 single-byte equivalents are deleted by the control
    /// class in `sanitizeOneLine`.
    static func stripAnsi(_ raw: String) -> String {
        let chars = Array(raw.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        func at(_ n: Int) -> Unicode.Scalar? { n >= 0 && n < chars.count ? chars[n] : nil }
        func inRange(_ c: Unicode.Scalar?, _ lo: UInt32, _ hi: UInt32) -> Bool {
            guard let c else { return false }
            return c.value >= lo && c.value <= hi
        }
        while i < chars.count {
            if chars[i] != "\u{1B}" {
                out.append(chars[i])
                i += 1
                continue
            }
            guard let next = at(i + 1) else {
                // A trailing lone ESC.
                i += 1
                continue
            }
            i += 2
            switch next {
            // Arm 1 — CSI: params, then intermediates, then one final byte.
            case "[":
                while inRange(at(i), 0x30, 0x3F) { i += 1 }
                while inRange(at(i), 0x20, 0x2F) { i += 1 }
                if inRange(at(i), 0x40, 0x7E) { i += 1 }
            // Arm 2 — a string opener: everything up to BEL or ST, both of which go with it.
            case "]", "P", "^", "_", "X":
                while let c = at(i), c != "\u{7}", c != "\u{1B}" { i += 1 }
                if at(i) == "\u{7}" {
                    i += 1
                } else if at(i) == "\u{1B}", at(i + 1) == "\\" {
                    // `ESC \` is the String Terminator. A bare ESC that is not the `\` form opens a
                    // new sequence and is left for the next pass of the loop.
                    i += 2
                }
            // Arm 3 — nF: one or more intermediates then one final.
            case _ where next.value >= 0x20 && next.value <= 0x2F:
                while inRange(at(i), 0x20, 0x2F) { i += 1 }
                if inRange(at(i), 0x30, 0x7E) { i += 1 }
            // Arm 4 — the catch-all. One printable goes with the ESC; anything else keeps only the
            // ESC's own deletion, so it is pushed back.
            case _ where next.value >= 0x20 && next.value <= 0x7E:
                break
            default:
                i -= 1
            }
        }
        return String(String.UnicodeScalarView(out))
    }

    /// The display normalizer for anything that must occupy exactly one line.
    ///
    /// The ORDER is the contract: ANSI goes WHOLE first, then CR/CRLF fold, then TAB/LF/CR become
    /// one space and every other control is deleted, then the invisibles go.
    static func sanitizeOneLine(_ raw: String) -> String {
        let ansiFree = Array(stripAnsi(raw).unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        while i < ansiFree.count {
            let c = ansiFree[i]
            i += 1
            if c == "\r" {
                // A CR followed by an LF is one break.
                if i < ansiFree.count, ansiFree[i] == "\n" { i += 1 }
                out.append(" ")
                continue
            }
            if isInvisible(c) { continue }
            if isControl(c) {
                if isSpaceControl(c) { out.append(" ") }
                continue
            }
            out.append(c)
        }
        return String(String.UnicodeScalarView(out))
    }

    /// Take `n` scalars of `text` — the cap's cut, and the one place the UTF-16 divergence lives.
    static func takeChars(_ text: String, _ n: Int) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.prefix(n)))
    }

    /// Rust's `str::trim` — Unicode White_Space at both ends.
    static func rustTrim(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One captured value, made safe — controls 1 and 2, in the order that matters.
    ///
    /// SANITIZE BEFORE CAPPING, or the byte count of an escape sequence buys a hostile pattern extra
    /// room under the cap. Trim again after: the strip can expose new edge whitespace.
    ///
    /// `nil` is "nothing survived", which every caller treats as "this group captured nothing": its
    /// token renders LITERALLY rather than as an empty string.
    static func sanitizeCapture(_ raw: String) -> String? {
        if raw.isEmpty { return nil }
        let clean = rustTrim(sanitizeOneLine(raw))
        if clean.isEmpty { return nil }
        let capped = rustTrim(takeChars(clean, maxCaptureChars))
        return capped.isEmpty ? nil : capped
    }

    /// Turn a match's named groups into the bounded, sanitized map a firing may carry.
    ///
    /// The one place raw regex output becomes a firing's captures, so every producer gets the same
    /// bounds whether it matched a raw line or a `where` field. `nil` when nothing survived.
    ///
    /// DECLARATION ORDER IS WHAT THE CAP CUTS ON. Unnamed groups are skipped: a token is a
    /// declaration, and a positional group declares nothing.
    static func harvestCaptures(_ re: UserRegex, _ m: NSTextCheckingResult, in text: String) -> CaptureMap? {
        var out = CaptureMap()
        for name in re.names {
            if out.count >= maxCaptureGroups { break }
            guard let value = re.group(name, m, in: text) else { continue }
            guard let clean = sanitizeCapture(value) else { continue }
            out[name] = clean
        }
        return out.isEmpty ? nil : out
    }

    /// Merge one condition's captures into an accumulator, FIRST WRITER WINS — which is source
    /// order. An 'all' composite means every condition matched this one event, so all their names
    /// are in scope. `nil` stays `nil`.
    static func mergeCaptures(_ into: CaptureMap?, _ from: CaptureMap?) -> CaptureMap? {
        guard let from else { return into }
        guard var into else { return from }
        for (k, v) in from where into[k] == nil { into[k] = v }
        return into
    }

    /// Which field of which kind names the entity — the closed table behind the `{target}` auto
    /// token. Returns the field holding the entity's display name, and what an ABSENT field means
    /// when absence is itself a statement. Only `buffFade` has the second: `Your <Spell> spell has
    /// worn off.` with no "of <mob>" and no "pet's" IS the self form.
    ///
    /// The exclusions are the point, and are reproduced by OMISSION — a kind absent here resolves
    /// nothing. `itemMergeFailed` spells an ITEM name `target`, and `consider` names a mob no spell
    /// is touching; both would be a wrong answer wearing the right field name.
    static func targetFieldOf(_ kind: String) -> (String, String?)? {
        switch kind {
        case "buffApply", "buffExpired", "buffWearOff", "illusionFade", "resist", "heal",
             "healUnstated", "poisonProc", "damage", "miss":
            return ("target", nil)
        case "buffFade": return ("target", "self")
        case "cc", "ccWake", "charm", "uncharm": return ("mob", nil)
        case "spellEmote": return ("subject", nil)
        default: return nil
        }
    }

    /// The parser's sentinels, and what they are aloud.
    ///
    /// MATCHED EXACTLY, NEVER CASE-FOLDED: the sentinels are lowercase literals the parser writes
    /// itself, while a real name arrives with the game's casing. A player named `Self` is spoken as
    /// `Self`, which is their name.
    static func sentinelSpeech(_ value: String) -> String? {
        switch value {
        case "self": return "you"
        case "pet": return "your pet"
        default: return nil
        }
    }

    /// Who this event is about, ready to speak — or `nil` when the family names nobody.
    ///
    /// `nil` rather than an empty string is what makes the token render LITERALLY. An empty field
    /// and a missing field get the same answer.
    static func resolveTarget(_ ev: Event) -> String? {
        guard let (field, absent) = targetFieldOf(ev.kind) else { return nil }
        let text = rustTrim(ev.str(field) ?? "")
        let value: String
        if text.isEmpty {
            guard let absent else { return nil }
            value = absent
        } else {
            value = text
        }
        return sanitizeCapture(sentinelSpeech(value) ?? value)
    }

    /// Does this def's spoken phrase write `{target}`, the closed list of one auto token.
    ///
    /// IT READS THE PHRASE, NOT THE TRIGGER. A substring test is the exact port: the token grammar
    /// `\{([A-Za-z_][A-Za-z0-9_]*)\}` admits no whitespace, modifiers or nesting.
    static func wantsTargetToken(_ phrase: String?) -> Bool {
        phrase.map { $0.contains("{target}") } ?? false
    }

    /// Merge the auto token into a match's own captures.
    ///
    /// THE PATTERN'S OWN GROUP ALWAYS WINS. The group bound still governs — the cap is a property of
    /// the FIRING, not of any one producer.
    static func withAutoCaptures(_ captures: CaptureMap?, _ wantsTarget: Bool, _ ev: Event) -> CaptureMap? {
        if !wantsTarget { return captures }
        if let c = captures, c["target"] != nil || c.count >= maxCaptureGroups { return captures }
        guard let value = resolveTarget(ev) else { return captures }
        var out = captures ?? CaptureMap()
        out["target"] = value
        return out
    }

    // MARK: - Checkpoint

    /// A firing's captures for a fold checkpoint — the words an armed warning froze at the arm,
    /// already sanitized and capped by the producers above; the codec re-applies neither. Key order
    /// is not a claim (see `CaptureMap`: consumers look tokens up by name), so a plain object is
    /// the honest encoding. `null` is "this firing carries no captures" — `harvestCaptures` never
    /// returns an empty map, so nil and empty are distinct answers and the distinction is kept.
    static func checkpointCaptures(_ captures: CaptureMap?) -> JSONValue {
        guard let captures else { return .null }
        var o: [String: JSONValue] = [:]
        for (k, v) in captures { o[k] = .string(v) }
        return .object(o)
    }

    /// Rebuild from `checkpointCaptures(_:)`. The OUTER nil is "malformed blob" (the caller refuses
    /// the whole checkpoint); `.some(nil)` is a firing that carried no captures.
    static func restoreCaptures(_ v: JSONValue) -> CaptureMap?? {
        if v.isNull { return .some(nil) }
        guard let obj = v.object else { return .none }
        var out = CaptureMap()
        for (k, val) in obj {
            guard let s = val.string else { return .none }
            out[k] = s
        }
        return .some(out)
    }
}
