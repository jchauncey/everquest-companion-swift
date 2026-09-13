// The floating windows' shared body. One non-activating panel per overlay: always on top, on every
// Space, never taking focus from the game, and click-through unless its "Move it" switch is on.
//
// HIDE, NEVER CLOSE. Auto-hide orders a panel out and back in. It keeps its position, size and lock
// - nothing is closed, and the switch that opened it is untouched.
//
// THE LOOK COMES FROM PREFERENCES, read at draw time: Appearance → Overlays owns the text size and
// the transparency, per overlay when its Independent switch is on and shared when it is off.
import AppKit
import SwiftUI
import Observation

/// The four floating windows, by the id their size and transparency are stored under.
enum OverlayID {
    static let meter = "meter"
    static let toast = "toast"
    static let banner = "banner"
    static let conCard = "conCard"

    /// The order Appearance → Overlays lists them in: the window you open, then the three strips
    /// that appear by themselves when something happens.
    static let all = [meter, toast, banner, conCard]

    /// Where the strips start in `all` - the seam the per-overlay list draws its caption across.
    static let strips = [toast, banner, conCard]

    static func label(_ id: String) -> String {
        switch id {
        case meter: return "Damage meter"
        case toast: return "Celebration toasts"
        case banner: return "Alert banner"
        case conCard: return "Mob card on con"
        default: return id
        }
    }
}

/// What Appearance → Overlays says one window should look like right now.
enum OverlayLook {
    /// 1.0 at 100%. Every size an overlay draws is multiplied by this.
    static func textScale(_ id: String) -> Double {
        Double(Prefs.shared.overlayTextScale(for: id)) / 100
    }

    /// The background's opacity, 1 when Overlays → "Give floating overlays a solid background" is on.
    static func backgroundAlpha(_ id: String) -> Double {
        Prefs.shared.overlaySolidBackground ? 1 : Double(Prefs.shared.overlayTransparency(for: id)) / 100
    }
}

/// One overlay window. The owner says whether it WANTS to be on screen; auto-hide decides whether it
/// is, and the two are different questions.
@MainActor
final class OverlayPanel {
    let id: String
    private let defaultRect: NSRect
    private let content: () -> AnyView
    private var panel: NSPanel?
    private var mover: Any?

    /// The owner's answer: the card's on switch, or a message being on screen.
    var wanted = false { didSet { if wanted != oldValue { apply() } } }
    /// "Move it": the panel draws a drag outline and stops passing clicks through.
    var movable = false { didSet { if movable != oldValue { apply() } } }

    init<Content: View>(id: String, defaultRect: NSRect, @ViewBuilder content: @escaping () -> Content) {
        self.id = id
        self.defaultRect = defaultRect
        self.content = { AnyView(content()) }
        OverlayHost.shared.register(self)
    }

    /// Where this window was left. Written on every move, so a panel that is ordered out and back in
    /// comes up where the player put it.
    private var frameKey: String { "overlay.\(id).frame" }

    private func savedOrigin() -> NSPoint? {
        guard let s = UserDefaults.standard.string(forKey: frameKey) else { return nil }
        let r = NSRectFromString(s)
        return r.size.width > 0 ? r.origin : nil
    }

    private func saveFrame() {
        guard let p = panel else { return }
        UserDefaults.standard.set(NSStringFromRect(p.frame), forKey: frameKey)
    }

