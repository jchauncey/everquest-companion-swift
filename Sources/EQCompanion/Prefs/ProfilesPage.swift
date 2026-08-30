// Preferences → Profiles — export your settings, import someone else's, and the class-loadout
// history with its correction surface. Ported from the Electron app's ProfileSharing.tsx,
// ShareImportDialog.tsx and ClassComboPanel.tsx / LoadoutOverride.tsx.
//
// A settings bundle is GLOBAL by construction: it carries alerts, alert prefs, the overlay look
// and a short whitelist of view preferences. It carries no file paths, no window positions and no
// character progress — those are machine and character state, and the exporter never reads them.
// The whitelist and the wire format live in PrefsShare.swift, which is the format the Windows app
// writes too, so a string copied there pastes here.
import SwiftUI
import AppKit
import EQCompanionCore

extension PrefPages {
    static let profiles = PrefPage(id: "profiles", label: "Profiles", icon: "square.and.arrow.up", sections: [
        PrefSectionInfo(id: "export-settings", label: "Export your settings",
                        keywords: "share export copy backup string bundle profile send give clipboard file"),
        PrefSectionInfo(id: "import-settings", label: "Import settings",
                        keywords: "share import paste restore string bundle profile receive add merge file"),
        PrefSectionInfo(id: "class-combo", label: "Your classes (loadout)",
                        keywords: "class combo loadout classes swap paladin rogue berserker who correction slot override manual set fix wrong incorrect change detect autodetect history")
    ]) { AnyView(ProfilesPage()) }
}

struct ProfilesPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ExportSettingsCard()
            ImportSettingsCard()
            ClassLoadoutCard()
        }
    }
}

// MARK: - Export

/// What a bundle leaves behind, stated as fact so the user knows what they are NOT handing over.
private let bundleExcludes = ["EverQuest folder", "window positions", "character progress", "sound pack files"]

struct ExportSettingsCard: View {
    @Environment(AppModel.self) private var model
    @State private var toast: (ok: Bool, text: String)?

    var body: some View {
        PrefCard("Export your settings") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Chip(text: "\(model.alerts.defs.count) alerts", color: Theme.green)
                    Chip(text: "alert volume + mute", color: Theme.green)
                    Chip(text: "overlay look", color: Theme.green)
                    Chip(text: "view preferences", color: Theme.green)
                    Chip(text: "favorites", color: Theme.green)
                }
                PrefCaption("Not included: \(bundleExcludes.joined(separator: " · ")).")
                HStack(spacing: 10) {
                    PrefButton(title: "Copy share string", icon: "doc.on.doc", filled: true, action: copy)
                    PrefButton(title: "Save to file…", icon: "square.and.arrow.down", action: save)
                }
                if let t = toast { PrefStatus(tone: t.ok ? .ok : .warn, text: t.text) }
            }
        }
    }

    /// The whole bundle, built from what this app actually stores.
    private func shareString() -> String {
        let body = SettingsBundle.body(alerts: model.alerts.definitions(),
                                       globalVolume: model.player.prefs.globalVolume,
                                       muted: model.player.prefs.muted,
                                       alwaysPlayAll: model.player.prefs.alwaysPlayAll,
                                       overlayShared: Double(Prefs.shared.overlayTransparency) / 100,
                                       overlayIndependent: Prefs.shared.overlayIndependent,
                                       overlays: Prefs.shared.overlayTransparencies.mapValues { Double($0) / 100 },
                                       ui: SettingsBundle.readUiPrefs())
        return ShareCodec.encode(ShareCodec.envelope(kind: .settings, body: body,
                                                     appVersion: AppVersion.current))
    }

    private func copy() {
        let text = shareString()
        let pb = NSPasteboard.general
        pb.clearContents()
        toast = pb.setString(text, forType: .string)
            ? (true, "Copied - \(text.count) characters. Paste it anywhere.")
            : (false, "Could not reach the clipboard. Save to a file instead.")
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "eq-companion-settings.eqshare"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(shareString().utf8).write(to: url, options: .atomic)
            toast = (true, "Saved to \(url.path)")
        } catch {
            toast = (false, "Could not write that file: \(error.localizedDescription)")
        }
    }
}

// MARK: - Import

struct ImportSettingsCard: View {
    @Environment(AppModel.self) private var model
    @State private var open = false
    @State private var result: ShareApplyResult?

    var body: some View {
        PrefCard("Import settings") {
            VStack(alignment: .leading, spacing: 10) {
                PrefCaption("Imports only ever ADD. Anything you already have is left exactly as it is.")
                PrefButton(title: "Import settings…", icon: "square.and.arrow.up", filled: true) { open = true }
                if let r = result { PrefStatus(tone: .ok, text: r.summary) }
            }
        }
        .sheet(isPresented: $open) {
            ShareImportSheet(onApplied: { result = $0; open = false }, onCancel: { open = false })
                .environment(model)
        }
    }
}

