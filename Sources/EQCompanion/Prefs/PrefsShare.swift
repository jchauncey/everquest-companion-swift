// PrefsShare — the SHARE WIRE FORMAT, ported byte-for-byte from the Electron app so a string
// written on Windows pastes into this app and back again:
//
//   EQC1-<base64url(deflateRaw(utf8(canonicalJson(envelope))))>
//
// The three halves are src/shared/shareSchema.ts (the envelope, the canonical-JSON/checksum pair,
// the body shapes and the export whitelist), src/main/shareCodec.ts (the compression and the
// tolerant decoder) and src/shared/shareMerge.ts (the diff a preview renders). They are one file
// here because nothing in this app needs them apart.
//
// WHY THE SPELLINGS ARE EXACT. The envelope carries a checksum over `canonicalJson(body)`, so the
// serializer has to agree with `JSON.stringify` to the byte: sorted keys, no whitespace, dropped
// `undefined`, JS's own number and string escaping. A Swift serializer that escaped `/` (as
// `JSONSerialization` does) or printed `1.0` where JS prints `1` would produce strings the other
// app refuses as damaged — and the failure would look like corruption rather than like a bug.
//
// DEFLATE, RAW. `Compression`'s `.zlib` is RFC-1951 raw DEFLATE with no header, which is what
// node's `deflateRawSync` writes. The compressor's LEVEL is free — a deflate stream is a deflate
// stream — so nothing here depends on matching node's level 9.
//
// AND NOTHING HERE THROWS AT THE USER. Every failure is a typed `ShareDecodeError` carrying the
// sentence the card prints, because "cut off when it was copied" is what the person needs to know
// and a stack trace is not.
import Foundation
import Compression
import EQCompanionCore

// MARK: - The envelope

/// What a share string carries. `character` is DESIGNED but not produced or consumed.
enum ShareKind: String {
    case alerts, settings, character
}

/// The versioned wrapper every share string carries.
struct ShareEnvelope {
    /// schema version — `ShareCodec.schemaVersion` at write time
    var v: Int
    var kind: ShareKind
    /// producing app version (provenance only — never a trust signal)
    var app: String
    /// ISO-8601 creation time
    var at: String
    /// `checksum(canonicalJson(body))`
    var sum: String
    var body: JSONValue
}

enum ShareDecodeError: String, Error {
    case empty
    case notAShareString
    case tooLong
    case corrupt
    case checksum
    case newerVersion
    case unknownKind
    case emptyPayload

    /// User-facing text for each failure. The UI reports these — it never throws at the user.
    var text: String {
        switch self {
        case .empty: return "Nothing to import - paste a share string first."
        case .notAShareString: return "That doesn't look like a share string. It should start with \"\(ShareCodec.prefix)\"."
        case .tooLong: return "That share string is too large to be genuine."
        case .corrupt: return "That share string is damaged - it may have been cut off when it was copied."
        case .checksum: return "That share string failed its integrity check - copy it again, in full."
        case .newerVersion: return "That share string was made by a newer version of the app. Update, then import."
        case .unknownKind: return "That share string carries something this version doesn't understand."
        case .emptyPayload: return "That share string is valid but contains nothing to import."
        }
    }
}

enum ShareCodec {
    /// Human-readable prefix + format generation. Only a BREAKING format bumps the digit.
    static let prefix = "EQC1-"
    /// Envelope schema version. Additive body changes bump this; decoders migrate forward.
    static let schemaVersion = 1

    /// Max sizes — a pasted string is UNTRUSTED input, so every list and string is bounded.
    enum Limits {
        /// longest share string we will even try to decode (~64KB of base64url)
        static let maxStringChars = 64 * 1024
        /// longest inflated JSON we will parse
        static let maxJsonChars = 512 * 1024
        static let maxAlerts = 500
        static let maxNameChars = 120
        static let maxUiValueChars = 20 * 1024
    }

    // MARK: canonical JSON + checksum

