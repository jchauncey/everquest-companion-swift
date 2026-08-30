// Preferences → Updates — the upstream UpdateSetting's two cards, told the truth about this build.
//
// THE VERSION, AND THE WAY FROM IT TO WHAT THAT VERSION CHANGED. The version number is what a
// person is looking at when the question "…and what is different about it?" occurs to them, so the
// answer is named right beside it. The notes have ONE home — Preferences → What's new — and this
// only points at it.
//
// WHAT IS NOT HERE, AND WHY. Upstream has an updater: a release feed, a background download, a
// state chip, a "Restart to update" button. This build has none of them — no feed is contacted and
// nothing can be downloaded — so there is no chip, no "last checked", and above all no "Check for
// updates" button, which would be a control that does nothing. The card says how an update
// actually happens here instead, which is the only honest thing it can say.
import SwiftUI
import AppKit

extension PrefPages {
    static let updates = PrefPage(id: "updates", label: "Updates", icon: "square.and.arrow.down", sections: [
        PrefSectionInfo(id: "version", label: "Version", keywords: "about build release app version"),
        PrefSectionInfo(id: "app-updates", label: "App updates",
                        keywords: "update upgrade check install download release replace applications manual by hand")
    ]) { AnyView(UpdatesPage()) }
}

struct UpdatesPage: View {
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
                PrefCaption("This build has no updater and no release feed - it never asks anything whether a newer version exists, and it cannot download one.")
                PrefCaption("Updates are installed by hand: replace the app in /Applications with the new one; your settings and state stay in Application Support.")
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