/// The import dialog: paste (or open a file), see what it would do, tick what you want.
///
/// ALERTS START TICKED — an import is additive and an alert you do not have is the thing you came
/// for. SCALAR REPLACEMENTS START UNTICKED, because each one overwrites a value of yours; the
/// unions (favorites, the class filter) start ticked, because they can only add.
struct ShareImportSheet: View {
    let onApplied: (ShareApplyResult) -> Void
    let onCancel: () -> Void

    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var preview: SharePreview?
    @State private var error: String?
    @State private var alertSel: Set<String> = []
    @State private var scalarSel: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import settings").font(.title3.weight(.semibold)).foregroundStyle(Theme.text)

            TextEditor(text: $text)
                .font(.caption.monospaced())
                .frame(height: 62)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).stroke(Theme.border))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Paste a share string (EQC1-…) here")
                            .font(.caption.monospaced()).foregroundStyle(Theme.textFaint)
                            .padding(10).allowsHitTesting(false)
                    }
                }

            HStack(spacing: 10) {
                PrefButton(title: "Preview", icon: "doc.on.clipboard", filled: true) { runPreview(text) }
                PrefButton(title: "Open file…", icon: "folder", action: openFile)
                Spacer()
                if let p = preview { PrefCaption(meta(p)) }
            }

            if let e = error { PrefStatus(tone: .warn, text: e) }

            if let p = preview {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if !p.alerts.isEmpty { alertsSection(p) }
                        if !p.scalars.isEmpty { scalarsSection(p) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 300)
            }

            HStack {
                Spacer()
                PrefButton(title: "Cancel", action: onCancel)
                PrefButton(title: applyLabel, filled: true, action: apply)
                    .disabled(!canApply)
                    .opacity(canApply ? 1 : 0.4)
            }
        }
        .padding(20)
        .frame(width: 620)
        .background(Theme.background)
    }

    // MARK: sections

    private func alertsSection(_ p: SharePreview) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("ALERTS - \(p.importable) to add\(p.alreadyHave > 0 ? ", \(p.alreadyHave) you already have" : "")")
                .font(.caption.weight(.semibold)).kerning(0.8).foregroundStyle(Theme.textDim)
            ForEach(p.alerts) { item in
                HStack(alignment: .top, spacing: 8) {
                    Toggle("", isOn: Binding(get: { alertSel.contains(item.finalId) },
                                             set: { on in
                                                 if on { alertSel.insert(item.finalId) } else { alertSel.remove(item.finalId) }
                                             }))
                        .labelsHidden().toggleStyle(.checkbox)
                        .disabled(item.action == .skip)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(item.name).font(.caption.weight(.semibold)).foregroundStyle(Theme.text)
                            Chip(text: item.action.label,
                                 color: item.action == .add ? Theme.green : item.action == .rekey ? Theme.blue : Theme.textDim)
                        }
                        Text(item.badge).font(.caption2.monospaced()).foregroundStyle(Theme.textDim)
                    }
                    Spacer()
                }
                .opacity(item.action == .skip ? 0.55 : 1)
            }
        }
    }

    private func scalarsSection(_ p: SharePreview) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider().overlay(Theme.border)
            Text("SETTINGS - THESE REPLACE YOUR VALUE, SO THEY'RE OPT-IN")
                .font(.caption.weight(.semibold)).kerning(0.8).foregroundStyle(Theme.textDim)
            ForEach(p.scalars) { s in
                HStack(alignment: .top, spacing: 8) {
                    Toggle("", isOn: Binding(get: { scalarSel.contains(s.id) },
                                             set: { on in
                                                 if on { scalarSel.insert(s.id) } else { scalarSel.remove(s.id) }
                                             }))
                        .labelsHidden().toggleStyle(.checkbox)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(s.label).font(.caption).foregroundStyle(Theme.text)
                            if s.merge == .union { Chip(text: "adds only", color: Theme.green) }
                        }
                        Text("\(s.current.isEmpty ? "-" : s.current) → \(s.incoming)")
                            .font(.caption2.monospaced()).foregroundStyle(Theme.textDim)
                            .lineLimit(2)
                    }
                    Spacer()
                }
            }
        }
    }

    private func meta(_ p: SharePreview) -> String {
        var s = p.kind == .alerts ? "Alert set" : "Settings bundle"
        if !p.appVersion.isEmpty { s += " · made with v\(p.appVersion)" }
        if !p.createdAt.isEmpty, let d = shareDate(p.createdAt) {
            s += " · \(ComboLabels.dateTime(Int64(d.timeIntervalSince1970 * 1000)))"
        }
        return s
    }

    /// The envelope's `at`, which carries fractional seconds when this app wrote it and may not
    /// when another one did.
    private func shareDate(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    /// The apply button's label — "Add 3 alerts + 2 settings", omitting either empty half.
    private var applyLabel: String {
        let a = alertSel.count
        let s = scalarSel.count
        let at = a > 0 ? "\(a) alert\(a == 1 ? "" : "s")" : ""
        let st = s > 0 ? "\(s) setting\(s == 1 ? "" : "s")" : ""
        return "Add \(at)\(at.isEmpty || st.isEmpty ? "" : " + ")\(st)"
    }

    private var canApply: Bool { preview != nil && (!alertSel.isEmpty || !scalarSel.isEmpty) }

    // MARK: actions

    private func context() -> ShareContext {
        ShareContext(alerts: model.alerts.defs,
                     globalVolume: model.player.prefs.globalVolume,
                     muted: model.player.prefs.muted,
                     alwaysPlayAll: model.player.prefs.alwaysPlayAll,
                     overlayShared: Double(Prefs.shared.overlayTransparency) / 100,
                     overlayIndependent: Prefs.shared.overlayIndependent,
                     overlays: Prefs.shared.overlayTransparencies.mapValues { Double($0) / 100 },
                     ui: SettingsBundle.readUiPrefs())
    }

    private func runPreview(_ input: String) {
        switch ShareMerge.preview(input, context()) {
        case .failure(let e):
            preview = nil
            error = e.text
        case .success(let p):
            preview = p
            error = nil
            alertSel = Set(p.alerts.filter { $0.action != .skip }.map(\.finalId))
            scalarSel = Set(p.scalars.filter { $0.merge == .union }.map(\.id))
        }
    }

    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url) else { return }
        text = String(decoding: data, as: UTF8.self)
        runPreview(text)
    }

    private func apply() {
        guard let p = preview else { return }
        var result = ShareApplyResult()
        var toAdd: [AlertDef] = []
        for item in p.alerts {
            if item.action == .skip || !alertSel.contains(item.finalId) {
                result.skipped += 1
                continue
            }
            toAdd.append(item.def)
            if item.action == .rekey { result.rekeyed += 1 } else { result.added += 1 }
        }
        if !toAdd.isEmpty { model.alerts.addAll(toAdd) }

        // IN LIST ORDER: the transparency MODE row is planned before the per-kind ones, because a
        // per-overlay value is only read while independent mode is on.
        for s in p.scalars where scalarSel.contains(s.id) {
            applyScalar(s, &result)
            result.scalarsApplied += 1
        }
        onApplied(result)
    }

    private func applyScalar(_ s: ScalarChange, _ result: inout ShareApplyResult) {
        switch s.id {
        case "alertPrefs.globalVolume":
            model.player.prefs.globalVolume = s.applied.double ?? model.player.prefs.globalVolume
        case "alertPrefs.muted":
            model.player.prefs.muted = s.applied.bool ?? model.player.prefs.muted
        case "alertPrefs.alwaysPlayAll":
            model.player.prefs.alwaysPlayAll = s.applied.bool ?? model.player.prefs.alwaysPlayAll
        case "overlayBgAlpha.shared":
            Prefs.shared.overlayTransparency = Int(((s.applied.double ?? 0.72) * 100).rounded())
        case "overlayBgAlpha.independent":
            Prefs.shared.overlayIndependent = s.applied.bool ?? Prefs.shared.overlayIndependent
        default:
            if s.id.hasPrefix("overlay."), s.id.hasSuffix(".bgAlpha") {
                let kind = String(s.id.dropFirst("overlay.".count).dropLast(".bgAlpha".count))
                Prefs.shared.overlayTransparencies[kind] = Int(((s.applied.double ?? 0.72) * 100).rounded())
            } else if s.id.hasPrefix("ui.") {
                let key = String(s.id.dropFirst(3))
                guard let spec = SettingsBundle.uiSpecs.first(where: { $0.key == key }),
                      let text = s.applied.string else { return }
                SettingsBundle.writeUiPref(spec, text)
                // These stores read their key once, when the app builds them — so the summary says
                // when the change appears rather than claiming it already has.
                result.deferredToRestart = true
            }
        }
    }
}

