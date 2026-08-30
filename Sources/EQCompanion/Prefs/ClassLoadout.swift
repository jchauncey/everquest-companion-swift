// ClassLoadout — the class-combo surface's vocabulary, its correction store, and the controls the
// Profiles page draws with them. Ported from src/shared/classCombo.ts and the renderer's
// features/profiles/ClassCombo* files.
//
// EQ Legends runs UP TO THREE CLASSES AT ONCE and the log NEVER states a loadout swap. The
// character's own `/who` row is the only line that names the combo outright; everything else is
// INFERENCE, so every reading here carries provenance, a confidence, and an explicit way of saying
// NOT KNOWING.
//
// THE THREE HONESTY RULES THIS FILE ENFORCES:
//   1. A slot with several candidates prints the SET (`CLR|PAL`) and never picks a member.
//   2. A slot with no evidence prints an em-dash. Not a class, not a blank, not a zero.
//   3. A boundary is a RANGE. A swap prints nothing, so the two events that bracket it can be
//      hours apart; the `~` marker and its window are the honest reading of `startTs`.
//
// CORRECTIONS ARE THE ONLY DURABLE COMBO STATE, and they are keyed by TIME, never by interval id:
// a correction recomputes every interval and ids are recompute-unstable by design. They live in
// UserDefaults here and are pushed to the engine as a `combo.define` — the whole list, every time,
// and again after each attach, because a fresh fold starts out holding none of them.
import SwiftUI
import AppKit
import EQCompanionCore

// MARK: - The closed class set

// The 16 EQ Legends classes, by their `/who` three-letter code, are already spelled once in this
// app — `classAbbrs` in GearIndex.swift, in the same order, and SHD rather than SHK for the same
// reason the shared module gives: the wiki spells the class both "Shadow Knight" and
// "Shadowknight", and both canonicalize there.

/// The whole class name, which is what a chip in a picker says (the abbreviation is the VALUE).
let classDisplayNames: [String: String] = [
    "BER": "Berserker", "BRD": "Bard", "BST": "Beastlord", "CLR": "Cleric",
    "DRU": "Druid", "ENC": "Enchanter", "MAG": "Magician", "MNK": "Monk",
    "NEC": "Necromancer", "PAL": "Paladin", "RNG": "Ranger", "ROG": "Rogue",
    "SHD": "Shadow Knight", "SHM": "Shaman", "WAR": "Warrior", "WIZ": "Wizard"
]

func classDisplayName(_ abbr: String) -> String { classDisplayNames[abbr] ?? abbr }

/// A loadout holds at most three classes (Primary + Secondary; Tertiary unlocks at level 10).
let maxComboSlots = 3

/// How many candidates make a slot UNKNOWN rather than merely ambiguous.
let allClassesCount = 16

// MARK: - Corrections

/// A user correction — the ONLY durable combo state. Keyed by time; `endTs == nil` means "from
/// startTs onward", i.e. it applies to the open interval too and autodetection cannot take it back.
struct ComboCorrectionRow: Equatable {
    var startTs: Int64
    var endTs: Int64?
    var classes: [String]
    /// When the user set it — a later correction wins over an earlier overlapping one.
    var setAt: Int64

    var json: JSONValue {
        ["startTs": .int(startTs),
         "endTs": endTs.map { JSONValue.int($0) } ?? .null,
         "classes": .array(classes.map { .string($0) }),
         "setAt": .int(setAt)]
    }

    static func from(_ v: JSONValue) -> ComboCorrectionRow? {
        guard let start = v["startTs"].int64, let setAt = v["setAt"].int64 else { return nil }
        let classes = (v["classes"].array ?? []).compactMap(\.string).filter(classAbbrs.contains)
        if classes.isEmpty || classes.count > maxComboSlots { return nil }
        return ComboCorrectionRow(startTs: start, endTs: v["endTs"].int64,
                                  classes: classes, setAt: setAt)
    }
}

/// The corrections this machine holds, persisted whole. Not in `Prefs.swift` because it is a
/// record rather than a setting — a list of statements about spans of time, with no default.
@MainActor
@Observable
final class ComboCorrections {
    static let shared = ComboCorrections()
    private let key = "prefs.profiles.comboCorrections"
    private(set) var rows: [ComboCorrectionRow] = []

    private init() {
        guard let text = UserDefaults.standard.string(forKey: key),
              let v = try? JSONValue.parse(text) else { return }
        rows = (v.array ?? []).compactMap(ComboCorrectionRow.from)
    }

    private func save() {
        UserDefaults.standard.set(ShareCodec.canonicalJson(.array(rows.map(\.json))), forKey: key)
    }

