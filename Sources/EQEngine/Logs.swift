// Which characters this install has. The app names the folder and pushes it (`logs.setDir`); this
// file reads it. Port of engined/src/logs.rs.
//
// Everything here is a pure function of a directory path plus whatever the filesystem says, so the
// whole answer — including the three ways a directory can fail to be one — is exercised against a
// temp folder. The world holds the pushed path and the op table turns the answer into a reply;
// neither knows what an `eqlog_` filename is.
//
// None of this is fold state and none of it may become any. An mtime is a served process fact: it
// is not addressed by (log identity, byte offset) and no replay can produce it, so nothing here is
// pushed into a module.
//
// The app keeps its own reader for launches with no engine, so two implementations answer one
// question and every rule below is the app's: the filename shape, the leftmost split, the truncated
// mtime, the most-recent-first order. The one addition is the tiebreak, because a served list is
// compared frame to frame and an unstable order is churn.
import Foundation
import EQCompanionCore

/// How reading the directory went. A failed read is never "no logs": `missing` is a path with
/// nothing at it, `unreadable` is a directory that exists and refused.
public enum LogsDirReadable: String, Sendable, Equatable {
    case ok
    case missing
    case unreadable
}

/// One character log, as the app's picker has always been handed it.
public struct LogCharacter: Sendable, Equatable {
    /// The character, as the filename spells it — the game's own capitalisation, never folded.
    public var name: String
    /// The server, as the filename spells it.
    public var server: String
    /// The path the app would hand `session.attach`.
    public var logPath: String
    /// The file's last-modified time, or nil when nothing can be said about it.
    public var lastPlayed: Int64?

    public init(name: String, server: String, logPath: String, lastPlayed: Int64?) {
        self.name = name
        self.server = server
        self.logPath = logPath
        self.lastPlayed = lastPlayed
    }

    public var json: JSONValue {
        var o: [String: JSONValue] = [
            "name": .string(name),
            "server": .string(server),
            "logPath": .string(logPath)
        ]
        // Absent, never zero: `0` would claim 1970, which a client would draw as a real date.
        if let lastPlayed { o["lastPlayed"] = .int(lastPlayed) }
        return .object(o)
    }
}

/// What one scan of a log directory found.
///
/// The verdict and the rows travel together because an empty list means three different things and
/// only the verdict separates them.
public struct LogScan: Sendable {
    /// How reading the directory went.
    public var readable: LogsDirReadable
    /// The character logs found, most recently written first. Always empty when `readable` is not
    /// `.ok`.
    public var characters: [LogCharacter]

    public init(readable: LogsDirReadable, characters: [LogCharacter]) {
        self.readable = readable
        self.characters = characters
    }
}

public enum Logs {
    /// The filename prefix EverQuest gives every character log.
    static let prefix = "eqlog_"
    /// The extension it gives them.
    static let suffix = ".txt"

    /// Scan one directory.
    ///
    /// Three outcomes, and a failed read is never "no logs". `missing` is a machine with EverQuest
    /// installed somewhere else. Every other error is `unreadable`: a permission refusal, a
    /// disconnected share, a path that is a file.
    ///
    /// A file that vanishes mid-scan is a row with no `lastPlayed`, not a missing row: the readdir
    /// and the stat are two syscalls with a window between them, and EverQuest is writing into this
    /// folder while a person clicks.
    ///
    /// A directory entry that is not a file is skipped: handing a folder named
    /// `eqlog_Foo_bar.txt` to `session.attach` would be an attach that can only fail.
    public static func scan(_ dir: URL) -> LogScan {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if !fm.fileExists(atPath: dir.path, isDirectory: &isDir) {
            return LogScan(readable: .missing, characters: [])
        }
        if !isDir.boolValue {
            return LogScan(readable: .unreadable, characters: [])
        }
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else {
            return LogScan(readable: .unreadable, characters: [])
        }
        var characters: [LogCharacter] = []
        for fileName in names {
            guard let (name, server) = splitLogName(fileName) else { continue }
            let path = dir.appendingPathComponent(fileName)
            // The metadata is taken once and answers two questions: is this a file at all, and when
            // was it last written. A row survives a failure of the second and not of the first.
            var st = stat()
            let statted = stat(path.path, &st) == 0
            if statted && (st.st_mode & S_IFMT) != S_IFREG { continue }
            characters.append(LogCharacter(name: name,
                                           server: server,
                                           logPath: path.path,
                                           lastPlayed: statted ? mtimeMs(st) : nil))
        }
        sortMostRecentFirst(&characters)
        return LogScan(readable: .ok, characters: characters)
    }