    /// Deterministic JSON, spelled the way `JSON.stringify` spells it: object keys sorted, no
    /// whitespace, nulls kept, integral doubles printed without a fraction. Two machines holding
    /// the same logical value produce byte-identical text, which is what makes the checksum stable
    /// across an export and an import on the other side.
    static func canonicalJson(_ value: JSONValue) -> String {
        switch value {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .double(let d): return number(d)
        case .string(let s): return quoted(s)
        case .array(let a): return "[" + a.map(canonicalJson).joined(separator: ",") + "]"
        case .object(let o):
            let parts = o.keys.sorted().map { "\(quoted($0)):\(canonicalJson(o[$0] ?? .null))" }
            return "{" + parts.joined(separator: ",") + "}"
        }
    }

    /// `JSON.stringify`'s number spelling: a non-finite value is `null`, an integral one prints
    /// with no fraction, everything else takes Swift's shortest round-trip form — which is the
    /// same shortest form JS prints.
    private static func number(_ d: Double) -> String {
        if !d.isFinite { return "null" }
        if d == d.rounded(), abs(d) < 1e15, let i = Int64(exactly: d.rounded()) { return String(i) }
        return "\(d)"
    }

    /// `JSON.stringify`'s string escaping: the two structural characters, the five short control
    /// escapes, `\u00xx` for the rest of C0 — and everything else literal, forward slashes and
    /// non-ASCII included.
    private static func quoted(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if u.value < 0x20 {
                    out += String(format: "\\u%04x", u.value)
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        return out + "\""
    }

    /// FNV-1a 32-bit over the text's UTF-16 code units, folded byte-wise, as 8 lowercase hex
    /// chars. Not a security primitive — a TRANSPORT check (a truncated paste, a chat client
    /// eating a character) and a content fingerprint.
    static func checksum(_ text: String) -> String {
        var h: UInt32 = 0x811c9dc5
        for c in text.utf16 {
            h ^= UInt32(c & 0xff)
            h = h &* 0x01000193
            if c > 0xff {
                h ^= UInt32((c >> 8) & 0xff)
                h = h &* 0x01000193
            }
        }
        return String(format: "%08x", h)
    }

    /// Wrap a body in a checksummed envelope. `now` is injectable so tests are deterministic.
    static func envelope(kind: ShareKind, body: JSONValue, appVersion: String, now: Date = Date()) -> JSONValue {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return ["v": .int(Int64(schemaVersion)),
                "kind": .string(kind.rawValue),
                "app": .string(appVersion.isEmpty ? "unknown" : appVersion),
                "at": .string(f.string(from: now)),
                "sum": .string(checksum(canonicalJson(body))),
                "body": body]
    }

    // MARK: encode / decode

    /// Encode an envelope into its single-line share string.
    static func encode(_ envelope: JSONValue) -> String {
        prefix + base64url(deflateRaw(Data(canonicalJson(envelope).utf8)))
    }

    /// Decode a pasted string. Tolerant of the ways chat clients mangle a paste — surrounding
    /// whitespace, wrapped lines, a stray code fence — but never of a bad checksum: a payload
    /// whose body doesn't match its `sum` is REJECTED rather than partially applied.
    static func decode(_ input: String) -> Result<ShareEnvelope, ShareDecodeError> {
        if input.isEmpty { return .failure(.empty) }
        // Strip anything that can't be part of a base64url payload or the prefix: newlines from a
        // wrapped paste, backticks from a code fence, quotes from a sentence.
        let cleaned = input.trimmingCharacters(in: .whitespacesAndNewlines)
            .filter { !" \t\n\r`\"'<>".contains($0) }
        if cleaned.isEmpty { return .failure(.empty) }
        if cleaned.count > Limits.maxStringChars { return .failure(.tooLong) }

        guard let at = cleaned.range(of: prefix) else {
            // A different generation (EQC2-…) is a "newer version" story, not a "wrong thing" one.
            let generation = cleaned.range(of: "^EQC[0-9]+-", options: [.regularExpression]) != nil
            return .failure(generation ? .newerVersion : .notAShareString)
        }
        var payload = String(cleaned[at.upperBound...])
        while let last = payload.last, !last.isLetter && !last.isNumber && last != "-" && last != "_" {
            payload.removeLast()
        }
        if payload.isEmpty { return .failure(.corrupt) }

        guard let raw = fromBase64url(payload), let inflated = inflateRaw(raw) else {
            return .failure(.corrupt)
        }
        if inflated.count > Limits.maxJsonChars { return .failure(.tooLong) }
        guard let parsed = try? JSONValue.parse(inflated) else { return .failure(.corrupt) }
        return validate(parsed)
    }

    /// Validate a decoded envelope object: shape, version, kind, checksum. Pure — the codec hands
    /// us the parsed JSON, we decide whether it may be shown to the user.
    static func validate(_ raw: JSONValue) -> Result<ShareEnvelope, ShareDecodeError> {
        guard let v = raw["v"].int, let kindText = raw["kind"].string, let sum = raw["sum"].string else {
            return .failure(.corrupt)
        }
        if v > schemaVersion { return .failure(.newerVersion) }
        guard let kind = ShareKind(rawValue: kindText) else { return .failure(.unknownKind) }
        let body = raw["body"]
        if body.isNull { return .failure(.corrupt) }
        if checksum(canonicalJson(body)) != sum { return .failure(.checksum) }
        return .success(ShareEnvelope(v: v, kind: kind,
                                      app: String((raw["app"].string ?? "").prefix(40)),
                                      at: String((raw["at"].string ?? "").prefix(40)),
                                      sum: sum, body: body))
    }

    /// Cheap "is the user even holding a share string" test, for live paste validation.
    static func looksLikeShareString(_ input: String) -> Bool {
        input.filter { !$0.isWhitespace }.contains(prefix)
    }

    // MARK: bytes

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func fromBase64url(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }

    /// Raw DEFLATE, no zlib header — every byte counts in a chat message and the prefix already
    /// identifies the format.
    static func deflateRaw(_ data: Data) -> Data {
        transform(data, operation: COMPRESSION_STREAM_ENCODE, hint: max(64, data.count))
    }

    /// The inverse. `nil` for anything that is not a deflate stream — the decoder calls that
    /// "damaged", which is what a truncated paste actually is.
    static func inflateRaw(_ data: Data) -> Data? {
        let out = transform(data, operation: COMPRESSION_STREAM_DECODE, hint: max(1024, data.count * 8))
        return out.isEmpty ? nil : out
    }

    /// One pass of the streaming API, growing the destination until the stream ends. Written
    /// against `compression_stream` rather than the one-shot buffer call because the inflated size
    /// is unknown up front and a short buffer would silently truncate.
    private static func transform(_ data: Data, operation: compression_stream_operation, hint: Int) -> Data {
        guard !data.isEmpty else { return Data() }
        var stream = compression_stream(dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!, dst_size: 0,
                                        src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!, src_size: 0,
                                        state: nil)
        guard compression_stream_init(&stream, operation, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            return Data()
        }
        defer { compression_stream_destroy(&stream) }

        let bufferSize = max(4096, min(hint, 1 << 20))
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        var out = Data()
        let ok: Bool = data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Bool in
            guard let base = src.bindMemory(to: UInt8.self).baseAddress else { return false }
            stream.src_ptr = base
            stream.src_size = data.count
            while true {
                stream.dst_ptr = buffer
                stream.dst_size = bufferSize
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = bufferSize - stream.dst_size
                if produced > 0 { out.append(buffer, count: produced) }
                if status == COMPRESSION_STATUS_END { return true }
                if status != COMPRESSION_STATUS_OK { return false }
            }
        }
        return ok ? out : Data()
    }
}

