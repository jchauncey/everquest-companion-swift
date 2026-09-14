// What changed, release by release, and who has not read it yet.
//
// THE NOTES ARE COMMITTED SOURCE, not a fetch. The app must be able to say what changed while
// offline, in a game session; a release note that needs a request is a release note that is
// sometimes absent, which is worse than none at all. They ship with the build that they describe,
// so a build can never show a newer release's notes and never loses its own.
//
// THE SEEN KEY IS A VERSION, NOT A BOOLEAN (Prefs.seenReleaseNotesVersion). Somebody who was on
// 0.1.0 and lands on 0.3.0 has two releases of news, and the panel marks both, because "new" is a
// comparison rather than a flag somebody had to remember to set per release. AN ABSENT KEY MEANS A
// FRESH INSTALL, WHICH HAS NO NEWS: nothing is marked, because a person who installed the app
// twenty minutes ago did not live through any of these changes.
//
// VOICE: player-centric and plain. What YOU can now do, or what stopped being wrong. Not wave
// names, not module names, not ticket ids. `kind` is the only structure. A fix, a change or a new
// option gets ONE bullet; a new surface earns two to five, never more — one says what it is, the
// others say what problem it was, in the player's terms and from before the thing existed.
import Foundation

/// Which sub-header an entry sits under.
enum ReleaseEntryKind: String {
    case new, fixed, changed
}

/// One bullet of a release's notes.
struct ReleaseEntry {
    let kind: ReleaseEntryKind
    let text: String
    init(_ kind: ReleaseEntryKind, _ text: String) { self.kind = kind; self.text = text }
}

/// One release. `date` is an ISO calendar date (YYYY-MM-DD), rendered through a local formatter and
/// never parsed for arithmetic.
struct ReleaseNote: Identifiable {
    let version: String
    let date: String
    let entries: [ReleaseEntry]
    var id: String { version }
}

enum ReleaseNotes {
    /// Sub-header order. New leads because it is why somebody would want the release at all; Fixed
    /// before Changed because "what stopped being wrong" is the thing people scan a release for.
    static let kindOrder: [ReleaseEntryKind] = [.new, .fixed, .changed]

    static func label(_ kind: ReleaseEntryKind) -> String {
        switch kind {
        case .new: return "New"
        case .fixed: return "Fixed"
        case .changed: return "Changed"
        }
    }

