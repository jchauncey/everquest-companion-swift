// Preferences → Appearance — the upstream TextSizeSetting + OverlaysAppearanceSetting, in this
// order, which is the hierarchy the owner asked for: what the APP draws at, then what the floating
// windows draw at.
//
// ONE STEPPER SHAPE FOR EVERY VALUE ON THE PAGE: a minus, a number, a plus. `A− / A+` on a text
// size, a bare `− / +` on a transparency, which is not text.
//
// THE ONLY DISABLED BUTTONS HERE ARE A STEPPER'S ENDS, and they are disabled because the value
// cannot move rather than because something else is switched off. A control that is not in force is
// not rendered at all — hence the overlays card's two shapes.
import SwiftUI

extension PrefPages {
    static let appearance = PrefPage(id: "appearance", label: "Appearance", icon: "textformat.size", sections: [
        PrefSectionInfo(id: "ui-scale", label: "In-app text size",
                        keywords: "\(AppearanceWords.size) window app main"),
        PrefSectionInfo(id: "overlays-appearance", label: "Overlays",
                        keywords: "\(AppearanceWords.size) \(AppearanceWords.alpha) \(AppearanceWords.overlay)")
    ]) { AnyView(AppearancePage()) }
}

/// The words somebody types when they cannot read something — symptom vocabulary as heavily as
/// mechanism, because the person searching is describing what they are experiencing.
enum AppearanceWords {
    static let size =
        "text size font bigger larger smaller enlarge shrink zoom scale magnify percent " +
        "readable read reading small tiny huge big hard to see eyes eyesight squint vision " +
        "accessibility accessible interface ui display appearance look"
    static let overlay =
        "overlay overlays meter card con mob toast banner independent separate each individually " +
        "window windows floating pinned locked strip popup"
    static let alpha =
        "transparency transparent opacity opaque see-through solid background bg dim darker lighter faded"
}

// MARK: - The ranges

/// The in-app ladder, in percent. 100% is the platform's own text size; the ends are where the app's
/// dynamic type scale runs out (`Prefs.dynamicType`).
enum UIScaleRange {
    static let min = 80
    static let max = 150
    static let step = 10
}

/// The overlays' text size, in percent — the upstream 0.8 … 2.0 in the vocabulary this page speaks.
enum OverlayScaleRange {
    static let min = 80
    static let max = 200
    static let step = 10
}

/// The overlays' background opacity, in percent, on a 5% grid. The shipped 72% is not on that grid,
/// so a press SNAPS to the next cell rather than adding five and leaving the number off the ladder.
enum OverlayAlphaRange {
    static let min = 10
    static let max = 100
    static let step = 5

    /// One cell up or down, from anywhere.
    static func stepped(_ value: Int, up: Bool) -> Int {
        let cells = Double(value) / Double(step)
        let eps = 1e-9
        let next = up ? (floor(cells + eps) + 1) : (ceil(cells - eps) - 1)
        return Swift.max(min, Swift.min(max, Int(next * Double(step))))
    }
}

// MARK: - The page

struct AppearancePage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextSizeCard()
            OverlaysAppearanceCard()
        }
    }
}

/// IT APPLIES ON THE PRESS: the window is being read at the size it just chose, which is the whole
/// evaluation loop for a setting like this — so there is no "restart to apply" sentence here.
private struct TextSizeCard: View {
    @Bindable private var prefs = Prefs.shared

    var body: some View {
        PrefCard("In-app text size") {
            PrefStepper(value: $prefs.uiScale,
                        range: UIScaleRange.min...UIScaleRange.max,
                        step: UIScaleRange.step)
            PrefCaption("This sizes the app window only, meters and numbers included, and it stays this way next time you open the app. The floating overlays are below.")
        }
    }
}

/// THE OVERLAYS CARD: one switch, then EITHER two steppers OR one row per overlay. Never both — the
/// values that are not in force still exist and are still remembered, they are simply not what
/// anything is doing, so there is nothing to show for them.
private struct OverlaysAppearanceCard: View {
    @Environment(AppModel.self) private var model
    @Bindable private var prefs = Prefs.shared

    /// Whether each overlay's own switch is on. A row for one that is off says so, because pressing
    /// its stepper changes nothing on screen right now.
    private func isOpen(_ id: String) -> Bool {
        switch id {
        case OverlayID.meter: return model.overlayVisible
        case OverlayID.toast: return prefs.toastsEnabled
        case OverlayID.banner: return prefs.bannerEnabled
        case OverlayID.conCard: return prefs.conCardEnabled
        default: return false
        }
    }