    /// Set the loadout for a span. A correction for the SAME span replaces the old one — two
    /// statements about one range is not a history, it is a contradiction.
    func set(startTs: Int64, endTs: Int64?, classes: [String]) {
        rows.removeAll { $0.startTs == startTs && $0.endTs == endTs }
        rows.append(ComboCorrectionRow(startTs: startTs, endTs: endTs, classes: classes,
                                       setAt: Int64(Date().timeIntervalSince1970 * 1000)))
        rows.sort { $0.startTs < $1.startTs }
        save()
    }

    /// Withdraw every correction that overlaps a span — "back to autodetect" for that stretch.
    func clear(startTs: Int64, endTs: Int64?) {
        let hi = endTs ?? Int64.max
        rows.removeAll { row in
            let rowHi = row.endTs ?? Int64.max
            return row.startTs <= hi && rowHi >= startTs
        }
        save()
    }
}

extension AppModel {
    /// Push the class-loadout corrections to the engine. Called after every edit and — by the
    /// integrator — after each attach: the combo module holds them as a define, and a fold that
    /// came up without them would re-infer the loadouts the user has already corrected.
    func pushComboCorrections() async {
        guard client.isReady else { return }
        let rows = ComboCorrections.shared.rows.map(\.json)
        do {
            _ = try await client.request(Op.comboDefine, ["corrections": .array(rows)])
        } catch {
            note("combo.define failed: \(error)")
        }
    }
}

// MARK: - Reading one interval

/// One slot's knowledge, as the `combo` module publishes it.
struct ComboSlotView {
    var candidates: [String]
    var confidence: Double
    var provenance: String

    static func from(_ v: JSONValue) -> ComboSlotView {
        ComboSlotView(candidates: (v["candidates"].array ?? []).compactMap(\.string),
                      confidence: v["confidence"].double ?? 0,
                      provenance: v["provenance"].string ?? "inferred")
    }

    enum Kind { case resolved, ambiguous, unknown }

    /// Resolved = exactly one candidate. Unknown = the whole roster (or nothing). Else ambiguous.
    var kind: Kind {
        if candidates.count == 1 { return .resolved }
        if candidates.isEmpty || candidates.count >= allClassesCount { return .unknown }
        return .ambiguous
    }

    /// `PAL` · `CLR|PAL` · `-`. Rules 1 and 2 in one property.
    var label: String { kind == .unknown ? "-" : candidates.joined(separator: "|") }

    /// A fact about what the log did or did not name — never about the algorithm.
    var help: String {
        switch kind {
        case .resolved: return "\(candidates[0]) - \(ComboLabels.provenance(provenance))."
        case .unknown: return "Nothing in this range named a class for this slot."
        case .ambiguous: return "One of \(candidates.joined(separator: ", ")) - the log never named which."
        }
    }
}

/// A contiguous span during which we believe the loadout did not change.
struct ComboIntervalView: Identifiable {
    var id: String
    var startTs: Int64
    var endTs: Int64?
    var startLo: Int64
    var startHi: Int64
    var startReason: String
    var startAlso: [String]
    var slots: [ComboSlotView]
    var levelLo: Int64?
    var levelHi: Int64?
    var evidenceCount: Int
    var userLocked: Bool
    var userOverruled: Bool
    var levelRegressed: Bool

    static func from(_ v: JSONValue) -> ComboIntervalView? {
        guard let id = v["id"].string, let start = v["startTs"].int64 else { return nil }
        return ComboIntervalView(id: id,
                                 startTs: start,
                                 endTs: v["endTs"].int64,
                                 startLo: v["startLo"].int64 ?? start,
                                 startHi: v["startHi"].int64 ?? start,
                                 startReason: v["startReason"].string ?? "logStart",
                                 startAlso: (v["startAlso"].array ?? []).compactMap(\.string),
                                 slots: (v["slots"].array ?? []).map(ComboSlotView.from),
                                 levelLo: v["levelLo"].int64,
                                 levelHi: v["levelHi"].int64,
                                 evidenceCount: v["evidenceCount"].int ?? 0,
                                 userLocked: v["userLocked"].bool == true,
                                 userOverruled: v["userOverruled"].bool == true,
                                 levelRegressed: v["levelRegressed"].bool == true)
    }

    /// Only the slots that hold exactly one candidate — an ambiguous or unknown slot seeds
    /// NOTHING into an editor, because a guess wearing the user's name is what this feature exists
    /// to prevent.
    var resolvedClasses: [String] { slots.filter { $0.candidates.count == 1 }.map { $0.candidates[0] } }