    public static func scan(_ dir: String) -> LogScan { scan(URL(fileURLWithPath: dir)) }

    /// `eqlog_<Character>_<server>.txt` → the two names, or nil for a filename that is not one.
    ///
    /// The split is LEFTMOST, matching the app's two lazy regex groups: a server name may contain
    /// an underscore and a character name may not, so a rightmost split would make the two
    /// implementations disagree about a name — and a name is the join key the picker and
    /// `characterId` are built on.
    ///
    /// Case-insensitive at both ends, and the names themselves are verbatim.
    ///
    /// Both halves must be non-empty — a row carrying an empty string is a picker entry with a
    /// blank label.
    static func splitLogName(_ fileName: String) -> (String, String)? {
        let lower = fileName.lowercased()
        guard lower.hasPrefix(prefix), lower.hasSuffix(suffix) else { return nil }
        guard fileName.count >= prefix.count + suffix.count else { return nil }
        let start = fileName.index(fileName.startIndex, offsetBy: prefix.count)
        let end = fileName.index(fileName.endIndex, offsetBy: -suffix.count)
        guard start <= end else { return nil }
        let middle = fileName[start..<end]
        guard let split = middle.firstIndex(of: "_") else { return nil }
        let name = String(middle[middle.startIndex..<split])
        let server = String(middle[middle.index(after: split)...])
        if name.isEmpty || server.isEmpty { return nil }
        return (name, server)
    }

    /// One file's last-modified time, in epoch milliseconds.
    ///
    /// Truncated rather than rounded, to equal the app's `Math.floor(mtimeMs)`.
    static func mtimeMs(_ st: stat) -> Int64? {
        let secs = Int64(st.st_mtimespec.tv_sec)
        let nanos = Int64(st.st_mtimespec.tv_nsec)
        if secs < 0 { return nil }
        return secs * 1000 + nanos / 1_000_000
    }

    /// Most recently written first, with an absent `lastPlayed` sorting as zero.
    ///
    /// The tiebreak is the path ascending, which the app's read does not need and this one does:
    /// a directory read promises no order, so two logs with the same stamp could come back either
    /// way on consecutive calls, and a served list that reshuffles is diff churn against a client
    /// holding a window.
    static func sortMostRecentFirst(_ characters: inout [LogCharacter]) {
        characters.sort { a, b in
            let x = a.lastPlayed ?? 0, y = b.lastPlayed ?? 0
            if x != y { return x > y }
            return a.logPath < b.logPath
        }
    }
}

/// The directory this engine has been told to enumerate, held for the life of the process.
///
/// A third kind of state: not fold state, so it does not move with the epoch, and not derived from
/// an attach either — the app told this process, so it survives an attach exactly as `defines`
/// does. A character switch is not the app withdrawing where its logs live.
public struct LogDir: Sendable {
    private var dir: URL?

    public init() { dir = nil }

    /// Take the app's statement. An idempotent full-set replace of one value: the latest push is
    /// the whole of what the app has said.
    public mutating func set(_ dir: String) {
        self.dir = URL(fileURLWithPath: dir)
    }

    /// The directory, or nil when no `logs.setDir` has arrived.
    public func get() -> URL? { dir }
}
