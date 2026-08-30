// Preferences → Window — the upstream CloseToTraySetting: one switch, "Closing the window".
//
// STATE, NEVER PROCESS. The captions say what closing the window WILL DO and how to get it back.
// Neither of them mentions hiding, processes, or the fact that anything is intercepting a close.
//
// A SECTION OF ITS OWN rather than a line under Overlays, because it is not about the overlays: it
// is about the app WINDOW, which is the thing the user just closed.
//
// MAC DIFFERENCE: there is no system tray. The equivalent is the menu bar's status area, so the
// label and the caption say "menu bar" and the icon that appears there is MenuBarItem — installed
// and removed by this switch, so the control and the thing it claims can never disagree. Upstream
// also puts a checkbox on the tray icon's own menu; this build's menu carries Show and Quit only,
// which is what a person who cannot see the window actually needs.
import SwiftUI

extension PrefPages {
    static let window = PrefPage(id: "window", label: "Window", icon: "macwindow", sections: [
        PrefSectionInfo(id: "close-to-tray", label: "Closing the window",
                        keywords: "tray systray system tray menu bar status item minimize minimise close closing quit exit x background hide taskbar dock")
    ]) { AnyView(WindowPage()) }
}

struct WindowPage: View {
    @Bindable private var prefs = Prefs.shared

    var body: some View {
        PrefCard("Closing the window") {
            PrefToggle(
                label: "Keep running in the menu bar when I close the window",
                isOn: $prefs.keepRunningInMenuBar,
                captionOn: "Closing the window keeps the companion and its overlays running. macOS has no system tray, so the companion waits in the menu bar: click its icon to bring the window back, or quit it from the same menu.",
                captionOff: "Closing the window quits the companion and closes its overlays."
            )
        }
        .onAppear { MenuBarItem.shared.sync() }
        .onChange(of: prefs.keepRunningInMenuBar) { MenuBarItem.shared.sync() }
    }
}
