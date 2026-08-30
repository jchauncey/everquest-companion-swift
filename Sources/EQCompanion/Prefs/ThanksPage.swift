// Preferences → Thanks — the upstream ThanksSetting, plus the two credits that are only true of
// this port.
//
// WHY IT EXISTS. Every item icon and every raid-boss portrait in this app was made by, or uploaded
// to, one of two volunteer-run EverQuest wikis, and the bytes SHIP INSIDE THE APP. Art you
// redistribute without naming the source is the kind of quiet borrowing that is fine right up
// until it is not, and the people it borrows from are two hobbyist wikis that never asked for
// anything. So the credit is a page a user can find, not a line in a file only developers read.
//
// It carries the DISCLOSURE as well as the thanks, because the two are one sentence: the images
// are copies, they are stored in the app, and the app therefore does not phone the wikis to draw
// them. That last clause is also the honest answer to "does this thing talk to the internet",
// which the app answers on the Usage analytics page and must not contradict here.
//
// AND THE FIRST CARD IS THE BIGGEST DEBT. This whole app is a translation of somebody else's
// work — the engine, the data, the fixtures, the rules the comments state. Crediting the pictures
// while quietly keeping the program would be the wrong way round.
import SwiftUI
import AppKit

extension PrefPages {
    static let thanks = PrefPage(id: "thanks", label: "Thanks", icon: "heart", sections: [
        PrefSectionInfo(id: "port", label: "This app is a port",
                        keywords: "port upstream electron rust josh moyers license fsl mit source github credit"),
        PrefSectionInfo(id: "image-credits", label: "The pictures are not ours",
                        keywords: "thanks credit credits attribution wiki wikis eqlwiki project1999 p99 image images icon icons art portrait portraits picture source sources license offline bundled shipped"),
        PrefSectionInfo(id: "voice-packs", label: "Voice packs",
                        keywords: "voice pack sound soundpack alan rickman openpeon license cc-by attribution")
    ]) { AnyView(ThanksPage()) }
}

/// One credited source: who they are, and what of theirs is in the app.
private struct Credit: Identifiable {
    let host: String
    let url: String
    let what: String
    var id: String { host }
}

/// The two wikis, in the order their contribution is visible to a user. Portraits first: they are
/// the pictures somebody actually looks at, and two thirds of the bundle by bytes.
private let imageCredits: [Credit] = [
    Credit(host: "wiki.project1999.com", url: "https://wiki.project1999.com/",
           what: "the raid-boss portraits on the Raid targets cards"),
    Credit(host: "eqlwiki.com", url: "https://eqlwiki.com/",
           what: "the item icons throughout loot, inventory and the planner - and the item, spell and quest knowledge behind them")
]

/// A link that opens in the user's browser. The app has no browser of its own and should not grow
/// one to show a credit.
private struct PrefLink: View {
    let title: String
    let url: String
    var body: some View {
        Button { if let u = URL(string: url) { NSWorkspace.shared.open(u) } } label: {
            HStack(spacing: 4) {
                Text(title)
                Image(systemName: "arrow.up.right.square").font(.caption2)
            }
            .foregroundStyle(Theme.gold)
        }
        .buttonStyle(.plain)
    }
}

struct ThanksPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            portCard
            picturesCard
            voiceCard
        }
    }

    private var portCard: some View {
        PrefCard("This app is a port") {
            Text("The engine, the data, the fixtures, the alert seeds and every panel's logic are a Swift translation of everquest-companion by Josh Moyers (Electron + Rust). The design, the rules the code states, and most of the sentences in the comments are his; the port keeps them because they are what its tests verify.")
                .font(.callout).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
            PrefLink(title: "github.com/jmoyers/everquest-companion", url: "https://github.com/jmoyers/everquest-companion")
            PrefCaption("Licensed FSL-1.1-MIT - the Functional Source License, which converts to MIT two years after each version's release. This port is a derivative work carried under the same terms. Nothing here is affiliated with or endorsed by upstream.")
            PrefCaption("EverQuest is a trademark of Daybreak Game Company LLC. This is a fan-made log reader; it is not affiliated with Daybreak, and it reads only the log file the game writes for you.")
        }
    }

    private var picturesCard: some View {
        PrefCard("The pictures are not ours") {
            Text("The pictures in this app are not ours. Item icons and boss portraits come from two volunteer-run EverQuest wikis, and they are copied into the app when it is built - so they are here on your machine, and drawing them never asks those sites for anything.")
                .font(.callout).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(imageCredits) { c in
                    VStack(alignment: .leading, spacing: 1) {
                        PrefLink(title: c.host, url: c.url)
                        PrefCaption(c.what)
                    }
                }
            }
            PrefCaption("Both are run by people who have spent years writing this game down for everyone else, and neither is affiliated with this app. If you have ever looked something up mid-raid, you owe them one.")
        }
    }

    private var voiceCard: some View {
        PrefCard("Voice packs") {
            Text("The default alert voice, installed on demand the first time the app runs, is the Alan Rickman soundpack from the openpeon registry, licensed CC-BY-4.0.")
                .font(.callout).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
            PrefLink(title: "utensils/openpeon-alan-rickman-soundpack",
                     url: "https://github.com/utensils/openpeon-alan-rickman-soundpack")
            PrefCaption("Packs you install from the in-app browser carry their own licenses and attribution in each pack's manifest; none of them are part of this app.")
        }
    }
}
