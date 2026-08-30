// Suggested alerts — the one-click templates, ported from
// src/renderer/src/features/alerts/suggestions.ts, and the catalog sheet that offers them.
//
// ID CONVENTION: `suggest:<spellKey>:<template>`, spellKey = the rank-stripped, lowercased spell
// name. It is a single source of truth: the sheet builds defs with it AND detects the ones already
// created (checked, disabled), so clicking the same chip twice can never author a second alert
// firing on the same lines.
//
// WHAT THIS PORT DOES NOT HAVE. Electron gates each chip on the SPELL CATALOG — the wiki's own
// message table says whether a spell has a wear-off sentence, a cast-on-other sentence, whether it
// is a mez or a charm — so an enchanter is only ever offered chips that can fire. This app has no
// catalog for the spells the character has cast, only the `spellLastCast` map the alerts module
// keeps, so every rank-less template is offered for every spell and the sheet says so. A chip on a
// spell whose family never prints that sentence authors an alert that simply never fires; it is
// visible in the list and one click to delete.
import SwiftUI
import EQCompanionCore

/// The rank-less templates, in the order Electron offers them.
enum SuggestTemplate: String, CaseIterable, Identifiable {
    case wearsOff, fade, lands, breaks, charmBreaks
    var id: String { rawValue }

    /// The chip's own words, verbatim from SUGGEST_TEMPLATES.
    var chip: String {
        switch self {
        case .wearsOff: return "When it wears off (you or your pet)"
        case .fade: return "When it fades on pet/target only"
        case .lands: return "When it lands on a target"
        case .breaks: return "When the mez/root breaks"
        case .charmBreaks: return "When the charm breaks"
        }
    }

    /// A short label for the chip row.
    var short: String {
        switch self {
        case .wearsOff: return "wears off"
        case .fade: return "fades"
        case .lands: return "lands"
        case .breaks: return "breaks"
        case .charmBreaks: return "charm breaks"
        }
    }

    /// What the authored alert is NAMED after the spell.
    var verb: String {
        switch self {
        case .wearsOff: return "wears off"
        case .fade: return "fades"
        case .lands: return "lands"
        case .breaks: return "broke"
        case .charmBreaks: return "charm broke"
        }
    }

    /// The Alan Rickman line it draws.
    var sound: String {
        switch self {
        case .wearsOff: return DefaultAlertSounds.buffWearsOff
        case .fade: return DefaultAlertSounds.buffFade
        case .lands: return DefaultAlertSounds.debuffLands
        case .breaks: return DefaultAlertSounds.illusionFade
        case .charmBreaks: return DefaultAlertSounds.charmBreak
        }
    }

    /// The spoken phrase it ships. `{target}` needs no pattern — the app fills it from the
    /// matched event's own entity field.
    func speaks(_ short: String) -> String {
        switch self {
        case .wearsOff: return "\(short) wore off {target}"
        case .fade: return "\(short) faded on {target}"
        case .lands: return "\(short) on {target}"
        case .breaks: return "\(short) broke on {target}"
        case .charmBreaks: return "\(short) charm broke on {target}"
        }
    }

    func trigger(spell: String) -> AlertTriggerSpec {
        switch self {
        case .wearsOff:
            // ONE CHIP, BOTH SIDES. The derived `buffExpired` covers only buffs YOU cast (the buffs
            // module's own-cast gate); the raw `buffWearOff` is the emote EQ prints to the holder,
            // whoever cast it. An `any` composite covers both and they cannot double-fire — the
            // derived event carries the primary's timestamp, so the cooldown swallows the second.
            return AlertTriggerSpec(combine: .any, conditions: [
                AlertCondition(kind: .event, eventKind: "buffExpired", wheres: [AlertWhere(field: "spell", value: spell)]),
                AlertCondition(kind: .event, eventKind: "buffWearOff", wheres: [AlertWhere(field: "spell", value: spell)])
            ])
        case .fade:
            return AlertTriggerSpec(eventKind: "buffFade", where: [AlertWhere(field: "spell", value: spell)])
        case .lands:
            return AlertTriggerSpec(eventKind: "buffApply", where: [AlertWhere(field: "spell", value: spell)])
        case .breaks:
            // `refresh:'true'` is what separates the BREAK from the landing: the same `cc` kind
            // carries both, and only the break shape names a spell.
            return AlertTriggerSpec(eventKind: "cc", where: [AlertWhere(field: "spell", value: spell),
                                                             AlertWhere(field: "refresh", value: "true")])
        case .charmBreaks:
            // `uncharm` carries `mob` and `spell` and nothing else, so pinning the name is the
            // whole trigger — and a charm break never carries `refresh`, which is why it is not
            // the same template as `breaks`.
            return AlertTriggerSpec(eventKind: "uncharm", where: [AlertWhere(field: "spell", value: spell)])
        }
    }
}

