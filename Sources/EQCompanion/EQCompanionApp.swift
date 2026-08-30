import SwiftUI
import EQCompanionCore

@main
struct EQCompanionApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        WindowGroup("EQ Companion") {
            RootView()
                .environment(model)
                .dynamicTypeSize(Prefs.shared.dynamicType)
                .frame(minWidth: 980, minHeight: 620)
                .onAppear { OverlayController.shared.bind(model); AppTiming.mark("Window created") }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Overlay") {
                Button(model.overlayVisible ? "Hide DPS Overlay" : "Show DPS Overlay") {
                    model.overlayVisible.toggle()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                Button(model.overlayLocked ? "Unlock Overlay (click-through off)" : "Lock Overlay (click-through)") {
                    model.overlayLocked.toggle()
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            }
            CommandMenu("Session") {
                Button("New Session Mark") { Task { await model.newSessionMark() } }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Divider()
                Button("Restart Engine") { model.retryEngine() }
            }
        }

        Settings {
            PreferencesView()
                .environment(model)
                .frame(minWidth: 1040, minHeight: 680)
        }
    }
}

extension AppModel {
    static let shared = AppModel()
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        _ = Prefs.shared
        // Always open on Overview: a tab that misbehaved last time must not be where you land.
        UserDefaults.standard.set(Tab.overview.rawValue, forKey: "eq.tab")
        AppTiming.mark("Settings loaded")
        GamePriority.applyFromPrefs()
        PerfHUD.shared.applyFromPrefs()
        AppModel.shared.boot()
        MenuBarItem.bootstrap()
        CursorRing.bootstrap()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.shutdown()
    }

    /// Preferences → Window: closing the window either quits or leaves the app in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !Prefs.shared.keepRunningInMenuBar
    }
}
