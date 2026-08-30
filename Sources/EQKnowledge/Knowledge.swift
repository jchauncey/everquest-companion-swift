// The committed corpora, engine-side (knowledge/src/lib.rs): the item, mob, quest and Plane of Sky
// datasets the app ships, indexed once and queried on demand behind `knowledge.item/mob/spell/search`.
//
// THE WIKI FETCH IS NOT HERE. The engine ships without a network stack, so resolution is:
//
//   1. the committed corpus, which answers the overwhelming majority and short-circuits the rest;
//   2. the runtime overlay — answers the app has already fetched and pushed back with
//      `knowledge.define`;
//   3. a MISS, recorded here, drained at a boundary and announced as a `knowledgeMiss` frame. The
//      app fetches under its own scrape throttle and cooldown, and pushes the answer in.
//
// Each name is announced AT MOST ONCE per process: a stacked loot burst probes one name many times
// and the app must not be asked to fetch it many times.
//
// Every index is built on first use. The bytes ship as bundle resources and nothing is parsed until
// something asks, because an attach must not pay for a corpus no client has queried. `warm()` is how
// a caller moves that parse off its own thread.
//
// `knowledge.spell` answers off `EQLog`'s effective spell DB and states exactly the fields that DB
// carries. It deliberately does NOT carry the derived effect classes, the rank lineage or the
// focus/level-dependent metrics: those need inputs this engine does not have, and half a card is a
// wrong answer wearing a right one's clothes. A named gap, stated in the schema beside the op.
import Foundation
import EQCompanionCore
import EQFold
import EQLog

/// The two corpora a `knowledge.define` may push into, and the two a miss may name.
///
/// Spells are not one of them. The item and mob corpora have an app-side FETCHER behind them, so a
/// name they lack is a question somebody can answer; the spell catalog is committed with no live
/// fallback anywhere in the app, so announcing a missing spell would ask the app to do something it
/// has no code for.
public let fetchableDomains: [String] = ["item", "mob"]

/// How many hits `knowledge.search` returns when the caller names no limit, and the most it returns
/// however large a limit it names.
///
/// A cap rather than a page: search is a type-ahead read by a human scanning a short list. The
/// window/offset machinery belongs to `view.subscribe`, where a list is the product.
public let searchDefaultLimit = 20
/// See `searchDefaultLimit`.
public let searchMaxLimit = 100

/// The process's one corpus: one instance shared by the ingest thread (the fold's own probes) and by
/// every connection thread (the `knowledge.*` ops). One overlay, one miss ledger, and the loot index
/// read through a seam rather than shared.
public final class KnowledgeCorpus: Knowledge, @unchecked Sendable {
    private let itemsBox: Lazy<ItemDb>
    private let questsBox: Lazy<[JSONValue]>
    private let localQuestsBox: Lazy<LocalQuests>
    private let mobIndexBox: Lazy<MobIndex>
    private let mobQuestsBox: Lazy<MobQuestIndex>
    private let searchRowsBox: Lazy<[SearchRow]>

    private let state = NSLock()
    /// domain → key → the record the app pushed. See `define`.
    private var overlay: [String: [String: JSONValue]] = [:]
    /// Names this process could not answer, waiting to be announced.
    private var pending: [KnowledgeMiss] = []
    /// Names already announced — the at-most-once law.
    private var announced: Set<String> = []

    /// A fresh, unshared corpus, for tests that want their own overlay and miss ledger. The indexes
    /// are parsed per instance, which is why production uses `shared()`.
    public init() {
        let quests = Lazy(Items.loadQuests)
        questsBox = quests
        localQuestsBox = Lazy { LocalQuests(quests: quests.get) }
        let items = Lazy(Items.loadItemDb)
        let mobs = Lazy(MobIndex.build)
        itemsBox = items
        mobIndexBox = mobs
        mobQuestsBox = Lazy { Mobs.questsByMob(quests.get) }
        searchRowsBox = Lazy { KnowledgeCorpus.buildSearchRows(items.get, mobs.get, quests.get) }
    }

    /// The process's corpus, built lazily and shared. A respawn is a launch, so there is no state to
    /// restore and no way to make a second one by accident.
    private static let process = KnowledgeCorpus()
    public static func shared() -> KnowledgeCorpus { process }

    // MARK: - The indexes

    var items: ItemDb { itemsBox.get }
    var quests: [JSONValue] { questsBox.get }
    var localQuests: LocalQuests { localQuestsBox.get }
    var mobIndex: MobIndex { mobIndexBox.get }
    var mobQuests: MobQuestIndex { mobQuestsBox.get }
    var searchRows: [SearchRow] { searchRowsBox.get }

