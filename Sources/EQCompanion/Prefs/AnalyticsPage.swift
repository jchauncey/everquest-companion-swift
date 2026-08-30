// Preferences → Usage analytics — the upstream TelemetrySetting and its first-run TelemetryNotice,
// answered by a build that collects nothing.
//
// THERE IS NO SWITCH, BECAUSE THERE IS NOTHING TO SWITCH. Upstream ships opt-out analytics: a
// toggle, a rotatable anonymous id, and a payload viewer showing the exact bytes that would leave,
// because the only claim about privacy a user can check is one they can read for themselves. This
// port has no analytics code at all, so a toggle here would be a control that does nothing and a
// payload viewer would be an empty box the user has to interpret. The card states the fact and
// then does the checkable thing that is still available: it names every file the app writes.
//
// AND IT IS HONEST ABOUT WHICH SILENCE THIS IS. "Nothing has been sent yet" and "nothing can ever
// be sent from this build" are very different sentences; this is the second one.
import SwiftUI

extension PrefPages {
    static let analytics = PrefPage(id: "analytics", label: "Usage analytics", icon: "shield", sections: [
        PrefSectionInfo(id: "telemetry", label: "Anonymous usage counts",
                        keywords: "telemetry analytics usage privacy tracking opt out optout data collect anonymous id payload send stats metrics network offline")
    ]) { AnyView(AnalyticsPage()) }
}

struct AnalyticsPage: View {
    var body: some View {
        PrefCard("Anonymous usage counts") {
            PrefStatus(tone: .ok, text: "Nothing is collected, and nothing ever will be from this build.")
            PrefCaption("There is no analytics code in this app: no counts, no anonymous id, no events, no endpoint. Nothing about how you use it leaves this machine, and there is nothing to opt out of.")
            PrefCaption("It makes one kind of network request, and only when you ask for it by name: installing a voice pack from the Sound packs browser fetches that pack. Nothing else in the app talks to the internet - the item icons, boss portraits, spells and mob knowledge are all copied into the app when it is built, so drawing them asks nobody for anything.")
            PrefCaption("It reads the log file EverQuest already writes. Nothing is injected, no game file is touched, nothing is automated.")

            Text("The only things it writes are these four:").font(.caption).foregroundStyle(Theme.textDim)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 6) {
                PrefPath(label: "The engine's own state (resist ledger, message overlay)", path: AppModel.stateDir.path)
                PrefPath(label: "Your alert definitions", path: AlertStore.file.path)
                PrefPath(label: "Installed voice packs", path: AlertPlayer.packsDir.path)
                PrefPath(label: "The app's notes and the engine's diagnostics", path: ClientLog.file.path)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.paperRaised))

            PrefCaption("Your preferences live beside them, in this app's own defaults. Delete any of it and the app starts from empty.")
        }
    }
}
