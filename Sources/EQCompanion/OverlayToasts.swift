// The celebration strip: a card slides in at the top of the screen when you drop a raid target or
// finish a Plane of Sky quest, then fades.
//
// SELF-CONTAINED BY LAW, the contract every strip in this app keeps: the panel fetches nothing.
// Everything a card draws is in the `Toast` it was handed.
//
// POINT AT IT TO KEEP IT UP, and the pointer is READ rather than received: the panel is
// click-through while "Move it" is off, so it gets no hover events — the sweep asks the OS where the
// mouse is instead. That is also why a card is not a click target: a click there belongs to the game.
//
// EXACTLY ONCE PER LIVE TRANSITION. Both watches seed a SILENT baseline on their first reading and
// reset it whenever the epoch bumps, because a new fold replays the whole log — every boss you ever
// killed and every quest you ever turned in arrives again, and none of it just happened.
import AppKit
import SwiftUI
import Observation
import EQCompanionCore

/// One celebration, as the strip draws it.
struct Toast: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String?
    /// When it arrived; it leaves `Toasts.holdSeconds` later unless the pointer is on the strip.
    var at: Date = Date()
}

/// The cards on screen, and the one door anything else uses to add one.
@MainActor
@Observable
final class Toasts {
    static let shared = Toasts()

    /// How long a card holds before it leaves. A timing constant with a good default: the strip
    /// stays up under the pointer anyway, so there is nothing here worth a preference.
    static let holdSeconds: TimeInterval = 6
    /// Cards on screen at once. Beyond a handful the strip stops being a glance.
    static let maxCards = 3

    private(set) var cards: [Toast] = []
    private var timer: Timer?

    /// THE ONE DOOR. A repeat id refreshes the card already on screen rather than stacking a second.
    static func show(title: String, subtitle: String? = nil, id: String? = nil) {
        shared.add(Toast(id: id ?? "\(title)|\(Date().timeIntervalSince1970)", title: title, subtitle: subtitle))
    }

    func add(_ card: Toast) {
        guard Prefs.shared.toastsEnabled else { return }
        if let i = cards.firstIndex(where: { $0.id == card.id }) {
            cards[i] = card
        } else {
            cards.append(card)
            if cards.count > Self.maxCards { cards.removeFirst(cards.count - Self.maxCards) }
        }
        OverlayToastPanel.shared.apply()
        arm()
    }

    /// Switching the card off takes what is on screen with it.
    func clear() {
        guard !cards.isEmpty else { return }
        cards.removeAll()
    }

    /// Runs only while there is something on screen.
    private func arm() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sweep() }
        }
    }

    private func sweep() {
        if OverlayToastPanel.shared.pointerIsOver { return }
        let now = Date()
        let kept = cards.filter { now.timeIntervalSince($0.at) < Self.holdSeconds }
        if kept.count != cards.count {
            cards = kept
            OverlayToastPanel.shared.apply()
        }
        if cards.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }
}

/// The strip's window: top centre of the main screen until it is dragged somewhere else.
@MainActor
final class OverlayToastPanel {
    static let shared = OverlayToastPanel()
    private var panel: OverlayPanel?

    private init() {}

    func start() {
        guard panel == nil else { return }
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let w: CGFloat = 400
        let rect = NSRect(x: screen.midX - w / 2, y: screen.maxY - 160, width: w, height: 120)
        panel = OverlayPanel(id: OverlayID.toast, defaultRect: rect) { ToastStripView() }
        watch()
        apply()
    }

    /// Is the pointer on the strip? Asked rather than received — a click-through panel has no hover.
    var pointerIsOver: Bool {
        guard let f = panel?.onScreenFrame else { return false }
        return f.contains(NSEvent.mouseLocation)
    }

    func apply() {
        guard let panel else { return }
        let prefs = Prefs.shared
        panel.movable = prefs.toastsMovable
        // The outline has to be reachable with nothing on screen, or a strip you have never seen
        // fire could never be placed.
        panel.wanted = prefs.toastsEnabled && (!Toasts.shared.cards.isEmpty || prefs.toastsMovable)
    }

    private func watch() {
        withObservationTracking {
            _ = Prefs.shared.toastsEnabled
            _ = Prefs.shared.toastsMovable
        } onChange: {
            Task { @MainActor in
                if !Prefs.shared.toastsEnabled { Toasts.shared.clear() }
                self.apply()
                self.watch()
            }
        }
    }
}

struct ToastStripView: View {
    @State private var toasts = Toasts.shared
    private var scale: Double { OverlayLook.textScale(OverlayID.toast) }

