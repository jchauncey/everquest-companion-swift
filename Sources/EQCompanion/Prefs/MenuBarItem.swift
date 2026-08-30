// The menu bar status item — this Mac's answer to the upstream app's Windows system tray.
//
// WHAT IT IS FOR. One preference (Preferences → Window) says closing the window must not end the
// app. Honouring that leaves a running app with nothing on screen, so there has to be a way back
// in and a way out: this is it. macOS has no notification area, and the menu bar's status area is
// the same idea in the same place people already look.
//
// IT EXISTS ONLY WHILE THE PREFERENCE IS ON. An icon that sits up there when closing the window
// quits anyway would be a control that does nothing. `sync()` is the whole lifecycle — install
// when the flag is on, remove when it is off — and it is called at launch and on every change.
//
// THE WINDOW IS HELD, NOT REOPENED. SwiftUI releases a WindowGroup's window when it closes, and a
// released window cannot be brought back; so the first time we see it we take a reference and turn
// `isReleasedWhenClosed` off. "Show EQ Companion" then orders the SAME window back — the app the
// user closed, with its state, not a second copy of it.
import AppKit
import SwiftUI

@MainActor
final class MenuBarItem: NSObject {
    static let shared = MenuBarItem()

    private var item: NSStatusItem?
    /// Strong on purpose: this is the reference that keeps the closed window alive.
    private var mainWindow: NSWindow?

    private override init() { super.init() }

    /// Called once at launch (from the app delegate) so the item is there before Preferences is.
    /// Deferred a tick: at `applicationDidFinishLaunching` the WindowGroup's window may not exist
    /// yet, and the point of running early is to catch it while it is the only window there is.
    static func bootstrap() {
        Task { @MainActor in shared.sync() }
    }

    /// Install or remove the item to match the preference, and adopt the main window if we can see
    /// it. Safe to call as often as you like — it is a diff, not a toggle.
    func sync() {
        adoptMainWindow()
        if Prefs.shared.keepRunningInMenuBar { install() } else { remove() }
    }

    // MARK: The item

    private func install() {
        guard item == nil else { return }
        let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let icon = NSImage(systemSymbolName: "gamecontroller", accessibilityDescription: "EQ Companion")
        icon?.isTemplate = true
        it.button?.image = icon
        it.button?.toolTip = "EQ Companion"

        let menu = NSMenu()
        let show = NSMenuItem(title: "Show EQ Companion", action: #selector(showWindow), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit EQ Companion", action: #selector(quit), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        it.menu = menu

        item = it
    }

    private func remove() {
        guard let it = item else { return }
        NSStatusBar.system.removeStatusItem(it)
        item = nil
    }

    // MARK: The window

    /// The app's own window, told apart from the Settings window and from the overlay panels. The
    /// WindowGroup is titled "EQ Companion", which is the cheap and stable answer; the fallback is
    /// the first ordinary window that can become main, which is the same one at launch.
    private func adoptMainWindow() {
        if mainWindow != nil { return }
        let windows = NSApp.windows.filter { !($0 is NSPanel) && $0.canBecomeMain }
        let found = windows.first { $0.title == "EQ Companion" } ?? windows.first
        guard let w = found else { return }
        w.isReleasedWhenClosed = false
        mainWindow = w
    }

    @objc private func showWindow() {
        adoptMainWindow()
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