    /// Every release, NEWEST FIRST — the order the panel renders and every derivation below assumes.
    static let all: [ReleaseNote] = [
        ReleaseNote(version: "1.0.1", date: "2026-09-14", entries: [
            ReleaseEntry(.fixed, "The DPS and other overlays stay above the game when it is full screen. They rise while EverQuest is the app in front and drop back the moment anything else is, so the meter never sits over another app's menus or dialogs."),
            ReleaseEntry(.fixed, "A mob the wiki files under two names is one creature again. The card for a revultant rat used to show one bracer per class and a single warrior item because the armour lived on the page for a spelling the game never writes; now the rat you fight lists everything, and the same goes for a loathling lich and Innoruuk's Chosen. A merged mob says so on its card."),
            ReleaseEntry(.changed, "\"Who drops this\" now asks every page that knows. The item pages alone missed half the gear you could see dropping in Plane of Hate, and named the wrong plane for some of it; the mob pages had it right, so the item card, the Gear zone filter, the era verdict and the jump to the map all read both. A dropper only the mob page knew is marked via: mob page. Across the corpus, 1,307 items gained a dropper and 31 stopped being judged unknown."),
            ReleaseEntry(.new, "Your own log is on the item card. A dropper you have looted it from shows how many times, and a corpse no wiki page names becomes its own row marked via: your loot - so the golem that dropped your Indicolite Helm twice is no longer missing from its card.")
        ]),
        ReleaseNote(version: "1.0.0", date: "2026-09-10", entries: [
            ReleaseEntry(.new, "Search lives in the toolbar, on every tab. Type a zone, a mob or an item and go straight to it - a zone or a mob opens the map with the camera on the pin, an item opens its card. Finding something used to mean knowing first which tab knew about it."),
            ReleaseEntry(.new, "One item card, wherever you meet an item. Gear, a Loot drill-down and a mob's drop list all open the same card - the full weapon numbers, what it gives you, who drops it, and a slider for the +N versions - instead of a different half-answer in each place."),
            ReleaseEntry(.new, "Map pins open the mob. Click one and its card comes up over the map, its drops clickable through to the item, and it stays put when you alt-tab to the game. A mob's detail gained Show on map, which opens the zone with the camera on the pin."),
            ReleaseEntry(.new, "Wiki annotations: one button turns every mob position the wiki states into a labels pack in EverQuest's own maps folder, so the game shows them too - accurate labels where a hand-installed pack has gone stale. You name the pack, it never overwrites one it did not write, its labels are red enough to read on parchment, and it marks only named and rare mobs unless you ask for the common spawns."),
            ReleaseEntry(.new, "Maps split the mob list into Named & rare and Common spawns, each with its own toggle, so the named you are camping is not buried in the trash that shares its ground - including the ones the wiki spells like trash."),
            ReleaseEntry(.new, "Item cards show Focus Exaltation, and the Gear page filters by it - so \"what do I own that carries this focus\" is one click instead of a read through every card."),
            ReleaseEntry(.new, "If the app cannot find your EverQuest folder when it starts, it asks: choose it, look again, or not now. The question clears itself the moment an install turns up."),
            ReleaseEntry(.fixed, "The Current era toggle no longer hides gear it should show. The roster says \"The Plane of Fear\" and the wiki's drop rows say \"Plane of Fear\", and that one word left 357 items judged unknown - whole armor sets, Umbral Platemail among them - invisible while the toggle was on. The same seam kept the planes' mobs off their maps; both spellings are one zone again."),
            ReleaseEntry(.fixed, "A locked DPS overlay takes your clicks again while the companion is the app in front, so the button that locked it can always unlock it; clicks pass through to the game only when the game is the one you are looking at."),
            ReleaseEntry(.fixed, "The app no longer crashes on startup over the sound device, and six places where an unexpected value could take it down mid-session cannot any more."),
            ReleaseEntry(.fixed, "Map labels sit at the elevation they claim, so the game stops filtering them out of dungeons."),
            ReleaseEntry(.changed, "Catching up on your log takes about two seconds where it took sixteen. The app saves what it has read and resumes from there, and any doubt at all about the file - a different log, an edit, a new build - makes it read the whole thing again from the start."),
            ReleaseEntry(.changed, "Gear and Loot are one table now: the same columns, sorting and behaviour in both, the zones filter is a type-ahead picker instead of a list to scroll, and every picker popover takes the arrow keys - down and up walk the list, Return picks, the highlight scrolls with you."),
            ReleaseEntry(.changed, "The Mobs tab is gone. Everything it answered is now a search away, or on the map."),
            ReleaseEntry(.changed, "The sidebar collapses, the title sits over it, and both columns run the full height of the window, so a wide tab no longer spills across the sidebar."),
            ReleaseEntry(.changed, "Records read like the item window: no blank lines in a stats block, no empty space held open under a short drop list, and the raw sub-objects folded away until you click them."),
            ReleaseEntry(.changed, "On the Maps pane the X clears the search and every pin comes back, hiding the side panel is its own button, and an item that drops in more than one zone asks which map you meant instead of choosing for you.")
        ]),
        ReleaseNote(version: "0.2.0", date: "2026-08-29", entries: [
            ReleaseEntry(.new, "The companion is one program now. Everything it does happens inside the app itself - there is no second process running beside it and nothing listening on a port, so there is nothing for security software to block and nothing left running if the app goes away."),
            ReleaseEntry(.new, "It ships as a single app you can drag anywhere and open. Nothing is installed alongside it."),
            ReleaseEntry(.new, "Preferences is a set of pages with a search box across all of them. Type what you are after - \"log folder\", \"transparency\", \"menu bar\" - and the setting comes to you instead of you hunting for the page it lives on."),
            ReleaseEntry(.changed, "The catch-up bar after launch or a character switch now measures the app's own read of your log, so the percentage and the time left are what is really happening."),
            ReleaseEntry(.changed, "When a panel is empty, everything worth reading is in one place: the app's notes and the engine's own diagnostics both go to client.log in Application Support."),
            ReleaseEntry(.changed, "Quitting writes the engine's state files, so what it had learned about resists and message shapes is still there next launch.")
        ]),
        ReleaseNote(version: "0.1.0", date: "2026-08-28", entries: [
            ReleaseEntry(.new, "A native Mac companion. Until now running it here meant running a Windows app inside the same compatibility layer as the game, on top of the game - this one is a Mac program that reads the log file EverQuest already writes inside your bottle."),
            ReleaseEntry(.new, "Every tab is here: Overview, Combat, Mobs, Loot, Gear, Maps, Raid targets, Plane of Sky, Alerts, Leveling, Buffs and Timers."),
            ReleaseEntry(.new, "The floating DPS overlay sits over the game, and can be locked so your clicks go straight through it.")
        ])
    ]

    /// "0.2.0" vs "0.1.0" — numeric, part by part, so 0.10.0 is newer than 0.9.0. Anything that is
    /// not a number sorts as zero rather than throwing: a version string is data, not a promise.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        let y = b.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0
            let r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    /// Does this release postdate what the install has been shown? An empty `seen` is a fresh
    /// install: no news, nothing marked.
    static func isNew(_ note: ReleaseNote, seen: String) -> Bool {
        !seen.isEmpty && isNewer(note.version, than: seen)
    }

    private static let iso: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let display: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateStyle = .short
        f.timeStyle = .none
        return f
    }()

    /// The calendar date in the reader's own format. An unparseable string is shown as it is.
    static func formatDate(_ date: String) -> String {
        guard let d = iso.date(from: date) else { return date }
        return display.string(from: d)
    }
}
