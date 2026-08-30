// Install-root discovery for a Mac: where does EverQuest Legends live, and which folder holds the
// `eqlog_<Char>_<server>.txt` files?
//
// On a Mac the game runs under a Windows compatibility layer, so the Daybreak public path sits
// inside a bottle/prefix's `drive_c`. A manual override always wins, and — as the Electron app
// learned from two field reports — an override is normalized rather than trusted: the install root,
// the `Logs` folder, or a log file all resolve to the same pair.
import Foundation

public struct ResolvedInstall: Sendable, Equatable {
    /// The install root (`<root>/Logs` is the log directory, `<root>/spells_us.txt` the spell table).
    public var root: URL
    /// The directory the `eqlog_*.txt` files actually live in.
    public var logsDir: URL
    /// Where this came from: `manual`, `env`, or the sweep's candidate label.
    public var source: String
}

public enum Discovery {
    /// The Daybreak subpath below a `drive_c`.
    public static let daybreakSubpath = "users/Public/Daybreak Game Company/Installed Games/EverQuest Legends"

    static let logNamePattern = try! NSRegularExpression(pattern: "^eqlog_.+\\.txt$", options: [.caseInsensitive])

    public static func isCharacterLog(_ name: String) -> Bool {
        logNamePattern.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }

    /// Does `dir` hold an `eqlog_*.txt` directly?
    public static func dirHasCharacterLogs(_ dir: URL, fm: FileManager = .default) -> Bool {
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return false }
        return names.contains(where: isCharacterLog)
    }

    public static func rootHasLogs(_ root: URL, fm: FileManager = .default) -> Bool {
        dirHasCharacterLogs(root.appendingPathComponent("Logs"), fm: fm)
    }

    static func isDirectory(_ url: URL, fm: FileManager) -> Bool {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    static func isFile(_ url: URL, fm: FileManager) -> Bool {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue
    }

    /// What a manual override MEANS. Three shapes a reasonable person picks:
    ///   * a log file (`eqlog_*.txt`)  → its folder is the Logs dir, its parent the root
    ///   * the `Logs` folder itself     → it is the Logs dir, its parent the root
    ///   * the install root             → `<root>/Logs`
    /// Anything else keeps the old behaviour (root as given), and the character count says the rest.
    public static func normalizeOverride(_ path: String, fm: FileManager = .default) -> ResolvedInstall {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        if isFile(url, fm: fm), isCharacterLog(url.lastPathComponent) {
            let logs = url.deletingLastPathComponent()
            return ResolvedInstall(root: logs.deletingLastPathComponent(), logsDir: logs, source: "manual")
        }
        if isDirectory(url, fm: fm) {
            if url.lastPathComponent.lowercased() == "logs" || dirHasCharacterLogs(url, fm: fm) {
                if !isDirectory(url.appendingPathComponent("Logs"), fm: fm) {
                    return ResolvedInstall(root: url.deletingLastPathComponent(), logsDir: url, source: "manual")
                }
            }
        }
        return ResolvedInstall(root: url, logsDir: url.appendingPathComponent("Logs"), source: "manual")
    }

    /// Every place a Mac might keep the game, most likely first. Each is a candidate INSTALL ROOT.
    public static func candidates(home: URL, fm: FileManager = .default) -> [(label: String, root: URL)] {
        var out: [(String, URL)] = []
        let support = home.appendingPathComponent("Library/Application Support")

        func bottles(under dir: URL, label: String) {
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
            for name in names.sorted() {
                let root = dir.appendingPathComponent(name).appendingPathComponent("drive_c").appendingPathComponent(daybreakSubpath)
                out.append(("\(label) bottle \(name)", root))
            }
        }

        // CrossOver keeps its bottles under Application Support.
        bottles(under: support.appendingPathComponent("CrossOver/Bottles"), label: "CrossOver")
        // Whisky (sandboxed) and its default bottle location.
        bottles(under: home.appendingPathComponent("Library/Containers/com.isaacmarovitz.Whisky/Bottles"), label: "Whisky")
        bottles(under: support.appendingPathComponent("com.isaacmarovitz.Whisky/Bottles"), label: "Whisky")
        // Plain Wine / Wineskin-style prefixes.
        out.append(("Wine prefix", home.appendingPathComponent(".wine/drive_c").appendingPathComponent(daybreakSubpath)))
        bottles(under: home.appendingPathComponent(".local/share/wineprefixes"), label: "Wine")
        // Parallels/VM shared folders and a bare copy in the home directory, just in case.
        out.append(("home", home.appendingPathComponent("Daybreak Game Company/Installed Games/EverQuest Legends")))
        out.append(("home", home.appendingPathComponent("EverQuest Legends")))
        return out.map { (label: $0.0, root: $0.1) }
    }

    /// The first candidate whose `Logs` holds a character log, or nil. Bounded by the candidate
    /// list, which is finite and local.
    public static func discover(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                environment: [String: String] = ProcessInfo.processInfo.environment,
                                fm: FileManager = .default) -> ResolvedInstall? {
        if let env = environment["EQ_INSTALL_DIR"], !env.isEmpty {
            var r = normalizeOverride(env, fm: fm)
            r.source = "env"
            return r
        }
        for c in candidates(home: home, fm: fm) where rootHasLogs(c.root, fm: fm) {
            return ResolvedInstall(root: c.root, logsDir: c.root.appendingPathComponent("Logs"), source: c.label)
        }
        return nil
    }

    /// Resolve with a manual override taking precedence over discovery.
    public static func resolve(override: String?,
                               home: URL = FileManager.default.homeDirectoryForCurrentUser,
                               environment: [String: String] = ProcessInfo.processInfo.environment,
                               fm: FileManager = .default) -> ResolvedInstall? {
        if let o = override?.trimmingCharacters(in: .whitespacesAndNewlines), !o.isEmpty {
            return normalizeOverride(o, fm: fm)
        }
        return discover(home: home, environment: environment, fm: fm)
    }
}