/// A concrete suggestion: the template it came from plus the exact def it authors.
struct AlertSuggestion: Identifiable, Equatable {
    var template: String
    var def: AlertDef
    var id: String { def.id }
}

enum Suggest {
    /// `spellLineKey`: trim, drop a roman-numeral rank tail, lowercase.
    static func spellKey(_ name: String) -> String {
        stripRank(name).trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// The rank tail EQ and the DB actually use: a trailing space + I…X.
    static func stripRank(_ name: String) -> String {
        let t = name.trimmingCharacters(in: .whitespaces)
        let ranks = ["I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X"]
        let parts = t.split(separator: " ")
        if parts.count > 1, let last = parts.last, ranks.contains(String(last).uppercased()) {
            return parts.dropLast().joined(separator: " ")
        }
        return t
    }

    /// Function words a spell name hides its distinctive noun behind.
    private static let functionWords: Set<String> = ["of", "the", "de", "in", "a", "an"]

    /// `spellShortName`: "Spirit of the Puma" → "Puma", "Clarity" → "Clarity". Take the words after
    /// the LAST function word, else the first word. Authoring only — it renames nothing.
    static func shortName(_ name: String) -> String {
        let words = stripRank(name).split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !words.isEmpty else { return name.trimmingCharacters(in: .whitespaces) }
        var last = -1
        for (i, w) in words.enumerated() where functionWords.contains(w.lowercased()) { last = i }
        if last >= 0 && last < words.count - 1 { return words[(last + 1)...].joined(separator: " ") }
        return words[0]
    }

    static func id(spell: String, template: SuggestTemplate) -> String {
        "suggest:\(spellKey(spell)):\(template.rawValue)"
    }

    /// Build the def for one (spell, template) pair, pointed at `packId`.
    static func def(spell: String, template: SuggestTemplate, packId: String) -> AlertDef {
        var d = AlertDef.fresh()
        d.id = id(spell: spell, template: template)
        d.name = "\(spell) \(template.verb)"
        d.trigger = template.trigger(spell: spell)
        d.packId = packId
        d.soundId = template.sound
        d.cooldownMs = 3000
        d.note = "Suggested alert - \(template.rawValue) for \(spell)."
        // Every template here says who; the phrase is the template's own and is editable.
        d.audio = "speech"
        d.speechMode = "custom"
        d.phrase = template.speaks(shortName(spell))
        return d
    }

    static func suggestions(spell: String, packId: String) -> [AlertSuggestion] {
        SuggestTemplate.allCases.map {
            AlertSuggestion(template: $0.rawValue, def: def(spell: spell, template: $0, packId: packId))
        }
    }

    /// The single, shared illusion-fade suggestion — one alert for any illusion, because the line
    /// `Your illusion fades.` names no spell.
    static func illusion(packId: String) -> AlertSuggestion {
        var d = AlertDef.fresh()
        d.id = "suggest:illusion:fade"
        d.name = "Illusion fades"
        d.trigger = AlertTriggerSpec(eventKind: "illusionFade")
        d.packId = packId
        d.soundId = DefaultAlertSounds.illusionFade
        d.cooldownMs = 3000
        d.audio = "sound"
        d.note = "Suggested alert - fires when your illusion clicks/wears off."
        return AlertSuggestion(template: "illusion", def: d)
    }
}

// MARK: - The catalog sheet

/// One spell the character has cast, with the chips it offers.
private struct SuggestRow: Identifiable {
    var spell: String
    var lastCast: Int64
    var id: String { spell }
}

struct AlertSuggestionsSheet: View {
    @Environment(AppModel.self) private var model
    var onDone: () -> Void
    var onCreateManually: () -> Void

    @State private var snap = ModuleSnapshot()
    @State private var query = ""
    @State private var picked: Set<String> = []
    @State private var pending: [String: AlertDef] = [:]
    @State private var expanded: Set<String> = []

    private var packId: String {
        model.player.packInfos().contains { $0.id == defaultAlertPackId } ? defaultAlertPackId
            : (model.player.packInfos().first?.id ?? "system")
    }