// MARK: - The settings bundle

/// How an imported UI pref combines with what you already have.
///  - `replace`  a scalar (a mode, a density). Cannot be additive, so it is OPT-IN on import.
///  - `union`    a JSON array of strings (favorites, selected classes). Additive by nature: the
///               union is taken, nothing you had is ever dropped.
enum UiPrefMerge { case replace, union }

/// One whitelisted preference that rides in a settings bundle. `key` is the localStorage key the
/// Electron app writes and the UserDefaults key this app writes — the SAME name, so the two apps'
/// bundles line up without a translation table.
struct UiPrefSpec {
    let key: String
    let label: String
    let merge: UiPrefMerge
    /// True when this app stores the value as a string ARRAY and the wire carries a JSON array.
    let list: Bool
}

/// What a settings bundle carries and how it is read back out.
///
/// The membership rule is the upstream whitelist's: GLOBAL preferences only. No file paths, no
/// window positions, no character progress — those are machine or character state, and the
/// exporter never reads them. This app's list is the upstream list MINUS the keys it has no store
/// for; a bundle carrying one of those simply offers a row this build has nothing to apply.
enum SettingsBundle {
    /// The overlay kinds a bundle may carry, and their names in a preview row.
    static let overlayKinds: [(String, String)] = [
        ("fight", "Fight meter"),
        ("overall", "Zone meter"),
        ("heal-fight", "Fight healing"),
        ("heal-overall", "Zone healing"),
        ("events", "Event log")
    ]

