// The two sound surfaces the Alerts toolbar opens: the registry browser (packs somebody else
// made) and "My sounds" (the pack the user makes by putting files in a folder).
import SwiftUI
import AppKit
import EQCompanionCore

struct SoundPacksSheet: View {
    @Environment(AppModel.self) private var model
    var onClose: () -> Void

    @State private var registry = SoundPackRegistry()
    @State private var query = ""
    @State private var installedOnly = false
    @State private var confirmRemove: String?

    private var installedIds: Set<String> {
        Set(model.player.packInfos().map(\.id).filter { $0 != userSoundsPackId })
    }

    private var rows: [RegistryPack] {
        let installed = installedIds
        var out = registry.packs
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            out = out.filter {
                $0.displayName.lowercased().contains(q) || $0.name.lowercased().contains(q)
                    || $0.summary.lowercased().contains(q) || $0.author.lowercased().contains(q)
            }
        }
        if installedOnly { out = out.filter { installed.contains($0.name) } }
        // Installed first, then by name — the packs you own are the ones you came to manage.
        return out.sorted { a, b in
            let ia = installed.contains(a.name), ib = installed.contains(b.name)
            if ia != ib { return ia }
            return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.border)
            if registry.loading && registry.packs.isEmpty {
                ProgressView("Fetching the registry…").padding(30).frame(maxWidth: .infinity)
            } else if registry.packs.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No packs to show.").foregroundStyle(Theme.text)
                    Text(registry.error ?? "The registry answered with an empty list.")
                        .font(.caption).foregroundStyle(Theme.textDim)
                }.padding(20).frame(maxWidth: .infinity, alignment: .topLeading)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(rows) { p in row(p) }
                    }.padding(12)
                }
            }
            Divider().overlay(Theme.border)
            HStack {
                Text("\(registry.packs.count) packs · \(installedIds.count) installed")
                    .font(.caption).foregroundStyle(Theme.textDim)
                Spacer()
                Button("Done") { onClose() }.keyboardShortcut(.defaultAction)
            }.padding(12)
        }
        .frame(width: 760, height: 640)
        .background(Theme.background)
        .task { await registry.load() }
        .alert("Remove this pack?", isPresented: Binding(get: { confirmRemove != nil },
                                                         set: { if !$0 { confirmRemove = nil } })) {
            Button("Cancel", role: .cancel) { confirmRemove = nil }
            Button("Remove", role: .destructive) {
                if let id = confirmRemove { registry.remove(id, player: model.player) }
                confirmRemove = nil
            }
        } message: {
            Text(removalMessage(confirmRemove))
        }
    }

    private func removalMessage(_ id: String?) -> String {
        guard let id else { return "" }
        let users = model.alerts.defs.filter { $0.packId == id }
        let audio = "Its files are deleted from disk; installing it again brings them back."
        let stone = id == defaultAlertPackId
            ? " This is the pack the app installs on first launch — removing it is remembered, so it will not come back on its own."
            : ""
        if users.isEmpty { return audio + stone }
        return "\(users.count) alert\(users.count == 1 ? "" : "s") play a line from it (\(users.prefix(3).map(\.name).joined(separator: ", "))). They keep their setting and fall back to a beep until you point them at another sound. " + audio + stone
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Sound packs").font(.headline).foregroundStyle(Theme.text)
                Spacer()
                if registry.fromCache {
                    Chip(text: registry.error == nil ? "cached" : "offline · cached", color: Theme.orange)
                }
                Button {
                    Task { await registry.load(force: true) }
                } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .buttonStyle(OutlineButtonStyle())
            }
            Text("Voice packs from the openpeon registry (\(SoundPackRegistry.url)). Installing downloads the pack's manifest and every audio file into Application Support.")
                .font(.caption).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
            if let e = registry.error {
                Text("Registry fetch failed: \(e)").font(.caption).foregroundStyle(Theme.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if registry.dropped > 0 {
                Text("\(registry.dropped) row(s) dropped at ingest for failing validation.")
                    .font(.caption).foregroundStyle(Theme.orange)
            }
            HStack {
                TextField("Search packs", text: $query).textFieldStyle(.roundedBorder)
                Toggle("Installed only", isOn: $installedOnly).toggleStyle(.checkbox).foregroundStyle(Theme.textDim)
            }
        }.padding(12)
    }

    @ViewBuilder
    private func row(_ p: RegistryPack) -> some View {
        let installed = installedIds.contains(p.name)
        let phase = registry.progress[p.name]
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(p.displayName).fontWeight(.semibold).foregroundStyle(Theme.text)
                        if installed { Chip(text: "installed", color: Theme.green) }
                        if p.name == defaultAlertPackId { Chip(text: "shipped default", color: Theme.gold) }
                        if p.trustTier == "verified" { Chip(text: "verified", color: Theme.blue) }
                    }
                    if !p.summary.isEmpty {
                        Text(p.summary).font(.caption).foregroundStyle(Theme.textDim)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                    Text(metaLine(p)).font(.caption2).foregroundStyle(Theme.textFaint)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 4) {
                    if registry.busy.contains(p.name) {
                        ProgressView().controlSize(.small)
                    } else if installed {
                        Button("Remove") { confirmRemove = p.name }.buttonStyle(OutlineButtonStyle())
                    } else {
                        Button("Install") {
                            Task { await registry.install(p, player: model.player) }
                        }.buttonStyle(OutlineButtonStyle())
                    }
                }
            }
            if let phase {
                Text(phase.text).font(.caption2)
                    .foregroundStyle({ if case .failed = phase { return Theme.red } else { return Theme.textDim } }())
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.paper))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
    }

    private func metaLine(_ p: RegistryPack) -> String {
        var parts: [String] = ["\(p.soundCount) sounds"]
        if p.totalSizeBytes > 0 { parts.append(Format.bytes(Int64(p.totalSizeBytes))) }
        if !p.author.isEmpty { parts.append("by \(p.author)") }
        parts.append(p.license)
        if !p.version.isEmpty { parts.append("v\(p.version)") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - My sounds

/// `<packsDir>/my-sounds/` — anything the user drops in becomes a choice in every picker. There is
/// no manifest to keep in step: the pack is READ from the folder, so the folder is the truth.
struct MySoundsSheet: View {
    @Environment(AppModel.self) private var model
    var onClose: () -> Void

    @State private var rejected: [String] = []
    @State private var refresh = 0

    private var sounds: [PackSound] {
        _ = refresh
        return model.player.pack(userSoundsPackId)?.sounds ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(userSoundsPackName).font(.headline).foregroundStyle(Theme.text)
                Text("Audio you drop into this folder shows up as a pack called “\(userSoundsPackName)” in every alert. \(userSoundExtensions.joined(separator: ", ")) · up to 25 MB.")
                    .font(.caption).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Add a sound…") { add() }.buttonStyle(OutlineButtonStyle())
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([AlertPlayer.mySoundsDir])
                    }.buttonStyle(OutlineButtonStyle())
                    Spacer()
                    Text(AlertPlayer.mySoundsDir.path).font(.caption2).foregroundStyle(Theme.textFaint)
                        .lineLimit(1).truncationMode(.head)
                }
                ForEach(rejected, id: \.self) { r in
                    Text(r).font(.caption).foregroundStyle(Theme.orange)
                }
            }.padding(12)
            Divider().overlay(Theme.border)
            if sounds.isEmpty {
                Text("Nothing here yet. Add an audio file and it becomes a choice in every alert.")
                    .font(.callout).foregroundStyle(Theme.textDim)
                    .padding(20).frame(maxWidth: .infinity, alignment: .topLeading)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(sounds) { s in
                            HStack(spacing: 8) {
                                Button {
                                    model.player.previewSound(pack: userSoundsPackId, sound: s.id)
                                } label: { Image(systemName: "play.circle") }.buttonStyle(.plain)
                                Text(s.label).foregroundStyle(Theme.text).lineLimit(1)
                                Spacer()
                                Text(s.id).font(.caption2.monospaced()).foregroundStyle(Theme.textFaint)
                                Button { remove(s) } label: { Image(systemName: "trash") }
                                    .buttonStyle(.plain).foregroundStyle(Theme.red)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 5)
                        }
                    }.padding(.vertical, 6)
                }
            }
            Divider().overlay(Theme.border)
            HStack {
                Text("\(sounds.count) sound\(sounds.count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(Theme.textDim)
                Spacer()
                Button("Done") { onClose() }.keyboardShortcut(.defaultAction)
            }.padding(12)
        }
        .frame(width: 600, height: 480)
        .background(Theme.background)
        .onAppear { model.player.invalidate(); refresh += 1 }
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = []
        panel.message = "Choose .wav, .mp3 or .ogg files to copy into My sounds."
        guard panel.runModal() == .OK else { return }
        var bad: [String] = []
        for url in panel.urls {
            let ext = url.pathExtension.lowercased()
            guard userSoundExtensions.contains(ext) else {
                bad.append("\(url.lastPathComponent) — not one of \(userSoundExtensions.joined(separator: ", "))")
                continue
            }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= 25 * 1024 * 1024 else {
                bad.append("\(url.lastPathComponent) — larger than 25 MB")
                continue
            }
            let dest = AlertPlayer.mySoundsDir.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)
            do { try FileManager.default.copyItem(at: url, to: dest) }
            catch { bad.append("\(url.lastPathComponent) — \(error.localizedDescription)") }
        }
        rejected = bad
        model.player.invalidate()
        refresh += 1
    }

    private func remove(_ s: PackSound) {
        let url = AlertPlayer.mySoundsDir.appendingPathComponent(s.file)
        try? FileManager.default.removeItem(at: url)
        model.player.invalidate()
        refresh += 1
    }
}
