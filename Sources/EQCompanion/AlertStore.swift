// The user's alert definitions, held as the engine takes them (`AlertDefinition` is an open shape
// the protocol states nothing about) and persisted as JSON under Application Support. The engine
// evaluates them against LIVE events; the app pushes the whole set on every change and reconnect.
//
// A trigger is one primitive condition or an any/all composite of them, exactly as
// `shared/alertTypes.ts` spells it. The `app:` primitive is stored and shared but NOT evaluated
// here: in Electron the renderer fires those signals (boss defeat, Sky quest complete) and this
// app has no such producer yet, so a def carrying one sits silent and says so in the row.
import Foundation
import Observation
import EQCompanionCore

/// The pack the app provisions and every picker falls back to (`DEFAULT_ALERT_PACK_ID`).
let defaultAlertPackId = "alan-rickman"

/// The Alan Rickman lines the shipped defs name, derived ids and all (`DEFAULT_ALERT_SOUNDS`).
enum DefaultAlertSounds {
    /// "I find myself... requiring your attention."
    static let charmBreak = "input-required-input-required-02"
    /// "The matter is settled."
    static let bossDefeat = "task-complete-task-complete-07"
    /// "It is done."
    static let questComplete = "task-complete-task-complete-01"
    /// "A moment of your time, if you'd be so kind."
    static let buffWearsOff = "input-required-input-required-01"
    /// "That, as they say, is that."
    static let buffFade = "resource-limit-resource-limit-09"
    /// "Consider this my opening move."
    static let debuffLands = "task-acknowledge-task-acknowledge-05"
    /// "It has all gone rather pear-shaped."
    static let illusionFade = "task-error-task-error-08"
}

/// The event kinds an alert can trigger on — the `LogEventKind` union of `shared/alertTypes.ts`,
/// in its own declaration order.
let alertEventKinds: [String] = [
    "zone", "loot", "offer", "trade", "level", "aaGain", "aaSpend", "aaPotion", "death", "damage",
    "heal", "healUnstated", "mitigation", "miss", "resist", "charm", "uncharm", "cc", "petClaim",
    "petSay", "castBegin", "castFizzle", "castInterrupted", "buffFade", "playerDeath", "spellEmote",
    "buffApply", "buffWearOff", "aaActivate", "illusionFade", "buffExpired", "stanceChange",
    "invocationChange", "spellMemorize", "spellForget", "spellSet", "consider", "poisonProc",
    "poisonCoat", "poisonDry"
]

/// The renderer-side signals of `AppSignal`. Stored, never fired here.
let alertAppSignals: [String] = ["bossDefeat", "questComplete"]

/// One field matcher on an event condition. The value is an exact case-insensitive compare, or
/// `/regex/` when slashes delimit it.
struct AlertWhere: Identifiable, Equatable {
    var id = UUID()
    var field: String = ""
    var value: String = ""
}

/// A PRIMITIVE trigger condition: a typed event, a raw line regex, or an app signal.
struct AlertCondition: Identifiable, Equatable {
    enum Kind: String, CaseIterable, Identifiable {
        case event, raw, app
        var id: String { rawValue }
        var label: String {
            switch self {
            case .event: return "Parsed event"
            case .raw: return "Raw line regex"
            case .app: return "App signal"
            }
        }
    }

    var id = UUID()
    var kind: Kind = .event
    var eventKind: String = "zone"
    var regex: String = ""
    var signal: String = "bossDefeat"
    var wheres: [AlertWhere] = []

    /// Keys we spell first so a badge reads the way the Electron one does; the rest sort by name.
    private static let whereOrder = ["spell", "target", "refresh", "caster", "mob", "effect", "done", "action"]

    func toJSON() -> JSONValue {
        switch kind {
        case .raw:
            return ["type": "raw", "regex": .string(regex)]
        case .app:
            return ["type": "app", "signal": .string(signal)]
        case .event:
            var o: [String: JSONValue] = ["type": "event", "kind": .string(eventKind)]
            var w: [String: JSONValue] = [:]
            for m in wheres {
                let f = m.field.trimmingCharacters(in: .whitespaces)
                if !f.isEmpty { w[f] = .string(m.value) }
            }
            if !w.isEmpty { o["where"] = .object(w) }
            return .object(o)
        }
    }