    /// The whitelist. Anything not listed here never leaves the machine.
    static let uiSpecs: [UiPrefSpec] = [
        UiPrefSpec(key: "eq.bossDensity", label: "Raid target list density", merge: .replace, list: false),
        UiPrefSpec(key: "eq.countSource", label: "Item count source", merge: .replace, list: false),
        UiPrefSpec(key: "eq.selectedClasses", label: "Plane of Sky class filter", merge: .union, list: true),
        UiPrefSpec(key: "eq.favorites", label: "Favorited items", merge: .union, list: true)
    ]

    /// Snapshot the whitelisted preferences as the WIRE spells them: a list key becomes the JSON
    /// array text the Electron app keeps in localStorage, a scalar key its bare string.
    static func readUiPrefs(_ d: UserDefaults = .standard) -> [String: String] {
        var out: [String: String] = [:]
        for spec in uiSpecs {
            if spec.list {
                let list = d.stringArray(forKey: spec.key) ?? []
                if list.isEmpty { continue }
                out[spec.key] = ShareCodec.canonicalJson(.array(list.map { .string($0) }))
            } else if let v = d.string(forKey: spec.key), !v.isEmpty {
                out[spec.key] = String(v.prefix(ShareCodec.Limits.maxUiValueChars))
            }
        }
        return out
    }

    /// Write one whitelisted value back. Lists are stored as string arrays, scalars as strings.
    static func writeUiPref(_ spec: UiPrefSpec, _ value: String, _ d: UserDefaults = .standard) {
        if spec.list {
            d.set(parseList(value), forKey: spec.key)
        } else {
            d.set(value, forKey: spec.key)
        }
    }

    /// A wire list → its members. Anything that is not an array of strings reads as empty rather
    /// than as an error: a stranger's bundle must not be able to raise.
    static func parseList(_ text: String) -> [String] {
        guard let v = try? JSONValue.parse(text), let a = v.array else { return [] }
        return a.compactMap(\.string)
    }

