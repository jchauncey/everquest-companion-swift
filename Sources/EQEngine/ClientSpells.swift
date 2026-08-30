// engined/src/spells.rs — the client's spell table, read by this process. `SpellsUs` is the format,
// pure over bytes; this file is the FILE — where it is, when it is read, and who waits.
//
// The table is never served as a bulk frame: measured at 48,252 entries and 6.13 MiB of JSON against
// an 8 MiB frame ceiling, on a table that grows with every client patch. This process parses it
// internally for its own joins and consumers ask per-spell questions instead. Nothing here
// serialises the table and there is deliberately no method that could.
//
// The path is derived from the attach, never discovered: the app pushes a log at
// `<eqRoot>/Logs/eqlog_<Char>_<server>.txt`, so the table is `<eqRoot>/spells_us.txt`. A character
// switch that changes installs changes the table with it, and nothing on the wire says so.
//
// The file is allowed to be missing — a folder of logs with no EverQuest behind it is a real
// configuration, and it produces a card that says so rather than a refusal.
//
// The read is lazy, off the ingest thread, exactly once. Never on the thread that tails the log: 38
// MB and a few hundred milliseconds of parsing there is the class of stall this program exists to
// remove. Never at attach, which would put a third of a second onto every character switch to serve
// a question nobody may ask. A failure is memoised too, so a missing file is answered instantly
// forever.
//
// Nothing is cached across a process, so there is nothing to invalidate: a client patch that
// rewrites `spells_us.txt` is followed by a game launch and a fresh engine.
import Foundation
import EQLog
import EQCompanionCore

/// Why there is no table, in the app's own words, so the two implementations describe the same three
/// situations the same way. `missing` and `unloadable` are two states rather than one because they
/// are two different sentences to a person: no file at that path, versus a file that would not read.
public enum SpellTableState: String, Sendable, Hashable {
    /// Read and parsed.
    case ok
    /// There is no `spells_us.txt` at the derived path. A supported state.
    case missing
    /// The file is there and could not be read or decoded.
    case unloadable
}

/// The client table for one install, read at most once.
///
/// Created at attach (a path join and an empty cell) and filled by whoever asks first. A new attach
/// makes a new one, so an install change is a new table rather than a stale one to be noticed.
public final class ClientSpells: @unchecked Sendable {
    /// `<eqRoot>/spells_us.txt`, derived from the attach's log path. Reported on the
    /// health/diagnostic surfaces so a card that says "there is no spells_us.txt at …" can name the
    /// place it looked.
    public let path: String
    /// `<eqRoot>/dbstr_us.txt`, beside it.
    public let dbstrPath: String

    /// The two cells are filled once each and independently: a surface can want the words without
    /// the rows, and the two files fail separately.
    private let lock = NSLock()
    private var tableDone = false
    private var tableCell: SpellTable?
    private var categoriesDone = false
    private var categoriesCell: DbStr.CategoryNames = [:]

    /// The refusal both spell ops give when nothing is attached — one sentence, so the two cannot
    /// describe the same situation differently.
    public static let noInstallSentence =
        "no log is attached, so there is no install to read a spell table beside"

    init(root: String) {
        path = ClientSpells.join(root, "spells_us.txt")
        dbstrPath = ClientSpells.join(root, "dbstr_us.txt")
    }

    /// Where the table would be, given the log this world is folding.
    ///
    /// `<eqRoot>/Logs/eqlog_<Char>_<server>.txt` → `<eqRoot>/spells_us.txt`. `nil` when the log path
    /// has no grandparent, which is a path shaped like nothing the product produces; answering `nil`
    /// rather than guessing is the rule.
    public static func besideLog(_ log: String) -> ClientSpells? {
        guard let logs = parent(log), let root = parent(logs) else { return nil }
        return ClientSpells(root: root)
    }

    /// The table, parsing it if nobody has yet. Blocks the calling thread on the first call.
    public func table() -> SpellTable? {
        lock.lock()
        defer { lock.unlock() }
        if !tableDone {
            tableDone = true
            tableCell = ClientSpells.read(path)
        }
        return tableCell
    }

    /// One spell, by the name the asker spells it. `nil` for a name the table has no row for, and for
    /// every state in which there is no table.
    ///
    /// The key is folded here: `spellCanonKey` strips a trailing Roman numeral and lower-cases, so
    /// `Scorching Arrow IV` and `scorching arrow` are one question. It is the same fold the table was
    /// built under, and a caller that pre-folded would be a second opinion about a join key.
    public func spell(_ name: String) -> SpellInfo? {
        table()?[Names.spellCanonKey(name)]
    }

    /// The words behind the category ids, parsing `dbstr_us.txt` if nobody has yet.
    ///
    /// An unreadable string table is an empty map rather than a failure: every id resolves to no
    /// word, so a row reports no category and a surface offers no category filter — a degraded list
    /// rather than an outage.
    public func categoryNames() -> DbStr.CategoryNames {
        lock.lock()
        defer { lock.unlock() }
        if !categoriesDone {
            categoriesDone = true
            categoriesCell = ClientSpells.readBytes(dbstrPath).map { DbStr.parseSpellCategories(latin1: $0) } ?? [:]
        }
        return categoriesCell
    }

    /// Why there is no answer, for a surface that has to say something. Forces the read, like
    /// `table()`, because "is it there" cannot be answered without looking.
    public var state: SpellTableState {
        if table() != nil { return .ok }
        return FileManager.default.fileExists(atPath: path) ? .unloadable : .missing
    }

    // MARK: - The op

    /// `resist.spell` — one spell out of the client's own table. No `notFound`: a row that is absent,
    /// a missing file and an unreadable file are things a card has to say in different words, so
    /// `table` and `path` ride every answer and `spell` rides a hit.
    public func resistSpell(name: String) -> ResistSpellResult {
        ResistSpellResult(spellName: name,
                          table: state,
                          path: path,
                          spell: spell(name).map(ClientSpell.init(_:)))
    }

