// The mob card on con: con a creature and a card appears over the game with its level and what your
// logs know about its resists.
//
// SELF-CONTAINED BY LAW: everything the card draws is in the frame the engine sent. This window has
// no knowledge service, no ledger and no store, and a card that had to ask questions after it
// appeared would appear half-empty over a running game.
//
// THE NEXT CON REPLACES IT. The frame's `id` is the mob key, so re-conning the same creature
// refreshes the card that is up rather than stacking a second one — and either way the hold starts
// again.
//
// FIVE CHIPS, ALWAYS. "We have not seen fire cast on this" and "fire is fine" are different
// statements, and a missing chip says neither.
import AppKit
import SwiftUI
import Observation
import EQCompanionCore

@MainActor
@Observable
final class ConCardOverlay {
    static let shared = ConCardOverlay()

    private(set) var card: JSONValue?
    private var model: AppModel?
    private var started = false
    private var shownAt = Date.distantPast
    private var timer: Timer?
    private var panel: OverlayPanel?

    private init() {}

    func start(_ model: AppModel) {
        guard !started else { return }
        started = true
        self.model = model
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let rect = NSRect(x: screen.maxX - 360, y: screen.midY, width: 300, height: 180)
        panel = OverlayPanel(id: OverlayID.conCard, defaultRect: rect) { ConCardOverlayView() }
        watch()
        apply()
    }

    private func watch() {
        withObservationTracking {
            _ = model?.lastConCard
            _ = Prefs.shared.conCardEnabled
            _ = Prefs.shared.conCardMovable
        } onChange: {
            Task { @MainActor in
                self.take()
                self.apply()
                self.watch()
            }
        }
        take()
    }

    private func take() {
        guard let next = model?.lastConCard, Prefs.shared.conCardEnabled else { return }
        guard next["id"].string != card?["id"].string || next["at"].int64 != card?["at"].int64 else { return }
        card = next
        shownAt = Date()
        arm()
    }

    private func arm() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sweep() }
        }
    }

    private var pointerIsOver: Bool {
        guard let f = panel?.onScreenFrame else { return false }
        return f.contains(NSEvent.mouseLocation)
    }

    private func sweep() {
        if !pointerIsOver, Date().timeIntervalSince(shownAt) >= TimeInterval(max(1, Prefs.shared.conCardSeconds)) {
            card = nil
        }
        apply()
        if card == nil {
            timer?.invalidate()
            timer = nil
        }
    }

    func apply() {
        guard let panel else { return }
        let prefs = Prefs.shared
        if !prefs.conCardEnabled { card = nil }
        panel.movable = prefs.conCardMovable
        panel.wanted = prefs.conCardEnabled && (card != nil || prefs.conCardMovable)
    }
}

struct ConCardOverlayView: View {
    @State private var overlay = ConCardOverlay.shared
    private var scale: Double { OverlayLook.textScale(OverlayID.conCard) }

    var body: some View {
        Group {
            if let c = overlay.card { card(c) } else { outline }
        }
        .frame(width: 300 * scale)
        .padding(4)
    }

    private var outline: some View {
        Text("Mob card on con")
            .font(.system(size: 12 * scale, weight: .semibold))
            .foregroundStyle(Theme.textDim)
            .frame(maxWidth: .infinity)
            .padding(10 * scale)
            .background(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Theme.gold.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }

    private func card(_ c: JSONValue) -> some View {
        VStack(alignment: .leading, spacing: 4 * scale) {
            Text(c["name"].string ?? "")
                .font(.system(size: 14 * scale, weight: .bold))
                .foregroundStyle(Theme.gold)
                .lineLimit(1)
            if !subtitle(c).isEmpty {
                Text(subtitle(c)).font(.system(size: 11 * scale)).foregroundStyle(Theme.textDim)
            }
            Divider().overlay(Theme.border)
            if c["spellData"].bool == true {
                ForEach(Array((c["chips"].array ?? []).enumerated()), id: \.offset) { _, chip in
                    chipRow(chip)
                }
            } else {
                // The card says WHY rather than drawing five identical "not enough data" chips.
                Text("No resist guidance: this app could not read the client’s spell file.")
                    .font(.system(size: 11 * scale)).foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12 * scale).padding(.vertical, 9 * scale)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(Color.black.opacity(OverlayLook.backgroundAlpha(OverlayID.conCard))))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.gold.opacity(0.35), lineWidth: 1))
    }

    private func subtitle(_ c: JSONValue) -> String {
        var parts: [String] = []
        if let l = c["level"].int { parts.append("Level \(l)") }
        if c["rare"].bool == true { parts.append("rare creature") }
        if let z = c["zone"].string, !z.isEmpty { parts.append(z) }
        return parts.joined(separator: " · ")
    }

    /// One axis: the word, or the honest blank when nothing has been observed on it.
    private func chipRow(_ chip: JSONValue) -> some View {
        let axis = (chip["axis"].string ?? "").capitalized
        let tag = chip["tag"].string
        let n = chip["n"].int ?? 0
        return HStack(spacing: 6 * scale) {
            Text(axis).font(.system(size: 11 * scale)).foregroundStyle(Theme.text)
                .frame(width: 58 * scale, alignment: .leading)
            Text(tag ?? "not seen yet")
                .font(.system(size: 11 * scale, weight: tag == nil ? .regular : .semibold))
                .foregroundStyle(tag == nil ? Theme.textFaint : colour(tag ?? ""))
            Spacer(minLength: 0)
            if n > 0 {
                Text("\(n)").font(.system(size: 10 * scale).monospacedDigit()).foregroundStyle(Theme.textFaint)
            }
        }
    }

    private func colour(_ tag: String) -> Color {
        switch tag {
        case "weak": return Theme.green
        case "normal": return Theme.blue
        case "resistant": return Theme.orange
        case "very resistant": return Theme.red
        default: return Theme.text
        }
    }
}
