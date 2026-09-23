// The composition root: the in-process engine, one client, the install/character state, and the
// connection-wide streams (progress, fires, con cards) the whole app reads.
import Foundation
import Observation
import EQCompanionCore
import EQEngine
import EQKnowledge

enum LaunchPhase: Equatable {
    case starting
    case folding
    case live
    case absent
    case failed
}

struct CharacterRef: Identifiable, Hashable {
    var name: String
    var server: String
    var logPath: String
    var lastPlayed: Int64?
    var id: String { logPath }
    var label: String { "\(name) @ \(server)" }
}

struct HealthReading: Equatable {
    var status: String
    var epoch: Int
    var uptimeMs: Int64
    var events: Int
    var offset: Int64?
    var lastEventTs: Int64?
    var logMtimeMs: Int64?
}

@MainActor
@Observable
final class AppModel {
    // MARK: - Engine (in-process: the World folds on its own thread; LocalEngine is the link)
    private(set) var world: World?
    private var link: LocalEngine?
    let client = EngineClient()
    var connection: ConnectionState = .closed
    var epoch: Int?
    var progress: FoldProgress?
    var foldRing = FoldRing()
    var health: HealthReading?
    var launchPhase: LaunchPhase = .starting
    var fault: EngineFault?
    var debugLog: [String] = []

    // MARK: - Install and characters
    var installOverride: String = UserDefaults.standard.string(forKey: "eq.installOverride") ?? "" {
        didSet { UserDefaults.standard.set(installOverride, forKey: "eq.installOverride") }
    }
    var install: ResolvedInstall?
    var logsReadable: String = "unknown"
    /// True when launch resolved NO install: the window opens with the setup sheet, because an
    /// app that reads a log it cannot find should say so first, not sit empty.
    var showInstallPrompt = false
    var characters: [CharacterRef] = []
    var selectedLogPath: String? = UserDefaults.standard.string(forKey: "eq.selectedLogPath") {
        didSet { UserDefaults.standard.set(selectedLogPath, forKey: "eq.selectedLogPath") }
    }
    var attached: CharacterRef?

    // MARK: - Streams
    var fires: [FireMessage] = []
    var lastConCard: JSONValue?
    var moduleSeqs: [String: Int] = [:]
    let alerts = AlertStore()
    let player = AlertPlayer()

    // MARK: - Overlay + preferences
    var overlayVisible: Bool = UserDefaults.standard.bool(forKey: "eq.overlay.visible") {
        didSet { UserDefaults.standard.set(overlayVisible, forKey: "eq.overlay.visible") }
    }
    var overlayLocked: Bool = UserDefaults.standard.bool(forKey: "eq.overlay.locked") {
        didSet { UserDefaults.standard.set(overlayLocked, forKey: "eq.overlay.locked") }
    }
    var overlayScope: String = UserDefaults.standard.string(forKey: "eq.overlay.scope") ?? "fight" {
        didSet { UserDefaults.standard.set(overlayScope, forKey: "eq.overlay.scope") }
    }

    static let stateDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("EQCompanion/engine-state", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private var healthTask: Task<Void, Never>?
    private var attachTask: Task<Void, Never>?
    private var healthMisses = 0

    init() {
        client.debug = { [weak self] s in self?.note(s) }
        _ = client.onState { [weak self] s in self?.connection = s }
        _ = client.onProgress { [weak self] p in self?.progressed(p) }
        _ = client.onEpoch { [weak self] e, reason in
            self?.epoch = e
            if reason == "attach" || reason == "restart" {
                self?.launchPhase = .folding
                self?.foldRing = FoldRing()
            }
        }
        _ = client.onFire { [weak self] f in self?.fired(f) }
        _ = client.onConCard { [weak self] c in self?.lastConCard = c }
        _ = client.onModuleChanged { [weak self] m, seq in self?.moduleSeqs[m] = seq }
        alerts.onChange = { [weak self] in self?.pushAlerts() }
        note("EQ Companion starting (pid \(ProcessInfo.processInfo.processIdentifier))")
    }

    func note(_ s: String) {
        debugLog.append("\(Format.time(ms: Int64(Date().timeIntervalSince1970 * 1000))) \(s)")
        if debugLog.count > 300 { debugLog.removeFirst(debugLog.count - 300) }
        ClientLog.write(s)
    }

    // MARK: - Boot

    func boot() {
        resolveInstall()
        if install == nil { showInstallPrompt = true }
        startEngine()
    }

    /// Retire the fold so its state files are written, then let the process end. The ingest exits
    /// at its next slice boundary (≤ 25 ms of nap in the live tail), so a short wait is enough.
    func shutdown() {
        healthTask?.cancel()
        client.detach()
        link?.close()
        link = nil
        world?.shutdown()
        world = nil
        Thread.sleep(forTimeInterval: 0.4)
    }

    /// Build the world and attach the client through the in-process link. Nothing is spawned.
    private func startEngine() {
        launchPhase = .starting
        fault = nil
        diagnosticSink = { line in ClientLog.write(line) }
        KnowledgeCorpus.shared().warm()
        AppTiming.mark("Spell + mob knowledge loaded")
        let w = World(ingest: starter(foldingSinks()))
        world = w
        let l = LocalEngine.attach(world: w, to: client)
        link = l
        note("engine: in-process world built")
        pushAlerts()
        attachTask?.cancel()
        attachTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshCharacters()
            await self.attachSelected()
            self.startHealth()
        }
    }