    /// Interval confidence is the MIN over slots — a combo you only 2/3 know is 2/3 known.
    var confidence: Double { slots.isEmpty ? 0 : (slots.map(\.confidence).min() ?? 0) }

    /// The strongest provenance in the interval — `user` beats `who` beats `inferred`.
    var provenance: String {
        if slots.contains(where: { $0.provenance == "user" }) { return "user" }
        if slots.contains(where: { $0.provenance == "who" }) { return "who" }
        return "inferred"
    }
}

// MARK: - The wording

/// The PURE wording of the class-combo surface — every honesty rule this feature has is a wording
/// decision, so they live as functions rather than rotting inside a view body.
enum ComboLabels {
    /// Chip text per provenance. `who` says what the log said, not how we read it.
    static func provenance(_ p: String) -> String {
        switch p {
        case "user": return "you set this"
        case "who": return "stated by /who"
        default: return "inferred"
        }
    }

    /// Where the loadout on screen came from, in the words the override control needs: it names
    /// the two things a user can act on, and says outright when nothing needs correcting.
    static func loadoutSource(_ i: ComboIntervalView) -> String {
        switch i.provenance {
        case "user": return "Set by you - autodetection will not change it."
        case "who": return "Named by your own /who row - the game stated this outright."
        default: return "Autodetected from the classes showing up in your log."
        }
    }

    /// The whole loadout, slot order preserved: `PAL / ROG / BER`, `PAL / CLR|PAL / -`.
    static func combo(_ i: ComboIntervalView) -> String {
        i.slots.map(\.label).joined(separator: " / ")
    }

    /// The notice for an override the game contradicted, or nil. Two facts, no adjudication.
    static func overruled(_ i: ComboIntervalView) -> String? {
        guard i.userOverruled else { return nil }
        return "A /who row inside this range named \(combo(i)), so your manual setting is not in effect here. Clear it, or set it to match."
    }

    /// Why the interval OPENED. Prose, because a raw `overDetermined` is not a state a user holds.
    static func boundaryReason(_ r: String) -> String {
        switch r {
        case "who": return "a /who row named a different loadout"
        case "levelDrop": return "the level dropped, which only a loadout swap does"
        case "evidenceShift": return "the classes showing up in the log changed"
        case "overDetermined": return "more classes than a loadout holds appeared here"
        case "user": return "you set this range"
        default: return "the log starts here"
        }
    }

    /// `8/2/2026, 2:13:34 AM → now` — the interval's span, user-local, one spelling.
    static func span(_ i: ComboIntervalView) -> String {
        "\(dateTime(i.startTs)) → \(i.endTs.map(dateTime) ?? "now")"
    }

    /// The `~` annotation for a fuzzy start, or nil when the boundary is exact. States the WINDOW
    /// first (that is the fact) and the detector second (that is why we believe it at all).
    static func startFuzz(_ i: ComboIntervalView) -> String? {
        let fuzz = max(0, i.startHi - i.startLo)
        if fuzz <= 0 { return nil }
        let reasons = ([i.startReason] + i.startAlso).map(boundaryReason).joined(separator: "; ")
        return "Started somewhere in a \(duration(fuzz)) window (\(dateTime(i.startLo)) → \(dateTime(i.startHi))): \(reasons)."
    }

    /// Why the confidence gate is holding this interval, or nil. The two conditions read
    /// differently to a user and are worth separating.
    static func uncertain(_ i: ComboIntervalView) -> String? {
        var reasons: [String] = []
        if i.startAlso.contains("overDetermined") { reasons.append("more classes showed up here than a loadout holds") }
        if i.levelRegressed { reasons.append("your level went backwards inside this range, which only a swap does") }
        if reasons.isEmpty { return nil }
        return "\(reasons.joined(separator: ", and ")) - so a swap probably happened in here that nothing dated. Treat these classes as a guess, and correct the range if you know better."
    }

    /// `levels 10-24`, `level 50`, or nil when no level was observed inside the interval.
    static func levelRange(_ i: ComboIntervalView) -> String? {
        guard let lo = i.levelLo, let hi = i.levelHi else { return nil }
        return lo == hi ? "level \(lo)" : "levels \(lo)-\(hi)"
    }

