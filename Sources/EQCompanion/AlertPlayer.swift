// What a fire does out loud: a pack sound, a system sound, or speech — through the frameworks the
// Mac already has. The only bytes ever downloaded are the sound packs the user (or first launch)
// installs, and those go through SoundPackRegistry.
import Foundation
import AppKit
import AVFoundation
import EQCompanionCore

/// One sound inside a pack.
struct PackSound: Identifiable, Equatable {
    var id: String
    var label: String
    var file: String
}

/// A pack on disk: `<packsDir>/<id>/manifest.json` with `{id, name, sounds: {id: {file, label}}}`.
struct SoundPackInfo: Identifiable, Equatable {
    var id: String
    var name: String
    var license: String?
    var sourceRepo: String?
    var sourceRef: String?
    var sounds: [PackSound]
    /// The reserved pack the user fills themselves; it is never a registry pack.
    var isMine: Bool { id == userSoundsPackId }
}

/// The reserved id for the user's own imported audio (`USER_SOUNDS_PACK_ID`).
let userSoundsPackId = "my-sounds"
/// Its display name in every picker (`USER_SOUNDS_PACK_NAME`).
let userSoundsPackName = "My sounds"
/// The three formats we have a decoder and a MIME for (`USER_SOUND_EXTENSIONS`).
let userSoundExtensions = ["wav", "mp3", "ogg"]

@MainActor
final class AlertPlayer {
    private var players: [AVAudioPlayer] = []
    private let synth = AVSpeechSynthesizer()
    private var cache: [SoundPackInfo] = []
    private var cacheLoaded = false
    private var window = AudioWindow()

    /// The three global switches. Owned here because this is what applies them.
    let prefs = AlertPrefs()

    /// First launch installs the shipped Alan Rickman pack, unless the user threw it away — the
    /// seeded alerts name its lines, and without it they are a beep. Best effort and silent: a
    /// failed run retries next launch and the Sound packs sheet installs it by hand meanwhile.
    init() {
        Task { await SoundPackRegistry.provisionDefaultPack(player: self) }
    }

