// Preferences → Combat — what the damage meters COUNT, ported from the Electron app's
// CombatSection.tsx (the section), MeterScopeSetting.tsx and the pet-nesting card inside it.
//
// Both cards are APP-LOCAL preferences, and that is not an accident of this port: the engine's
// `combat.snapshot` opts carry neither a scope nor a pet fold (the schema says so outright —
// "there is deliberately no `combinePets`"). The engine answers with every combatant it saw and
// every pet as its own source row; whose rows are shown, and where the pet's damage sits inside
// them, is decided here and applied in CombatData.swift, which every damage meter reads through.
//
// ONE SWITCH, EVERY DAMAGE METER. The Combat tab, the Overview card and the floating meter all
// build their rows with the same two functions, so there is one answer to "what am I looking at"
// and no surface can show a different breakdown for the same fight.
//
// WHAT IS NOT HERE: the upstream third card, "What teaches the resist numbers". This app draws no
// resist profile anywhere — no mob resist card, no con-card resist row — so the switch would
// govern a number nothing displays. A control that does nothing must not exist.
import SwiftUI

extension PrefPages {
    static let combat = PrefPage(id: "combat", label: "Combat", icon: "chart.bar", sections: [
        PrefSectionInfo(id: "meter-scope", label: "Whose damage the meters show",
                        keywords: "scope whose damage you group everyone party raid roster member members source cohort filter meter meters overlay combat dps show hide"),
        PrefSectionInfo(id: "combine-pet", label: "Show your pet inside your damage",
                        keywords: "pet combine merge damage breakdown solo meter drill charm nest source zoom default level")
    ]) { AnyView(CombatPage()) }
}

struct CombatPage: View {
    @Bindable private var prefs = Prefs.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PrefCard("Whose damage the meters show") {
                VStack(alignment: .leading, spacing: 8) {
                    // A SEGMENTED CONTROL, NOT A CYCLE: three visible options with the chosen one
                    // lit is the shape that says what the alternatives even are. Scope has no
                    // "off" — every meter is showing SOMEBODY — so there is no fourth state.
                    SegmentPicker(selection: $prefs.meterScope,
                                  options: MeterScope.allCases.map { ($0.rawValue, $0.label.uppercased()) })
                    PrefCaption(scopeCaption)
                }
            }

            PrefCard("Show your pet inside your damage") {
                PrefToggle(label: "Show your pet inside your damage", isOn: $prefs.petInline,
                           captionOn: "On the floating meter your pet’s damage rides inside your bar. (The Combat tab always lists your pet as one row of your breakdown, with its own card below.)",
                           captionOff: "On the floating meter your pet gets its own bar beside yours.")
            }
        }
    }

    /// The selected scope's own sentence, plus the one line about Group's no-roster fallback —
    /// the single thing about this setting a user is most likely to be confused by.
    private var scopeCaption: String {
        let s = MeterScope.preferred
        return s == .group
            ? "\(s.hint). Until the log gives the app a group signal there is no roster to filter by, so Group shows everyone and the meters say so (“Group (no roster yet)”)."
            : "\(s.hint)."
    }
}
