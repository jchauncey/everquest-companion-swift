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