    private var nothingOpen: Bool { OverlayID.all.allSatisfy { !isOpen($0) } }

    var body: some View {
        PrefCard("Overlays") {
            VStack(alignment: .leading, spacing: 4) {
                Toggle(isOn: $prefs.overlayIndependent) {
                    Text("Independent per overlay").foregroundStyle(Theme.text)
                }
                .toggleStyle(.switch).tint(Theme.gold)
                PrefCaption(independentCaption)
            }
            if prefs.overlayIndependent { perOverlayRows } else { sharedRows }
        }
    }

    /// The shared steppers' version of the `closed` tag: they govern all four at once, so the
    /// equivalent state is "none of them is open" — and there the honest answer to "what changes on
    /// screen when I press this" is "nothing yet". The value they set is what those windows open at.
    private var independentCaption: String {
        if prefs.overlayIndependent { return "Each overlay keeps its own text size and transparency." }
        let base = "All overlays share one text size and one transparency."
        return nothingOpen ? base + " None is open right now, so this is what they will open at." : base
    }

    private var sharedRows: some View {
        VStack(spacing: 6) {
            PrefRow(label: "Text size") {
                PrefStepper(value: $prefs.overlayTextScale,
                            range: OverlayScaleRange.min...OverlayScaleRange.max,
                            step: OverlayScaleRange.step)
            }
            PrefRow(label: "Transparency") {
                PrefStepper(value: gridded($prefs.overlayTransparency),
                            range: OverlayAlphaRange.min...OverlayAlphaRange.max,
                            step: OverlayAlphaRange.step, textSize: false)
            }
        }
    }

    /// TWO COLUMNS UNDER TWO HEADERS: the header does the naming, so the steppers' faces go plain.
    private var perOverlayRows: some View {
        VStack(alignment: .leading, spacing: 2) {
            columnHeaders
            ForEach(OverlayID.all, id: \.self) { id in
                if id == OverlayID.strips.first {
                    Text("These appear by themselves when something happens.")
                        .font(.caption).foregroundStyle(Theme.textDim)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6)
                }
                overlayRow(id)
            }
        }
    }

    private var columnHeaders: some View {
        HStack(spacing: 24) {
            Spacer()
            Text("Text size").font(.caption).foregroundStyle(Theme.textDim)
                .frame(width: 112, alignment: .center)
            Text("Opacity").font(.caption).foregroundStyle(Theme.textDim)
                .frame(width: 112, alignment: .center)
        }
    }

    private func overlayRow(_ id: String) -> some View {
        let open = isOpen(id)
        return HStack(spacing: 24) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(OverlayID.label(id)).foregroundStyle(Theme.text).opacity(open ? 1 : 0.7)
                if !open { Text("closed").font(.caption).foregroundStyle(Theme.textFaint) }
            }
            Spacer()
            PrefStepper(value: perOverlayScale(id),
                        range: OverlayScaleRange.min...OverlayScaleRange.max,
                        step: OverlayScaleRange.step, textSize: false)
                .frame(width: 112)
            PrefStepper(value: gridded(perOverlayAlpha(id)),
                        range: OverlayAlphaRange.min...OverlayAlphaRange.max,
                        step: OverlayAlphaRange.step, textSize: false)
                .frame(width: 112)
        }
    }

    // MARK: - The bindings

    /// One overlay's own text size, starting from the shared one it was last drawn at.
    private func perOverlayScale(_ id: String) -> Binding<Int> {
        Binding(get: { prefs.overlayTextScales[id] ?? prefs.overlayTextScale },
                set: { prefs.overlayTextScales[id] = $0 })
    }

    private func perOverlayAlpha(_ id: String) -> Binding<Int> {
        Binding(get: { prefs.overlayTransparencies[id] ?? prefs.overlayTransparency },
                set: { prefs.overlayTransparencies[id] = $0 })
    }

    /// A transparency stepper moves by CELLS on the 5% grid whatever the stored number is: the
    /// shared control hands us its arithmetic answer and we take only the direction from it.
    private func gridded(_ inner: Binding<Int>) -> Binding<Int> {
        Binding(get: { inner.wrappedValue },
                set: { proposed in
                    let cur = inner.wrappedValue
                    guard proposed != cur else { return }
                    inner.wrappedValue = OverlayAlphaRange.stepped(cur, up: proposed > cur)
                })
    }
}
