// Preferences → Game — the upstream EqFolderSetting: the one card that says where EverQuest is.
//
// The effective paths, a chip saying how the install root resolved, the folder picker + the
// auto-detection reset, and validation feedback (how many character logs are under the folder we
// actually read). Changes apply live — `setInstallOverride` re-resolves, re-lists the characters
// and re-attaches — so this card is the whole flow rather than a form with an Apply button.
//
// BOTH PATHS ARE SHOWN, AND THE SECOND ONE IS THE POINT (upstream JOS-82). What the user picks is
// normalized — pick `…/EverQuest Legends/Logs` and the row snaps to its PARENT — and to the person
// who just chose a folder that reads as the app quietly refusing the change. Naming the folder the
// app actually READS makes the pick visible, and it is the line that matters anyway: it is where
// the `eqlog_*.txt` files have to be.
//
// FOUR VERDICTS, NOT TWO. "No logs here" once stood for three different situations, one of which is
// "the OS would not let me list that folder at all". Telling someone who is staring at their logs
// in Finder to enable logging is a silent wrong answer, so `logsReadable` carries the difference
// and each case gets advice that can actually work.
//
// MAC DIFFERENCES: there is no Windows folder dialog to work around, but the second button is kept
// for the reason it was added upstream — a real `Logs` directory has no subfolders, and the file
// dialog is the one that can actually display an `eqlog_*.txt`. The install lives inside a
// CrossOver/Whisky bottle, so the paths are POSIX paths rather than `C:\users\Public\…`.
import SwiftUI
import AppKit

extension PrefPages {
    static let game = PrefPage(id: "game", label: "Game", icon: "gamecontroller", sections: [
        PrefSectionInfo(id: "eq-folder", label: "EverQuest install folder",
                        keywords: "path directory logs eqlog character detect override install location bottle crossover whisky wine")
    ]) { AnyView(GamePage()) }
}

struct GamePage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        PrefCard("EverQuest install folder") {
            paths
            check
            buttons
        }
    }

    // MARK: The paths

    /// The effective paths, plus a chip saying how the install root resolved. Set off by a
    /// background fill, NOT a border: the card around it is the one border level in this view.
    private var paths: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                PrefPath(label: "Install folder", path: model.install?.root.path ?? "-")
                PrefPath(label: "Reading logs from", path: model.install?.logsDir.path ?? "-")
            }
            Spacer(minLength: 8)
            if let chip = sourceChip { PrefChip(text: chip.label, color: chip.color) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.paperRaised))
    }

    /// How the root resolved. A manual override always wins, so it is its own word; `EQ_INSTALL_DIR`
    /// is named rather than called "auto", because someone who set it wants to see that it took.
    private var sourceChip: (label: String, color: Color)? {
        guard let install = model.install else { return nil }
        if !model.installOverride.isEmpty { return ("manual", Theme.blue) }
        if install.source == "env" { return ("EQ_INSTALL_DIR", Theme.blue) }
        return ("auto", Theme.green)
    }

    // MARK: The verdict

    @ViewBuilder
    private var check: some View {
        if model.install == nil {
            PrefStatus(tone: .warn, text: "No EverQuest Legends install found. Pick the folder your eqlog_*.txt files are in - or pick one of the files itself.")
        } else if model.logsReadable == "unreadable" {
            PrefStatus(tone: .bad, text: "This folder could not be read. Its files may be blocked by permissions or by macOS privacy settings, or it may be a broken alias. Try choosing one of the log files directly.")
        } else if model.logsReadable == "missing" {
            PrefStatus(tone: .warn, text: "This folder doesn't exist. Pick the folder your eqlog_*.txt files are in - or pick one of the files itself.")
        } else if model.characters.isEmpty {
            PrefStatus(tone: .warn, text: "No character logs (eqlog_*.txt) found here. Make sure EverQuest logging is enabled (/log on), then pick the folder those files are in - or pick one of the files itself.")
        } else {
            PrefStatus(tone: .ok, text: Self.foundText(model.characters.count))
        }
    }

    /// "Found 1 character log in this folder." — the plural is the only thing that moves.
    static func foundText(_ n: Int) -> String {
        "Found \(n) character log\(n == 1 ? "" : "s") in this folder."
    }

    // MARK: The buttons

    private var buttons: some View {
        HStack(spacing: 8) {
            PrefButton(title: "Choose folder…", icon: "folder", filled: true) { choose(directories: true) }
            // The label is the whole explanation: a person who could not find their files in the
            // folder dialog reads "Choose log file…" and knows what to press. No tooltip.
            PrefButton(title: "Choose log file…", icon: "doc.text") { choose(directories: false) }
            PrefButton(title: "Use auto-detection", icon: "wand.and.stars") { model.setInstallOverride("") }
                .disabled(model.installOverride.isEmpty)
                .opacity(model.installOverride.isEmpty ? 0.45 : 1)
            Spacer()
        }
    }

    /// One panel for both buttons: a picked folder and a picked file normalize to the same
    /// {root, logsDir} pair, so the two doors are one flow through the dialog that can show the file.
    private func choose(directories: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = directories
        panel.canChooseFiles = !directories
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.prompt = "Choose"
        panel.message = directories
            ? "Choose your EverQuest Legends folder, or the Logs folder inside it."
            : "Choose one of your eqlog_*.txt files."
        if let dir = model.install?.logsDir { panel.directoryURL = dir }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.setInstallOverride(url.path)
    }
}
