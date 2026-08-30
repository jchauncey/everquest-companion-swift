// The Preferences vocabulary — the upstream PrefSectionBlock / PrefStepper / toggle-with-caption
// rows, drawn in the app's theme: a dark card per setting, a gold accent, captions in dim text.
import SwiftUI
import AppKit

/// One page in the sidebar. `sections` is what the search box matches (label + keywords).
struct PrefPage: Identifiable {
    let id: String
    let label: String
    let icon: String
    let sections: [PrefSectionInfo]
    let body: () -> AnyView
}

struct PrefSectionInfo: Identifiable {
    let id: String
    let label: String
    let keywords: String
}

/// The upper-case dim heading above a page's cards ("APPEARANCE").
struct PrefPageHeading: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold)).kerning(1.2)
            .foregroundStyle(Theme.textDim)
            .padding(.bottom, 2)
    }
}

/// A titled card holding one setting or one small group of them.
struct PrefCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    init(_ title: String, @ViewBuilder content: @escaping () -> Content) { self.title = title; self.content = content }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.body.weight(.medium)).foregroundStyle(Theme.text)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.paper))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
    }
}

/// Dim explanatory text under a control.
struct PrefCaption: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.caption).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
    }
}

/// A toggle with its label beside it and a caption that changes with the state.
struct PrefToggle: View {
    let label: String
    @Binding var isOn: Bool
    var captionOn: String? = nil
    var captionOff: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: $isOn) { Text(label).foregroundStyle(Theme.text) }
                .toggleStyle(.switch).tint(Theme.gold)
            if let c = isOn ? captionOn : captionOff { PrefCaption(c) }
        }
    }
}

/// `A−  100%  A+` (text sizes) or `−  72%  +` (percentages). Steps and clamps.
struct PrefStepper: View {
    @Binding var value: Int
    var range: ClosedRange<Int>
    var step: Int = 10
    var textSize: Bool = true
    var suffix: String = "%"
    var body: some View {
        HStack(spacing: 10) {
            button(textSize ? "A−" : "−") { value = max(range.lowerBound, value - step) }
                .disabled(value <= range.lowerBound)
            Text("\(value)\(suffix)").font(.body.monospacedDigit()).foregroundStyle(Theme.text).frame(minWidth: 44)
            button(textSize ? "A+" : "+") { value = min(range.upperBound, value + step) }
                .disabled(value >= range.upperBound)
        }
    }
    private func button(_ t: String, _ f: @escaping () -> Void) -> some View {
        Button(action: f) { Text(t).font(.caption.weight(.bold)).frame(minWidth: 24) }
            .buttonStyle(.plain).foregroundStyle(Theme.text)
    }
}

/// A labelled row whose control sits at the trailing edge ("Text size … A− 100% A+").
struct PrefRow<Control: View>: View {
    let label: String
    @ViewBuilder let control: () -> Control
    var body: some View {
        HStack {
            Text(label).foregroundStyle(Theme.text)
            Spacer()
            control()
        }
    }
}

/// The upstream outlined / filled "CHOOSE FOLDER…" buttons.
struct PrefButton: View {
    let title: String
    var icon: String? = nil
    var filled: Bool = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let i = icon { Image(systemName: i) }
                Text(title.uppercased()).font(.caption.weight(.semibold)).kerning(0.6)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .foregroundStyle(filled ? Color.black.opacity(0.85) : Theme.gold)
            .background(RoundedRectangle(cornerRadius: 6).fill(filled ? Theme.gold : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.gold.opacity(filled ? 0 : 0.6), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// A small pill chip ("manual", "stated by /who").
struct PrefChip: View {
    let text: String
    var color: Color = Theme.blue
    var body: some View {
        Text(text).font(.caption)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .foregroundStyle(color)
            .overlay(Capsule().stroke(color.opacity(0.7), lineWidth: 1))
    }
}

/// A labelled slider with the value in the label ("Size (44px)").
struct PrefSlider: View {
    let label: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double = 1
    var format: (Double) -> String = { String(Int($0.rounded())) }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(label) (\(format(value)))").font(.caption).foregroundStyle(Theme.textDim)
            Slider(value: $value, in: range, step: step).tint(Theme.gold)
        }
    }
}

/// A labelled popup ("A line stays for  [4 seconds ▾]").
struct PrefSelect<T: Hashable>: View {
    let label: String
    @Binding var selection: T
    let options: [(T, String)]
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(Theme.textDim)
            Picker("", selection: $selection) {
                ForEach(Array(options.enumerated()), id: \.offset) { _, o in Text(o.1).tag(o.0) }
            }
            .labelsHidden().frame(maxWidth: 220)
        }
    }
}

/// A monospaced path line, selectable.
struct PrefPath: View {
    let label: String
    let path: String
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).foregroundStyle(Theme.textDim)
            Text(path).font(.caption.monospaced()).foregroundStyle(Theme.text).textSelection(.enabled)
                .lineLimit(2).truncationMode(.middle)
        }
    }
}

/// A green/amber/red status line with an icon ("✓ Found 1 character log in this folder.").
struct PrefStatus: View {
    enum Tone { case ok, warn, bad }
    let tone: Tone
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: tone == .ok ? "checkmark.circle" : tone == .warn ? "exclamationmark.triangle" : "xmark.circle")
                .foregroundStyle(tone == .ok ? Theme.green : tone == .warn ? Theme.orange : Theme.red)
            Text(text).foregroundStyle(Theme.text)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill((tone == .ok ? Theme.green : tone == .warn ? Theme.orange : Theme.red).opacity(0.08)))
    }
}

extension Color {
    /// "#RRGGBB" → Color; nil when malformed.
    init?(hexString: String) {
        var s = hexString.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }
}