    static let packsDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("EQCompanion/soundpacks", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// `<packsDir>/my-sounds` — drop .wav/.mp3/.ogg in here and they become choices.
    static var mySoundsDir: URL {
        let dir = packsDir.appendingPathComponent(userSoundsPackId, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Packs

    /// Forget the on-disk listing; the next read re-scans. Called after an install/remove/import.
    func invalidate() {
        cacheLoaded = false
        cache = []
    }

    /// Every pack on disk, the reserved "My sounds" one included.
    func packInfos() -> [SoundPackInfo] {
        if cacheLoaded { return cache }
        var out: [SoundPackInfo] = []
        let fm = FileManager.default
        for dir in (try? fm.contentsOfDirectory(atPath: Self.packsDir.path))?.sorted() ?? [] {
            if dir.hasPrefix(".") || dir.hasSuffix(".installing") { continue }
            if dir == userSoundsPackId { continue }
            if let p = Self.readPack(id: dir) { out.append(p) }
        }
        out.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        // The user's own audio always sorts last, so the packs they browsed for come first.
        if let mine = Self.readMySounds() { out.append(mine) }
        cache = out
        cacheLoaded = true
        return out
    }

    /// The legacy tuple shape the pickers were written against.
    func packs() -> [(id: String, name: String, sounds: [(id: String, label: String)])] {
        packInfos().map { p in (id: p.id, name: p.name, sounds: p.sounds.map { (id: $0.id, label: $0.label) }) }
    }

    func pack(_ id: String) -> SoundPackInfo? { packInfos().first { $0.id == id } }

    func label(pack packId: String, sound soundId: String) -> String? {
        if packId == "system" { return AlertPlayer.systemSounds.contains(soundId) ? soundId : nil }
        return pack(packId)?.sounds.first { $0.id == soundId }?.label
    }

    /// Read one pack directory's manifest.
    private static func readPack(id: String) -> SoundPackInfo? {
        let m = packsDir.appendingPathComponent(id).appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: m), let v = try? JSONValue.parse(data) else { return nil }
        let sounds = (v["sounds"].object ?? [:]).map { (k, s) in
            PackSound(id: k, label: s["label"].string ?? k, file: s["file"].string ?? "")
        }.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
        guard !sounds.isEmpty else { return nil }
        return SoundPackInfo(id: v["id"].string ?? id, name: v["name"].string ?? id,
                             license: v["license"].string, sourceRepo: v["source"]["repo"].string,
                             sourceRef: v["source"]["ref"].string, sounds: sounds)
    }

    /// The reserved pack, synthesized from whatever audio is in the folder RIGHT NOW — no manifest
    /// to keep in step, so a file the user drags in is a choice the next time a picker opens.
    private static func readMySounds() -> SoundPackInfo? {
        let dir = mySoundsDir
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { userSoundExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        guard !files.isEmpty else { return nil }
        var taken = Set<String>()
        var sounds: [PackSound] = []
        for f in files {
            let stem = (f as NSString).deletingPathExtension
            sounds.append(PackSound(id: userSoundId(stem, taken: &taken), label: stem.isEmpty ? f : stem, file: f))
        }
        return SoundPackInfo(id: userSoundsPackId, name: userSoundsPackName, license: nil,
                             sourceRepo: nil, sourceRef: nil, sounds: sounds)
    }

    /// `userSoundId`: lowercase, non-alphanumerics folded to single dashes, capped, de-duplicated.
    private static func userSoundId(_ stem: String, taken: inout Set<String>) -> String {
        var slug = stem.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.reduce(into: "") { acc, c in
            if c == "-" && acc.hasSuffix("-") { return }
            acc.append(c)
        }
        while slug.hasPrefix("-") { slug.removeFirst() }
        while slug.hasSuffix("-") { slug.removeLast() }
        if slug.count > 64 { slug = String(slug.prefix(64)) }
        while slug.hasSuffix("-") { slug.removeLast() }
        var id = slug.isEmpty ? "sound" : slug
        if taken.contains(id) {
            var n = 2
            while taken.contains("\(id)-\(n)") { n += 1 }
            id = "\(id)-\(n)"
        }
        taken.insert(id)
        return id
    }

    static let systemSounds = ["Glass", "Ping", "Pop", "Purr", "Hero", "Funk", "Submarine", "Blow",
                               "Bottle", "Frog", "Morse", "Sosumi", "Tink", "Basso"]

    // MARK: - Playing

    /// A fire from the engine. Global mute wins over everything; the coalescing window folds a
    /// burst of the same audible thing into one, unless this def (or the global switch) opts out.
    func play(_ fire: FireMessage, def: AlertDef?) {
        guard !prefs.muted else { return }
        let audio = def?.audio ?? "sound"
        let words = (audio == "speech" || audio == "both") ? text(for: fire, def: def) : ""
        let soundKey = (audio == "sound" || audio == "both") ? (def.map(\.soundKey) ?? fire.sound) : ""
        let identity = "\(soundKey)|\(words)"
        let bypass = prefs.alwaysPlayAll || (def?.alwaysPlay ?? false)
        guard window.admit(identity, now: Int64(Date().timeIntervalSince1970 * 1000), bypass: bypass) else { return }
        let volume = Float((def?.volume ?? 1) * prefs.globalVolume)
        if !soundKey.isEmpty { playSound(key: soundKey, volume: volume) }
        if !words.isEmpty { speak(words, volume: volume) }
    }

    /// The row's test button and the editor's: the same path, minus the throttle (the user asked
    /// for this one, now) but never past a global mute.
    func preview(def: AlertDef) {
        guard !prefs.muted else { return }
        let volume = Float(def.volume * prefs.globalVolume)
        if def.audio == "sound" || def.audio == "both" { playSound(key: def.soundKey, volume: volume) }
        if def.audio == "speech" || def.audio == "both" {
            let f = FireMessage(at: 0, rule: def.name, sound: def.soundKey, message: "",
                                captures: ["target": "a fire giant", "player": "Zoddrick"],
                                spell: "Example Spell III", dueAt: nil)
            speak(text(for: f, def: def), volume: volume)
        }
    }

    /// Play one pack sound directly (the pack browser, "My sounds", the sound dropdown preview).
    func previewSound(pack packId: String, sound soundId: String) {
        guard !prefs.muted else { return }
        playSound(key: "\(packId)/\(soundId)", volume: Float(prefs.globalVolume))
    }

    /// `<packId>/<soundId>`: a pack on disk, or `system/<Name>` for a built-in NSSound.
    func playSound(key: String, volume: Float) {
        let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { NSSound.beep(); return }
        let (packId, soundId) = (parts[0], parts[1])
        if packId == "system" {
            if let s = NSSound(named: NSSound.Name(soundId)) {
                s.volume = volume
                s.play()
            } else {
                NSSound.beep()
            }
            return
        }
        guard let url = fileURL(pack: packId, sound: soundId) else { NSSound.beep(); return }
        guard let p = try? AVAudioPlayer(contentsOf: url) else { NSSound.beep(); return }
        p.volume = volume
        players.removeAll { !$0.isPlaying }
        players.append(p)
        p.play()
    }

    /// Where a pack sound's bytes are, or nil when the pack or the line is gone (a removed pack,
    /// a manifest that drifted) — the caller beeps rather than inventing audio.
    func fileURL(pack packId: String, sound soundId: String) -> URL? {
        guard let p = pack(packId), let s = p.sounds.first(where: { $0.id == soundId }) else { return nil }
        let base = Self.packsDir.appendingPathComponent(packId)
        let url = base.appendingPathComponent(s.file)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Say it in the voice Preferences → Voice chose. `volume` is the caller's own level (the
    /// alert's, times the global one); the voice's volume multiplies on top of it, the way the
    /// upstream engine applies its gain.
    func speak(_ text: String, volume: Float) {
        guard !text.isEmpty else { return }
        let p = Prefs.shared
        let u = AVSpeechUtterance(string: text)
        u.volume = max(0, min(1, volume * Float(p.voiceVolume)))
        u.rate = Self.utteranceRate(p.voiceRate)
        // An identifier the machine no longer has (a voice removed in System Settings) is not an
        // error: the synthesizer's own default speaks instead, which is what an empty id means too.
        if !p.voiceId.isEmpty, let v = AVSpeechSynthesisVoice(identifier: p.voiceId) { u.voice = v }
        synth.speak(u)
    }

    /// The ▶ beside the voice picker: the alert speech path minus the throttle, but never past a
    /// global mute — the same rule `preview(def:)` follows, and the sentence the Voice page leads
    /// with ("Muting alerts silences speech too") is what says so.
    func speakPreview(_ text: String) {
        guard !prefs.muted else { return }
        speak(text, volume: Float(prefs.globalVolume))
    }

    /// The speed slider (0.5×…2×) as an `AVSpeechUtterance` rate. 1× IS the platform's default
    /// rate, scaled proportionally either side of it and clamped to what the synthesizer accepts —
    /// so "normal" means what the Mac means by normal, not a number we invented.
    static func utteranceRate(_ multiplier: Double) -> Float {
        let scaled = AVSpeechUtteranceDefaultSpeechRate * Float(multiplier)
        return max(AVSpeechUtteranceMinimumSpeechRate, min(AVSpeechUtteranceMaximumSpeechRate, scaled))
    }

    /// Rank-stripped: `Mesmerization III` → `Mesmerization`.
    static func stripRank(_ name: String) -> String {
        let parts = name.split(separator: " ")
        guard let last = parts.last, parts.count > 1 else { return name }
        let roman = Set("IVXLC")
        if last.allSatisfy({ roman.contains($0) }) { return parts.dropLast().joined(separator: " ") }
        if last.hasPrefix("Rk."), parts.count > 2 { return parts.dropLast(2).joined(separator: " ") }
        return name
    }

    func text(for fire: FireMessage, def: AlertDef?) -> String {
        let mode = def?.speechMode ?? "alertName"
        switch mode {
        case "custom":
            var phrase = def?.phrase ?? fire.rule
            for (k, v) in fire.captures { phrase = phrase.replacingOccurrences(of: "{\(k)}", with: v) }
            if let s = fire.spell { phrase = phrase.replacingOccurrences(of: "{spell}", with: Self.stripRank(s)) }
            return phrase.isEmpty ? fire.rule : phrase
        case "spellName":
            return fire.spell.map(Self.stripRank) ?? fire.rule
        case "spellFirstWord":
            return fire.spell.map { String(Self.stripRank($0).split(separator: " ").first ?? "") } ?? fire.rule
        default:
            return fire.rule
        }
    }
}