    // MARK: - IO

    /// Read and parse, or `nil`.
    static func read(_ path: String) -> SpellTable? {
        guard let bytes = readBytes(path) else { return nil }
        return SpellsUs.parseSpellsUs(latin1: bytes)
    }

    /// One client file's bytes. Latin-1 is applied by the parsers, per field.
    static func readBytes(_ path: String) -> [UInt8]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return [UInt8](data)
    }

    // MARK: - Paths, with Rust's `Path` semantics

    /// `Path::parent`: `nil` when the path terminates in a root, otherwise the path with the final
    /// component removed — which for a bare file name is the empty path, not `nil`. `eqlog.txt` has a
    /// parent (`""`) and no grandparent, which is what makes it derive nothing.
    static func parent(_ p: String) -> String? {
        if p.isEmpty { return nil }
        var s = Substring(p)
        while s.count > 1, s.hasSuffix("/") { s = s.dropLast() }
        if s == "/" { return nil }
        guard let i = s.lastIndex(of: "/") else { return "" }
        if i == s.startIndex { return "/" }
        var head = s[s.startIndex..<i]
        while head.count > 1, head.hasSuffix("/") { head = head.dropLast() }
        return String(head)
    }

    /// `Path::join` for a relative leaf.
    static func join(_ dir: String, _ leaf: String) -> String {
        if dir.isEmpty { return leaf }
        return dir.hasSuffix("/") ? dir + leaf : dir + "/" + leaf
    }
}

// MARK: - The wire shapes

/// The effect-0 hitpoint slot, which is what the resist estimator reads. An effect slot is
/// `slot | effectId | base | limit | CALC | MAX` — measured.
public struct ClientSpellSlot: Sendable, Hashable {
    public var base: Double
    public var max: Double
    public var calc: Double

    public var json: JSONValue {
        .object(["base": .double(base), "max": .double(max), "calc": .double(calc)])
    }
}

/// A resist-DECREASE slot worth at least five points.
public struct ClientSpellDebuff: Sendable, Hashable {
    public var axis: SpellsUs.Axis
    public var base: Double
    public var calc: Double
    public var max: Double

    public var json: JSONValue {
        .object(["axis": .string(axis.rawValue), "base": .double(base),
                 "calc": .double(calc), "max": .double(max)])
    }
}

/// One parsed `spells_us.txt` row, as the wire describes it.
///
/// The fold's doubles become the schema's numbers unchanged: the file carries fractions on some rows,
/// so rounding here would make this engine's answer differ from the app's own parser. Absent stays
/// absent — a `0` or a `false` invented here would disagree with the parser about what the file said.
/// `song` is `true` or nothing, never `false`.
public struct ClientSpell: Sendable, Hashable {
    /// A spell's own axis is never `all` — that belongs to a debuff slot, and the two are different
    /// sets on the wire. The `all` arm is unreachable and answers absent.
    public var axis: SpellsUs.Axis?
    public var resistAdj: Double
    public var castMs: Double
    public var recastMs: Double?
    public var aeMaxTargets: Double?
    public var mana: Double?
    public var targetType: Double
    public var levelCap: Double?
    public var song: Bool?
    public var damageSlot: ClientSpellSlot?
    public var debuffSlots: [ClientSpellDebuff]

    public init(_ info: SpellInfo) {
        axis = (info.axis == .all) ? nil : info.axis
        resistAdj = info.resistAdj
        castMs = info.castMs
        recastMs = info.recastMs
        aeMaxTargets = info.aeMaxTargets
        mana = info.mana
        targetType = info.targetType
        levelCap = info.levelCap
        song = info.song ? true : nil
        damageSlot = info.damageSlot.map { ClientSpellSlot(base: $0.base, max: $0.max, calc: $0.calc) }
        debuffSlots = info.debuffSlots.map {
            ClientSpellDebuff(axis: $0.axis, base: $0.base, calc: $0.calc, max: $0.max)
        }
    }

    public var json: JSONValue {
        var o: [String: JSONValue] = [
            "resistAdj": .double(resistAdj),
            "castMs": .double(castMs),
            "targetType": .double(targetType),
            "debuffSlots": .array(debuffSlots.map(\.json))
        ]
        if let axis { o["axis"] = .string(axis.rawValue) }
        if let recastMs { o["recastMs"] = .double(recastMs) }
        if let aeMaxTargets { o["aeMaxTargets"] = .double(aeMaxTargets) }
        if let mana { o["mana"] = .double(mana) }
        if let levelCap { o["levelCap"] = .double(levelCap) }
        if let song { o["song"] = .bool(song) }
        if let damageSlot { o["damageSlot"] = damageSlot.json }
        return .object(o)
    }
}

/// What the client's table says about one spell, or why it says nothing. `table` is ALWAYS present
/// and `spell` is present only on a hit: `table: missing` means the player has no EverQuest install
/// behind the folder this app was pointed at, and `table: ok` with no `spell` means the file was read
/// and has no row under this name — a different sentence entirely.
public struct ResistSpellResult: Sendable, Hashable {
    /// The name as it was asked for, echoed back — never the folded key.
    public var spellName: String
    public var table: SpellTableState
    /// Where this engine looked. Present always, because the sentence a missing table produces has to
    /// name a place.
    public var path: String
    public var spell: ClientSpell?

    public var json: JSONValue {
        var o: [String: JSONValue] = [
            "spellName": .string(spellName),
            "table": .string(table.rawValue),
            "path": .string(path)
        ]
        if let spell { o["spell"] = spell.json }
        return .object(o)
    }
}