    func resolveInstall() {
        install = Discovery.resolve(override: installOverride.isEmpty ? nil : installOverride)
        if let i = install { note("install: \(i.root.path) (\(i.source))") } else { note("install: not found") }
    }

    /// The user picked a folder (or typed one): normalize, re-list, re-attach.
    func setInstallOverride(_ path: String) {
        installOverride = path
        resolveInstall()
        if install != nil { showInstallPrompt = false }
        Task { await self.refreshCharacters(); await self.attachSelected() }
    }

    /// Rebuild the world from scratch — a respawn is a launch: fresh epoch, fresh state.
    func retryEngine() {
        healthTask?.cancel()
        client.detach()
        link?.close()
        link = nil
        // Retire the old fold first: its ingest thread holds the world and only exits once its
        // generation is no longer owned, so a bare `world = nil` leaves it tailing forever.
        world?.shutdown()
        world = nil
        attached = nil
        health = nil
        startEngine()
    }

    // MARK: - Characters and attach

    func refreshCharacters() async {
        guard client.isReady, let install else {
            if install == nil { characters = []; logsReadable = "missing" }
            return
        }
        do {
            _ = try await client.request(Op.logsSetDir, ["dir": .string(install.logsDir.path)])
            let r = try await client.request(Op.logsList)
            logsReadable = r["readable"].string ?? "unknown"
            characters = (r["characters"].array ?? []).compactMap { c in
                guard let name = c["name"].string, let server = c["server"].string, let path = c["logPath"].string else { return nil }
                return CharacterRef(name: name, server: server, logPath: path, lastPlayed: c["lastPlayed"].int64)
            }
            if let sel = selectedLogPath, !characters.contains(where: { $0.logPath == sel }) {
                selectedLogPath = nil
            }
            if selectedLogPath == nil { selectedLogPath = characters.first?.logPath }
        } catch {
            note("logs.list failed: \(error)")
        }
    }

    func select(_ c: CharacterRef) {
        selectedLogPath = c.logPath
        Task { await attachSelected() }
    }

    func attachSelected() async {
        guard client.isReady, let path = selectedLogPath,
              let c = characters.first(where: { $0.logPath == path }) else { return }
        if attached?.logPath == path { return }
        do {
            launchPhase = .folding
            foldRing = FoldRing()
            let r = try await client.request(Op.sessionAttach,
                                             ["logPath": .string(path), "stateDir": .string(Self.stateDir.path)],
                                             deadline: 60)
            if r["accepted"].bool == true {
                attached = c
                AppTiming.mark("Log session started")
                // Fold inputs the engine holds per generation: a fresh fold trusts nobody but you
                // and knows no class corrections until the app says them again.
                await pushBuffTrust()
                await pushComboCorrections()
                note("attached \(c.label) (epoch \(r["epoch"].int ?? -1))")
            }
        } catch {
            note("session.attach failed: \(error)")
        }
    }

