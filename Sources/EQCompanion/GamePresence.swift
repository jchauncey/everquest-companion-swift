// Is EverQuest running, and is it the window the player is in? The game runs inside a CrossOver
// bottle, so it is not an ordinary app: it shows up as a wine process named for the executable
// (`eqgame.exe`) and, when frontmost, as CrossOver's application. Both readings are polled, never
// pushed — nothing here watches the game, it only asks the OS twice a second what is running.
import AppKit
import Darwin
import Observation

@Observable
final class GamePresence {
    static let shared = GamePresence()

    /// A game process exists.
    private(set) var isRunning = false
    /// The game is the frontmost application.
    private(set) var isFrontmost = false

    private var timer: Timer?

    /// Start polling (idempotent). Pages and overlays read the two flags; nobody polls for itself.
    func start() {
        guard timer == nil else { return }
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func poll() {
        let running = Self.gameProcessExists()
        let front = NSWorkspace.shared.frontmostApplication
        let name = (front?.localizedName ?? "").lowercased()
        let bundle = (front?.bundleIdentifier ?? "").lowercased()
        let frontIsGame = running && (name.contains("everquest") || name.contains("eqgame")
            || (bundle.contains("codeweavers") && name != "crossover"))
        if running != isRunning { isRunning = running }
        if frontIsGame != isFrontmost { isFrontmost = frontIsGame }
    }

    /// Scan the process table for the game's executable name (wine names the process after it).
    static func gameProcessExists() -> Bool {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return false }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard got > 0 else { return false }
        var buf = [CChar](repeating: 0, count: 256)
        for pid in pids.prefix(Int(got)) where pid > 0 {
            let n = proc_name(pid, &buf, UInt32(buf.count))
            guard n > 0 else { continue }
            let name = String(cString: buf).lowercased()
            if name.hasPrefix("eqgame") || name == "everquest" { return true }
        }
        return false
    }
}