    static func from(_ v: JSONValue) -> AlertCondition {
        var c = AlertCondition()
        switch v["type"].string {
        case "raw":
            c.kind = .raw
            c.regex = v["regex"].string ?? ""
        case "app":
            c.kind = .app
            c.signal = v["signal"].string ?? "bossDefeat"
        case "event":
            c.kind = .event
            c.eventKind = v["kind"].string ?? "zone"
            c.wheres = orderedWheres(v["where"])
        default:
            // An unreadable trigger is shown as the raw text it was, never silently dropped.
            c.kind = .raw
            c.regex = v.serializedString()
        }
        return c
    }

    private static func orderedWheres(_ v: JSONValue) -> [AlertWhere] {
        guard let o = v.object else { return [] }
        let keys = o.keys.sorted { a, b in
            let ia = whereOrder.firstIndex(of: a) ?? whereOrder.count
            let ib = whereOrder.firstIndex(of: b) ?? whereOrder.count
            return ia == ib ? a < b : ia < ib
        }
        return keys.map { AlertWhere(field: $0, value: o[$0]?.display ?? "") }
    }

    /// `event:uncharm {spell=Allure}`, `raw:/pattern/i`, `app:bossDefeat` — `primitiveBadge`.
    var badge: String {
        switch kind {
        case .raw: return "raw:/\(regex)/i"
        case .app: return "app:\(signal)"
        case .event:
            let pairs = wheres.filter { !$0.field.trimmingCharacters(in: .whitespaces).isEmpty }
            let w = pairs.isEmpty ? "" : " {" + pairs.map { "\($0.field)=\($0.value)" }.joined(separator: ", ") + "}"
            return "event:\(eventKind)\(w)"
        }
    }
}

/// A trigger: one condition, or an `any`/`all` composite of them (same-event correlation only).
struct AlertTriggerSpec: Equatable {
    enum Combine: String, CaseIterable, Identifiable {
        case single, any, all
        var id: String { rawValue }
        var label: String {
            switch self {
            case .single: return "One condition"
            case .any: return "Any of these (OR)"
            case .all: return "All of these, same event (AND)"
            }
        }
    }

    var combine: Combine = .single
    var conditions: [AlertCondition] = [AlertCondition()]

    init(combine: Combine = .single, conditions: [AlertCondition] = [AlertCondition()]) {
        self.combine = combine
        self.conditions = conditions.isEmpty ? [AlertCondition()] : conditions
    }

    /// Convenience for a one-condition event trigger.
    init(eventKind: String, where wheres: [AlertWhere] = []) {
        self.init(combine: .single, conditions: [AlertCondition(kind: .event, eventKind: eventKind, wheres: wheres)])
    }

    /// Convenience for a one-condition app-signal trigger.
    init(appSignal: String) {
        self.init(combine: .single, conditions: [AlertCondition(kind: .app, signal: appSignal)])
    }

    func toJSON() -> JSONValue {
        if combine == .single || conditions.count == 1 { return conditions[0].toJSON() }
        return ["type": .string(combine.rawValue), "conditions": .array(conditions.map { $0.toJSON() })]
    }

    static func from(_ v: JSONValue) -> AlertTriggerSpec {
        if let list = v["conditions"].array, let t = v["type"].string, t == "any" || t == "all" {
            return AlertTriggerSpec(combine: t == "any" ? .any : .all, conditions: list.map(AlertCondition.from))
        }
        return AlertTriggerSpec(combine: .single, conditions: [AlertCondition.from(v)])
    }

    /// `triggerBadge`: `any(event:buffExpired {spell=X}, event:buffWearOff {spell=X})`.
    var badge: String {
        if combine == .single || conditions.count == 1 { return conditions[0].badge }
        return "\(combine.rawValue)(" + conditions.map(\.badge).joined(separator: ", ") + ")"
    }

    /// Does this trigger rest on an app signal nothing in this app fires yet?
    var hasAppSignal: Bool { conditions.contains { $0.kind == .app } }
}

