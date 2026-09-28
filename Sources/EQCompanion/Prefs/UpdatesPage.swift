// Preferences → Updates: the version, and the updater (AppUpdater.swift — Sparkle).
//
// THE VERSION, AND THE WAY FROM IT TO WHAT THAT VERSION CHANGED. The version number is what a
// person is looking at when the question "…and what is different about it?" occurs to them, so the
// answer is named right beside it. The notes have ONE home — Preferences → What's new — and this
// only points at it.
//
// THE UPDATER SAYS WHAT IT DOES. It asks the project's GitHub releases whether there is a newer
// version and installs one only after verifying its signature. A build that cannot update itself
// (run from source, or built without the signing key) shows no controls that would do nothing —
// it says why, and how an update happens instead.
import SwiftUI
import AppKit

extension PrefPages {
    static let updates = PrefPage(id: "updates", label: "Updates", icon: "square.and.arrow.down", sections: [
        PrefSectionInfo(id: "version", label: "Version", keywords: "about build release app version"),
        PrefSectionInfo(id: "app-updates", label: "App updates",
                        keywords: "update upgrade check install download release sparkle automatic daily")
    ]) { AnyView(UpdatesPage()) }
}

struct UpdatesPage: View {
    @State private var updater = AppUpdater.shared
    // Sparkle's settings are not observable here; mirrored and written through.
    @State private var autoCheck = AppUpdater.shared.automaticallyChecks
    @State private var autoDownload = AppUpdater.shared.automaticallyDownloads

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PrefCard("Version") {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("v\(AppVersion.current)").font(.body.monospaced()).foregroundStyle(Theme.text)
                        .textSelection(.enabled)
                    Text("What's new is the next page down.").font(.caption).foregroundStyle(Theme.textDim)
                }
            }

            PrefCard("App updates") {
                if updater.available {
                    PrefToggle(label: "Check for updates automatically", isOn: $autoCheck,
                               captionOn: "About once a day the app asks the project's GitHub releases whether a newer version is out. Nothing else is sent.",
                               captionOff: "The app never looks by itself; use Check Now, or EQ Companion → Check for Updates….")
                        .onChange(of: autoCheck) { _, v in updater.automaticallyChecks = v }
                    if autoCheck {
                        PrefToggle(label: "Download updates in the background", isOn: $autoDownload,
                                   captionOn: "A new version is downloaded when it is found, and installed when you quit.",
                                   captionOff: "When a new version is found you are asked before anything is downloaded.")
                            .onChange(of: autoDownload) { _, v in updater.automaticallyDownloads = v }
                    }
                    HStack(spacing: 8) {
                        PrefButton(title: "Check Now", icon: "arrow.triangle.2.circlepath") { updater.checkForUpdates() }
                            .disabled(!updater.canCheck)
                        Text(updater.lastCheck.map { "Last checked \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Never checked")
                            .font(.caption).foregroundStyle(Theme.textDim)
                        Spacer()
                    }
                    PrefCaption("Every update is signed; one whose signature does not verify is refused. Your settings and state in Application Support are kept.")
                } else {
                    PrefCaption(updater.unavailableReason ?? "This build cannot update itself.")
                    PrefCaption("Update by hand: replace the app in /Applications with the new one; your settings and state stay in Application Support.")
                    HStack(spacing: 8) {
                        PrefButton(title: "Reveal app", icon: "folder") {
                            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                        }
                        Spacer()
                    }
                }
            }
        }
    }
}
