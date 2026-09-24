// The app's preferences: one observable store, one UserDefaults key per setting, defaults that
// match the upstream app's. Every Preferences page reads and writes THIS and nothing else, so a
// setting has exactly one spelling and one home. Keys are namespaced `prefs.<page>.<name>`.
import Foundation
import Observation

@Observable
final class Prefs {
    static let shared = Prefs()
    private let d = UserDefaults.standard

    // MARK: Appearance
    /// In-app text size, percent (80…150). Applied at the root as a dynamic type size.
    var uiScale: Int { didSet { d.set(uiScale, forKey: "prefs.appearance.uiScale") } }
    /// Off: every overlay shares one text size and one transparency.
    var overlayIndependent: Bool { didSet { d.set(overlayIndependent, forKey: "prefs.appearance.overlayIndependent") } }
    var overlayTextScale: Int { didSet { d.set(overlayTextScale, forKey: "prefs.appearance.overlayTextScale") } }
    /// Percent opaque (the upstream "Transparency" number reads 72% = 72% opaque).
    var overlayTransparency: Int { didSet { d.set(overlayTransparency, forKey: "prefs.appearance.overlayTransparency") } }
    /// Per-overlay overrides when `overlayIndependent`: id → percent.
    var overlayTextScales: [String: Int] { didSet { d.set(overlayTextScales, forKey: "prefs.appearance.overlayTextScales") } }
    var overlayTransparencies: [String: Int] { didSet { d.set(overlayTransparencies, forKey: "prefs.appearance.overlayTransparencies") } }

    // MARK: Combat
    /// "you" | "group" | "everyone" — whose damage the meters show.
    var meterScope: String { didSet { d.set(meterScope, forKey: "prefs.combat.meterScope") } }
    var petInline: Bool { didSet { d.set(petInline, forKey: "prefs.combat.petInline") } }

    // MARK: Overlays
    var hideOverlaysWhenGameClosed: Bool { didSet { d.set(hideOverlaysWhenGameClosed, forKey: "prefs.overlays.hideWhenGameClosed") } }
    var hideOverlaysWhenGameUnfocused: Bool { didSet { d.set(hideOverlaysWhenGameUnfocused, forKey: "prefs.overlays.hideWhenGameUnfocused") } }
    var toastsEnabled: Bool { didSet { d.set(toastsEnabled, forKey: "prefs.overlays.toastsEnabled") } }
    var toastsMovable: Bool { didSet { d.set(toastsMovable, forKey: "prefs.overlays.toastsMovable") } }
    var bannerEnabled: Bool { didSet { d.set(bannerEnabled, forKey: "prefs.overlays.bannerEnabled") } }
    var bannerMovable: Bool { didSet { d.set(bannerMovable, forKey: "prefs.overlays.bannerMovable") } }
    /// Seconds a banner line stays (2, 4, 6, 8, 10).
    var bannerLineSeconds: Int { didSet { d.set(bannerLineSeconds, forKey: "prefs.overlays.bannerLineSeconds") } }
    /// Lines on screen at once (1…8).
    var bannerLines: Int { didSet { d.set(bannerLines, forKey: "prefs.overlays.bannerLines") } }
    var conCardEnabled: Bool { didSet { d.set(conCardEnabled, forKey: "prefs.overlays.conCardEnabled") } }
    var conCardMovable: Bool { didSet { d.set(conCardMovable, forKey: "prefs.overlays.conCardMovable") } }
    /// Seconds a con card stays (2, 3, 5, 8, 12).
    var conCardSeconds: Int { didSet { d.set(conCardSeconds, forKey: "prefs.overlays.conCardSeconds") } }
    var overlaySolidBackground: Bool { didSet { d.set(overlaySolidBackground, forKey: "prefs.overlays.solidBackground") } }

    // MARK: Window
    /// Closing the window leaves the app running in the menu bar (the upstream "system tray").
    var keepRunningInMenuBar: Bool { didSet { d.set(keepRunningInMenuBar, forKey: "prefs.window.keepRunningInMenuBar") } }

    // MARK: Buffs
    /// Other casters whose buffs and debuffs the bars show, besides your own.
    var trustedCasters: [String] { didSet { d.set(trustedCasters, forKey: "prefs.buffs.trustedCasters") } }

    // MARK: Timers
    /// The respawn watch list as the `respawn.define` payload's `watches` array, JSON-encoded. nil
    /// until the first watch is set on this install: the list used to live only in the fold's
    /// checkpoint, and an app that pushed "nothing" for it would wipe what the checkpoint holds.
    var respawnWatchesJSON: String? { didSet { d.set(respawnWatchesJSON, forKey: "prefs.timers.respawnWatches") } }

    // MARK: Cursor ring
    var cursorRingEnabled: Bool { didSet { d.set(cursorRingEnabled, forKey: "prefs.cursorRing.enabled") } }
    var cursorRingSize: Int { didSet { d.set(cursorRingSize, forKey: "prefs.cursorRing.size") } }
    var cursorRingThickness: Int { didSet { d.set(cursorRingThickness, forKey: "prefs.cursorRing.thickness") } }
    /// "#RRGGBB".
    var cursorRingColor: String { didSet { d.set(cursorRingColor, forKey: "prefs.cursorRing.color") } }

