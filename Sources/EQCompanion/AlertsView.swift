// Alerts: the definitions the engine evaluates against live events, the three global switches, one
// card per alert, and the suggestion catalog. Ported from
// src/renderer/src/features/alerts/{AlertsView,AlertsToolbar,AlertList}.tsx.
//
// THE ENGINE EVALUATES `event:` AND `raw:` TRIGGERS, AND ONLY THOSE. `app:` signals (boss defeat,
// Sky quest complete) are fired by the RENDERER in the Electron app; nothing in this app produces
// them yet, so a def carrying one is stored, pushed, shared and exported — and never sounds. Each
// such row says so rather than looking armed.
import SwiftUI
import AppKit
import EQCompanionCore

struct AlertsView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var editing: AlertDef?
    @State private var showImport = false
    @State private var importText = ""
    @State private var lastImport: String?
    @State private var showPacks = false
    @State private var showMySounds = false
    @State private var showSuggest = false
    @State private var confirmReset = false
    @State private var toast: String?
    @State private var expanded: Set<String> = []
    @State private var dragVolume: [String: Double] = [:]

    private var filtering: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    private var shown: [AlertDef] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return model.alerts.defs }
        return model.alerts.defs.filter { haystack($0).contains(q) }
    }

    /// What the search box searches — the wide set its placeholder names.
    private func haystack(_ d: AlertDef) -> String {
        var s = [d.name, d.trigger.badge, d.packId, d.soundId, d.phrase, d.note]
        if let l = model.player.label(pack: d.packId, sound: d.soundId) { s.append(l) }
        return s.joined(separator: " ").lowercased()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                toolbar
                if shown.isEmpty {
                    Text(filtering ? "No alerts match that search."
                                   : "No alerts yet. Add one to play a sound when something happens in your log.")
                        .font(.callout).foregroundStyle(Theme.textDim).padding(.vertical, 12)
                }
                ForEach(shown) { d in alertCard(d) }
                Button { showSuggest = true } label: { Label("Add from suggestion…", systemImage: "plus") }
                    .buttonStyle(OutlineButtonStyle())
                    .padding(.top, 4)
                footnote
            }
            .padding(12)
        }
        .background(Theme.background)
        .sheet(item: $editing) { d in
            AlertEditor(def: d) { saved in
                model.alerts.upsert(saved)
                editing = nil
            } onCancel: { editing = nil }
                .environment(model)
        }
        .sheet(isPresented: $showPacks) {
            SoundPacksSheet { showPacks = false }.environment(model)
        }
        .sheet(isPresented: $showMySounds) {
            MySoundsSheet { showMySounds = false }.environment(model)
        }
        .sheet(isPresented: $showSuggest) {
            AlertSuggestionsSheet {
                showSuggest = false
            } onCreateManually: {
                showSuggest = false
                editing = AlertDef.fresh()
            }.environment(model)
        }
        .sheet(isPresented: $showImport) { importSheet }
        .alert("Reset alerts to defaults?", isPresented: $confirmReset) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                model.alerts.resetToDefaults()
                toast = "Alerts reset to the seeded set."
            }
        } message: {
            Text("This replaces all alerts, including any you added or edited, with the seeded built-in set (Charm break, Raid target defeated, Sky quest complete). This can't be undone.")
        }
        .overlay(alignment: .bottom) { toastView }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 14) {
                    HStack(spacing: 6) {
                        Image(systemName: model.player.prefs.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .foregroundStyle(model.player.prefs.muted ? Theme.textFaint : Theme.gold)
                        Text("Global volume").font(.caption).foregroundStyle(Theme.textDim)
                        Slider(value: Binding(get: { model.player.prefs.globalVolume },
                                              set: { model.player.prefs.globalVolume = $0 }), in: 0...1)
                            .frame(width: 130)
                        Text("\(Int(model.player.prefs.globalVolume * 100))%")
                            .font(.caption.monospacedDigit()).foregroundStyle(Theme.textDim).frame(width: 34)
                    }
                    Toggle("Mute all", isOn: Binding(get: { model.player.prefs.muted },
                                                     set: { model.player.prefs.muted = $0 }))
                        .toggleStyle(.switch)
                    Toggle("Always play all", isOn: Binding(get: { model.player.prefs.alwaysPlayAll },
                                                            set: { model.player.prefs.alwaysPlayAll = $0 }))
                        .toggleStyle(.switch)
                        .help("Off by default: when several alerts fire at once you hear the first one. Turn this on to hear every one of them, stacked.")
                    Spacer(minLength: 8)
                    TextField("Search name, spell, trigger, sound", text: $query)
                        .textFieldStyle(.roundedBorder).frame(minWidth: 200, maxWidth: 300)
                    Button("Sound packs…") { showPacks = true }.buttonStyle(OutlineButtonStyle())
                    Button("My sounds…") { showMySounds = true }.buttonStyle(OutlineButtonStyle())
                }
                HStack(spacing: 8) {
                    Button("Copy all") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.alerts.exportJSON(), forType: .string)
                        toast = "\(model.alerts.defs.count) alerts copied as JSON."
                    }
                    .buttonStyle(OutlineButtonStyle())
                    .disabled(model.alerts.defs.isEmpty)
                    Button("Import…") { showImport = true }.buttonStyle(OutlineButtonStyle())
                    Button("Reset to defaults") { confirmReset = true }.buttonStyle(OutlineButtonStyle())
                    Spacer()
                    Text("\(model.alerts.defs.filter(\.enabled).count) of \(model.alerts.defs.count) enabled")
                        .font(.caption).foregroundStyle(Theme.textDim)
                }
            }
        }
    }

    // MARK: - One alert

    @ViewBuilder
    private func alertCard(_ d: AlertDef) -> some View {
        let fires = model.fires.filter { $0.rule == d.name }
        let isOpen = expanded.contains(d.id)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Toggle("", isOn: Binding(get: { d.enabled }, set: { _ in model.alerts.toggle(d.id) }))
                    .labelsHidden().toggleStyle(.switch)

                VStack(alignment: .leading, spacing: 1) {
                    Text(d.name).fontWeight(.semibold).foregroundStyle(Theme.text)
                        .lineLimit(1).help(d.name)
                    HStack(spacing: 5) {
                        Text(d.trigger.badge).font(.caption.monospaced()).foregroundStyle(Theme.textDim)
                            .lineLimit(1).help(d.trigger.badge)
                        if d.trigger.hasAppSignal { Chip(text: "not fired here", color: Theme.orange) }
                    }
                }
                .frame(minWidth: 140, idealWidth: 230, maxWidth: .infinity, alignment: .leading)
                .opacity(d.enabled ? 1 : 0.55)

                audioPicker(d)

                HStack(spacing: 4) {
                    Text("vol").font(.caption).foregroundStyle(Theme.textDim)
                    // Drags locally, persists on release: every write here rewrites alerts.json AND
                    // re-pushes the whole set to the engine, which is not a thing to do per frame.
                    Slider(value: Binding(get: { dragVolume[d.id] ?? d.volume },
                                          set: { dragVolume[d.id] = $0 }),
                           in: 0...1) { editing in
                        guard !editing, let v = dragVolume[d.id] else { return }
                        var c = d
                        c.volume = v
                        model.alerts.upsert(c)
                        dragVolume[d.id] = nil
                    }.frame(width: 80)
                }

                actions(d, fires: fires.count, isOpen: isOpen)
            }
            if isOpen { recentFires(fires) }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.paper))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
    }

    /// The row's two audio dropdowns, ported from AudioPicker.tsx: OUTPUT (every installed pack,
    /// then "Voice (spoken)") and, contextually, the SOUND or the speak-what mode. There is no
    /// hidden state a row can be in without saying so.
    @ViewBuilder
    private func audioPicker(_ d: AlertDef) -> some View {
        let speaks = d.audio == "speech"
        let output = Binding<String>(get: { speaks ? Self.speechOutput : d.packId }, set: { v in
            var c = d
            if v == Self.speechOutput {
                c.audio = "speech"
            } else {
                c.audio = "sound"
                c.packId = v
                let ids = v == "system" ? AlertPlayer.systemSounds
                                        : (model.player.pack(v)?.sounds.map(\.id) ?? [])
                if !ids.contains(c.soundId), let first = ids.first { c.soundId = first }
            }
            model.alerts.upsert(c)
        })
        HStack(spacing: 6) {
            Picker("", selection: output) {
                ForEach(model.player.packInfos()) { Text($0.name).tag($0.id) }
                Text("System sounds").tag("system")
                if !speaks && d.packId != "system"
                    && !model.player.packInfos().contains(where: { $0.id == d.packId }) {
                    Text("\(d.packId) (not installed)").tag(d.packId)
                }
                Divider()
                Text("Voice (spoken)").tag(Self.speechOutput)
            }
            .labelsHidden().frame(width: 150)

            if speaks {
                Picker("", selection: Binding(get: { d.speechMode }, set: { v in
                    var c = d; c.speechMode = v; model.alerts.upsert(c)
                })) {
                    Text(d.phrase.isEmpty ? "Speak: custom\u{2026}" : "Speak: \u{201C}\(d.phrase)\u{201D}").tag("custom")
                    Text("Speak: alert name").tag("alertName")
                    Text("Speak: spell name").tag("spellName")
                    Text("Speak: first word").tag("spellFirstWord")
                }
                .labelsHidden().frame(width: 200)
                .help(d.speechMode == "custom" && !d.phrase.isEmpty
                      ? "Says \u{201C}\(d.phrase)\u{201D} \u{2014} edit it in the pencil dialog." : "What this alert says")
            } else {
                Picker("", selection: Binding(get: { d.soundId }, set: { v in
                    var c = d; c.soundId = v; model.alerts.upsert(c)
                })) {
                    if d.packId == "system" {
                        ForEach(AlertPlayer.systemSounds, id: \.self) { Text($0).tag($0) }
                    } else if let p = model.player.pack(d.packId) {
                        ForEach(p.sounds) { Text($0.label).tag($0.id) }
                        if !p.sounds.contains(where: { $0.id == d.soundId }) {
                            Text("\(d.soundId) (missing)").tag(d.soundId)
                        }
                    } else {
                        Text("\(d.soundId) (pack not installed)").tag(d.soundId)
                    }
                }
                .labelsHidden().frame(width: 200)
                .help(model.player.label(pack: d.packId, sound: d.soundId) ?? d.soundId)
            }
        }
    }

    /// The sentinel the output picker uses for "this row speaks" — never a pack id.
    private static let speechOutput = "__speech"

    private func actions(_ d: AlertDef, fires: Int, isOpen: Bool) -> some View {
        HStack(spacing: 6) {
            Button {
                if isOpen { expanded.remove(d.id) } else { expanded.insert(d.id) }
            } label: { Image(systemName: "clock.arrow.circlepath") }
                .buttonStyle(.plain).foregroundStyle(isOpen ? Theme.gold : Theme.textDim)
                .help("Recent fires (\(fires))")
            Button { model.player.preview(def: d) } label: { Image(systemName: "play.fill") }
                .buttonStyle(.plain).foregroundStyle(Theme.textDim).help("Test (play now)")
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(model.alerts.exportJSON(d), forType: .string)
                toast = "“\(d.name)” copied as JSON."
            } label: { Image(systemName: "square.and.arrow.up") }
                .buttonStyle(.plain).foregroundStyle(Theme.textDim).help("Copy this alert as JSON")
            Button { editing = d } label: { Image(systemName: "pencil") }
                .buttonStyle(.plain).foregroundStyle(Theme.textDim).help("Edit")
            Button { model.alerts.remove(d.id) } label: { Image(systemName: "trash") }
                .buttonStyle(.plain).foregroundStyle(Theme.red).help("Delete")
        }
    }

    @ViewBuilder
    private func recentFires(_ fires: [FireMessage]) -> some View {
        Divider().overlay(Theme.border)
        if fires.isEmpty {
            Text("No fires recorded yet.").font(.caption).foregroundStyle(Theme.textFaint).padding(.leading, 6)
        } else {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(fires.prefix(20)) { f in
                    HStack(alignment: .top, spacing: 8) {
                        Text(Format.time(ms: f.at)).font(.caption2.monospaced()).foregroundStyle(Theme.textFaint)
                        Text(f.message.isEmpty ? "(no matched text)" : f.message)
                            .font(.caption2.monospaced()).foregroundStyle(Theme.textDim)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }.padding(.leading, 6)
        }
    }

    private var footnote: some View {
        Text("The engine evaluates alerts against LIVE lines only — a replay never makes a sound. Cooldowns are per alert. `app:` triggers are stored but nothing in this app fires them yet.")
            .font(.caption).foregroundStyle(Theme.textFaint)
            .fixedSize(horizontal: false, vertical: true).padding(.top, 6)
    }

    // MARK: - Import

    private var importSheet: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Paste alert JSON (an array, or {\"defs\": [...]}). Imports only ever add.")
                .font(.callout).foregroundStyle(Theme.text)
            TextEditor(text: $importText).font(.caption.monospaced()).frame(width: 520, height: 260)
            if let l = lastImport { Text(l).font(.caption).foregroundStyle(Theme.textDim) }
            HStack {
                Spacer()
                Button("Cancel") { showImport = false }
                Button("Import") {
                    let n = model.alerts.importJSON(importText)
                    lastImport = n > 0 ? "Added \(n) alert(s)." : "Nothing readable in that text."
                    if n > 0 { importText = "" }
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .background(Theme.background)
    }

    @ViewBuilder
    private var toastView: some View {
        if let t = toast {
            Text(t)
                .font(.caption).foregroundStyle(Theme.text)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Capsule().fill(Theme.paperRaised))
                .overlay(Capsule().stroke(Theme.border))
                .padding(.bottom, 14)
                .task(id: t) {
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    toast = nil
                }
        }
    }
}
