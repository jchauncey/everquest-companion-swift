// The performance HUD: this process's CPU and memory, sampled once a second and only while the
// switch in Preferences → Performance is on.
//
// NOTHING RUNS WHILE IT IS OFF — that is the caption's promise, so `setEnabled(false)` invalidates
// the timer and clears the text rather than leaving a sampler ticking into a hidden view.
//
// One process, so one reading: the upstream HUD splits by Electron process and names a separate
// engine binary, and neither exists here — the engine folds on a thread inside this app.
import Foundation
import Observation
import Darwin

@MainActor
@Observable
final class PerfHUD {
    static let shared = PerfHUD()

    /// What the title bar shows — `CPU 3% · 412 MB`. Nil while the HUD is off, and for the one
    /// second before the first interval exists: a percentage needs two samples, and a zero printed
    /// in the meantime would be a measurement nobody took.
    private(set) var text: String?
    private(set) var enabled = false

    /// Percent of ONE core, the upstream convention.
    private(set) var cpuPercent: Double?
    /// Resident bytes at the last sample.
    private(set) var memoryBytes: UInt64 = 0

    private var timer: Timer?
    private var lastCPUNs: UInt64?
    private var lastAt: Date?

    private init() {}

    /// Turn the sampler on or off. Idempotent, so the toggle and the launch-time apply can both
    /// call it.
    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        if on {
            _ = takeSample()           // the baseline; it produces no rate and no text
            let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else {
            timer?.invalidate()
            timer = nil
            lastCPUNs = nil
            lastAt = nil
            cpuPercent = nil
            memoryBytes = 0
            text = nil
        }
    }

    /// The launch-time apply: the HUD runs from launch when the setting says so, without waiting
    /// for anybody to open Preferences.
    func applyFromPrefs() { setEnabled(Prefs.shared.perfHUD) }

    private func tick() {
        guard let s = takeSample() else { return }
        text = Self.format(cpuPercent: s.rate, memoryBytes: s.resident)
    }

    /// Read the process's counters and turn them into a rate against the last read.
    @discardableResult
    private func takeSample() -> (rate: Double?, resident: UInt64)? {
        guard let s = Self.sample() else { return nil }
        let now = Date()
        var rate: Double?
        if let lastNs = lastCPUNs, let lastAt, now.timeIntervalSince(lastAt) > 0.05 {
            let cpuNs = Double(s.cpuNs &- lastNs)
            let wallNs = now.timeIntervalSince(lastAt) * 1_000_000_000
            rate = max(0, cpuNs / wallNs * 100)
        }
        lastCPUNs = s.cpuNs
        lastAt = now
        cpuPercent = rate
        memoryBytes = s.residentBytes
        return (rate, s.residentBytes)
    }

    /// `CPU 3% · 412 MB`. A rate that does not exist yet is a dash, never a zero.
    static func format(cpuPercent: Double?, memoryBytes: UInt64) -> String {
        let mb = Int((Double(memoryBytes) / 1_048_576).rounded())
        let cpu = cpuPercent.map { "\(Int($0.rounded()))%" } ?? "—"
        return "CPU \(cpu) · \(mb) MB"
    }

    /// This process's cumulative CPU time in nanoseconds and its resident size in bytes, as the
    /// kernel reports them. Nil when the call fails, which is reported rather than guessed at.
    static func sample() -> (cpuNs: UInt64, residentBytes: UInt64)? {
        var info = rusage_info_current()
        let ok = withUnsafeMutablePointer(to: &info) { p -> Int32 in
            p.withMemoryRebound(to: (rusage_info_t?).self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_CURRENT, $0)
            }
        }
        guard ok == 0 else { return nil }
        return (info.ri_user_time &+ info.ri_system_time, info.ri_resident_size)
    }
}