    /// Build the GLOBAL settings body — the whitelist in executable form. It PROJECTS named fields
    /// out of its inputs, so a machine path or a window bound cannot appear in an export even if
    /// some future code puts one in the store.
    static func body(alerts: [JSONValue], globalVolume: Double, muted: Bool, alwaysPlayAll: Bool,
                     overlayShared: Double, overlayIndependent: Bool, overlays: [String: Double],
                     ui: [String: String]) -> JSONValue {
        var o: [String: JSONValue] = [:]
        let picked = Array(alerts.prefix(ShareCodec.Limits.maxAlerts))
        if !picked.isEmpty { o["alerts"] = .array(picked) }
        var prefs: [String: JSONValue] = ["globalVolume": .double(clamp01(globalVolume)),
                                          "muted": .bool(muted)]
        // Projected only when TRUE, the same rule the store writes it by: a bundle from a machine
        // with the audio throttle on is byte-identical to one written before the preference
        // existed, so no old share string suddenly grows a row it never carried.
        if alwaysPlayAll { prefs["alwaysPlayAll"] = .bool(true) }
        o["alertPrefs"] = .object(prefs)
        // The transparency PREFERENCE and the per-kind values ride together: a machine running an
        // older build reads this bundle and finds everything it knows how to apply. `seeded` is
        // deliberately absent — it is bookkeeping about this install's own history with the switch.
        o["overlayBgAlpha"] = ["shared": .double(clamp01(overlayShared)),
                               "independent": .bool(overlayIndependent)]
        var perKind: [String: JSONValue] = [:]
        for (kind, _) in overlayKinds {
            guard let a = overlays[kind] else { continue }
            perKind[kind] = ["bgAlpha": .double(clamp01(a))]
        }
        if !perKind.isEmpty { o["overlays"] = .object(perKind) }
        var uiOut: [String: JSONValue] = [:]
        for spec in uiSpecs {
            if let v = ui[spec.key], !v.isEmpty { uiOut[spec.key] = .string(v) }
        }
        if !uiOut.isEmpty { o["ui"] = .object(uiOut) }
        return .object(o)
    }

    private static func clamp01(_ v: Double) -> Double { v.isFinite ? max(0, min(1, v)) : 0 }
}

// MARK: - The preview: what an incoming bundle would do

/// What would happen to one incoming alert.
enum AlertMergeAction: String {
    /// you do not have it — it is added as it is
    case add
    /// you have that ID already, holding something else — it is added under a fresh one
    case rekey
    /// you already have this exact alert — nothing happens
    case skip

    var label: String {
        switch self {
        case .add: return "add"
        case .rekey: return "add (new id)"
        case .skip: return "already have"
        }
    }
}

struct AlertMergeItem: Identifiable {
    var id: String { finalId }
    /// the id it would land under — the incoming one, or a fresh one when that collides
    var finalId: String
    var name: String
    var badge: String
    var action: AlertMergeAction
    var def: AlertDef
}

/// One setting an incoming bundle would change. Each REPLACES your value (or, for a union, adds
/// to it), so each is its own opt-in row.
struct ScalarChange: Identifiable {
    var id: String
    var label: String
    var current: String
    var incoming: String
    var merge: UiPrefMerge
    /// The value to store when this row is applied — already merged, for a union.
    var applied: JSONValue
}

/// The state an incoming bundle is diffed against.
struct ShareContext {
    var alerts: [AlertDef]
    var globalVolume: Double
    var muted: Bool
    var alwaysPlayAll: Bool
    var overlayShared: Double
    var overlayIndependent: Bool
    var overlays: [String: Double]
    var ui: [String: String]
}

struct SharePreview {
    var kind: ShareKind
    var appVersion: String
    var createdAt: String
    var alerts: [AlertMergeItem]
    var scalars: [ScalarChange]
    /// The original string, echoed back so applying doesn't have to re-parse a paste.
    var text: String

    var importable: Int { alerts.filter { $0.action != .skip }.count }
    var alreadyHave: Int { alerts.count - importable }
    var isEmpty: Bool { alerts.isEmpty && scalars.isEmpty }
}

enum ShareMerge {
    /// WHAT MAKES TWO ALERTS THE SAME ALERT. Not the id — an id is a machine's bookkeeping and two
    /// people can hold the same alert under two of them. It is the BEHAVIOUR: what fires it, what
    /// it is called, and what it does when it fires. An incoming alert that matches one you hold
    /// on all of that is one you already have, whatever its id says.
    static func behaviorKey(_ d: AlertDef) -> String {
        ShareCodec.canonicalJson(["name": .string(d.name),
                                  "trigger": d.trigger.toJSON(),
                                  "sound": ["packId": .string(d.packId), "soundId": .string(d.soundId)],
                                  "audio": .string(d.audio),
                                  "speech": ["mode": .string(d.speechMode), "phrase": .string(d.phrase)]])
    }

