// The respawn watch preferences the app pushes (fold/src/modules/respawn.rs `RespawnPrefs`).
import Foundation
import EQLog
import EQCompanionCore

/// One mob the user has chosen to watch, and the number they chose for it.
public struct RespawnWatchPref: Sendable, Equatable {
    /// Canonical (lowercased) mob name — what a death line's name canonicalizes to.
    public var key: String
    /// The name as the log printed it, for display.
    public var display: String
    /// The user's own respawn, in SECONDS. Rung 1; absent means "use what you learn".
    public var customSec: Int64?
    public init(key: String, display: String, customSec: Int64?) { self.key = key; self.display = display; self.customSec = customSec }

    var json: JSONValue {
        var o: [String: JSONValue] = ["key": .string(key), "display": .string(display)]
        if let customSec { o["customSec"] = .int(customSec) }
        return .object(o)
    }
}

/// `DEFAULT_RESPAWN_PREFS` is an empty list and that is the shipped default: tracking is opt-in per
/// mob, so a caller that passes nothing gets a module that clocks nothing.
public struct RespawnPrefs: Sendable, Equatable {
    public var watches: [RespawnWatchPref] = []
    public init() {}
    public init(watches: [RespawnWatchPref]) { self.watches = watches }

    var json: JSONValue { ["watches": .array(watches.map(\.json))] }

    /// Read a pushed `respawn.define` payload — `{ watches: [...] }`, as the store holds it.
    ///
    /// It normalizes as `shared/respawn.ts normalizeRespawnPrefs` does, because an engine that
    /// trusted the wire would be a third place with its own idea of what a watch is. The key is
    /// lowercased and capped, a watch with no key or a duplicate key is dropped, an out-of-range
    /// `customSec` is dropped (reading as "use what you learn", never as zero), and the list is
    /// capped.
    ///
    /// nil for a payload that is not an object, which leaves the previous set standing — the honest
    /// outcome for app knowledge that arrived malformed.
    public static func read(_ payload: JSONValue) -> RespawnPrefs? {
        /// `RESPAWN_MAX_WATCHES`.
        let maxWatches = 200
        /// `MAX` on a stored key or display, in chars.
        let maxName = 64
        /// `RESPAWN_CUSTOM_MIN_SEC` / `RESPAWN_CUSTOM_MAX_SEC`.
        let minSec: Int64 = 1
        let maxSec: Int64 = 7 * 24 * 3600

        guard payload.object != nil else { return nil }
        var watches: [RespawnWatchPref] = []
        var seen: Set<String> = []
        for w in payload["watches"].array ?? [] {
            let key = takeChars(rustTrim(w["key"].string ?? "").lowercased(), maxName)
            if key.isEmpty || seen.contains(key) { continue }
            seen.insert(key)
            let display = takeChars(rustTrim(w["display"].string ?? ""), maxName)
            var customSec: Int64?
            if let raw = w["customSec"].double {
                let r = raw.rounded()
                if r.isFinite, r >= Double(minSec), r <= Double(maxSec) { customSec = Int64(r) }
            }
            watches.append(RespawnWatchPref(key: key, display: display.isEmpty ? key : display, customSec: customSec))
            if watches.count >= maxWatches { break }
        }
        return RespawnPrefs(watches: watches)
    }

    /// `str::trim` — Unicode whitespace, which is what the Rust normalizer runs.
    private static func rustTrim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// `chars().take(n)` — a Rust char is a Unicode scalar.
    private static func takeChars(_ s: String, _ n: Int) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.prefix(n)))
    }
}