struct AlertDef: Identifiable, Equatable {
    var id: String
    var name: String
    var enabled: Bool
    var trigger: AlertTriggerSpec
    var packId: String
    var soundId: String
    var volume: Double
    var cooldownMs: Int
    var audio: String            // sound | speech | both (both is readable, never offered)
    var speechMode: String       // custom | alertName | spellName | spellFirstWord
    var phrase: String
    var showOnScreen: Bool
    var bannerText: String
    var note: String
    /// Opt this alert out of the cross-alert coalescing window: it always plays.
    var alwaysPlay: Bool
    /// Fields the editor does not know about, carried verbatim so a shared def survives a round trip.
    var extra: [String: JSONValue]

    static func fresh() -> AlertDef {
        AlertDef(id: UUID().uuidString.lowercased(), name: "New alert", enabled: true,
                 trigger: AlertTriggerSpec(), packId: defaultAlertPackId,
                 soundId: DefaultAlertSounds.buffWearsOff, volume: 1, cooldownMs: 3000, audio: "sound",
                 speechMode: "alertName", phrase: "", showOnScreen: true, bannerText: "", note: "",
                 alwaysPlay: false, extra: [:])
    }

    var soundKey: String { "\(packId)/\(soundId)" }

    func toJSON() -> JSONValue {
        var o = extra
        o["id"] = .string(id)
        o["name"] = .string(name)
        o["enabled"] = .bool(enabled)
        o["trigger"] = trigger.toJSON()
        o["sound"] = ["packId": .string(packId), "soundId": .string(soundId)]
        o["volume"] = .double(volume)
        o["cooldownMs"] = .int(Int64(cooldownMs))
        o["audio"] = .string(audio)
        var speech: [String: JSONValue] = ["mode": .string(speechMode)]
        if speechMode == "custom" { speech["phrase"] = .string(phrase) }
        o["speech"] = .object(speech)
        o["showOnScreen"] = .bool(showOnScreen)
        o["alwaysPlay"] = alwaysPlay ? .bool(true) : nil
        o["bannerText"] = bannerText.isEmpty ? nil : .string(bannerText)
        o["note"] = note.isEmpty ? nil : .string(note)
        return .object(o)
    }

    static func from(_ v: JSONValue) -> AlertDef? {
        guard let o = v.object, let id = o["id"]?.string else { return nil }
        let known: Set<String> = ["id", "name", "enabled", "trigger", "sound", "volume", "cooldownMs", "audio",
                                  "speech", "showOnScreen", "bannerText", "note", "alwaysPlay"]
        var extra = o
        for k in known { extra[k] = nil }
        return AlertDef(id: id,
                        name: o["name"]?.string ?? id,
                        enabled: o["enabled"]?.bool ?? true,
                        trigger: AlertTriggerSpec.from(o["trigger"] ?? .null),
                        packId: o["sound"]?["packId"].string ?? defaultAlertPackId,
                        soundId: o["sound"]?["soundId"].string ?? DefaultAlertSounds.buffWearsOff,
                        volume: o["volume"]?.double ?? 1,
                        cooldownMs: o["cooldownMs"]?.int ?? 3000,
                        audio: o["audio"]?.string ?? "sound",
                        speechMode: o["speech"]?["mode"].string ?? "alertName",
                        phrase: o["speech"]?["phrase"].string ?? "",
                        showOnScreen: o["showOnScreen"]?.bool ?? true,
                        bannerText: o["bannerText"]?.string ?? "",
                        note: o["note"]?.string ?? "",
                        alwaysPlay: o["alwaysPlay"]?.bool ?? false,
                        extra: extra)
    }
}

@MainActor
@Observable
final class AlertStore {
    private(set) var defs: [AlertDef] = []
    var onChange: (() -> Void)?

    static let file: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("EQCompanion", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("alerts.json")
    }()

    init() {
        load()
    }

    func load() {
        if let data = try? Data(contentsOf: Self.file), let v = try? JSONValue.parse(data) {
            defs = (v["defs"].array ?? []).compactMap(AlertDef.from)
        } else {
            defs = Self.seeds()
            save()
        }
    }

    func definitions() -> [JSONValue] { defs.map { $0.toJSON() } }

    func def(named name: String) -> AlertDef? { defs.first { $0.name == name } }

    func def(id: String) -> AlertDef? { defs.first { $0.id == id } }

