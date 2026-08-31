// The three global alert switches — how loud, at all, and how many at once — plus the audio
// coalescing window they govern. One blob, one editor (the Alerts toolbar), the way
// `AlertPrefs` is one blob in the Electron app.
import Foundation
import Observation

/// Global sound preferences, persisted in UserDefaults (the Electron app's `AlertPrefs`).
@MainActor
@Observable
final class AlertPrefs {
    /// 0..1 master volume applied on top of each alert's own volume. Electron's default is 0.7.
    var globalVolume: Double { didSet { d.set(globalVolume, forKey: Keys.volume) } }
    /// When true nothing plays. The engine still evaluates and the history still fills.
    var muted: Bool { didSet { d.set(muted, forKey: Keys.muted) } }
    /// Skip the cross-alert coalescing window for EVERY alert: four buffs fading is four sounds.
    var alwaysPlayAll: Bool { didSet { d.set(alwaysPlayAll, forKey: Keys.alwaysPlayAll) } }

    private let d = UserDefaults.standard
    private enum Keys {
        static let volume = "alerts.globalVolume"
        static let muted = "alerts.muted"
        static let alwaysPlayAll = "alerts.alwaysPlayAll"
    }

    init() {
        globalVolume = d.object(forKey: Keys.volume) as? Double ?? 0.7
        muted = d.bool(forKey: Keys.muted)
        alwaysPlayAll = d.bool(forKey: Keys.alwaysPlayAll)
    }
}

/// How long one played alert occupies the audio channel, ported from the Electron
/// `audioThrottle.ts`: a burst-coalescing window, not a rate limit and not a setting. Three buffs
/// fading at once is one thing to hear; three DIFFERENT lines are three facts and all are kept.
let audioCoalesceMs: Int64 = 1500

/// How many distinct audible identities one window admits before it stops taking new ones.
let audioDistinctCap = 8

/// The coalescing decision, pure so it can be reasoned about without a clock. First arrival owns
/// the window; a suppressed firing never extends it.
struct AudioWindow {
    /// NIL, not a sentinel. "No window has opened yet" was `Int64.min`, and the first thing the
    /// window does with it is `now - openedAt` - which for a wall-clock millisecond `now` overflows
    /// Int64 and traps. Every alert this app ever played went through that subtraction, so the
    /// first sound after launch crashed it outright (`AlertPrefs.swift:50`, in the wild).
    private var openedAt: Int64?
    private var heard: Set<String> = []

    /// `identity` is what the firing would be HEARD as (the sound key plus the spoken words).
    /// Returns true when it should play.
    mutating func admit(_ identity: String, now: Int64, bypass: Bool) -> Bool {
        if bypass { return true }
        // Inside a window that is still open: coalesce. Anything else - no window yet, or the last
        // one has lapsed - opens a fresh one, and the arrival that opens it owns it.
        if let openedAt, now - openedAt <= audioCoalesceMs {
            if heard.contains(identity) { return false }
            if heard.count >= audioDistinctCap { return false }
            heard.insert(identity)
            return true
        }
        openedAt = now
        heard = [identity]
        return true
    }
}
