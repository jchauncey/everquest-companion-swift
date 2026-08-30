// Preferences → Voice.
//
// The GLOBAL half of voice alerts: which engine speaks, the default voice, and how fast/loud.
// Per-alert choices (what an alert says, and how) live in the alert editor's Speech block — this
// panel is what those defer to.
//
// IT IS CONFIGURATION, NOT PERMISSION. There is no master "speak alerts" switch: an alert speaks
// because ITS output says Voice, full stop. What remains here never decides WHETHER the app talks,
// only how it sounds when an alert says it should.
//
// ONE ENGINE, HONESTLY. The Windows app offers a second, downloadable tier (a ~115 MB natural
// voice). That engine is Windows-only, so the picker here has one entry and a caption says why
// rather than showing a choice that cannot be made.
import SwiftUI
import AVFoundation

extension PrefPages {
    static let voice = PrefPage(id: "voice", label: "Voice", icon: "person.wave.2", sections: [
        PrefSectionInfo(id: "voice-alerts", label: "Spoken alerts",
                        keywords: "voice speech speak tts talk say spoken narrate announce engine rate speed volume alert sound")
    ]) { AnyView(VoicePage()) }
}

/// The sentence the ▶ preview speaks. Fixed on purpose: it is an ALERT-shaped utterance.
let voicePreviewText = "Charm break"

struct VoicePage: View {
    @Environment(AppModel.self) private var model
    @Bindable private var prefs = Prefs.shared
    @State private var voices: [VoiceOption] = []

    var body: some View {
        PrefCard("Spoken alerts") {
            PrefCaption("Alerts speak when you set their output to Voice, in the Alerts tab - there is no switch here. This is the voice they use. Muting alerts silences speech too.")
            VStack(alignment: .leading, spacing: 4) {
                // One option, and it is the only engine that exists on this machine — the picker is
                // here because the setting is real, not because there is a decision to make.
                PrefSelect(label: "Voice engine", selection: .constant("system"),
                           options: [("system", "macOS voices (built in)")])
                PrefCaption("The Windows app can also download a natural voice; that engine is Windows-only, so it is not here. macOS speaks with its own voices - add more in System Settings › Accessibility › Spoken Content.")
            }
            HStack(alignment: .bottom, spacing: 12) {
                PrefSelect(label: "Voice", selection: $prefs.voiceId, options: voiceOptions)
                PrefButton(title: "Preview", icon: "play.fill") {
                    model.player.speakPreview(voicePreviewText)
                }
                Spacer(minLength: 0)
            }
            HStack(alignment: .center, spacing: 24) {
                PrefSlider(label: "Speed", value: $prefs.voiceRate, range: 0.5...2.0, step: 0.05,
                           format: { String(format: "%.2f×", $0) })
                    .frame(width: 180)
                PrefSlider(label: "Volume", value: $prefs.voiceVolume, range: 0...1, step: 0.05,
                           format: { "\(Int(($0 * 100).rounded()))%" })
                    .frame(width: 180)
                Spacer(minLength: 0)
            }
        }
        .task { voices = VoiceCatalog.system() }
    }

    /// The empty id first — "whatever voice the system defaults to" — then every installed voice.
    /// An empty machine says so rather than offering a default it cannot speak with.
    private var voiceOptions: [(String, String)] {
        [("", voices.isEmpty ? "No voices available" : "Default voice")] + voices.map { ($0.id, $0.label) }
    }
}

/// One entry in the voice picker: the identifier the setting stores, and what the user reads.
struct VoiceOption: Hashable, Identifiable {
    let id: String
    let label: String
}

/// Which voices this machine can speak with, in the order a picker should show them.
///
/// GROUPED BY LANGUAGE, the player's own first. macOS ships a hundred-odd voices across forty
/// languages; unsorted that is a wall, and the three the player might actually pick are scattered
/// through it. The language is in the label too, because "Karen" and "Moira" are otherwise
/// indistinguishable until you press ▶.
enum VoiceCatalog {
    struct Entry: Hashable {
        let id: String
        let name: String
        /// A BCP-47 tag: "en-US", "de-DE".
        let language: String
    }

    static func system() -> [VoiceOption] {
        let entries = AVSpeechSynthesisVoice.speechVoices().map {
            Entry(id: $0.identifier, name: $0.name, language: $0.language)
        }
        return options(entries, preferring: Locale.current.identifier)
    }

    /// Pure so it can be reasoned about without a machine's voice list. `preferring` is a locale
    /// identifier; only its language part decides which group sorts first.
    static func options(_ entries: [Entry], preferring preferred: String) -> [VoiceOption] {
        let mine = languageCode(preferred)
        return entries
            .sorted { a, b in
                let (la, lb) = (languageCode(a.language), languageCode(b.language))
                if la != lb {
                    if la == mine { return true }
                    if lb == mine { return false }
                    return la < lb
                }
                if a.language != b.language { return a.language < b.language }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            .map { VoiceOption(id: $0.id, label: "\($0.name) (\($0.language))") }
    }

    /// "en-US" / "en_US" → "en".
    static func languageCode(_ tag: String) -> String {
        String(tag.lowercased().prefix { $0 != "-" && $0 != "_" })
    }
}
