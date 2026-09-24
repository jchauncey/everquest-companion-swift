// The look: the Electron app's palette, verbatim (src/renderer/src/theme/theme.ts) — charcoal
// backgrounds, a muted gold primary, a sky-blue secondary. Every surface reads these tokens.
import SwiftUI

enum Theme {
    static let background = Color(hex: 0x0f1115)
    static let paper = Color(hex: 0x171a21)
    static let paperRaised = Color(hex: 0x1d2129)
    static let border = Color.white.opacity(0.08)
    static let gold = Color(hex: 0xd9b25f)
    static let goldDim = Color(hex: 0xd9b25f).opacity(0.65)
    static let blue = Color(hex: 0x6fb3d2)
    static let green = Color(hex: 0x5fbf72)
    static let orange = Color(hex: 0xe0a94a)
    static let red = Color(hex: 0xd45f5f)
    static let purple = Color(hex: 0x9b8cf0)
    static let text = Color.white.opacity(0.92)
    static let textDim = Color.white.opacity(0.6)
    static let textFaint = Color.white.opacity(0.4)

    /// The meter bar colour by attribution kind — the Combat tab's and the overlay's one map.
    static func kind(_ kind: String) -> Color {
        switch kind {
        case "you": return gold
        case "pet": return blue
        case "member": return green
        case "allyPet": return Color(hex: 0x7fd6c2)
        case "enemy": return Color(hex: 0xb05a6a)
        default: return Color.gray
        }
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255,
                  opacity: alpha)
    }
}

/// A card: the app's `paper` surface with a hairline border and a small caps title.
struct Card<Content: View>: View {
    var title: String?
    var trailing: AnyView?
    @ViewBuilder var content: () -> Content

    init(_ title: String? = nil, trailing: AnyView? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.trailing = trailing
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if title != nil || trailing != nil {
                HStack {
                    if let t = title {
                        Text(t.uppercased()).font(.caption.weight(.bold)).tracking(0.8).foregroundStyle(Theme.textDim)
                    }
                    Spacer()
                    if let tr = trailing { tr }
                }
            }
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.paper))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
    }
}

/// A small outlined chip: `beta`, `1 active · 37 tracked`, a class abbreviation.
struct Chip: View {
    var text: String
    var color: Color = Theme.textDim
    var filled = false

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(filled ? Theme.background : color)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(filled ? color : Color.clear))
            .overlay(Capsule().stroke(color.opacity(filled ? 0 : 0.6)))
    }
}

/// The gold segmented control the Electron app uses for scope toggles.
struct SegmentPicker<T: Hashable>: View {
    @Binding var selection: T
    var options: [(T, String)]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, o in
                Button { selection = o.0 } label: {
                    Text(o.1)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .foregroundStyle(selection == o.0 ? Theme.gold : Theme.textDim)
                        .background(selection == o.0 ? Theme.gold.opacity(0.14) : Color.clear)
                }
                .buttonStyle(.plain)
            }
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.paperRaised))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border))
    }
}

/// A gold-accented outlined button, the Electron app's secondary action style.
struct OutlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.semibold))
            .textCase(.uppercase)
            .foregroundStyle(Theme.gold)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.gold.opacity(configuration.isPressed ? 0.25 : 0.08)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.gold.opacity(0.5)))
    }
}

/// A big numeric tile with a caption, coloured by its border — the Leveling tab's headline row.
struct BigStat: View {
    var value: String
    var label: String
    var sub: String? = nil
    var color: Color = Theme.gold
    var icon: String? = nil

    var body: some View {
        AccentCard(color: color, icon: icon) {
            Text(value).font(.system(size: 30, weight: .semibold)).foregroundStyle(color).monospacedDigit()
            Text(label).font(.callout).foregroundStyle(Theme.text)
            if let s = sub { Text(s).font(.caption).foregroundStyle(Theme.textDim) }
        }
    }
}

/// BigStat's frame for any content: the accent-coloured border and left bar, the icon beside a
/// leading column. For a headline card whose body is more than a value and two lines.
struct AccentCard<Content: View>: View {
    var color: Color = Theme.gold
    var icon: String? = nil
    /// Stretch to the height offered — so a row of cards can be one height (the row sized to its
    /// tallest with `fixedSize(horizontal: false, vertical: true)`).
    var fill = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if let i = icon { Image(systemName: i).foregroundStyle(color).font(.title2).padding(.top, 4) }
            VStack(alignment: .leading, spacing: 2) { content() }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: fill ? .infinity : nil, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.paper))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(color.opacity(0.5), lineWidth: 1))
        .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 3).padding(.vertical, 10) }
    }
}