    /// Read one incoming alert. `nil` for anything that could not be an alert here — it is
    /// dropped rather than half-applied.
    static func readAlert(_ v: JSONValue) -> AlertDef? {
        guard var d = AlertDef.from(v) else { return nil }
        d.name = String(d.name.prefix(ShareCodec.Limits.maxNameChars)).trimmingCharacters(in: .whitespaces)
        if d.id.isEmpty || d.name.isEmpty || d.packId.isEmpty || d.soundId.isEmpty { return nil }
        return d
    }

    /// Plan the alert half of an import: what is new, what collides on an id, what you have.
    static func planAlerts(_ body: JSONValue, _ ctx: ShareContext) -> [AlertMergeItem] {
        let incoming = (body["alerts"].array ?? []).prefix(ShareCodec.Limits.maxAlerts).compactMap(readAlert)
        let mine = Set(ctx.alerts.map(\.id))
        let behaviours = Set(ctx.alerts.map(behaviorKey))
        var out: [AlertMergeItem] = []
        for var d in incoming {
            let action: AlertMergeAction
            if behaviours.contains(behaviorKey(d)) {
                action = .skip
            } else if mine.contains(d.id) {
                action = .rekey
                d.id = UUID().uuidString.lowercased()
            } else {
                action = .add
            }
            out.append(AlertMergeItem(finalId: d.id, name: d.name, badge: d.trigger.badge,
                                      action: action, def: d))
        }
        return out
    }

    /// Diff the settings half. Only genuinely different rows come back.
    ///
    /// THE PREFERENCE ROWS COME BEFORE THE PER-KIND ONES, and the order is load-bearing: this
    /// app's per-overlay transparencies are only read when independent mode is on, so a per-kind
    /// value applied first would be about to be governed by a mode row the same import selected.
    static func planScalars(_ body: JSONValue, _ ctx: ShareContext) -> [ScalarChange] {
        var out: [ScalarChange] = []
        let prefs = body["alertPrefs"]
        if !prefs.isNull {
            push(&out, id: "alertPrefs.globalVolume", label: "Global alert volume",
                 current: pct(ctx.globalVolume), incoming: pct(prefs["globalVolume"].double ?? ctx.globalVolume),
                 merge: .replace, applied: .double(prefs["globalVolume"].double ?? ctx.globalVolume))
            push(&out, id: "alertPrefs.muted", label: "Mute all alerts",
                 current: onOff(ctx.muted), incoming: onOff(prefs["muted"].bool ?? false),
                 merge: .replace, applied: .bool(prefs["muted"].bool ?? false))
            // Absent on both sides means OFF on both sides, so a bundle written before this
            // preference existed offers no row here — which is right: it has no opinion to import.
            push(&out, id: "alertPrefs.alwaysPlayAll", label: "Always play all alerts",
                 current: onOff(ctx.alwaysPlayAll), incoming: onOff(prefs["alwaysPlayAll"].bool ?? false),
                 merge: .replace, applied: .bool(prefs["alwaysPlayAll"].bool ?? false))
        }
        let alpha = body["overlayBgAlpha"]
        if !alpha.isNull {
            let shared = alpha["shared"].double ?? ctx.overlayShared
            push(&out, id: "overlayBgAlpha.shared", label: "Overlay transparency",
                 current: pct(ctx.overlayShared), incoming: pct(shared),
                 merge: .replace, applied: .double(shared))
            let independent = alpha["independent"].bool ?? ctx.overlayIndependent
            push(&out, id: "overlayBgAlpha.independent", label: "Independent transparency per overlay",
                 current: onOff(ctx.overlayIndependent), incoming: onOff(independent),
                 merge: .replace, applied: .bool(independent))
        }
        for (kind, label) in SettingsBundle.overlayKinds {
            let inc = body["overlays"][kind]
            guard !inc.isNull, let a = inc["bgAlpha"].double else { continue }
            push(&out, id: "overlay.\(kind).bgAlpha", label: "\(label) - background opacity",
                 current: ctx.overlays[kind].map(pct) ?? "", incoming: pct(a),
                 merge: .replace, applied: .double(a))
        }
        for spec in SettingsBundle.uiSpecs {
            let inc = body["ui"][spec.key]
            guard let text = inc.string else { continue }
            let merged = spec.merge == .union ? unionText(ctx.ui[spec.key], text) : text
            push(&out, id: "ui.\(spec.key)", label: spec.label,
                 current: ctx.ui[spec.key] ?? "", incoming: merged,
                 merge: spec.merge, applied: .string(merged))
        }
        return out
    }

