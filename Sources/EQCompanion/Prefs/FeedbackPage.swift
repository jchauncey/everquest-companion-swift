// Preferences → Feedback (upstream FeedbackSetting.tsx).
//
// The upstream card opens a dialog that UPLOADS. This app has nowhere to upload to — no account,
// no server, no endpoint — so the honest port is the same report with the send button removed: you
// write what happened, the app assembles the file, and you send it yourself. A "Send" button that
// wrote to nothing would be the one thing this page may not be.
//
// The checklist is not decoration. A report you send by hand is a report you can read first, and
// the list is what makes reading it unnecessary — it says what is in the file BEFORE it is written,
// including the two things that are taken out of it.
import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension PrefPages {
    static let feedback = PrefPage(id: "feedback", label: "Feedback", icon: "exclamationmark.bubble", sections: [
        PrefSectionInfo(id: "send-feedback", label: "Send feedback",
                        keywords: "feedback bug report problem crash issue log diagnostics save copy")
    ]) { AnyView(FeedbackPage()) }
}

struct FeedbackPage: View {
    @Environment(AppModel.self) private var model
    @State private var what: String = ""
    @State private var status: (tone: PrefStatus.Tone, text: String)?
    @State private var working = false

    /// What the report carries, in the order the file states it. Every line is a thing that is
    /// actually in there — the last two say what is taken out.
    private let includes: [String] = [
        "The app's version and the version of macOS it is running on",
        "Where your EverQuest install was found and which folder your logs are in - the log file names are stripped to eqlog_*, so no character name rides in a path",
        "What the engine says about itself: what it is doing, how many events it has folded, and how far behind the log it is",
        "The engine's own performance numbers and its verdict on each of its budgets",
        "The last 200 lines of this app's own log (client.log), with every character name replaced by <character>",
        "What you write above, exactly as you write it"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PrefCard("Send feedback") {
                PrefCaption("There is no send button here, and that is deliberate: this app has no account and no server to send anything to. A report is a FILE - it is written on your machine, you read it if you want to, and you send it yourself by whatever route you already use.")

                VStack(alignment: .leading, spacing: 4) {
                    Text("What happened").foregroundStyle(Theme.text)
                    TextEditor(text: $what)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 110)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.background))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
                    PrefCaption("What you were doing, what you expected, and what happened instead.")
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("The report includes").font(.caption.weight(.semibold)).foregroundStyle(Theme.textDim)
                    ForEach(includes, id: \.self) { line in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "checkmark").font(.caption).foregroundStyle(Theme.gold)
                            PrefCaption(line)
                        }
                    }
                }

                PrefCaption("No line of your EverQuest log is in it, and nothing leaves this machine until you send it.")

                HStack(spacing: 10) {
                    PrefButton(title: "Save report…", icon: "square.and.arrow.down", filled: true) { save() }
                    PrefButton(title: "Copy to clipboard", icon: "doc.on.doc") { copy() }
                    if working { ProgressView().controlSize(.small) }
                }

                if let s = status { PrefStatus(tone: s.tone, text: s.text) }
            }
        }
    }

    // MARK: - The two buttons

    private func save() {
        report { text in
            let panel = NSSavePanel()
            panel.nameFieldStringValue = BugReport.suggestedFileName()
            panel.allowedContentTypes = [.json]
            panel.canCreateDirectories = true
            panel.title = "Save bug report"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                status = (tone: .ok, text: "Saved to \(url.path). Attach it to your message.")
            } catch {
                status = (tone: .bad, text: "Could not write that file: \(error.localizedDescription)")
            }
        }
    }

    private func copy() {
        report { text in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            status = (tone: .ok, text: "Copied. Paste it wherever you are sending it.")
        }
    }

    /// Assemble the report, then hand it to whichever button asked for it. The engine is asked
    /// exactly here — once per press.
    private func report(_ then: @escaping (String) -> Void) {
        guard !working else { return }
        working = true
        status = nil
        Task { @MainActor in
            let text = await BugReport.gather(model: model, what: what)
            working = false
            then(text)
        }
    }
}