    func has(id: String) -> Bool { defs.contains { $0.id == id } }

    func save() {
        let doc: JSONValue = ["defs": .array(definitions())]
        try? Data(doc.pretty().utf8).write(to: Self.file, options: .atomic)
        onChange?()
    }

    func upsert(_ d: AlertDef) {
        if let i = defs.firstIndex(where: { $0.id == d.id }) { defs[i] = d } else { defs.append(d) }
        save()
    }

    /// Add several at once (the suggestion catalog's "Add N alerts"). Existing ids are replaced.
    @discardableResult
    func addAll(_ list: [AlertDef]) -> Int {
        guard !list.isEmpty else { return 0 }
        for d in list {
            if let i = defs.firstIndex(where: { $0.id == d.id }) { defs[i] = d } else { defs.append(d) }
        }
        save()
        return list.count
    }

    func remove(_ id: String) {
        defs.removeAll { $0.id == id }
        save()
    }

    func toggle(_ id: String) {
        if let i = defs.firstIndex(where: { $0.id == id }) {
            defs[i].enabled.toggle()
            save()
        }
    }

    /// Replace every alert — added, edited or seeded — with the shipped set. No undo.
    func resetToDefaults() {
        defs = Self.seeds()
        save()
    }

    /// The whole set as one JSON document, for "Copy all".
    func exportJSON() -> String {
        JSONValue.object(["defs": .array(definitions())]).pretty()
    }

    /// One def as its own document, for a row's share button.
    func exportJSON(_ d: AlertDef) -> String {
        JSONValue.object(["defs": .array([d.toJSON()])]).pretty()
    }

    /// Import a JSON array or `{defs:[...]}` document. Imports only ever ADD.
    @discardableResult
    func importJSON(_ text: String) -> Int {
        guard let v = try? JSONValue.parse(text) else { return 0 }
        let list = v.array ?? v["defs"].array ?? []
        var added = 0
        for item in list {
            guard var d = AlertDef.from(item) else { continue }
            if defs.contains(where: { $0.id == d.id }) { d.id = UUID().uuidString.lowercased() }
            defs.append(d)
            added += 1
        }
        if added > 0 { save() }
        return added
    }

    /// Repoint every def that names `packId` at another pack — what a pack removal owes the
    /// alerts that were using it. Returns how many moved.
    @discardableResult
    func repoint(fromPack packId: String, toPack newPack: String, soundId: String) -> Int {
        var changed = 0
        for i in defs.indices where defs[i].packId == packId {
            defs[i].packId = newPack
            defs[i].soundId = soundId
            changed += 1
        }
        if changed > 0 { save() }
        return changed
    }

    /// The seeded set, mirroring `SEED_ALERTS` in `src/main/store.ts`.
    ///
    /// Two of the three are `app:` signals, which main stores and the RENDERER fires. This app has
    /// no producer for them yet, so they are carried (they share, they export, they are ready the
    /// day a producer exists) and their note says plainly that nothing fires them here.
    static func seeds() -> [AlertDef] {
        func make(_ id: String, _ name: String, _ trigger: AlertTriggerSpec, _ soundId: String,
                  note: String) -> AlertDef {
            var d = AlertDef.fresh()
            d.id = id
            d.name = name
            d.trigger = trigger
            d.packId = defaultAlertPackId
            d.soundId = soundId
            d.audio = "sound"
            d.note = note
            return d
        }
        let appNote = " In this app nothing fires app: signals yet, so it is stored but silent."
        return [
            make("charm-break", "Charm break", AlertTriggerSpec(eventKind: "uncharm"),
                 DefaultAlertSounds.charmBreak,
                 note: "Seeded default - fires when a charm spell wears off (you lose your pet)."),
            make("boss-defeat", "Raid target defeated", AlertTriggerSpec(appSignal: "bossDefeat"),
                 DefaultAlertSounds.bossDefeat,
                 note: "Seeded default - fires the same moment boss confetti does." + appNote),
            make("quest-complete", "Sky quest complete", AlertTriggerSpec(appSignal: "questComplete"),
                 DefaultAlertSounds.questComplete,
                 note: "Seeded default - fires the same moment a Sky quest turn-in celebration does." + appNote)
        ]
    }
}
