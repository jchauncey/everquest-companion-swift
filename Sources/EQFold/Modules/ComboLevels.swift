// Port of fold/src/modules/combo/levels.rs — reading the character's level, for the interval
// builder.
//
// EQ Legends states your level in exactly two places: a `Welcome to level N!` ding and your own
// `/who` row's bracket. Everything here reconciles them.
//
// The fact it all rests on: the displayed level is the MINIMUM over the loadout's class levels.
// Two consequences pull in opposite directions — inside one loadout the number only ever RISES, so
// a level that goes backwards proves a swap; across a swap it can fall by forty, which is why
// `levelDropBoundaries` treats a non-increasing ding as the loudest swap signal in the log.
//
// `levelAt`'s two loops share one `at`, so the latest statement wins whichever source it came from.
// Running them in sequence would let an old `/who` row's level beat every ding after it. A row at
// the SAME instant as a ding still wins: it states the bracket outright.
import Foundation

/// A `/who` row, reduced to what interval construction needs.
public struct WhoRow {
    public var ts: Int64
    public var seq: Int64
    public var classes: [ClassAbbr]
    /// The bracketed level — min over the loadout, so it is the interval's level too.
    public var level: Int64

    public init(ts: Int64, seq: Int64, classes: [ClassAbbr], level: Int64) {
        self.ts = ts
        self.seq = seq
        self.classes = classes
        self.level = level
    }
}

/// A `You have gained a level!` ding.
public struct LevelPoint {
    public var ts: Int64
    public var level: Int64

    public init(ts: Int64, level: Int64) {
        self.ts = ts
        self.level = level
    }
}

/// Everything that ever STATES a level, which is the whole input to this file.
public struct LevelStatements {
    public var levels: [LevelPoint]
    public var whoRows: [WhoRow]

    public init(levels: [LevelPoint], whoRows: [WhoRow]) {
        self.levels = levels
        self.whoRows = whoRows
    }
}

/// The level in force at `ts` — the LATEST statement at or before it, from either source.
public func levelAt(_ input: LevelStatements, _ ts: Int64) -> Int64? {
    var level: Int64? = nil
    var at = Int64.min
    for p in input.levels where p.ts <= ts && p.ts >= at {
        level = p.level
        at = p.ts
    }
    for r in input.whoRows where r.ts <= ts && r.ts >= at {
        level = r.level
        at = r.ts
    }
    return level
}

/// Every level stated inside `[from, end)`. `from` is inclusive for the range — a ding that opens an
/// interval is that interval's level — while the regression test asks for the exclusive form, which
/// is why it is a parameter rather than a convention.
private func statedIn(_ input: LevelStatements, _ from: Int64, _ end: Int64?, _ inclusive: Bool) -> [Int64] {
    func inside(_ ts: Int64) -> Bool {
        (inclusive ? ts >= from : ts > from) && (end.map { ts < $0 } ?? true)
    }
    var out = input.levels.filter { inside($0.ts) }.map(\.level)
    out.append(contentsOf: input.whoRows.filter { inside($0.ts) }.map(\.level))
    return out
}

/// Levels observed inside a slice, for the interval's honest level range.
public func levelRange(_ input: LevelStatements, _ startAt: Int64, _ end: Int64?) -> (Int64?, Int64?) {
    var inside = statedIn(input, startAt, end, true)
    if let inForce = levelAt(input, startAt) { inside.append(inForce) }
    if inside.isEmpty { return (nil, nil) }
    return (inside.min(), inside.max())
}

/// A level span one loadout cannot produce. Inside a fixed loadout the minimum only ever goes UP, so
/// a level observed inside the interval that is BELOW the level in force when it opened proves a
/// swap in there that no detector cut.
///
/// Stated as a regression rather than as a width, because a width is not evidence of anything:
/// `levels 24-50` is a legitimate month of grinding, and `levels 11-50` is impossible only because
/// the 11 came after the 50.
public func levelRegressedInside(_ input: LevelStatements, _ startAt: Int64, _ end: Int64?) -> Bool {
    guard let inForce = levelAt(input, startAt) else { return false }
    return statedIn(input, startAt, end, false).contains { $0 < inForce }
}