    /// Parse every index off the CALLER'S thread.
    ///
    /// Lazy is the law — an attach must not pay for a corpus no client has queried — but the bill is
    /// far past the 100 ms an op may not spend: measured in a release build, 432 ms for the item side
    /// (items.json is 8.7 MB), 133 ms for the mob catalog and 69 ms for the search fold, ~630 ms in
    /// all. The Rust pays ~42 ms for the same item parse and can afford to take it on the asking
    /// thread; this cannot. So the world warms it in the background at attach and the first
    /// `knowledge.item` finds it built. Idempotent: `Lazy` runs each closure once however many
    /// callers race, and a caller that skips `warm` still gets a correct answer, slowly, once.
    public func warm(on queue: DispatchQueue = .global(qos: .utility)) {
        queue.async { [self] in
            _ = items
            _ = mobIndex
            _ = localQuests
            _ = mobQuests
            _ = searchRows
        }
    }

    // MARK: - The overlay

    /// Take one pushed answer — `knowledge.define`.
    ///
    /// Every other `*.define` carries the WHOLE set; this one cannot, because the set is the wiki:
    /// unbounded, not owned by the app, and learned one entry at a time in answer to one miss.
    ///
    /// It keeps the part of that law the law is for: idempotent and order-independent per key, so a
    /// crash-respawn stays trivial (the overlay is empty, every name misses again, the app answers
    /// again) and the input is still hash-friendly as a set of (key, entry) pairs. What it gives up
    /// is DELETE, which nothing asks for.
    ///
    /// It survives an attach: this is what the APP has told the process about committed data, not
    /// what a generation folded.
    @discardableResult
    public func define(_ domain: String, _ name: String, _ entry: JSONValue) -> Bool {
        guard let domain = KnowledgeCorpus.fetchable(domain) else { return false }
        let key = KnowledgeCorpus.keyFor(domain, name)
        if key.isEmpty { return false }
        state.lock()
        defer { state.unlock() }
        overlay[domain, default: [:]][key] = entry
        return true
    }

    /// How many entries the overlay holds for one domain — the diagnostic a `perf` row or a test
    /// reads, never a wire field.
    public func overlaySize(_ domain: String) -> Int {
        state.lock()
        defer { state.unlock() }
        return overlay[domain]?.count ?? 0
    }

    private func overlayEntry(_ domain: String, _ key: String) -> JSONValue? {
        state.lock()
        defer { state.unlock() }
        return overlay[domain]?[key]
    }

