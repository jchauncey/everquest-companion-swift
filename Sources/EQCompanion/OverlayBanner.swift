// The alert banner: alerts marked "Show on screen" appear as large text over the game, then fade.
//
// THE NEWEST SITS AT THE BOTTOM and when the strip is full the oldest leaves — the reading order a
// chat window has, so the line you have not read yet is the one nearest where you were looking.
//
// POINT AT THE STRIP TO KEEP IT UP. The panel is click-through while "Move it" is off, so it is sent
// no hover events; the sweep asks the OS where the pointer is instead.
//
// EACH ALERT SAYS WHETHER IT APPEARS HERE: `showOnScreen` on the alert's own definition is the gate,
// and this window never invents a line for an alert that did not ask for one.
import AppKit
import SwiftUI
import Observation
import EQCompanionCore

/// One line on the strip.
struct BannerLine: Identifiable, Equatable {
    let id: String
    let text: String
    var at: Date = Date()
}

@MainActor
@Observable
final class AlertBanner {
    static let shared = AlertBanner()

    private(set) var lines: [BannerLine] = []
    private var model: AppModel?
    /// Fires already accounted for. Seeded from whatever is in hand at start, so a strip switched on
    /// mid-session does not replay the morning.
    private var seen: Set<String> = []
    private var started = false
    private var timer: Timer?
    private var panel: OverlayPanel?

    private init() {}

    func start(_ model: AppModel) {
        guard !started else { return }
        started = true
        self.model = model
        seen = Set(model.fires.map(\.id))
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let w: CGFloat = 520
        let rect = NSRect(x: screen.midX - w / 2, y: screen.maxY - 320, width: w, height: 140)
        panel = OverlayPanel(id: OverlayID.banner, defaultRect: rect) { AlertBannerView() }
        watch()
        apply()
    }

    /// Re-arm on every change: `withObservationTracking` fires once per mutation.
    private func watch() {
        withObservationTracking {
            _ = model?.fires
            _ = Prefs.shared.bannerEnabled
            _ = Prefs.shared.bannerMovable
            _ = Prefs.shared.bannerLines
        } onChange: {
            Task { @MainActor in
                self.take()
                self.apply()
                self.watch()
            }
        }
        take()
    }

    /// Every fire this window has not shown yet, oldest first so the newest ends up at the bottom.
    private func take() {
        guard let model else { return }
        let fresh = model.fires.filter { !seen.contains($0.id) }.reversed()
        for f in fresh {
            seen.insert(f.id)
            guard let def = model.alerts.def(named: f.rule), def.showOnScreen else { continue }
            let text = def.bannerText.isEmpty ? (f.message.isEmpty ? f.rule : f.message) : def.bannerText
            guard Prefs.shared.bannerEnabled else { continue }
            lines.append(BannerLine(id: f.id, text: text))
        }
        trim()
        if !lines.isEmpty { arm() }
    }

    /// When the strip is full the oldest one leaves.
    private func trim() {
        let cap = max(1, Prefs.shared.bannerLines)
        if lines.count > cap { lines.removeFirst(lines.count - cap) }
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
        if !pointerIsOver {
            let hold = TimeInterval(max(1, Prefs.shared.bannerLineSeconds))
            let now = Date()
            let kept = lines.filter { now.timeIntervalSince($0.at) < hold }
            if kept.count != lines.count { lines = kept }
        }
        apply()
        if lines.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }

    func apply() {
        guard let panel else { return }
        let prefs = Prefs.shared
        if !prefs.bannerEnabled { lines.removeAll() }
        trim()
        panel.movable = prefs.bannerMovable
        panel.wanted = prefs.bannerEnabled && (!lines.isEmpty || prefs.bannerMovable)
    }
}

struct AlertBannerView: View {
    @State private var banner = AlertBanner.shared
    private var scale: Double { OverlayLook.textScale(OverlayID.banner) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3 * scale) {
            if banner.lines.isEmpty {
                Text("Alert banner")
                    .font(.system(size: 12 * scale, weight: .semibold))
                    .foregroundStyle(Theme.textDim)
                    .frame(maxWidth: .infinity)
                    .padding(10 * scale)
                    .background(RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Theme.gold.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            }
            ForEach(banner.lines) { line in
                Text(line.text)
                    .font(.system(size: 20 * scale, weight: .heavy))
                    .foregroundStyle(Theme.gold)
                    .shadow(color: .black.opacity(0.9), radius: 2)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10 * scale).padding(.vertical, 5 * scale)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(Color.black.opacity(OverlayLook.backgroundAlpha(OverlayID.banner))))
            }
        }
        .frame(width: 520 * scale)
        .padding(4)
    }
}
