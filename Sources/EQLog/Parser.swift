// The single parse pass (eqlog/src/parse/mod.rs). The cascade order is semantic — never reorder.
// A parse is a pure function of (bytes, spell DB, character name); everything stateful lives on
// `Parser` and nothing outlives it.
import Foundation

/// One log line, pre-split. `text` is the message with the `[timestamp] ` prefix removed.
public struct Ctx {
    public let text: String
    public let ts: Int64
    public let seq: Int64
    public let raw: String
    public init(text: String, ts: Int64, seq: Int64, raw: String) {
        self.text = text; self.ts = ts; self.seq = seq; self.raw = raw
    }
}

public final class Parser: @unchecked Sendable {
    public let clock: Clock
    public let db: SpellDb?
    public let character: String?
    private let line: Re
    let combat = CombatRes()
    let casts = CastRes()
    let world = WorldRes()
    let who = WhoRes()
    let acquire = AcquireRes()
    let group = GroupRes()
    /// Stamps that matched the line pattern but not the timestamp pattern.
    public private(set) var unparsedStamps: Int = 0

    public init(clock: Clock, db: SpellDb?, character: String?) {
        self.clock = clock
        self.db = db
        self.character = character
        line = Re("^\\[(\(JS.DOT)+?)\\]\(JS.S)?(\(JS.DOT)*)$")
    }

    /// The parser the app builds: the effective spell DB, and the tailed character's name.
    public static func forCharacter(_ character: String, clock: Clock) -> Parser {
        Parser(clock: clock, db: SpellDb.shared(), character: character)
    }

    private static let logFile = Re("(?i)^eqlog_(.+?)_([^_]+?)\\.[^.]+\\.txt$")
    private static let logFileBare = Re("(?i)^eqlog_(.+?)_([^_.]+?)\\.txt$")

    /// The character a log was cut for, off its filename (`eqlog_<Name>_<server>[.<slice>].txt`).
    public static func characterOf(_ fileName: String) -> String? {
        (logFile.captures(fileName) ?? logFileBare.captures(fileName)).map { $0.s(1) }
    }

    public static func serverOf(_ fileName: String) -> String? {
        (logFile.captures(fileName) ?? logFileBare.captures(fileName)).map { $0.s(2) }
    }

    /// Parse one raw line into `out`. `false` when it is not a timestamped log line.
    public func parseEvent(_ raw: String, seq: Int64, into out: Ev) -> Bool {
        guard let pm = line.captures(raw) else { return false }
        let ts = clock.parseEQTimestamp(pm.s(1))
        if ts == 0 { unparsedStamps += 1 }
        let c = Ctx(text: pm.s(2), ts: ts, seq: seq, raw: raw)
        classify(c, out)
        return true
    }

    /// The ordered line-shape cascade. Each classifier claims the line or declines.
    private func classify(_ c: Ctx, _ out: Ev) {
        let name = character
        let claimed =
            classifyMiss(combat, c, out)
            || classifyMitigation(combat, c, out)
            || classifyResist(combat, c, out)
            || classifyDamage(combat, c, out)
            || classifyHeal(combat, c, out)
            || classifyConsider(world, c, out)
            || classifyCastLifecycle(casts, c, out)
            || classifyCharm(casts, db, c, out)
            || classifyWornOff(casts, db, c, out)
            || classifyCcApply(casts, db, c, out)
            || classifyCcWake(casts, c, out)
            || classifyPetClaim(casts, c, out)
            || classifyPetSay(casts, c, out)
            || classifyPetLeader(casts, name, c, out)
            || classifyAllyPetLeader(casts, name, c, out)
            || classifyDeath(world, c, out)
            || classifyZone(world, c, out)
            || classifyInstanceCreate(world, c, out)
            || classifySessionStart(c, out)
            || classifyCamp(c, out)
            || classifyOutputFile(c, out)
            || classifyGroup(group, c, out)
            || classifyLoot(world, c, out)
            || classifyItemMerge(world, c, out)
            || classifyAcquire(acquire, c, out)
            || classifyTurnIn(world, c, out)
            || classifyLevel(world, c, out)
            || classifyExp(world, c, out)
            || classifyAA(world, c, out)
            || classifyAAPotion(c, out)
            || classifyAAActivate(casts, c, out)
            || classifyStance(casts, c, out)
            || classifySpellGems(casts, c, out)
            || classifySelfWho(who, name, c, out)
            || classifySkillUp(who, c, out)
            || classifySpecialAttack(who, c, out)
            || classifyClassUnlock(c, out)
            || classifyIllusionFade(c, out)
            || classifyPoisonCoat(casts, c, out)
            || classifyPoisonProc(casts, c, out)
            || classifyDbBuff(db, c, out)
            || classifyItemActivate(who, c, out)
            || classifySpellEmote(casts, c, out)
        if !claimed {
            out.begin(.unknown)
            out.envelope(c)
        }
    }
}
