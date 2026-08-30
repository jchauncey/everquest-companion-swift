// Preferences → What's new — the upstream WhatsNewPanel: the browsable release history.
//
// WHERE IT LIVES, AND WHY. Its own row in the rail, directly under Updates, where a person looking
// for "what version am I on, and what changed" is already standing. It is a reading surface with
// no controls, which is exactly why it is a page of its own rather than a line tucked under
// something about switches.
//
// OPENING THE PANEL IS SEEING THE NOTES. The seen stamp is written on appear, and it does not
// disturb what is on screen: the NEW chips a user came here to read stay up for this visit and are
// gone the next time.
//
// STATE, NEVER PROCESS: the page says what changed. It does not explain where notes come from, how
// "new" is computed, or that anything is stored.
//
// WHAT IS NOT HERE: upstream ends with an "All releases on GitHub" link, because what ships in a
// build is every release up to that build and the releases page answers what came after. This port
// has no releases page of its own, and pointing at upstream's would list a different program's
// versions - so the door is left out rather than pointed somewhere wrong.
import SwiftUI

extension PrefPages {
    static let whatsNew = PrefPage(id: "whatsNew", label: "What's new", icon: "sparkles", sections: [
        PrefSectionInfo(id: "release-notes", label: "Release notes",
                        keywords: "whats new release notes changelog changes history updates version fixed added changed news log recent")
    ]) { AnyView(WhatsNewPage()) }
}

struct WhatsNewPage: View {
    /// What the install had been shown when this page opened. Captured before the stamp is written,
    /// so marking the notes seen does not erase the chips the reader is looking at.
    @State private var seenAtOpen: String?

    var body: some View {
        PrefCard("Release notes") {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(ReleaseNotes.all) { note in
                    release(note)
                }
            }
        }
        .onAppear {
            if seenAtOpen == nil { seenAtOpen = Prefs.shared.seenReleaseNotesVersion }
            Prefs.shared.seenReleaseNotesVersion = AppVersion.current
        }
    }

    /// One release: its version, its date, a NEW chip when it postdates what this install had seen,
    /// and its bullets grouped by kind.
    private func release(_ note: ReleaseNote) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("v\(note.version)").font(.callout.weight(.bold)).foregroundStyle(Theme.text)
                Text(ReleaseNotes.formatDate(note.date)).font(.caption).foregroundStyle(Theme.textDim)
                if ReleaseNotes.isNew(note, seen: seenAtOpen ?? Prefs.shared.seenReleaseNotesVersion) {
                    PrefChip(text: "new", color: Theme.gold)
                }
                Spacer()
            }
            ForEach(ReleaseNotes.kindOrder, id: \.self) { kind in
                let entries = note.entries.filter { $0.kind == kind }
                if !entries.isEmpty { group(ReleaseNotes.label(kind), entries) }
            }
        }
    }

    /// One group of bullets under its sub-header.
    private func group(_ label: String, _ entries: [ReleaseEntry]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption.weight(.bold)).kerning(0.5).foregroundStyle(Theme.textDim)
            // A real marker and a hanging indent, so a three-line change still reads as one item.
            ForEach(Array(entries.enumerated()), id: \.offset) { _, e in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("•").foregroundStyle(Theme.textDim)
                    Text(e.text).font(.callout).foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 6)
            }
        }
    }
}