// MARK: - Your classes (loadout)

/// The class-loadout history and its correction surface, in the order a user needs them: what is
/// in effect right now and how to set it by hand, then every interval the combo module believes
/// in, newest first, in a fixed-height box that cannot push the page taller.
///
/// WHAT IT NEVER DOES. It does not explain the algorithm, and it does not smooth. A 33.9-hour swap
/// window renders as 33.9 hours of not-knowing; a `{CLR,PAL}` slot renders as `CLR|PAL` forever
/// rather than resolving to the likelier one.
struct ClassLoadoutCard: View {
    @Environment(AppModel.self) private var model
    @State private var snap = ModuleSnapshot()
    @State private var editing: EditingSheet?

    private var intervals: [ComboIntervalView] {
        // NEWEST FIRST: the loadout you care about is the one you are wearing.
        (snap.state["intervals"].array ?? []).compactMap(ComboIntervalView.from).reversed()
    }

    private var current: ComboIntervalView? { ComboIntervalView.from(snap.state["current"]) }

    var body: some View {
        PrefCard("Your classes (loadout)") {
            VStack(alignment: .leading, spacing: 10) {
                override
                if !snap.state.isNull, snap.state["ready"].bool == false {
                    Chip(text: "class tables unavailable", color: Theme.orange)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        if intervals.isEmpty {
                            PrefCaption("Nothing recorded yet.")
                        } else {
                            ForEach(intervals) { i in row(i) }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 268)
                PrefCaption("Edit any past range you know better - your correction wins over autodetection until a /who row says otherwise, and the panel tells you when one does.")
            }
        }
        .task(id: "combo|\(model.moduleSeqs["combo"] ?? 0)|\(model.epoch ?? 0)") {
            await snap.refresh(model, module: "combo")
        }
        .sheet(item: $editing) { s in
            ClassComboEditorSheet(interval: s.interval, openEnded: s.openEnded) {
                editing = nil
                Task { await snap.refresh(model, module: "combo") }
            }
            .environment(model)
        }
    }

    /// A loadout override needs a span to attach to; manufacturing one before the log has said
    /// anything would put a correction on a timeline that does not exist.
    @ViewBuilder
    private var override: some View {
        if let c = current {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("In effect now").font(.caption).foregroundStyle(Theme.textDim)
                    ForEach(Array(c.slots.enumerated()), id: \.offset) { _, s in SlotChipView(slot: s) }
                    Chip(text: ComboLabels.provenance(c.provenance),
                         color: c.provenance == "inferred" ? Theme.textDim : Theme.green)
                    Spacer()
                    PrefButton(title: "Set classes", icon: "pencil") {
                        editing = EditingSheet(interval: c, openEnded: true)
                    }
                    if c.userLocked {
                        PrefButton(title: "Back to autodetect", icon: "arrow.counterclockwise") {
                            ComboCorrections.shared.clear(startTs: c.startTs, endTs: nil)
                            Task {
                                await model.pushComboCorrections()
                                await snap.refresh(model, module: "combo")
                            }
                        }
                    }
                }
                PrefCaption(ComboLabels.loadoutSource(c))
                if let o = ComboLabels.overruled(c) { PrefStatus(tone: .warn, text: o) }
            }
        } else {
            PrefCaption("No loadout read yet - one appears as soon as the log names classes you played, and you can set it by hand from there.")
        }
    }

    /// One interval. Everything on this row is a fact about the data, never about the method.
    private func row(_ i: ComboIntervalView) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                ForEach(Array(i.slots.enumerated()), id: \.offset) { _, s in SlotChipView(slot: s) }
                Spacer()
                Chip(text: ComboLabels.provenance(i.provenance),
                     color: i.provenance == "inferred" ? Theme.textDim : Theme.green)
                Chip(text: ComboLabels.confidence(i.confidence), color: Theme.textDim)
                if i.userLocked { Chip(text: "locked", color: Theme.blue) }
                if let u = ComboLabels.uncertain(i) { Chip(text: "mixed loadouts", color: Theme.orange).help(u) }
                if let o = ComboLabels.overruled(i) { Chip(text: "/who overrode you", color: Theme.orange).help(o) }
                PrefButton(title: "Edit", icon: "pencil") {
                    editing = EditingSheet(interval: i, openEnded: false)
                }
            }
            HStack(spacing: 3) {
                if let f = ComboLabels.startFuzz(i) {
                    // The '~' marker: the start is a RANGE, and its tooltip says how wide and why.
                    Text("~").font(.caption).foregroundStyle(Theme.orange).help(f)
                }
                Text(ComboLabels.span(i)
                     + (ComboLabels.levelRange(i).map { " · \($0)" } ?? "")
                     + (i.evidenceCount > 0 ? " · \(i.evidenceCount) signals" : ""))
                    .font(.caption).foregroundStyle(Theme.textDim)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border))
    }
}

/// The editor's identity: a fresh sheet per row, so opening a different range never carries the
/// previous row's picks into it.
struct EditingSheet: Identifiable {
    let interval: ComboIntervalView
    let openEnded: Bool
    var id: String { "\(interval.id)|\(openEnded)" }
}