    /// `75%` — confidence as the min-over-slots number.
    static func confidence(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

    static func dateTime(_ ms: Int64) -> String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .medium
        return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    static func duration(_ ms: Int64) -> String {
        let total = max(0, Int(ms / 1000))
        let hrs = total / 3600
        if hrs >= 48 { return "\(hrs / 24)d \(hrs % 24)h" }
        let mins = (total % 3600) / 60
        if hrs > 0 { return "\(hrs)h \(mins)m" }
        return mins > 0 ? "\(mins)m" : "\(total % 60)s"
    }
}

// MARK: - Controls

/// One slot, as a chip. Colour carries the kind; the label carries the content.
struct SlotChipView: View {
    let slot: ComboSlotView
    var body: some View {
        Text(slot.label)
            .font(.caption.weight(slot.kind == .resolved ? .bold : .regular))
            .padding(.horizontal, 8).padding(.vertical, 2)
            .foregroundStyle(slot.kind == .ambiguous ? Theme.orange : Theme.text)
            .opacity(slot.kind == .unknown ? 0.55 : 1)
            .overlay(Capsule().stroke((slot.kind == .ambiguous ? Theme.orange : Theme.border).opacity(0.8)))
            .help(slot.help)
    }
}

/// The 16 classes as toggles, capped at a loadout's three slots. The chips say the WHOLE class
/// name; the value is still the `/who` code, which is what the store keeps and the engine
/// re-validates. Selection ORDER is preserved — the model has no primary/secondary ranking, so
/// nothing here sorts and nothing pretends the first pick means more.
struct ClassPickerView: View {
    @Binding var picked: [String]

    /// Add or remove a class, refusing a fourth pick. The one place the cap is implemented.
    static func toggle(_ picked: [String], _ c: String) -> [String] {
        if picked.contains(c) { return picked.filter { $0 != c } }
        return picked.count < maxComboSlots ? picked + [c] : picked
    }

    var body: some View {
        let full = picked.count >= maxComboSlots
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 4),
                         alignment: .leading, spacing: 6) {
            ForEach(classAbbrs, id: \.self) { abbr in
                let on = picked.contains(abbr)
                Button { picked = Self.toggle(picked, abbr) } label: {
                    Text(classDisplayName(abbr))
                        .font(.caption.weight(on ? .bold : .regular))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .foregroundStyle(on ? Theme.background : Theme.text)
                        .background(RoundedRectangle(cornerRadius: 6).fill(on ? Theme.gold : Color.clear))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(on ? Color.clear : Theme.border))
                }
                .buttonStyle(.plain)
                .disabled(!on && full)
                .opacity(!on && full ? 0.4 : 1)
            }
        }
    }
}

/// The editor sheet. It corrects a TIME RANGE, not an interval: setting a correction recomputes
/// every interval, so the id the row was keyed by may not exist a moment later — which is why the
/// save button says "applies to this time range".
struct ClassComboEditorSheet: View {
    let interval: ComboIntervalView
    /// nil endTs = the current-loadout override: "from the start of the span I am in, onward".
    let openEnded: Bool
    let onDone: () -> Void

    @Environment(AppModel.self) private var model
    @State private var picked: [String] = []
    @State private var seeded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(openEnded ? "Set your current classes" : "Set the loadout for this time range")
                .font(.title3.weight(.semibold)).foregroundStyle(Theme.text)
            if !openEnded { PrefCaption(ComboLabels.span(interval)) }
            ClassPickerView(picked: $picked)
            PrefCaption(picked.isEmpty
                ? "Pick 1 to 3 classes."
                : "\(picked.map(classDisplayName).joined(separator: " / ")) - \(picked.count) of \(maxComboSlots) slots.")
            if openEnded {
                PrefCaption("This applies from the start of your current loadout onward and stays until you change it or go back to autodetect.")
            }
            HStack(spacing: 10) {
                if interval.userLocked {
                    PrefButton(title: openEnded ? "Back to autodetect" : "Reset to detected") {
                        ComboCorrections.shared.clear(startTs: interval.startTs, endTs: openEnded ? nil : interval.endTs)
                        push()
                    }
                }
                Spacer()
                PrefButton(title: "Cancel", action: onDone)
                PrefButton(title: openEnded ? "Use these classes" : "Save - applies to this time range",
                           filled: true) {
                    guard !picked.isEmpty else { return }
                    ComboCorrections.shared.set(startTs: interval.startTs,
                                                endTs: openEnded ? nil : interval.endTs,
                                                classes: picked)
                    push()
                }
                .disabled(picked.isEmpty)
                .opacity(picked.isEmpty ? 0.4 : 1)
            }
        }
        .padding(20)
        .frame(width: 520)
        .background(Theme.background)
        .onAppear {
            // Seeded from what we currently believe, so "the middle slot is wrong" is two clicks.
            if !seeded { picked = interval.resolvedClasses; seeded = true }
        }
    }

    private func push() {
        Task {
            await model.pushComboCorrections()
            onDone()
        }
    }
}
