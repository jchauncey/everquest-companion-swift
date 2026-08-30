// The pure half of the Mobs tab: the mob identity key, the kill record, the catalog fuzzy
// search, and the drops fold. Ported one-for-one from the Electron renderer so the two clients
// report the same numbers for the same log — `src/shared/mobKey.ts`, `src/shared/kills.ts`,
// `src/shared/fuzzy.ts`, `src/shared/mobDrops.ts`, `features/mobs/mobZone.ts`.
//
// Nothing here touches SwiftUI: every function is a fold over a snapshot the engine served or
// over the committed catalog, so it can be reasoned about (and measured) on its own.
import Foundation
import EQCompanionCore

// MARK: - Mob identity

/// The canonical identity key for a mob NAME (`src/shared/mobKey.ts`).
///
/// Trim, drop a trailing spawn-generation ` (N)` (the app's own label suffix — no log line
/// carries it), lower-case, fold the three apostrophe glyphs the log/wiki/catalog disagree on,
/// collapse whitespace runs. The leading article is deliberately KEPT: "a giant rat" and "giant
/// rat" are different wiki pages. Display always stays raw; only joins go through this.
enum MobKey {
    static func of(_ name: String) -> String {
        var s = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = s.range(of: #"\s*\(\d+\)$"#, options: .regularExpression) { s.removeSubrange(r) }
        s = s.lowercased()
        s = String(s.map { c -> Character in
            (c == "`" || c == "\u{2019}" || c == "\u{00B4}") ? "'" : c
        })
        return s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

// MARK: - The kill record

/// One mob's kills at ONE tier key. `firstTs`/`lastTs` bracket that key's kills only.
struct KillTierRun {
    var count = 0
    var firstTs: Int64 = 0
    var lastTs: Int64 = 0
    var credited = 0
    /// When the most recent CREDITED kill of this run landed; 0 when none of them were yours.
    var lastCreditedTs: Int64 = 0
}

/// A mob's whole kill history. Every scalar is DERIVED from `tiers` — one fold, no drift.
struct KillInfo {
    var display: String
    var tiers: [Int: KillTierRun]
    var count: Int
    var bestTier: Int
    var firstTs: Int64
    var lastTs: Int64
    var credited: Int
}

enum KillRecord {
    /// A bare zone name: no instance, so no lockout to be on.
    static let openWorld = -1
    /// The log never stated where the kill happened. Not "the base difficulty".
    static let unknownTier = -2
    /// Every instance difficulty the game offers, base first.
    static let difficultyTiers = [0, 1, 2, 3, 4]

    static func isDifficulty(_ tier: Int) -> Bool { difficultyTiers.contains(tier) }

    /// The five derived scalars, folded from the per-tier runs (`killTotals`). The `bestTier`
    /// seed is the FLOOR of the key ordering, so an open-world-only record never claims a d0.
    static func totals(_ tiers: [Int: KillTierRun]) -> (count: Int, bestTier: Int, firstTs: Int64, lastTs: Int64, credited: Int) {
        var count = 0, credited = 0
        var bestTier = unknownTier
        var firstTs: Int64 = 0, lastTs: Int64 = 0
        for (key, run) in tiers where run.count > 0 {
            count += run.count
            bestTier = max(bestTier, key)
            firstTs = firstTs != 0 ? min(firstTs, run.firstTs) : run.firstTs
            lastTs = max(lastTs, run.lastTs)
            credited += run.credited
        }
        return (count, bestTier, firstTs, lastTs, credited)
    }

    /// Fold one run into an accumulating tiers map (union of counts and time spans).
    static func add(_ into: inout [Int: KillTierRun], _ tier: Int, _ run: KillTierRun) {
        guard var prev = into[tier] else { into[tier] = run; return }
        prev.count += run.count
        prev.firstTs = prev.firstTs != 0 ? min(prev.firstTs, run.firstTs) : run.firstTs
        prev.lastTs = max(prev.lastTs, run.lastTs)
        prev.credited += run.credited
        prev.lastCreditedTs = max(prev.lastCreditedTs, run.lastCreditedTs)
        into[tier] = prev
    }

    /// One tier run with its tier key attached.
    struct TierRun: Identifiable {
        var tier: Int
        var run: KillTierRun
        var id: Int { tier }
    }

    /// The per-tier runs ordered by their OWN most recent kill — the order a chronological
    /// grouping wants, since each run joins the timeline at its own `lastTs`.
    static func runs(_ tiers: [Int: KillTierRun]) -> [TierRun] {
        tiers.filter { $0.value.count > 0 }
            .map { TierRun(tier: $0.key, run: $0.value) }
            .sorted { $0.run.lastTs != $1.run.lastTs ? $0.run.lastTs < $1.run.lastTs : $0.tier < $1.tier }
    }

    private static func info(_ display: String, _ tiers: [Int: KillTierRun]) -> KillInfo {
        let t = totals(tiers)
        return KillInfo(display: display, tiers: tiers, count: t.count, bestTier: t.bestTier,
                        firstTs: t.firstTs, lastTs: t.lastTs, credited: t.credited)
    }

    /// The `kills` module snapshot as the engine keyed it (the slain line's own spelling).
    static func parse(_ state: JSONValue) -> [String: KillInfo] {
        var out: [String: KillInfo] = [:]
        for (key, v) in state["mobs"].object ?? [:] {
            var tiers: [Int: KillTierRun] = [:]
            for (tk, run) in v["tiers"].object ?? [:] {
                guard let tier = Int(tk) else { continue }
                tiers[tier] = KillTierRun(count: run["count"].int ?? 0,
                                          firstTs: run["firstTs"].int64 ?? 0,
                                          lastTs: run["lastTs"].int64 ?? 0,
                                          credited: run["credited"].int ?? 0,
                                          lastCreditedTs: run["lastCreditedTs"].int64 ?? 0)
            }
            out[key] = info(v["display"].string ?? key, tiers)
        }
        return out
    }

    /// THE JOIN (`killIndex`): re-key by `MobKey`, folding any two spellings that were one mob
    /// into one record. Both sides of every later lookup are then folded by the same rule.
    static func index(_ map: [String: KillInfo]) -> [String: KillInfo] {
        var out: [String: KillInfo] = [:]
        for (rawKey, entry) in map {
            let key = MobKey.of(entry.display.isEmpty ? rawKey : entry.display)
            guard var prev = out[key] else { out[key] = entry; continue }
            for (tier, run) in entry.tiers { add(&prev.tiers, tier, run) }
            out[key] = info(prev.display, prev.tiers)
        }
        return out
    }

    /// What the kills module knows about ONE mob, whatever spelling the caller holds.
    /// `index` must be an `index(_:)` result.
    static func killsFor(_ index: [String: KillInfo], _ name: String) -> KillInfo? {
        index[MobKey.of(name)]
    }
}

// MARK: - Fuzzy catalog search (src/shared/fuzzy.ts)

/// The scorer the Electron search box uses, on UTF-8 bytes so 7,866 rows stay cheap per keystroke.
enum MobFuzzy {
    static let scoreExact = 1.0
    static let scorePrefix = 0.85
    static let scoreSubstring = 0.7
    static let scoreFuzzy = 0.6
    static let minFuzzyLen = 3

    static func editBudget(_ longest: Int) -> Int {
        if longest < 3 { return 0 }
        if longest < 5 { return 1 }
        return 2
    }

    /// Lower-cased `[a-z0-9]+` runs.
    static func tokenize(_ text: String) -> [[UInt8]] {
        var out: [[UInt8]] = []
        var cur: [UInt8] = []
        for b in Array(text.lowercased().utf8) {
            if (b >= 97 && b <= 122) || (b >= 48 && b <= 57) {
                cur.append(b)
            } else if !cur.isEmpty {
                out.append(cur); cur = []
            }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    private static func hasPrefix(_ h: [UInt8], _ q: [UInt8]) -> Bool {
        guard q.count <= h.count else { return false }
        for i in 0..<q.count where h[i] != q[i] { return false }
        return true
    }

    private static func contains(_ h: [UInt8], _ q: [UInt8]) -> Bool {
        guard q.count <= h.count else { return false }
        let last = h.count - q.count
        var i = 0
        while i <= last {
            var j = 0
            while j < q.count, h[i + j] == q[j] { j += 1 }
            if j == q.count { return true }
            i += 1
        }
        return false
    }

    /// Reusable Damerau-Levenshtein rows. The scorer runs ~80,000 times per keystroke over the
    /// whole catalog, and allocating three Int arrays inside that loop is the whole cost of the
    /// search — so the rows are allocated ONCE per query and handed down by reference.
    struct Scratch {
        static let width = 64
        var prev2 = [Int](repeating: 0, count: width)
        var prev = [Int](repeating: 0, count: width)
        var cur = [Int](repeating: 0, count: width)
    }

    /// Damerau-Levenshtein with an early bail at `max`. `b` must be shorter than
    /// `Scratch.width`; a longer token cannot be within budget of a search token anyway, and the
    /// length guard above rejects it before we get here.
    static func distance(_ a: [UInt8], _ b: [UInt8], max limit: Int, _ s: inout Scratch) -> Int {
        if a == b { return 0 }
        if abs(a.count - b.count) > limit { return limit + 1 }
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        if b.count + 1 > Scratch.width || a.count + 1 > Scratch.width { return limit + 1 }
        let bl = b.count
        for j in 0...bl { s.prev[j] = j }
        for i in 1...a.count {
            s.cur[0] = i
            var rowMin = i
            let ca = a[i - 1]
            for j in 1...bl {
                let cost = ca == b[j - 1] ? 0 : 1
                var v = Swift.min(s.cur[j - 1] + 1, s.prev[j] + 1, s.prev[j - 1] + cost)
                if i > 1, j > 1, ca == b[j - 2], a[i - 2] == b[j - 1] { v = Swift.min(v, s.prev2[j - 2] + 1) }
                s.cur[j] = v
                if v < rowMin { rowMin = v }
            }
            if rowMin > limit { return limit + 1 }
            swap(&s.prev2, &s.prev)
            swap(&s.prev, &s.cur)
        }
        let d = s.prev[bl]
        return d > limit ? limit + 1 : d
    }

    static func tokenScore(_ q: [UInt8], _ h: [UInt8], _ s: inout Scratch) -> Double {
        if q == h { return scoreExact }
        if hasPrefix(h, q) { return scorePrefix }
        if contains(h, q) { return scoreSubstring }
        if q.count < minFuzzyLen || h.count < minFuzzyLen { return 0 }
        let longest = Swift.max(q.count, h.count)
        let budget = editBudget(longest)
        if budget == 0 { return 0 }
        // The cheap half of `trivialDistance`, hoisted out of the inner routine: most haystack
        // tokens are the wrong LENGTH and never need a matrix at all.
        if abs(q.count - h.count) > budget { return 0 }
        let d = distance(q, h, max: budget, &s)
        if d > budget { return 0 }
        return scoreFuzzy * (1 - Double(d) / Double(longest))
    }

    static func bestTokenScore(_ q: [UInt8], _ hay: [[UInt8]], _ s: inout Scratch) -> Double {
        var best = 0.0
        for h in hay {
            let score = tokenScore(q, h, &s)
            if score > best {
                best = score
                if best == scoreExact { break }
            }
        }
        return best
    }

    /// Every query token must match something, or the row is out. Nil = no match at all.
    static func scoreQuery(_ query: [[UInt8]], _ hay: [[UInt8]], _ s: inout Scratch) -> Double? {
        if query.isEmpty || hay.isEmpty { return nil }
        var sum = 0.0
        for q in query {
            let best = bestTokenScore(q, hay, &s)
            if best == 0 { return nil }
            sum += best
        }
        return sum / Double(query.count)
    }
}

/// The catalog's search index — name + zones, tokenized once and reused for every keystroke.
@MainActor
final class MobCatalogIndex {
    static let shared = MobCatalogIndex()
    private var haystacks: [[[UInt8]]]?
    private var rows: [GameData.Mob] = []
    /// One-entry memo. A SwiftUI body re-evaluates for reasons that have nothing to do with the
    /// query (a kills snapshot, a con), and re-scoring 7,866 rows for an unchanged box is the one
    /// avoidable cost on this tab.
    private var lastQuery: String?
    private var lastHits: [GameData.Mob] = []

    /// How many hits the UI lists. A ranked list, not a page of 7,866.
    static let limit = 60

    var catalogCount: Int { GameData.shared.mobs.count }

    private func build() {
        if haystacks != nil { return }
        rows = GameData.shared.mobs
        haystacks = rows.map { m in
            MobFuzzy.tokenize(m.zones.isEmpty ? m.name : "\(m.name) \(m.zones.joined(separator: " "))")
        }
    }

    /// Score desc, then drop count desc (with names as ambiguous as EQ's, the row that can
    /// answer "what does it drop" is the more useful one), then page title.
    func search(_ text: String) -> [GameData.Mob] {
        if lastQuery == text { return lastHits }
        let query = MobFuzzy.tokenize(text)
        if query.isEmpty {
            lastQuery = text
            lastHits = []
            return []
        }
        build()
        guard let hay = haystacks else { return [] }
        var scratch = MobFuzzy.Scratch()
        var hits: [(mob: GameData.Mob, score: Double)] = []
        for i in rows.indices {
            guard let s = MobFuzzy.scoreQuery(query, hay[i], &scratch) else { continue }
            hits.append((rows[i], s))
        }
        hits.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.mob.drops.count != b.mob.drops.count { return a.mob.drops.count > b.mob.drops.count }
            return a.mob.page < b.mob.page
        }
        lastQuery = text
        lastHits = hits.prefix(Self.limit).map(\.mob)
        return lastHits
    }
}

// MARK: - The zone roster (features/mobs/mobZone.ts)

enum MobZone {
    /// The level to SORT by: the FIRST digit run of whatever shape the wiki wrote ("9-12",
    /// "~53", "50+"). No digits at all is genuinely unknown and sorts LAST rather than
    /// pretending to be level 0.
    static func sortLevel(_ level: String) -> Int? {
        var digits = ""
        for c in level {
            if c.isNumber { digits.append(c) } else if !digits.isEmpty { break }
        }
        return Int(digits)
    }

    /// Every catalog mob whose home zone is the raw log zone, lowest level first (unknown last),
    /// then name, then page — fully deterministic and independent of scrape order.
    ///
    /// The zone FOLD itself is `GameData.mobs(inLogZone:)`, which unions the zone table's
    /// verified catalog renames with the plain key match; this only orders the result.
    @MainActor
    static func roster(_ rawZone: String) -> [GameData.Mob] {
        GameData.shared.mobs(inLogZone: rawZone).sorted { a, b in
            let la = sortLevel(a.level), lb = sortLevel(b.level)
            if la != lb {
                guard let la else { return false }
                guard let lb else { return true }
                return la < lb
            }
            let na = a.name.lowercased(), nb = b.name.lowercased()
            if na != nb { return na < nb }
            return a.page < b.page
        }
    }
}

// MARK: - The drops fold (src/shared/mobDrops.ts)

/// What a mob drops, as the two sources between them know it. The WIKI table leads — it is the
/// definitive statement of what the thing can drop — and your own history rides on the matching
/// row as a count; only items the page does not list get their own trailing block.
struct MobDropsSplit {
    /// Every drop NAME, wiki-first.
    var all: [String] = []
    /// Lower-cased item name → how many YOU have looted.
    var countByKey: [String: Int] = [:]
}

enum MobDrops {
    /// `splitMobDrops` + `mobDropNames`, folded into the one shape both callers want.
    /// A knowledge blob that says nothing yields an empty split, never a claim.
    static func split(_ knowledge: JSONValue) -> MobDropsSplit {
        var out = MobDropsSplit()
        let seen = knowledge["dropsSeen"].array ?? []
        let wiki = knowledge["dropsWiki"].array ?? []
        var seenByKey: [String: Int] = [:]
        for d in seen {
            guard let item = d["item"].string else { continue }
            seenByKey[item.lowercased()] = d["count"].int ?? 0
        }
        var wikiKeys = Set<String>()
        for d in wiki {
            guard let item = d["item"].string else { continue }
            wikiKeys.insert(item.lowercased())
            out.all.append(item)
            if let mine = seenByKey[item.lowercased()] { out.countByKey[item.lowercased()] = mine }
        }
        for d in seen {
            guard let item = d["item"].string, !wikiKeys.contains(item.lowercased()) else { continue }
            out.all.append(item)
            out.countByKey[item.lowercased()] = d["count"].int ?? 0
        }
        return out
    }
}

// MARK: - The consider ring

/// One `/con` the engine recorded, with the knowledge it managed to attach.
struct ConsiderRowModel: Identifiable {
    var id: String
    var mob: String
    var level: Int?
    var rare: Bool
    var cons: Int
    var ts: Int64
    var zone: String
    var faction: String
    var difficulty: String
    var drops: MobDropsSplit
    /// The quests this mob figures in, as the enrichment stated them. Empty = nothing known.
    var quests: [String]

    static func parse(_ state: JSONValue) -> [ConsiderRowModel] {
        (state.array ?? []).map { r in
            let k = r["knowledge"]
            return ConsiderRowModel(
                id: r["id"].string ?? r["mob"].display,
                mob: r["mob"].string ?? "",
                level: r["level"].int,
                rare: r["rare"].bool ?? false,
                cons: r["cons"].int ?? 1,
                ts: r["ts"].int64 ?? 0,
                zone: r["zone"].string ?? "",
                faction: r["faction"].string ?? "",
                difficulty: r["difficulty"].string ?? "",
                drops: MobDrops.split(k),
                quests: (k["quests"].array ?? []).compactMap { $0["quest"].string ?? $0["name"].string })
        }
    }
}

/// The faction rung's wording (`CONSIDER_FACTION_LABEL`), shown as the row's hover text only —
/// the difficulty verdict is deliberately not rendered at all (it is a statement about the gap
/// between your level and the mob's ON THE DAY, and it is wrong the moment you ding).
enum ConsiderFaction {
    static let label: [String: String] = [
        "ally": "ally",
        "warmly": "warmly",
        "kindly": "kindly",
        "amiably": "amiable",
        "indifferent": "indifferent",
        "apprehensive": "apprehensive",
        "dubious": "dubious",
        "threatening": "threatening",
        "scowls": "KOS"
    ]

    static func text(_ key: String) -> String {
        label[key] ?? (key.isEmpty ? "faction unknown" : key)
    }
}

// MARK: - Wording

enum MobFormat {
    /// `formatAge` (src/renderer/src/lib/formatDate.ts): `just now`, `14m ago`, `13h ago`, `3d ago`.
    static func age(_ ts: Int64, now: Int64) -> String {
        guard ts > 0 else { return "" }
        let secs = Double(max(0, now - ts)) / 1000
        if secs < 90 { return "just now" }
        let mins = secs / 60
        if mins < 90 { return "\(Int(mins.rounded()))m ago" }
        let hrs = mins / 60
        if hrs < 36 { return "\(Int(hrs.rounded()))h ago" }
        return "\(Int((hrs / 24).rounded()))d ago"
    }
}