    // MARK: Voice
    /// An AVSpeechSynthesisVoice identifier; empty = the system default.
    var voiceId: String { didSet { d.set(voiceId, forKey: "prefs.voice.id") } }
    /// 0.5…2.0, 1.0 = normal.
    var voiceRate: Double { didSet { d.set(voiceRate, forKey: "prefs.voice.rate") } }
    /// 0…1.
    var voiceVolume: Double { didSet { d.set(voiceVolume, forKey: "prefs.voice.volume") } }

    // MARK: Performance
    /// The fold thread runs at utility QoS so the game gets the processor first.
    var yieldCPU: Bool { didSet { d.set(yieldCPU, forKey: "prefs.performance.yieldCPU") } }
    var perfHUD: Bool { didSet { d.set(perfHUD, forKey: "prefs.performance.hud") } }

    // MARK: What's new
    /// The last version whose notes the user has seen (the nav badge clears when it matches).
    var seenReleaseNotesVersion: String { didSet { d.set(seenReleaseNotesVersion, forKey: "prefs.whatsNew.seen") } }

    private init() {
        let d = UserDefaults.standard
        func int(_ k: String, _ def: Int) -> Int { d.object(forKey: k) == nil ? def : d.integer(forKey: k) }
        func bool(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) == nil ? def : d.bool(forKey: k) }
        func dbl(_ k: String, _ def: Double) -> Double { d.object(forKey: k) == nil ? def : d.double(forKey: k) }
        func str(_ k: String, _ def: String) -> String { d.string(forKey: k) ?? def }
        uiScale = int("prefs.appearance.uiScale", 100)
        overlayIndependent = bool("prefs.appearance.overlayIndependent", false)
        overlayTextScale = int("prefs.appearance.overlayTextScale", 100)
        overlayTransparency = int("prefs.appearance.overlayTransparency", 72)
        overlayTextScales = (d.dictionary(forKey: "prefs.appearance.overlayTextScales") as? [String: Int]) ?? [:]
        overlayTransparencies = (d.dictionary(forKey: "prefs.appearance.overlayTransparencies") as? [String: Int]) ?? [:]
        meterScope = str("prefs.combat.meterScope", "everyone")
        petInline = bool("prefs.combat.petInline", true)
        hideOverlaysWhenGameClosed = bool("prefs.overlays.hideWhenGameClosed", true)
        hideOverlaysWhenGameUnfocused = bool("prefs.overlays.hideWhenGameUnfocused", false)
        toastsEnabled = bool("prefs.overlays.toastsEnabled", true)
        toastsMovable = bool("prefs.overlays.toastsMovable", false)
        bannerEnabled = bool("prefs.overlays.bannerEnabled", false)
        bannerMovable = bool("prefs.overlays.bannerMovable", false)
        bannerLineSeconds = int("prefs.overlays.bannerLineSeconds", 4)
        bannerLines = int("prefs.overlays.bannerLines", 4)
        conCardEnabled = bool("prefs.overlays.conCardEnabled", false)
        conCardMovable = bool("prefs.overlays.conCardMovable", false)
        conCardSeconds = int("prefs.overlays.conCardSeconds", 3)
        overlaySolidBackground = bool("prefs.overlays.solidBackground", false)
        keepRunningInMenuBar = bool("prefs.window.keepRunningInMenuBar", false)
        trustedCasters = d.stringArray(forKey: "prefs.buffs.trustedCasters") ?? []
        respawnWatchesJSON = d.string(forKey: "prefs.timers.respawnWatches")
        cursorRingEnabled = bool("prefs.cursorRing.enabled", false)
        cursorRingSize = int("prefs.cursorRing.size", 44)
        cursorRingThickness = int("prefs.cursorRing.thickness", 4)
        cursorRingColor = str("prefs.cursorRing.color", "#FFFFFF")
        voiceId = str("prefs.voice.id", "")
        voiceRate = dbl("prefs.voice.rate", 1.0)
        voiceVolume = dbl("prefs.voice.volume", 1.0)
        yieldCPU = bool("prefs.performance.yieldCPU", true)
        perfHUD = bool("prefs.performance.hud", false)
        seenReleaseNotesVersion = str("prefs.whatsNew.seen", "")
    }

    /// The effective text scale / opacity for one overlay, honouring the independent switch.
    func overlayTextScale(for id: String) -> Int { overlayIndependent ? (overlayTextScales[id] ?? overlayTextScale) : overlayTextScale }
    func overlayTransparency(for id: String) -> Int { overlayIndependent ? (overlayTransparencies[id] ?? overlayTransparency) : overlayTransparency }
}

/// The app's version as the bundle states it, or the repo's VERSION file under `swift run`.
enum AppVersion {
    static let current: String = {
        if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String, !v.isEmpty { return v }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        if let s = try? String(contentsOf: repo.appendingPathComponent("VERSION"), encoding: .utf8) {
            return s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return "0.0.0"
    }()
}
