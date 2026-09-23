// The small world the resist fold needs (fold/src/modules/resist/world.rs): how old a mob is, who is
// allowed to teach us anything, which resist debuffs are up, and who is standing in melee range.
//
// "Person or creature" is asked twice and answered differently, and confusing the two is a shipped
// bug:
//
//   For a caster (`CasterIndex`), "you have landed damage on this name" is a reason to call it a
//   creature — safe, because the consequence is that its level comes from the catalog ladder rather
//   than being unknowable.
//
//   For a target (`isMobTarget`), the same fact would admit the name, and a groupmate can reach
//   `struck` through a damage shield or an area effect. So the target test is the standing "is this a
//   person" pair and nothing else: EQ gives players one capitalized word with no space, and the
//   committed catalog knows the proper-named NPCs that shape would refuse.
//
// The residual is stated rather than hidden: a proper-named NPC the catalog has never heard of and
// that you never hit is read as a person.
//
// The memos are measurements. Both are pure functions of the name, so a cache cannot change an
// answer — and both are per-fold fields, so nothing outlives a fold.
import Foundation
import EQLog

/// Bound on the display-name caches. Cleared wholesale rather than evicted one at a time, because a
/// long session meets thousands of distinct names and an unbounded map is a slow leak.
private let maxKeyCache = 4_096
private let maxTargetVerdicts = 4_096

/// A mob's level, and how sure we are. `/con` is the game telling you; the catalog is the wiki.
public struct MobLevelFact: Equatable, Sendable {
    /// What the estimator uses: the stated level, or a range's midpoint.
    public var level: Int64
    public var lo: Int64
    public var hi: Int64
    /// `con` or `catalog`.
    public var from: String
}

/// `/con` for this mob this session beats the catalog beats nothing.
public final class MobLevels {
    private var conned: [String: Int64] = [:]
    private var catalog: [String: MobLevelFact?] = [:]

    public init() {}

    /// Only the `/con` half is dropped: the catalog verdicts are a pure function of committed data
    /// and are the same on either side of a source boundary.
    public func reset() { conned.removeAll() }

    /// A `/con` line stated a level. Latest statement wins — the game just said it.
    ///
    /// Filed under every spelling the roster states for the creature, so a `/con` of `Innoruuk`
    /// answers a row keyed `innoruuk, the prince of hate` and the other way round.
    public func note(_ mobKey: String, _ level: Int64) {
        if level <= 0 { return }
        let id = ResistCatalog.resolveMobIdentity(mobKey)
        if !id.aliased {
            conned[mobKey] = level
        } else {
            for key in id.keys { conned[key] = level }
        }
    }

    public func levelOf(_ mobKey: String, _ display: String) -> MobLevelFact? {
        if let con = conned[mobKey] {
            return MobLevelFact(level: con, lo: con, hi: con, from: "con")
        }
        if let cached = catalog[mobKey] { return cached }
        let fact = MobLevels.catalogLevelOf(display)
        catalog.updateValue(fact, forKey: mobKey)
        return fact
    }

    /// The same question, asked by a reader rather than by the fold. `levelOf` mutates because it
    /// memoises the catalog verdict, and the ingest's one door is read-only by law.
    ///
    /// It answers the same thing: the precedence is identical and the only difference is whether the
    /// verdict is written back, which is unobservable because `catalogLevelOf` is a pure function of
    /// `display` and committed data. A reader that misses the memo does not warm it — deliberately.
    public func levelOfRef(_ mobKey: String, _ display: String) -> MobLevelFact? {
        if let con = conned[mobKey] {
            return MobLevelFact(level: con, lo: con, hi: con, from: "con")
        }
        if let cached = catalog[mobKey] { return cached }
        return MobLevels.catalogLevelOf(display)
    }

    /// The catalog is asked under every spelling the roster states: the catalog carries `Innoruuk`
    /// while the game prints `Innoruuk, the Prince of Hate`, and a plain lookup would miss, file a
    /// null level, and have the estimator drop the row for want of both levels.
    static func catalogLevelOf(_ display: String) -> MobLevelFact? {
        var entry = ResistCatalog.localMobEntry(display)
        if entry == nil {
            let id = ResistCatalog.resolveMobIdentity(display)
            if id.aliased { entry = ResistCatalog.localMobEntry(id.canonical) }
        }
        guard let (lo, hi) = ResistCatalog.parseCatalogLevel(entry.flatMap { $0 }) else { return nil }
        // A midpoint half rounds up, matching the app's `Math.round`.
        return MobLevelFact(level: (lo + hi + 1) / 2, lo: lo, hi: hi, from: "catalog")
    }
}

/// The leading article, the mob-name marker EQ prints, sentence-initial or not. Stated separately
/// from the single-word test even though `a ` could never satisfy it, because the article is the mob
/// marker and a reader looking for it should find it.
private let articleRe = Re("(?i)^(?:a|an|the)\(JS.S)")
private let anySpaceRe = Re(JS.S)

// `world.rs is_player_shaped_name` — EQ gives players a single capitalized word with no space, and
// mobs an article plus a noun phrase. The same function the combat side already carries, so this
// file calls that one rather than restating it.

/// Names the caster rather than refusing one: self, another player, or an NPC (charmed pets
/// included). Whether the estimator weighs a kind is a preference decided downstream.
public final class CasterIndex {
    private var pets = Set<String>()
    private var struck = Set<String>()
    private var verdicts: [String: String] = [:]

    public init() {}

    public func reset() {
        pets.removeAll(); struck.removeAll(); verdicts.removeAll()
    }