    /// Combine one union pref: both sides as string lists, yours first then theirs, nothing you
    /// had ever dropped. Anything that does not read as a list falls back to replace semantics
    /// rather than guessing.
    static func unionText(_ mine: String?, _ theirs: String) -> String {
        let a = SettingsBundle.parseList(mine ?? "[]")
        let b = SettingsBundle.parseList(theirs)
        if b.isEmpty && !theirs.isEmpty && theirs != "[]" { return theirs }
        var seen = Set<String>()
        var merged: [String] = []
        for n in a + b where !seen.contains(n) {
            seen.insert(n)
            merged.append(n)
        }
        return ShareCodec.canonicalJson(.array(merged.map { .string($0) }))
    }

    /// Record a row only when the two sides genuinely differ, as the preview renders them.
    private static func push(_ out: inout [ScalarChange], id: String, label: String,
                             current: String, incoming: String, merge: UiPrefMerge, applied: JSONValue) {
        guard current != incoming else { return }
        out.append(ScalarChange(id: id, label: label, current: current, incoming: incoming,
                                merge: merge, applied: applied))
    }

    private static func pct(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

    /// Not `true`/`false`: the row is a sentence a person opts into, and
    /// "Independent transparency per overlay: false → true" is not one.
    private static func onOff(_ b: Bool) -> String { b ? "On" : "Off" }

    /// Build the whole preview for a pasted string.
    static func preview(_ text: String, _ ctx: ShareContext) -> Result<SharePreview, ShareDecodeError> {
        switch ShareCodec.decode(text) {
        case .failure(let e): return .failure(e)
        case .success(let env):
            let alerts = planAlerts(env.body, ctx)
            let scalars = env.kind == .settings ? planScalars(env.body, ctx) : []
            let p = SharePreview(kind: env.kind, appVersion: env.app, createdAt: env.at,
                                 alerts: alerts, scalars: scalars, text: text)
            return p.alerts.isEmpty && p.scalars.isEmpty ? .failure(.emptyPayload) : .success(p)
        }
    }
}

/// What an import actually did, in the words the card reports it with.
struct ShareApplyResult {
    var added = 0
    var rekeyed = 0
    var scalarsApplied = 0
    var skipped = 0
    /// A view preference this app reads once, at start — so the honest sentence says when it lands.
    var deferredToRestart = false

    var summary: String {
        var bits: [String] = []
        if added > 0 { bits.append("added \(added) alert\(added == 1 ? "" : "s")") }
        if rekeyed > 0 { bits.append("\(rekeyed) kept alongside an existing id") }
        if scalarsApplied > 0 { bits.append("\(scalarsApplied) setting\(scalarsApplied == 1 ? "" : "s")") }
        if skipped > 0 { bits.append("\(skipped) skipped") }
        guard !bits.isEmpty else { return "Nothing to add - you already have it all." }
        let tail = deferredToRestart ? " View preferences and favorites appear next time you open the app." : ""
        return "Imported - \(bits.joined(separator: ", "))." + tail
    }
}