    var body: some View {
        VStack(spacing: 6 * scale) {
            if toasts.cards.isEmpty {
                // The drag outline: what "Move it" gives you to aim at.
                Text("Celebration toasts")
                    .font(.system(size: 12 * scale, weight: .semibold))
                    .foregroundStyle(Theme.textDim)
                    .frame(maxWidth: .infinity)
                    .padding(10 * scale)
                    .background(RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Theme.gold.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            }
            ForEach(toasts.cards) { card in
                VStack(alignment: .leading, spacing: 2 * scale) {
                    Text(card.title)
                        .font(.system(size: 14 * scale, weight: .bold))
                        .foregroundStyle(Theme.gold)
                    if let s = card.subtitle, !s.isEmpty {
                        Text(s).font(.system(size: 11 * scale)).foregroundStyle(Theme.text)
                    }
                }
                .padding(.horizontal, 12 * scale).padding(.vertical, 9 * scale)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(OverlayLook.backgroundAlpha(OverlayID.toast))))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.gold.opacity(0.35), lineWidth: 1))
            }
        }
        .frame(width: 400 * scale)
        .padding(4)
    }
}

// MARK: - What the celebrations ride on

/// The two always-mounted watches: a raid target you got credit for, and a Plane of Sky quest
/// turning in. Both are LIVE-ONLY by construction — the baseline is seeded silently on the first
/// reading of each epoch, so a startup replay of a month of logs celebrates nothing.
@MainActor
final class CelebrationWatch {
    static let shared = CelebrationWatch()
    private var model: AppModel?
    private var epoch: Int?
    /// target name → tier → credited kills. `nil` until the first reading of this epoch.
    private var bossBaseline: [String: [Int: Int]]?
    /// quest key → turn-ins the log itself detected.
    private var questBaseline: [String: Int]?
    private let sky = SkyStore()
    private var reading = false

    private init() {}

    func start(_ model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
        watch()
    }

    private func watch() {
        withObservationTracking {
            _ = model?.epoch
            _ = model?.launchPhase
            _ = model?.moduleSeqs["kills"]
            _ = model?.moduleSeqs["turnins"]
        } onChange: {
            Task { @MainActor in
                self.read()
                self.watch()
            }
        }
        read()
    }

    private func read() {
        guard let model, model.client.isReady, !reading else { return }
        // Nothing is read until the fold is live. During catch-up `module.snapshot` answers with the
        // prefix folded so far (or not at all), and a baseline taken from it makes every later kill
        // and turn-in in the history look new the moment the fold lands.
        guard model.launchPhase == .live else { return }
        if epoch != model.epoch {
            // A new world: everything it is about to report already happened.
            epoch = model.epoch
            bossBaseline = nil
            questBaseline = nil
        }
        reading = true
        Task { @MainActor in
            defer { self.reading = false }
            await self.readKills(model)
            await self.readQuests(model)
        }
    }

    private func readKills(_ model: AppModel) async {
        guard let r = try? await model.client.request(Op.moduleSnapshot, ["module": .string("kills")], deadline: 15) else { return }
        var next: [String: [Int: Int]] = [:]
        for s in BossStatus.all(r["state"]) {
            next[s.target.name] = s.tiers.mapValues(\.credited)
        }
        defer { bossBaseline = next }
        guard let was = bossBaseline else { return }
        for (name, tiers) in next {
            for (tier, credited) in tiers where credited > (was[name]?[tier] ?? 0) {
                // THE TIER OF THIS KILL, not the target's all-time best: a Sunday D1 kill announced
                // as "D4 · Refined" is a false sentence on a per-event card.
                let zone = GameData.shared.raidTargets.first { $0["name"].string == name }?["zone"].string
                let sub = [RaidTier.style(tier).long, zone].compactMap { $0 }.joined(separator: " · ")
                Toasts.show(title: "\(name) defeated", subtitle: sub, id: "boss:\(name):\(tier):\(credited)")
            }
        }
    }

    private func readQuests(_ model: AppModel) async {
        await sky.refresh(model)
        if sky.lastRefreshFailed { return }
        var next: [String: Int] = [:]
        for q in sky.quests { next[q.key] = q.logTurnIns }
        defer { questBaseline = next }
        guard let was = questBaseline else { return }
        for q in sky.quests where q.logTurnIns > (was[q.key] ?? 0) {
            let sub = q.giver.map { "\(q.className) · turned in to \($0)" } ?? q.className
            Toasts.show(title: "Quest complete: \(q.name)", subtitle: sub,
                        id: "quest:\(q.key)#\(q.logTurnIns)")
        }
    }
}
