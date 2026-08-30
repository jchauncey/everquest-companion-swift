// The cursor ring: a thick circle that follows the mouse, drawn ONLY while EverQuest is the window
// the player is in (owner request: "I lose my mouse on EQ screens"). Off by default; the toggle in
// Preferences is the only thing that makes it exist.
//
// THE REAL CURSOR IS NEVER TOUCHED. This is a borderless, transparent, non-activating panel that
// ignores every mouse event, so the pointer the player aims with is exactly where it always was —
// the ring can never make the mouse itself feel heavy.
//
// NEWEST POINT WINS. The panel is created once and sized only when a setting changes; a mouse move
// costs one `setFrameOrigin`. Nothing is queued, so a burst of samples cannot become a ring
// replaying where the mouse used to be.
import AppKit
import SwiftUI
import Observation

/// The slider bounds, shared by the ring and the preferences card so the cap is one number.
enum CursorRingLimits {
    static let minSize = 20
    static let maxSize = 200
    static let minThickness = 1
    static let maxThickness = 12

    /// A stroke can never be more than half the diameter, or the ring fills its own hole.
    static func clampThickness(_ thickness: Int, size: Int) -> Int {
        max(minThickness, min(min(thickness, maxThickness), size / 2))
    }

    static func clampSize(_ size: Int) -> Int { max(minSize, min(maxSize, size)) }
}

/// The alpha the stroke has always been drawn at, and it is not a setting: the three shadows around
/// it are tuned against 0.9, so the colour picker changes the hue and leaves the contrast alone.
let cursorRingStrokeAlpha = 0.9

@MainActor
final class CursorRing {
    static let shared = CursorRing()

    private var panel: NSPanel?
    private var view: CursorRingView?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var observing = false

    /// Called once at launch. Starts the presence poll and the settings observation; idempotent, so
    /// the preferences page may call it too rather than depending on the order of two boots.
    static func bootstrap() { shared.begin() }

    private func begin() {
        GamePresence.shared.start()
        guard !observing else { return }
        observing = true
        observe()
    }

    /// Re-arm observation on every change: `withObservationTracking` fires once per mutation.
    private func observe() {
        let prefs = Prefs.shared
        withObservationTracking {
            _ = prefs.cursorRingEnabled
            _ = prefs.cursorRingSize
            _ = prefs.cursorRingThickness
            _ = prefs.cursorRingColor
            _ = GamePresence.shared.isFrontmost
        } onChange: {
            Task { @MainActor in
                self.sync()
                self.observe()
            }
        }
        sync()
    }

    /// Install or remove the ring from the two facts that decide it: the setting, and whether the
    /// game is the window the player is in. Safe to call at any time and as often as you like.
    func sync() {
        let prefs = Prefs.shared
        guard prefs.cursorRingEnabled, GamePresence.shared.isFrontmost else { return park() }
        let size = CursorRingLimits.clampSize(prefs.cursorRingSize)
        let thickness = CursorRingLimits.clampThickness(prefs.cursorRingThickness, size: size)
        let color = NSColor(Color(hexString: prefs.cursorRingColor) ?? .white)
        let panel = ensurePanel()
        view?.apply(size: CGFloat(size), thickness: CGFloat(thickness), color: color)
        let side = CGFloat(size) + CursorRingView.margin * 2
        if panel.frame.width != side {
            panel.setContentSize(NSSize(width: side, height: side))
        }
        startTracking()
        follow()
        panel.orderFrontRegardless()
    }

    /// Nothing drawn and nothing tracked — the monitors go with the window, so an off ring costs
    /// the app no mouse events at all.
    private func park() {
        stopTracking()
        panel?.orderOut(nil)
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let side = CGFloat(CursorRingLimits.maxSize) + CursorRingView.margin * 2
        let p = NSPanel(contentRect: NSRect(x: -9999, y: -9999, width: side, height: side),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        // Above the game, and above the app's own overlays: the ring is the one thing that must
        // never be behind anything, because it is standing in for the pointer.
        p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.isFloatingPanel = true
        p.becomesKeyOnlyIfNeeded = true
        // Belt to the click-through promise: this window is never a mouse target, whatever else
        // it is doing.
        p.ignoresMouseEvents = true
        let v = CursorRingView(frame: NSRect(origin: .zero, size: NSSize(width: side, height: side)))
        p.contentView = v
        panel = p
        view = v
        return p
    }

    // MARK: - Following the pointer

    /// Mouse-moved monitors need no accessibility permission — only keyboard taps do. The global
    /// monitor is the one that matters (the game is frontmost when the ring shows); the local one
    /// keeps the ring honest for the frames where the app itself has the pointer.
    private func startTracking() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        if globalMonitor == nil {
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { _ in
                MainActor.assumeIsolated { CursorRing.shared.follow() }
            }
        }
        if localMonitor == nil {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
                MainActor.assumeIsolated { CursorRing.shared.follow() }
                return event
            }
        }
    }

    private func stopTracking() {
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor { NSEvent.removeMonitor(m) }
        globalMonitor = nil
        localMonitor = nil
    }

    /// Centre the panel on the pointer. `NSEvent.mouseLocation` rather than the event's own point:
    /// a global monitor's event has no window to be relative to, and the newest reading is the only
    /// one worth painting. Whole pixels, so a crisp 4px stroke is not resampled soft.
    private func follow() {
        guard let panel else { return }
        let p = NSEvent.mouseLocation
        let half = panel.frame.width / 2
        panel.setFrameOrigin(NSPoint(x: (p.x - half).rounded(), y: (p.y - half).rounded()))
    }
}

/// The ring itself. Readability on both bright and dark scenes comes from three shadows around one
/// slightly-transparent stroke: a dark contour outside it, a dark contour inside it, and a wide soft
/// glow — over a snowfield the contours separate the ring from the background, over a dungeon the
/// stroke does that on its own and the glow only softens the edge.
final class CursorRingView: NSView {
    /// Room around the ring for the soft glow to fall off in.
    static let margin: CGFloat = 24

    private var sizePx: CGFloat = 44
    private var thicknessPx: CGFloat = 4
    private var color: NSColor = .white

    func apply(size: CGFloat, thickness: CGFloat, color: NSColor) {
        guard size != sizePx || thickness != thicknessPx || color != self.color else { return }
        sizePx = size
        thicknessPx = thickness
        self.color = color
        needsDisplay = true
    }

    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        let outer = sizePx / 2
        let stroke = min(thicknessPx, outer)
        let shadow = NSColor.black.withAlphaComponent(0.6)

        // The soft glow, drawn first so everything else sits on top of it.
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 14, color: NSColor.black.withAlphaComponent(0.28).cgColor)
        ring(ctx, centre, radius: outer + 2, width: 4, color: NSColor.black.withAlphaComponent(0.28))
        ctx.restoreGState()

        ring(ctx, centre, radius: outer + 0.5, width: 1, color: shadow)
        ring(ctx, centre, radius: outer - stroke / 2, width: stroke,
             color: color.withAlphaComponent(cursorRingStrokeAlpha))
        let inner = outer - stroke - 0.5
        if inner > 0.5 { ring(ctx, centre, radius: inner, width: 1, color: shadow) }
    }

    private func ring(_ ctx: CGContext, _ centre: CGPoint, radius: CGFloat, width: CGFloat, color: NSColor) {
        guard radius > 0 else { return }
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(width)
        ctx.strokeEllipse(in: CGRect(x: centre.x - radius, y: centre.y - radius,
                                     width: radius * 2, height: radius * 2))
    }
}