    /// One row per spell LINE, not per rank: the templates are rank-less by construction (the
    /// engine folds a literal `spell` matcher to the line key on both sides), so `Drain Spirit`,
    /// `Drain Spirit II` and `Drain Spirit III` are one suggestion, named after the base and dated
    /// by the most recent cast of any rank — the same one-per-line set the Windows wizard offers.
    private var rows: [SuggestRow] {
        let map = snap.state["spellLastCast"].object ?? [:]
        var byLine: [String: SuggestRow] = [:]
        for (name, ts) in map {
            let key = Suggest.spellKey(name)
            let at = ts.int64 ?? 0
            if let have = byLine[key], have.lastCast >= at { continue }
            byLine[key] = SuggestRow(spell: Suggest.stripRank(name), lastCast: at)
        }
        var out = Array(byLine.values)
        out.sort { $0.lastCast == $1.lastCast ? $0.spell < $1.spell : $0.lastCast > $1.lastCast }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty { out = out.filter { $0.spell.lowercased().contains(q) } }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.border)
            if snap.loading {
                ProgressView().padding(30).frame(maxWidth: .infinity)
            } else if rows.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        illusionRow
                        ForEach(rows) { r in spellCard(r) }
                    }
                    .padding(12)
                }
            }
            Divider().overlay(Theme.border)
            footer
        }
        .frame(width: 720, height: 620)
        .background(Theme.background)
        .task(id: model.epoch) { await snap.refresh(model, module: "alerts") }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Add from suggestion").font(.headline).foregroundStyle(Theme.text)
            Text("One click per chip. Every spell this character has cast is here, most recent first — the Windows app narrows the chips by each spell's own message table and this app has no such catalog, so all five are offered and a chip whose sentence the spell never prints simply never fires.")
                .font(.caption).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
            TextField("Search spells", text: $query).textFieldStyle(.roundedBorder)
        }
        .padding(12)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(snap.error ?? "No spells recorded yet.").foregroundStyle(Theme.text)
            Text("The alerts module remembers a spell the first time you cast it with the log attached. Cast something, or write an alert by hand.")
                .font(.caption).foregroundStyle(Theme.textDim)
        }
        .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var illusionRow: some View {
        let s = Suggest.illusion(packId: packId)
        return chipCard(title: "Any illusion", subtitle: "one alert for every illusion — the line names no spell",
                        chips: [(s.def.id, "When your illusion fades", s.def)])
    }

    private func spellCard(_ r: SuggestRow) -> some View {
        let subtitle = r.lastCast > 0 ? "last cast \(Format.ago(ms: r.lastCast, now: nowMs()))" : ""
        let chips = Suggest.suggestions(spell: r.spell, packId: packId).map {
            ($0.def.id, SuggestTemplate(rawValue: $0.template)?.chip ?? $0.template, $0.def)
        }
        return chipCard(title: r.spell, subtitle: subtitle, chips: chips)
    }

    private func chipCard(title: String, subtitle: String,
                          chips: [(String, String, AlertDef)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(title).fontWeight(.semibold).foregroundStyle(Theme.text)
                if !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(Theme.textFaint) }
                Spacer()
            }
            FlowChips(items: chips.map { ($0.0, $0.1) },
                      state: { id in
                          model.alerts.has(id: id) ? .already : (picked.contains(id) ? .picked : .off)
                      },
                      toggle: { id in
                          guard !model.alerts.has(id: id) else { return }
                          if picked.contains(id) {
                              picked.remove(id)
                              pending[id] = nil
                          } else {
                              picked.insert(id)
                              pending[id] = chips.first { $0.0 == id }?.2
                          }
                      })
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.paper))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
    }

    private var footer: some View {
        HStack {
            Button("Create manually…") { onCreateManually() }.buttonStyle(OutlineButtonStyle())
            Spacer()
            Text(picked.isEmpty ? "Nothing selected" : "\(picked.count) selected")
                .font(.caption).foregroundStyle(Theme.textDim)
            Button("Cancel") { onDone() }
            Button("Add \(picked.count) alert\(picked.count == 1 ? "" : "s")") {
                model.alerts.addAll(picked.compactMap { pending[$0] })
                onDone()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(picked.isEmpty)
        }
        .padding(12)
    }
}

/// A wrapping row of selectable chips. Three states: off, picked now, already created.
struct FlowChips: View {
    enum ChipState { case off, picked, already }
    var items: [(String, String)]
    var state: (String) -> ChipState
    var toggle: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(items, id: \.0) { item in
                let s = state(item.0)
                Button { toggle(item.0) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: s == .off ? "plus.circle" : "checkmark.circle.fill")
                            .font(.caption2)
                        Text(item.1).font(.caption)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .foregroundStyle(s == .already ? Theme.textFaint : (s == .picked ? Theme.gold : Theme.textDim))
                    .background(Capsule().fill(s == .picked ? Theme.gold.opacity(0.14) : Color.clear))
                    .overlay(Capsule().stroke((s == .already ? Theme.textFaint : (s == .picked ? Theme.gold : Theme.textDim)).opacity(0.5)))
                }
                .buttonStyle(.plain)
                .disabled(s == .already)
                .help(s == .already ? "Already created" : item.1)
            }
        }
    }
}

/// A minimal wrapping HStack (SwiftUI has no built-in one before Layout on macOS 13).
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        // Never echo an unbounded proposal back as our width (see MapFlow): one line instead.
        let oneLine = sizes.reduce(CGFloat(0)) { $0 + $1.width } + spacing * CGFloat(max(0, sizes.count - 1))
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? oneLine
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for size in sizes {
            if x + size.width > width, x > 0 {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: width, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
