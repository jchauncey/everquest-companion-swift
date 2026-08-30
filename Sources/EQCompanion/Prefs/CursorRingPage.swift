// Preferences → Cursor ring.
//
// A thick circle that follows the mouse, drawn ONLY over the EverQuest window (owner request:
// "I lose my mouse on EQ screens"). Off by default; the toggle is the only thing that makes it
// exist. It is white until the player picks another colour, and the default is the old colour
// exactly, so nobody's ring changes by upgrading.
//
// THE NOTE ABOUT SCOPE IS NOT DECORATION. "Only over EverQuest" is the single most surprising thing
// about this feature — a user who turns it on while reading Preferences sees nothing happen, and
// without that line would reasonably conclude it is broken. It states WHERE the ring is.
//
// Every control here is live: CursorRing observes these settings, so dragging a slider resizes the
// halo under the pointer and picking a colour recolours it, instead of on the next restart.
import SwiftUI
import AppKit

extension PrefPages {
    static let cursorRing = PrefPage(id: "cursorRing", label: "Cursor ring", icon: "circle.circle", sections: [
        PrefSectionInfo(id: "cursor-ring", label: "Cursor ring",
                        keywords: "cursor mouse pointer ring circle halo highlight find lost locate ultimate size thickness white color colour picker")
    ]) { AnyView(CursorRingPage()) }
}

struct CursorRingPage: View {
    @Bindable private var prefs = Prefs.shared

    var body: some View {
        PrefCard("Cursor ring") {
            PrefToggle(
                label: "Show a ring around your mouse cursor",
                isOn: $prefs.cursorRingEnabled,
                captionOn: "A ring follows your pointer so you can find it on a busy screen. Your real cursor is untouched - the ring never gets in the way of a click.",
                captionOff: "Off. Nothing is drawn and nothing is tracked."
            )
            HStack(alignment: .center, spacing: 24) {
                PrefSlider(label: "Size", value: sizeBinding,
                           range: Double(CursorRingLimits.minSize)...Double(CursorRingLimits.maxSize),
                           step: 2, format: { "\(Int($0.rounded()))px" })
                    .frame(width: 180)
                PrefSlider(label: "Thickness", value: thicknessBinding,
                           range: Double(CursorRingLimits.minThickness)...Double(CursorRingLimits.maxThickness),
                           step: 1, format: { "\(Int($0.rounded()))px" })
                    .frame(width: 180)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Color").font(.caption).foregroundStyle(Theme.textDim)
                    ColorPicker("", selection: colorBinding, supportsOpacity: false).labelsHidden()
                }
                RingPreview(size: CursorRingLimits.clampSize(prefs.cursorRingSize), thickness: thickness, color: color)
                Spacer(minLength: 0)
            }
            PrefCaption("The ring only appears over EverQuest, while the game is the window you’re in.")
        }
        // Idempotent: the ring's own bootstrap runs at launch, and calling it here means the toggle
        // works even on a page opened before anything else has touched the ring.
        .task { CursorRing.bootstrap() }
    }

    // MARK: - Bindings

    /// The stroke can never exceed half the diameter, so shrinking the ring pulls it down with it —
    /// the same clamp the ring itself draws with, applied where the number is chosen.
    private var thickness: Int {
        CursorRingLimits.clampThickness(prefs.cursorRingThickness, size: prefs.cursorRingSize)
    }

    private var color: Color { Color(hexString: prefs.cursorRingColor) ?? .white }

    private var sizeBinding: Binding<Double> {
        Binding(get: { Double(CursorRingLimits.clampSize(prefs.cursorRingSize)) },
                set: { new in
                    let size = CursorRingLimits.clampSize(Int(new.rounded()))
                    prefs.cursorRingSize = size
                    let clamped = CursorRingLimits.clampThickness(prefs.cursorRingThickness, size: size)
                    if clamped != prefs.cursorRingThickness { prefs.cursorRingThickness = clamped }
                })
    }

    private var thicknessBinding: Binding<Double> {
        Binding(get: { Double(thickness) },
                set: { prefs.cursorRingThickness = CursorRingLimits.clampThickness(Int($0.rounded()), size: prefs.cursorRingSize) })
    }

    private var colorBinding: Binding<Color> {
        Binding(get: { color }, set: { prefs.cursorRingColor = hexString(of: $0) })
    }
}

/// A small live sample of the ring, so the sliders describe something you can see without
/// alt-tabbing into the game. Same three shadows as the real thing (CursorRing.swift).
///
/// IT IS A SAMPLE, NOT A RULER. This card is drawn in the main window, which carries the app's text
/// size, while the ring window draws in screen points — so at 125% this circle is wider on screen
/// than the halo the game gets. Left alone on purpose: a preview that shrank while the labels beside
/// it grew would read as broken, and the number being chosen is on the slider's own label.
private struct RingPreview: View {
    let size: Int
    let thickness: Int
    let color: Color

    var body: some View {
        ZStack {
            Circle().strokeBorder(Color.black.opacity(0.28), lineWidth: 4)
                .frame(width: CGFloat(size) + 4, height: CGFloat(size) + 4)
                .blur(radius: 5)
            Circle().strokeBorder(Color.black.opacity(0.6), lineWidth: 1)
                .frame(width: CGFloat(size) + 1, height: CGFloat(size) + 1)
            Circle().strokeBorder(color.opacity(cursorRingStrokeAlpha), lineWidth: CGFloat(thickness))
                .frame(width: CGFloat(size), height: CGFloat(size))
            Circle().strokeBorder(Color.black.opacity(0.6), lineWidth: 1)
                .frame(width: max(0, CGFloat(size - thickness * 2) - 1), height: max(0, CGFloat(size - thickness * 2) - 1))
        }
        .frame(width: CGFloat(size) + 8, height: CGFloat(size) + 8)
    }
}

/// A SwiftUI colour back to the "#RRGGBB" the setting is stored as — the other half of
/// `Color(hexString:)`. sRGB, because that is the space the hex names; a colour that cannot be
/// converted keeps the ring's default rather than storing something the parser would refuse.
func hexString(of color: Color) -> String {
    guard let c = NSColor(color).usingColorSpace(.sRGB) else { return "#FFFFFF" }
    func byte(_ v: CGFloat) -> Int { max(0, min(255, Int((v * 255).rounded()))) }
    return String(format: "#%02X%02X%02X", byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent))
}