    /// Record one name this process could not answer, at most once ever.
    private func noteMiss(_ domain: String, _ name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return }
        state.lock()
        defer { state.unlock() }
        if !announced.insert("\(domain)\u{0}\(name)").inserted { return }
        pending.append(KnowledgeMiss(domain: domain, name: name))
    }

    public func takeMisses() -> [KnowledgeMiss] {
        state.lock()
        defer { state.unlock() }
        let out = pending
        pending = []
        return out
    }

    /// The domain as a canonical name, or nil for one this engine does not take pushes for.
    private static func fetchable(_ domain: String) -> String? { fetchableDomains.first { $0 == domain } }

    /// The overlay key for one domain — each domain's own canonical fold, never a shared one.
    private static func keyFor(_ domain: String, _ name: String) -> String {
        domain == "mob" ? Mobs.mobKey(name) : ItemNames.itemKey(name)
    }

    /// Did a pushed record claim a real negative? A `notFound` push is the app saying "I looked and
    /// the wiki has no page" — an ANSWER, which stops the engine announcing that name again, but not
    /// a `found`.
    private static func overlayFound(_ entry: JSONValue) -> Bool { !(entry["notFound"].bool ?? false) }

    // MARK: - knowledge.item

    /// The committed DB, then the overlay, then a miss. Local sources are merged into whichever
    /// answers, because they say something about the item's USES that no item page states.
    public func item(_ name: String) -> KnowledgeAnswer {
        let display = Items.displayOf(name)
        let local = localQuests.forItem(name)
        let key = ItemNames.itemKey(name)
        // Primary: the committed database. Answered here, an item costs no overlay read and no
        // announcement, so a miss describes only names the corpus lacks.
        if let entry = items.get(key) {
            var record = Items.mergeLocal(Items.knowledgeFromDb(entry, display), local)
            // `cached: true` because this is knowledge we already had, not a fresh lookup.
            record.set("cached", true)
            return KnowledgeAnswer(record: record, found: true)
        }
        if let entry = overlayEntry("item", key) {
            let found = KnowledgeCorpus.overlayFound(entry)
            var record = Items.mergeLocal(Items.knowledgeFromDb(entry, display), local)
            record.set("cached", true)
            return KnowledgeAnswer(record: record, found: found)
        }
        // Asked with the DISPLAY name: that is what the app's fetch will search the wiki for, and a
        // folded key is not a name.
        noteMiss("item", display)
        return KnowledgeAnswer(record: Items.unanswered(display, local), found: false)
    }

    // MARK: - knowledge.mob

    public func identityKeys(_ mob: String) -> [String] {
        mobIndex.identity(mob.trimmingCharacters(in: .whitespacesAndNewlines)).keys
    }

    /// The catalog, then the overlay, then a miss; the local half merged on top of whichever
    /// answered, and the era evidence attached at the one confluence all exits pass through.
    public func mob(_ name: String, loot: OwnLoot) -> KnowledgeAnswer {
        let display = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = mobIndex.identity(display)
        // What the catalog and the overlay are asked. Identical to `display` for every mob the
        // roster does not spell two ways, which is nearly all of them.
        let ask = id.canonical
        let base: JSONValue
        let found: Bool
        if let entry = mobIndex.entry(ask) {
            base = Mobs.knowledgeFromCatalog(display, entry)
            found = true
        } else if let entry = overlayEntry("mob", Mobs.mobKey(ask)) {
            found = KnowledgeCorpus.overlayFound(entry)
            var record = entry
            record.set("name", .string(display))
            record.set("cached", true)
            base = record
        } else {
            // Asked with the CANONICAL name: the roster's spelling is the one the wiki and the
            // catalog use.
            noteMiss("mob", ask)
            base = Mobs.unanswered(display)
            found = false
        }
        let merged = Mobs.mergeLocalKnowledge(base, id, mobQuests, loot)
        return KnowledgeAnswer(record: Mobs.annotateDropEras(merged, items), found: found)
    }

    /// The committed catalog, and NOTHING ELSE: no overlay read, no alias resolution, and — the
    /// load-bearing half — no miss.
    public func knownMob(_ name: String) -> Bool {
        mobIndex.entry(name.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
    }

    // MARK: - knowledge.spell

    /// One spell, from the effective catalog.
    ///
    /// Every field is copied across ONLY IF THE DB STATES IT, so an absent wiki field stays absent
    /// and the card never has to decide what a missing duration looks like.
    ///
    /// EXACT NAME MATCH ONLY, a stated limit rather than a bug: answering `Rune III` with `Rune`'s
    /// numbers needs the lineage block that would say out loud they are the line's, which is the
    /// named gap in the header. Without it, `found: false` is the honest answer.
    public func spell(_ name: String) -> KnowledgeAnswer {
        let queried = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let db = SpellDb.shared()
        let wanted = queried.lowercased()
        guard let entry = db.spells.first(where: {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == wanted
        }) else {
            return KnowledgeAnswer(record: ["queried": .string(queried), "found": false, "illusion": false],
                                   found: false)
        }
        var record: JSONValue = [
            "queried": .string(queried),
            "name": .string(entry.name),
            "found": true,
            "illusion": .bool(entry.illusion)
        ]
        func stated(_ key: String, _ value: JSONValue) {
            if !value.isNull { record.set(key, value) }
        }
        stated("durationText", entry.durationText.map { .string($0) } ?? .null)
        stated("durationMs", entry.durationMs.map { .int($0) } ?? .null)
        stated("targetType", entry.targetType.map { .string($0) } ?? .null)
        stated("spellType", entry.spellType.map { .string($0) } ?? .null)
        stated("classes", entry.classes.map { .string($0) } ?? .null)
        stated("msgCastOnYou", entry.msgCastOnYou.map { .string($0) } ?? .null)
        stated("msgCastOnOther", entry.msgCastOnOther.map { .string($0) } ?? .null)
        stated("msgWearsOff", entry.msgWearsOff.map { .string($0) } ?? .null)
        stated("effects", entry.effects.map { .array($0.map { .string($0) }) } ?? .null)
        return KnowledgeAnswer(record: record, found: true)
    }

    // MARK: - knowledge.search

    /// One searchable name, folded once at index time.
    ///
    /// The Rust case-folds every candidate on every keystroke and its corpora are `&str` slices out
    /// of one parsed document; here a candidate is a `String` inside a `JSONValue`, and folding all
    /// ~18,000 of them per keystroke allocated two copies each. The fold is hoisted into the index
    /// instead, which puts a keystroke at 0.9–9.4 ms in a release build. Nothing about the ANSWER
    /// changes: `order` below is still the order the four corpora are pushed in, so the sort's last
    /// term is what it was.
    struct SearchRow {
        let name: String
        /// `name` lowercased, as UTF-8 bytes — what `rankOf` compares against.
        let folded: [UInt8]
        /// `name.len()` in the Rust: bytes, the second ranking term.
        let length: Int
        let page: String?
        let domain: String
    }

    /// The four corpora in the order `search` pushes them, each name folded once.
    ///
    /// Item order is the committed map's KEY order, which is `serde_json`'s `BTreeMap` order in the
    /// Rust — byte-sorted. It shows only in the sort's last term, and only for two names that tie on
    /// all four of the terms before it.
    private static func buildSearchRows(_ items: ItemDb, _ mobs: MobIndex, _ quests: [JSONValue]) -> [SearchRow] {
        var rows: [SearchRow] = []
        rows.reserveCapacity(items.keysSorted.count + mobs.names().count + quests.count + 4096)
        func row(_ name: String, _ page: String?, _ domain: String) -> SearchRow {
            SearchRow(name: name, folded: foldedBytes(name), length: name.utf8.count, page: page, domain: domain)
        }
        for key in items.keysSorted {
            guard let entry = items.map[key] else { continue }
            let page = entry["page"].string
            rows.append(row(entry["name"].string ?? page ?? "", page, "item"))
        }
        for name in mobs.names() {
            rows.append(row(name, mobs.entry(name)?["page"].string, "mob"))
        }
        for q in quests {
            rows.append(row(q["name"].string ?? "", q["page"].string, "quest"))
        }
        for entry in SpellDb.shared().spells {
            rows.append(row(entry.name, nil, "spell"))
        }
        return rows
    }

    /// Lowercased UTF-8 bytes. ASCII — every name in these corpora but a handful — folds in place;
    /// anything else goes the long way through Swift's full lowercasing, which is what the Rust's
    /// `to_lowercase` does for the characters a `[a-z0-9]`-ish needle can match anyway.
    static func foldedBytes(_ s: String) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(s.utf8.count)
        for b in s.utf8 {
            if b >= 0x80 { return Array(s.lowercased().utf8) }
            out.append(b >= 0x41 && b <= 0x5A ? b + 32 : b)
        }
        return out
    }

    /// One scored candidate. `order` is the corpus's own push order, which stands in for the
    /// stability of Rust's `sort_by` — the four ranking terms are not total on their own.
    private struct Scored {
        var rank: UInt8
        var length: Int
        var name: String
        var domain: String
        var page: String?
        var order: Int
    }

    /// Name search across every corpus this engine holds.
    ///
    /// A lookup needs the exact name; a person types three letters. Hits rank EXACT, then PREFIX,
    /// then CONTAINS, and within a rank by name length then alphabetically, so the ranking is total
    /// and the same query twice is the same answer twice.
    ///
    /// The ranking is the ENGINE'S, not the client's: the renderer never sorts or filters domain
    /// data, so handing back an unordered bag would be handing back the work.
    public func search(_ query: String, domain: String? = nil, limit: Int? = nil) -> JSONValue {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let needle = KnowledgeCorpus.foldedBytes(trimmed)
        let limit = min(limit ?? searchDefaultLimit, searchMaxLimit)
        if needle.isEmpty { return ["query": .string(trimmed), "total": 0, "hits": .array([])] }
        var scored: [Scored] = []
        for (i, r) in searchRows.enumerated() {
            // The `domain` filter is a filter and not a hint: an unranked hit from another corpus
            // would be the same defect an accept-and-ignore filter field is on a view.
            if let domain, domain != r.domain { continue }
            guard let rank = KnowledgeCorpus.rankOf(r.folded, needle) else { continue }
            scored.append(Scored(rank: rank, length: r.length, name: r.name, domain: r.domain,
                                 page: r.page, order: i))
        }
        scored.sort { a, b in
            if a.rank != b.rank { return a.rank < b.rank }
            if a.length != b.length { return a.length < b.length }
            if a.name != b.name { return bytesLess(a.name, b.name) }
            if a.domain != b.domain { return bytesLess(a.domain, b.domain) }
            return a.order < b.order
        }
        let total = scored.count
        let hits: [JSONValue] = scored.prefix(limit).map { s in
            var hit: JSONValue = ["domain": .string(s.domain), "name": .string(s.name)]
            if let page = s.page { hit.set("page", .string(page)) }
            return hit
        }
        // `total` is the MATCH count, not the hit count: the one number a caller cannot compute from
        // what it was handed.
        return ["query": .string(trimmed), "total": .int(Int64(total)), "hits": .array(hits)]
    }

    /// EXACT (0), PREFIX (1), CONTAINS (2), or no match. Both sides already case-folded.
    ///
    /// Byte-wise, because the Rust it ports is: `str`'s `==`, `starts_with` and `contains` compare
    /// UTF-8 bytes, while Swift's own three fold canonical equivalence in first.
    static func rankOf(_ folded: [UInt8], _ needle: [UInt8]) -> UInt8? {
        if folded.count < needle.count { return nil }
        func matches(_ at: Int) -> Bool {
            for i in 0..<needle.count where folded[at + i] != needle[i] { return false }
            return true
        }
        if matches(0) { return folded.count == needle.count ? 0 : 1 }
        var at = 1
        while at + needle.count <= folded.count {
            if matches(at) { return 2 }
            at += 1
        }
        return nil
    }
}
