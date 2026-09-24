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
        ReleaseNote(version: "1.1.0", date: "2026-09-24", entries: [
            ReleaseEntry(.new, "The Overview is now a sheet of statistics about all your play. Tiles at the top show items looted, items sold, coin earned from selling, mobs killed, motes and your average fight DPS. Below them are cards for leveling, motes, DPS over time across every fight, loot and sales, kills, and the recent feeds."),
            ReleaseEntry(.new, "The old Overview showed one fight and one mob, which the Combat tab already does. It could not answer the long-run questions: how much this character has sold, what drops most, whether your damage is getting better over the weeks."),
            ReleaseEntry(.new, "Your sales are now counted from your log, split three ways: auto-sell, merchant sales and the Reward Chest's auto-sell. Items sold for nothing are counted too, and you can see which items paid the most. The Motes card adds up the same rows as the Motes tab, so the two can never disagree."),
            ReleaseEntry(.new, "Any fight in your log, however old, now opens with its full detail: the DPS curve, the Timeline and its own combat log lines. The detail is read back from the log file, and a note says when a fight's detail was rebuilt that way."),
            ReleaseEntry(.new, "Until now only your last 60 fights kept their detail. An older fight showed its meter beside three empty boxes, and its Timeline could not be opened. The first launch after this update reads your whole log once, so that every past fight gets its summary."),
            ReleaseEntry(.new, "The Combat tab shows one mob at a time. Each mob of a multi-mob pull is its own row in the fight picker. A stats strip shows the mob's total dps, your damage with your pet's, what the mob did to you, and the experience and AA its kill gave. Its loot and corpse coin get a card of their own."),
            ReleaseEntry(.new, "A pet card shows what your pet hit with, what it cast, what it took, and the heals and buffs on it."),
            ReleaseEntry(.new, "Each direction now opens on its breakdown. Outgoing shows your damage by class and then ability by ability, with each ability's own dps and colour taken from the class that lands it, and your pet as its own row. Incoming lists each attacker with what it hit you with. Healing lists each healer with the spells it used."),
            ReleaseEntry(.new, "Before, a pull was one lump of damage against several mobs. Finding out what you did meant ranking yourself against everyone and then drilling in."),
            ReleaseEntry(.changed, "The fight picker lists every fight you have, grouped by day, for the last 24 hours, 3, 7 or 30 days. It filters as you type on the mob's name or the zone: \"gloom\" finds Estrella of Gloomwater, and * matches any gap. Older fights used to be reachable only by search, and Load more fights did nothing until you reopened the list."),
            ReleaseEntry(.changed, "The Leveling tab has a fixed layout. AA pace sits in the row of stat tiles, and each tile names the time window it measures. Best spells and the AA list sit side by side at the same height, and each scrolls inside its own panel with nothing folded away. The AA and level charts run full width under the time-range bar."),
            ReleaseEntry(.changed, "The Buffs tab is gone. The Timers tab now always shows every timer."),
            ReleaseEntry(.changed, "Loading your log is more than twice as fast. A large log that took about half a minute to read on launch or on a character switch now takes about eleven seconds."),
            ReleaseEntry(.fixed, "Restart Engine no longer leaves the old engine running. Each restart used to add another copy that kept reading your log and writing the same saved files."),
            ReleaseEntry(.fixed, "Switching characters while the log was still loading could save a half-read history over the complete one on disk. That no longer happens."),
            ReleaseEntry(.fixed, "Quitting while the app was saving could lose the last save. Quit now waits up to five seconds for the save to finish."),
            ReleaseEntry(.fixed, "With no EverQuest install or no character logs, the banner used to spin on Starting forever. A character that failed to load stayed on Catching up with a bar that never moved. Both now say No log, with the reason. The failure card now goes away on its own once the engine recovers."),
            ReleaseEntry(.fixed, "Respawn watches stay put. Two quick clicks, or a click while the log was loading, could drop watches, and a full reload of the log lost the list."),
            ReleaseEntry(.fixed, "Launching the app no longer celebrates boss kills and quest turn-ins from your history as if they had just happened."),
            ReleaseEntry(.fixed, "Your trusted casters and combo corrections could be ignored until the next character switch if they arrived while a character was loading. They now always apply."),
            ReleaseEntry(.fixed, "A panel could stop updating and ignore your clicks until you switched characters. It no longer gets stuck."),
            ReleaseEntry(.fixed, "Procs no longer counts a caster's own poison spells, such as Envenomed Bolt, as poison procs. The poison ledger now only appears when you have a poison coat on record."),
            ReleaseEntry(.fixed, "The AA and level charts no longer draw past the left edge of their panel when the scope is Zone or Session."),
            ReleaseEntry(.fixed, "Sound pack downloads are safer. Each file and each pack has a size limit, downloads only follow redirects to trusted hosts, and a failed install leaves nothing behind. A pack with an oddly named file no longer stops the whole install."),
            ReleaseEntry(.fixed, "A bad pasted share code can no longer swell to tens of megabytes before being turned away as too long.")
        ]),
        ReleaseNote(version: "1.0.2", date: "2026-09-22", entries: [
            ReleaseEntry(.new, "A Motes tab: where the Motes of Potential come from. Every counted kill and every mote you have looted are joined into one row per mob at one difficulty, with kills, corpses that gave a mote, drop rate, motes per kill and a column per grade."),
            ReleaseEntry(.new, "The question a farmer asks is where it is worth standing. Until now the answer was a memory of a good evening in one zone; the log had the numbers all along but nothing added them up."),
            ReleaseEntry(.new, "Regroup the same rows by mob, zone, difficulty, named vs trash or level band, and filter first, so \"Plane of Hate, by difficulty\" compares the tiers of one zone. A group's rate is its corpses over its kills, never an average of averages."),
            ReleaseEntry(.new, "The rate is yours, not the server's: a group-mate who loots a corpse takes the mote out of your log but not the kill out of your count, and the caption says so. \"Only mobs that gave a mote\" is on by default; turn it off and a zero is a fact about that mob."),
            ReleaseEntry(.new, "Gear page filters on stats. Pick STR and WIS and see only what gives both; each stat you add narrows the table further. A penalty like -5 CHA does not count as having CHA."),
            ReleaseEntry(.fixed, "The minus button on the Sky quest card's turn-in counter can be clicked. It was only live along a line two points tall, so a turn-in recorded by hand could not be taken back; both buttons now have the same square target.")
        ]),
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