    private func make() -> NSPanel {
        let p = NSPanel(contentRect: defaultRect,
                        styleMask: [.nonactivatingPanel, .borderless, .utilityWindow],
                        backing: .buffered, defer: false)
        p.level = Self.level(gameInFront: GamePresence.shared.isFrontmost)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.isMovableByWindowBackground = true
        p.becomesKeyOnlyIfNeeded = true
        p.isFloatingPanel = true
        p.titleVisibility = .hidden
        let host = NSHostingView(rootView: content())
        host.sizingOptions = [.preferredContentSize]
        p.contentView = host
        if let o = savedOrigin() { p.setFrameOrigin(o) }
        mover = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: p,
                                                       queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveFrame() }
        }
        return p
    }

    /// Where the window is right now, when it is on screen — what a strip that has to ASK where the
    /// pointer is tests against, because a click-through panel is sent no hover events.
    var onScreenFrame: NSRect? {
        guard let p = panel, p.isVisible else { return nil }
        return p.frame
    }

    /// Click-through is for the GAME's benefit, so it applies only while the game (or anything
    /// else) is in front. When EQ Companion itself is the active app, a locked panel takes
    /// clicks again — otherwise the lock button that locked it could never unlock it, and the
    /// only way back was a menu shortcut advertised by a tooltip the lock made unhoverable.
    /// Locked stays NOT draggable either way: clickable-while-active must not mean movable.
    static func clickThrough(movable: Bool, appActive: Bool) -> Bool {
        !movable && !appActive
    }

    /// How high the panel floats. `.floating` (3) clears every ordinary window, and
    /// `.fullScreenAuxiliary` lets it join a native full-screen Space - but the game is not native.
    /// Wine's Mac driver puts an ACTIVE FULL-SCREEN window at main-menu+1 (25), so a panel at 3 is on
    /// screen, ordered front, and entirely behind the game. While the game is in front the panel
    /// rides above that (`.popUpMenu`, 101: above the menu bar's neighbourhood, below the screen
    /// saver and system alerts); the moment anything else is, it drops back to `.floating` so it
    /// never sits over another app's menus or dialogs. Pure, so the rule can be stated in a test.
    static func level(gameInFront: Bool) -> NSWindow.Level {
        gameInFront ? .popUpMenu : .floating
    }

    /// On screen exactly when the owner wants it and auto-hide is not taking it away.
    func apply() {
        if wanted && !OverlayHost.suppressed {
            let p = panel ?? make()
            panel = p
            p.level = Self.level(gameInFront: GamePresence.shared.isFrontmost)
            p.ignoresMouseEvents = Self.clickThrough(movable: movable, appActive: NSApp.isActive)
            p.isMovableByWindowBackground = movable
            p.orderFrontRegardless()
        } else {
            panel?.orderOut(nil)
        }
    }
}

/// The panels, and the one rule that applies to all of them.
@MainActor
final class OverlayHost {
    static let shared = OverlayHost()
    private var panels: [OverlayPanel] = []
    private var observing = false

    func register(_ p: OverlayPanel) { panels.append(p) }

    /// Should every overlay be off screen right now? Preferences → Overlays, against what the OS
    /// says about the game.
    static var suppressed: Bool {
        let prefs = Prefs.shared
        let game = GamePresence.shared
        if prefs.hideOverlaysWhenGameClosed && !game.isRunning { return true }
        if prefs.hideOverlaysWhenGameUnfocused && !game.isFrontmost { return true }
        return false
    }

    /// Poll the game and re-arm on every change: `withObservationTracking` fires once per mutation.
    func start() {
        guard !observing else { return }
        observing = true
        GamePresence.shared.start()
        watch()
        // Activation flips the click-through answer (see `OverlayPanel.clickThrough`), and AppKit
        // does not re-ask — so every panel re-applies on both edges.
        for name in [NSApplication.didBecomeActiveNotification,
                     NSApplication.didResignActiveNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    for p in OverlayHost.shared.panels { p.apply() }
                }
            }
        }
    }

    private func watch() {
        withObservationTracking {
            _ = GamePresence.shared.isRunning
            _ = GamePresence.shared.isFrontmost
            _ = Prefs.shared.hideOverlaysWhenGameClosed
            _ = Prefs.shared.hideOverlaysWhenGameUnfocused
        } onChange: {
            Task { @MainActor in
                for p in self.panels { p.apply() }
                self.watch()
            }
        }
    }
}
