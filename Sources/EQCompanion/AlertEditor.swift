// The alert dialog: name, trigger (one condition or an any/all list), what it does out loud, and
// the banner. Ported from src/renderer/src/features/alerts/AlertDialog.tsx + ConditionEditor.tsx.
import SwiftUI
import EQCompanionCore

struct AlertEditor: View {
    @Environment(AppModel.self) private var model
    @State var def: AlertDef
    var onSave: (AlertDef) -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    alertSection
                    triggerSection
                    audioSection
                    bannerSection
                }.padding(14)
            }
            Divider().overlay(Theme.border)
            HStack {
                Button("Test") { model.player.preview(def: def) }.buttonStyle(OutlineButtonStyle())
                Text(def.trigger.badge).font(.caption.monospaced()).foregroundStyle(Theme.textFaint).lineLimit(1)
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save") { onSave(def) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(def.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }.padding(12)
        }
        .frame(width: 600, height: 680)
        .background(Theme.background)
    }

    private var alertSection: some View {
        Card("ALERT") {
            TextField("Name", text: $def.name).textFieldStyle(.roundedBorder)
            Toggle("Enabled", isOn: $def.enabled)
            TextField("Note (why this exists)", text: $def.note).textFieldStyle(.roundedBorder)
        }
    }

    private var triggerSection: some View {
        Card("TRIGGER") {
            Picker("Combine", selection: $def.trigger.combine) {
                ForEach(AlertTriggerSpec.Combine.allCases) { Text($0.label).tag($0) }
            }
            if def.trigger.combine == .all {
                Text("`all` is SAME-EVENT correlation only: every condition must match the one incoming event. Cross-event windows are out of scope.")
                    .font(.caption).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(def.trigger.conditions.enumerated()), id: \.element.id) { i, _ in
                conditionEditor(i)
            }
            if def.trigger.combine != .single {
                Button("Add a condition") { def.trigger.conditions.append(AlertCondition()) }
                    .buttonStyle(OutlineButtonStyle())
            }
            Stepper("Cooldown: \(Format.clock(ms: Int64(def.cooldownMs)))",
                    value: $def.cooldownMs, in: 0...600_000, step: 1000)
            Toggle("Always play (never folded into a burst with other alerts)", isOn: $def.alwaysPlay)
        }
    }

    @ViewBuilder
    private func conditionEditor(_ i: Int) -> some View {
        let c = $def.trigger.conditions[i]
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("Type", selection: c.kind) {
                    ForEach(AlertCondition.Kind.allCases) { Text($0.label).tag($0) }
                }
                if def.trigger.conditions.count > 1 {
                    Button {
                        def.trigger.conditions.remove(at: i)
                    } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                }
            }
            switch def.trigger.conditions[i].kind {
            case .raw:
                TextField("Regex (case-insensitive, against the log line)", text: c.regex)
                    .textFieldStyle(.roundedBorder).font(.caption.monospaced())
                Text("Named groups become speakable tokens: `(?<player>\\w+) has been slain` → “{player}”.")
                    .font(.caption).foregroundStyle(Theme.textDim)
            case .app:
                Picker("Signal", selection: c.signal) {
                    ForEach(alertAppSignals, id: \.self) { Text($0).tag($0) }
                }
                Text("App signals are fired by the app, not the engine. This app has no producer for them yet, so a def with one is stored and shared but never fires here.")
                    .font(.caption).foregroundStyle(Theme.orange).fixedSize(horizontal: false, vertical: true)
            case .event:
                Picker("Event kind", selection: c.eventKind) {
                    ForEach(alertEventKinds, id: \.self) { Text($0).tag($0) }
                }
                ForEach(Array(def.trigger.conditions[i].wheres.enumerated()), id: \.element.id) { j, _ in
                    HStack {
                        TextField("Field (spell, target, …)", text: c.wheres[j].field).textFieldStyle(.roundedBorder)
                        TextField("Value or /regex/", text: c.wheres[j].value).textFieldStyle(.roundedBorder)
                        Button {
                            def.trigger.conditions[i].wheres.remove(at: j)
                        } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                    }
                }
                Button("Add a field matcher") { def.trigger.conditions[i].wheres.append(AlertWhere()) }
                    .buttonStyle(OutlineButtonStyle())
                Text("`target` = `self` matches only your own side; omit it to match anyone. A `spell` value matches every rank, and every spell whose family prints the same sentence.")
                    .font(.caption).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.paperRaised))
    }

    private var audioSection: some View {
        Card("WHAT IT DOES") {
            Picker("Output", selection: $def.audio) {
                Text("A pack sound").tag("sound")
                Text("Spoken").tag("speech")
                if def.audio == "both" { Text("Sound + spoken (retired)").tag("both") }
            }
            if def.audio != "speech" {
                SoundChoice(packId: $def.packId, soundId: $def.soundId)
            }
            if def.audio != "sound" {
                Picker("Say", selection: $def.speechMode) {
                    Text("The alert's name").tag("alertName")
                    Text("The spell's name").tag("spellName")
                    Text("The spell's first word").tag("spellFirstWord")
                    Text("A custom phrase").tag("custom")
                }
                if def.speechMode == "custom" {
                    TextField("Phrase — {target}, {spell} and named groups fill in", text: $def.phrase)
                        .textFieldStyle(.roundedBorder)
                }
            }
            HStack {
                Text("Volume").font(.caption).foregroundStyle(Theme.textDim)
                Slider(value: $def.volume, in: 0...1)
                Text("\(Int(def.volume * 100))%").font(.caption.monospacedDigit()).foregroundStyle(Theme.textDim)
            }
        }
    }

    private var bannerSection: some View {
        Card("ON SCREEN") {
            Toggle("Show a banner on the overlay", isOn: $def.showOnScreen)
            if def.showOnScreen {
                TextField("Banner text (blank = the alert's name)", text: $def.bannerText)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }
}

/// The pack + sound pair, shared by the editor and every alert row.
struct SoundChoice: View {
    @Environment(AppModel.self) private var model
    @Binding var packId: String
    @Binding var soundId: String
    var compact = false

    private var packs: [SoundPackInfo] { model.player.packInfos() }

    var body: some View {
        Group {
            Picker(compact ? "" : "Pack", selection: $packId) {
                if !packs.contains(where: { $0.id == packId }) && packId != "system" {
                    Text("\(packId) (not installed)").tag(packId)
                }
                ForEach(packs) { Text($0.name).tag($0.id) }
                Text("System sounds").tag("system")
            }
            .onChange(of: packId) { _, new in
                // A pack change must land on a line that EXISTS in the new pack, or the alert
                // goes quietly mute the next time it fires.
                let ids = new == "system" ? AlertPlayer.systemSounds : (packs.first { $0.id == new }?.sounds.map(\.id) ?? [])
                if !ids.contains(soundId), let first = ids.first { soundId = first }
            }
            Picker(compact ? "" : "Sound", selection: $soundId) {
                if packId == "system" {
                    ForEach(AlertPlayer.systemSounds, id: \.self) { Text($0).tag($0) }
                } else if let p = packs.first(where: { $0.id == packId }) {
                    ForEach(p.sounds) { Text($0.label).tag($0.id) }
                    if !p.sounds.contains(where: { $0.id == soundId }) {
                        Text("\(soundId) (missing)").tag(soundId)
                    }
                } else {
                    Text(soundId).tag(soundId)
                }
            }
        }
        .labelsHidden(compact)
    }
}

private extension View {
    @ViewBuilder func labelsHidden(_ on: Bool) -> some View {
        if on { self.labelsHidden() } else { self }
    }
}