    private func progressed(_ p: FoldProgress) {
        guard !p.live else {
            if launchPhase == .folding { launchPhase = .live; AppTiming.mark("Log history replayed") }
            return
        }
        progress = p
        foldRing.push(p, at: Date())
        if p.pct >= 100 {
            // The scan's last frame; the live handoff follows. Give the bar a beat, then go live.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 400_000_000)
                if self?.launchPhase == .folding { self?.launchPhase = .live; AppTiming.mark("Log history replayed") }
            }
        } else if launchPhase != .folding {
            launchPhase = .folding
        }
    }

    // MARK: - Health

    private func startHealth() {
        healthTask?.cancel()
        healthMisses = 0
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollHealth()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    func pollHealth() async {
        guard client.isReady else { return }
        do {
            let r = try await client.request(Op.sessionHealth, deadline: 5)
            healthMisses = 0
            health = HealthReading(status: r["status"].string ?? "?",
                                   epoch: r["epoch"].int ?? 0,
                                   uptimeMs: r["uptimeMs"].int64 ?? 0,
                                   events: r["events"].int ?? 0,
                                   offset: r["mark"]["offset"].int64,
                                   lastEventTs: r["lastEventTs"].int64,
                                   logMtimeMs: r["logMtimeMs"].int64)
            if health?.status == "live", launchPhase == .folding { launchPhase = .live; AppTiming.mark("Log history replayed") }
        } catch {
            healthMisses += 1
            note("health: \(error) (\(healthMisses))")
            if healthMisses >= 3 {
                healthMisses = 0
                fault = EngineFault(kind: .unhealthy, attempts: 1, detail: "\(error)")
                launchPhase = .failed
            }
        }
    }

    // MARK: - Alerts

    func pushAlerts() {
        guard client.isReady else { return }
        let defs = alerts.definitions()
        Task { [weak self] in
            do {
                _ = try await self?.client.request(Op.alertsDefine, ["defs": .array(defs)])
            } catch {
                self?.note("alerts.define failed: \(error)")
            }
        }
    }

    private func fired(_ f: FireMessage) {
        fires.insert(f, at: 0)
        if fires.count > 200 { fires.removeLast(fires.count - 200) }
        player.play(f, def: alerts.def(named: f.rule))
    }

    func newSessionMark() async {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        _ = try? await client.request(Op.sessionMarkAdd, ["at": .int(now)])
    }
}

// MARK: - The fold-progress readout

/// The engine states what it measured; the extrapolation is a display decision taken against the
/// host's wall clock. Twelve samples at ~4 Hz is a three-second window.
struct FoldRing {
    static let samples = 12
    static let minSpanMs = 600.0
    private(set) var entries: [(FoldProgress, Date)] = []

    mutating func push(_ p: FoldProgress, at: Date) {
        if let last = entries.last, p.offset < last.0.offset { entries = [] }
        entries.append((p, at))
        if entries.count > Self.samples { entries.removeFirst(entries.count - Self.samples) }
    }

    var rate: Double? {
        guard let first = entries.first, let last = entries.last, entries.count > 1 else { return nil }
        let span = last.1.timeIntervalSince(first.1) * 1000
        let moved = Double(last.0.offset - first.0.offset)
        guard span >= Self.minSpanMs, moved > 0 else { return nil }
        return moved / span
    }

    var etaText: String? {
        guard let last = entries.last?.0, let r = rate else { return nil }
        let remaining = Double(last.logSize - last.offset)
        guard remaining > 0 else { return nil }
        let ms = remaining / r
        guard ms.isFinite, ms < 24 * 3600 * 1000 else { return nil }
        return "about \(Format.duration(ms: ms)) left"
    }
}


/// `~/Library/Application Support/EQCompanion/client.log` — the client's own notes and the engine's
/// stderr, appended, capped by truncation at 2 MB. The first thing to read when a panel is empty.
enum ClientLog {
    static let file: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("EQCompanion", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("client.log")
    }()
    private static let queue = DispatchQueue(label: "eqcompanion.clientlog")
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func write(_ line: String) {
        let text = "\(stamp.string(from: Date())) \(line)\n"
        queue.async {
            let fm = FileManager.default
            if let attrs = try? fm.attributesOfItem(atPath: file.path), let size = attrs[.size] as? Int, size > 2_000_000 {
                try? fm.removeItem(at: file)
            }
            if !fm.fileExists(atPath: file.path) { fm.createFile(atPath: file.path, contents: nil) }
            if let h = try? FileHandle(forWritingTo: file) {
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: Data(text.utf8))
                try? h.close()
            }
        }
    }
}