    public func notePet(_ name: String) {
        let key = Names.idKey(name)
        verdicts.removeValue(forKey: key)
        pets.insert(key)
    }

    /// You landed damage on it, so it is a mob. One direction only; this never un-files a player.
    public func noteStruck(_ name: String) {
        let key = Names.idKey(name)
        verdicts.removeValue(forKey: key)
        struck.insert(key)
    }

    public func kindOf(_ name: String) -> ResistCasterKind {
        // The identity compare answers almost every call; `idKey` is the fallback for the shapes that
        // reach here unnormalised.
        if name == "You" { return .selfCast }
        let key = Names.idKey(name)
        if key == "you" { return .selfCast }
        if let cached = verdicts[key] { return CasterIndex.kindFrom(cached) }
        let verdict = judge(key, name)
        verdicts[key] = verdict
        return CasterIndex.kindFrom(verdict)
    }

    /// The tests, in the order they are cheap: a name you have landed damage on is a mob; a name bound
    /// as somebody's pet is a pet; a leading article or an interior space is a mob, because EQ player
    /// names are one word and never carry one; a name the committed catalog knows is a mob.
    private func judge(_ key: String, _ name: String) -> String {
        if pets.contains(key) || struck.contains(key) { return "npc" }
        let trimmed = JS.trim(name)
        if articleRe.isMatch(trimmed) { return "npc" }
        if anySpaceRe.isMatch(trimmed) { return "npc" }
        if ResistCatalog.catalogKnows(name) { return "npc" }
        return "pc"
    }

    static func kindFrom(_ v: String) -> ResistCasterKind { v == "npc" ? .npc : .pc }
}

/// May a row be filed about this name as a target? Memoised per fold; the verdict is a pure function
/// of the name, so nothing can invalidate an entry.
public final class TargetVerdicts {
    private var verdicts: [String: Bool] = [:]

    public init() {}

    public func isMobTarget(_ name: String) -> Bool {
        if let hit = verdicts[name] { return hit }
        let verdict = TargetVerdicts.judgeTarget(name)
        if verdicts.count >= maxTargetVerdicts { verdicts.removeAll() }
        verdicts[name] = verdict
        return verdict
    }

    static func judgeTarget(_ name: String) -> Bool {
        let n = JS.trim(name)
        // The catalog happens to hold an entry that folds to the key `you`, so self is tested first
        // and by identity, exactly as the fold's own `isSelf` does.
        if n == "You" || Names.idKey(n) == "you" { return false }
        return !isPlayerShapedName(n) || ResistCatalog.catalogKnows(n)
    }
}

/// How long a tash/malo line is assumed to hold. A constant rather than a per-spell duration because
/// the row records which debuffs were up and the estimator joins the amount at read time. Closed
/// early by the mob's death or a zone change, both of which the log states.
public let DEBUFF_WINDOW_MS: Int64 = 11 * 60 * 1000

/// Which resist debuffs are up on which mob. The row stores the keys; nothing else.
public final class DebuffWindows {
    private var byMob: [String: JSMap<Int64>] = [:]

    public init() {}

    public func reset() { byMob.removeAll() }

    public func open(_ mobKey: String, _ spellKey: String, _ ts: Int64) {
        var m = byMob[mobKey] ?? JSMap<Int64>()
        m.insert(spellKey, ts + DEBUFF_WINDOW_MS)
        byMob[mobKey] = m
    }

    /// The row's `debuffs` field: sorted, pipe-joined, empty when nothing is up. Expired entries are
    /// dropped on the way past, which is the only sweep this map ever gets.
    public func active(_ mobKey: String, _ ts: Int64) -> String {
        guard var m = byMob[mobKey] else { return "" }
        var dead: [String] = []
        var live: [String] = []
        for (key, until) in m.pairs {
            if until <= ts { dead.append(key) } else { live.append(key) }
        }
        for key in dead { m.remove(key) }
        byMob[mobKey] = m
        live.sort(by: Rust.bytesLess)
        return live.joined(separator: "|")
    }

    public func clearMob(_ mobKey: String) { byMob.removeValue(forKey: mobKey) }
}

/// Mob names both ways. Display to key is a memo; key to display is not a cache but a fact the ledger
/// needs, since the fold keys rows canonically and the surfaces show the log's spelling.
public final class MobNames {
    private var keys: [String: String] = [:]
    private var display: [String: String] = [:]

    public init() {}

    /// Drops the key memo and not the display map: the memo is a cache, the display map is knowledge,
    /// and a new source does not un-say what the log spelled.
    public func reset() { keys.removeAll() }

    public func key(_ display: String) -> String {
        if let hit = keys[display] { return hit }
        let key = ResistCatalog.mobKey(display)
        if keys.count >= maxKeyCache { keys.removeAll() }
        keys[display] = key
        return key
    }

    /// Note the spelling the game just used for this creature.
    public func remember(_ displayName: String) {
        display[key(displayName)] = displayName
    }

    public func displayFor(_ key: String) -> String { display[key] ?? key }
}

/// Melee proximity, the stand-in for point-blank range that song rule 3 needs.
public final class MeleeContact {
    private var last = JSMap<Int64>()

    public init() {}

    public func reset() { last.clear() }

    public func note(_ mobKey: String, _ ts: Int64) { last.insert(mobKey, ts) }

    public func dropMob(_ mobKey: String) { last.remove(mobKey) }

    /// Every mob you traded blows with inside the window ending at `ts`.
    public func within(_ ts: Int64, _ windowMs: Int64) -> [String] {
        last.pairs.filter { $0.1 <= ts && ts - $0.1 <= windowMs }.map(\.0)
    }
}
