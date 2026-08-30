// The launch's own stopwatch — the marks behind Preferences → Performance's "Last startup".
//
// It is recorded on EVERY launch, whether the performance HUD is on or not, because the question
// it answers ("why was that launch slow?") is always asked afterwards.
//
// Every mark is milliseconds since PROCESS START, read from the kernel rather than from whenever
// this file first happened to load, so a mark taken before the first window is measured against
// the moment the user actually double-clicked. The profile is written to UserDefaults on every
// mark, so a launch that never finished still leaves the phases it reached.
import Foundation
import Darwin

/// One phase that landed: what it is called, and how far into the launch it was.
struct StartupMark: Codable, Equatable {
    var phase: String
    /// Milliseconds since this process started. Never a wall clock.
    var atMs: Double
}

/// A phase's slice of the launch: when it landed, and how long it took to get there.
struct StartupPhaseTiming: Identifiable, Equatable {
    var phase: String
    var atMs: Double
    /// `atMs` less the previous mark's (the first phase's is its own `atMs`).
    var durationMs: Double
    var id: String { phase }
}

/// One launch, as the page draws it.
struct StartupProfile: Codable, Equatable {
    /// Wall clock of the launch, so "Last startup" can say when.
    var startedAt: Date
    /// App version, so a profile read next week names the build it describes.
    var version: String
    /// The marks, in the order they landed.
    var marks: [StartupMark]

    /// The last mark — how long the launch took to reach the furthest phase it reached.
    var totalMs: Double { marks.map(\.atMs).max() ?? 0 }

    /// False while a launch is still short of a phase, which the page says out loud rather than
    /// drawing a total that is not one yet.
    var complete: Bool { AppTiming.phases.allSatisfy { p in marks.contains { $0.phase == p } } }

    /// Each phase with the gap it closed — its `atMs` less the previous mark's. Sorted by when
    /// they landed rather than by the fixed list, because two phases that race land in the order
    /// they actually landed and an assumed order would draw a negative bar.
    var timings: [StartupPhaseTiming] {
        var previous = 0.0
        return marks.sorted { $0.atMs < $1.atMs }.map { m in
            let d = max(0, m.atMs - previous)
            previous = m.atMs
            return StartupPhaseTiming(phase: m.phase, atMs: m.atMs, durationMs: d)
        }
    }
}

enum AppTiming {
    /// The phases this app can honestly mark, in boot order.
    ///
    /// The upstream list has two more — "Window system ready" and "Caches + services ready" — that
    /// name Electron's `app.whenReady` and its protocol/cache registration. This app has neither
    /// step, and a bar drawn for a phase nothing reaches is a fabricated measurement, so they are
    /// absent rather than zeroed.
    static let phases: [String] = [
        "Settings loaded",
        "Spell + mob knowledge loaded",
        "Window created",
        "Log session started",
        "Log history replayed",
        "Interface drawn"
    ]

    private static let storeKey = "perf.startup.last"
    private static let lock = NSLock()
    private static var marks: [StartupMark] = []

    /// When this process began, from the kernel. `Date()` only if the kernel refuses, which is the
    /// honest fallback — a first-touch baseline would silently subtract the whole of app launch.
    static let processStart: Date = readProcessStart()

    /// The profile the PREVIOUS launch persisted, read once and before this launch writes anything.
    static let previous: StartupProfile? = readStored()

    /// Milliseconds since this process started.
    static func sinceLaunchMs() -> Double { Date().timeIntervalSince(processStart) * 1000 }

    /// Record a phase. Safe from any thread; a phase already marked is kept at its first landing,
    /// because a second call is a caller's mistake and the first number is the true one.
    static func mark(_ phase: String) {
        _ = previous  // read the last launch's file before this launch overwrites it
        let at = sinceLaunchMs()
        lock.lock()
        guard phases.contains(phase), !marks.contains(where: { $0.phase == phase }) else {
            lock.unlock()
            return
        }
        marks.append(StartupMark(phase: phase, atMs: at))
        let snapshot = marks
        lock.unlock()
        store(StartupProfile(startedAt: processStart, version: AppVersion.current, marks: snapshot))
    }

    /// What the page draws: this launch if it has marked anything, otherwise the last one that did.
    static func profile() -> StartupProfile? {
        lock.lock()
        let snapshot = marks
        lock.unlock()
        if snapshot.isEmpty { return previous }
        return StartupProfile(startedAt: processStart, version: AppVersion.current, marks: snapshot)
    }

    /// Forget both this launch's marks and the stored one. Tests only.
    static func reset() {
        lock.lock()
        marks = []
        lock.unlock()
        UserDefaults.standard.removeObject(forKey: storeKey)
    }

    // MARK: - Storage

    private static func store(_ p: StartupProfile) {
        guard let data = try? JSONEncoder().encode(p) else { return }
        UserDefaults.standard.set(data, forKey: storeKey)
    }

    private static func readStored() -> StartupProfile? {
        guard let data = UserDefaults.standard.data(forKey: storeKey) else { return nil }
        return try? JSONDecoder().decode(StartupProfile.self, from: data)
    }

    private static func readProcessStart() -> Date {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return Date() }
        let tv = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
    }
}

/// The upstream `formatMs`: seconds to two decimals once past a second, whole milliseconds below.
enum StartupFormat {
    static func ms(_ v: Double) -> String {
        let m = max(0, v.isFinite ? v : 0)
        if m >= 1000 {
            // Two decimals, trailing zeros dropped — `String(round(v / 1000, 2))`'s own output.
            var t = String(format: "%.2f", (m / 1000 * 100).rounded() / 100)
            while t.hasSuffix("0") { t.removeLast() }
            if t.hasSuffix(".") { t.removeLast() }
            return "\(t) s"
        }
        return "\(Int(m.rounded())) ms"
    }

    /// "8/26/2026, 9:51:18 PM" — the upstream `formatDateTime`, in the user's own locale.
    static func dateTime(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .medium
        return f.string(from: d)
    }
}
