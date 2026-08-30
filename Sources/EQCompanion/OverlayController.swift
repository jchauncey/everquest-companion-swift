// The floating DPS meter, and the one place every overlay is brought up.
//
// The meter is a non-activating, always-on-top, transparent panel that never takes focus from the
// game and becomes click-through when locked. It joins every Space and full-screen auxiliary layer
// so it sits over a windowed or borderless game — all of that is `OverlayPanel` now, which the three
// strips share.
import AppKit
import SwiftUI
import Observation
import EQCompanionCore

@MainActor
final class OverlayController {
    static let shared = OverlayController()
    private var panel: OverlayPanel?
    private var model: AppModel?
    private var observing = false

    /// Called once, from the app's first window. Everything that floats starts here.
    func bind(_ model: AppModel) {
        self.model = model
        guard !observing else { return }
        observing = true
        Self.carryMeterFrameForward()
        panel = OverlayPanel(id: OverlayID.meter,
                             defaultRect: NSRect(x: 200, y: 200, width: 340, height: 220)) {
            OverlayMeterView().environment(model)
        }
        OverlayToastPanel.shared.start()
        AlertBanner.shared.start(model)
        ConCardOverlay.shared.start(model)
        CelebrationWatch.shared.start(model)
        // Last: the auto-hide rule, over every panel registered above.
        OverlayHost.shared.start()
        observe()
    }

    /// Re-arm observation on every change: `withObservationTracking` fires once per mutation.
    private func observe() {
        guard let model else { return }
        withObservationTracking {
            _ = model.overlayVisible
            _ = model.overlayLocked
        } onChange: {
            Task { @MainActor in
                self.apply()
                self.observe()
            }
        }
        apply()
    }

    private func apply() {
        guard let model, let panel else { return }
        // Locked means click-through, so the meter is MOVABLE exactly while it is unlocked.
        panel.movable = !model.overlayLocked
        panel.wanted = model.overlayVisible
    }

    /// The meter used to remember itself through AppKit's frame autosave. Its position moves to the
    /// key every overlay uses, once, so nobody's meter jumps on the upgrade.
    private static func carryMeterFrameForward() {
        let d = UserDefaults.standard
        let key = "overlay.\(OverlayID.meter).frame"
        guard d.string(forKey: key) == nil,
              let old = d.string(forKey: "NSWindow Frame eq.overlay.frame") else { return }
        let n = old.split(whereSeparator: \.isWhitespace).compactMap { Double($0) }
        guard n.count >= 4 else { return }
        d.set(NSStringFromRect(NSRect(x: n[0], y: n[1], width: n[2], height: n[3])), forKey: key)
    }
}
