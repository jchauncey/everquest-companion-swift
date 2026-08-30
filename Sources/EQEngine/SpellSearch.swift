// engined/src/spell_search.rs — searching the client's spell table by TYPE, the way the in-game
// Actions/Spells window does: `spells_us.txt` files each spell under two integer ids and
// `dbstr_us.txt` says what those ids are called, so the app can offer the same capability without
// inventing a vocabulary.
//
// The query lives here and not in the fold: `SpellsUs` and `DbStr` own the two formats,
// `ClientSpells` owns the two files, and this module owns the question. Nothing here touches fold
// state in either direction, so the equivalence oracle is untouched by any of it.
//
// The parsed table is never served in one reply, so this is a filtered, sorted, windowed question
// with the window bounded at the op. The corpus is scanned linearly per call — the whole table is
// already in this process's memory, and an index would be complexity bought with nothing.
//
// The renderer re-derives none of it: rows arrive filtered, sorted and windowed with their category
// and subcategory spelled as words rather than ids. `categories` exists for the same reason — the
// category vocabulary lives only in the player's install, so the app cannot ship a hardcoded list.
import Foundation
import EQLog
import EQCompanionCore

/// How the caller wants the list ordered. Two members and no more: an unknown sort is `badParams` by
/// the schema's enum rather than by a check here, which satisfies "never accept-and-ignore"
/// structurally.
public enum SpellSort: String, Sendable, Hashable {
    /// Level descending — the in-game window's own order, and the default for that reason.
    case level
    /// Alphabetical, for a reader looking for a name rather than for what is newest.
    case name
}

public enum SpellSearch {
    /// One question about the client's table. Every filter is AND-ed, and an absent one filters
    /// nothing.
    public struct Query: Sendable {
        /// A case-insensitive substring of the spell's name, its category or its subcategory.
        ///
        /// The three fields are one haystack, and that is the capability rather than a convenience: a
        /// `tap` search returns `Leech` and `Siphon Strength`, whose names contain no `tap` — they
        /// are there because their category is `Taps`.
        public var text: String?
        /// An exact category, spelled as `Found.categories` spells it. Case-insensitive, so a value
        /// round-tripped through a URL or a stored preference still matches.
        public var category: String?
        /// An exact subcategory. Independent of `category` — the client table files nine rows under a
        /// subcategory with no category at all, so this is not a refinement of that filter.
        public var subcategory: String?
        /// The class COLUMNS to scope to, or `nil` for every class. The caller names the combo rather
        /// than the engine reading the attached world's, which would make a question about a static
        /// client file depend on fold state.
        public var classes: [Int]?
        public var sort: SpellSort = .level
        /// Where the window starts. Past the end is an empty page, never an error.
        public var offset: Int = 0
        /// How many rows the window holds. Bounded by the op before it ever reaches here.
        public var limit: Int = 0

        public init(text: String? = nil, category: String? = nil, subcategory: String? = nil,
                    classes: [Int]? = nil, sort: SpellSort = .level, offset: Int = 0, limit: Int = 0) {
            self.text = text; self.category = category; self.subcategory = subcategory
            self.classes = classes; self.sort = sort; self.offset = offset; self.limit = limit
        }
    }

    /// One class that can cast a spell, and when it learns it.
    public struct ClassLevel: Sendable, Hashable {
        /// The class code, spelled as the app spells it (`SHD`, `BRD`, `WIZ`).
        public var `class`: String
        /// The level that class learns it at. Always `1...254` — a zero is not a row.
        public var level: UInt8
        public init(class cls: String, level: UInt8) { self.class = cls; self.level = level }
    }

    /// One spell, as the surface draws it.
    public struct Row: Sendable, Hashable {
        /// The client's own spelling. The log and `spells_us.txt` outrank the wiki on a spell's name.
        public var name: String
        /// The level the list is sorted and filed by: the lowest level at which any class in scope
        /// learns this — the earliest a character with this combo could have it. `classes` beside it
        /// carries the whole truth, so nothing is hidden by the choice.
        public var level: UInt8
        /// Every in-scope class that can cast it, in the client file's column order.
        public var classes: [ClassLevel]
        /// The Category column's word, absent when the row files itself under none — or when the
        /// string table could not be read.
        public var category: String?
        public var subcategory: String?
        public init(name: String, level: UInt8, classes: [ClassLevel],
                    category: String?, subcategory: String?) {
            self.name = name; self.level = level; self.classes = classes
            self.category = category; self.subcategory = subcategory
        }
    }

    /// A category and the subcategories found under it, for a filter control to draw.
    public struct Facet: Sendable, Hashable {
        public var name: String
        /// Alphabetical, and only the ones actually present in this scope.
        public var subcategories: [String]
        public init(name: String, subcategories: [String]) {
            self.name = name; self.subcategories = subcategories
        }
    }

    /// What one query answered.
    public struct Found: Sendable, Hashable {
        /// The window — already filtered, already sorted.
        public var rows: [Row]
        /// How many rows matched, before the window. A surface says `1-20 of 143` off this without
        /// ever holding 143.
        public var total: Int
        /// The category vocabulary present in this scope.
        public var categories: [Facet]
        public init(rows: [Row], total: Int, categories: [Facet]) {
            self.rows = rows; self.total = total; self.categories = categories
        }
    }

    /// Can any class at all cast this? A row nobody can learn is a mob's or an item's copy of a
    /// spell, and it is excluded from every answer here: the in-game window lists what a player can
    /// have.
    static func playable(_ levels: SpellsUs.ClassLevels) -> Bool { levels.contains { $0 > 0 } }

    /// The in-scope classes that can cast this, and the lowest level among them. `nil` when none can,
    /// which is what excludes the row.
    static func scoped(_ levels: SpellsUs.ClassLevels, _ classes: [Int]?) -> (UInt8, [ClassLevel])? {
        var out: [ClassLevel] = []
        for (i, level) in levels.enumerated() {
            if level == 0 { continue }
            if let scope = classes, !scope.contains(i) { continue }
            out.append(ClassLevel(class: SpellsUs.CLASS_ORDER[i], level: level))
        }
        guard let lowest = out.map(\.level).min() else { return nil }
        return (lowest, out)
    }

    /// Case-insensitive equality, for a filter value that may have been round-tripped through a
    /// store.
    static func same(_ a: String, _ b: String) -> Bool { JS.eqIgnoreASCIICase(a, b) }

    /// Does the spell's name, category or subcategory contain this (already lower-cased) needle? The
    /// needle is lower-cased once by the caller rather than per row — this runs ~48,000 times per
    /// keystroke's worth of question.
    static func matchesText(_ name: String, _ category: String?, _ subcategory: String?, _ needle: String) -> Bool {
        if needle.isEmpty { return true }
        for field in [name, category, subcategory].compactMap({ $0 }) where field.lowercased().contains(needle) {
            return true
        }
        return false
    }

    /// `String`'s Rust `Ord`, which is byte-wise over UTF-8 — not Swift's `<`, which collates. Every
    /// tiebreak in this file rides on it, and the two orders part company the moment a name carries a
    /// latin-1 high byte.
    static func utf8Less(_ a: String, _ b: String) -> Bool {
        var x = a.utf8.makeIterator(), y = b.utf8.makeIterator()
        while true {
            switch (x.next(), y.next()) {
            case (nil, nil): return false
            case (nil, _): return true
            case (_, nil): return false
            case (let u?, let v?): if u != v { return u < v }
            }
        }
    }

    /// Search the client's table.
    ///
    /// The order is total: every sort ends in the canon key, which is unique because it is what the
    /// table is keyed by. That term is load-bearing — the corpus is a dictionary with unspecified
    /// iteration order, so a sort ending at `level` would order the same query's rows differently
    /// every call.
    ///
    /// The facets ignore the filter they describe: `categories` is computed over the class and text
    /// scope but not over `category`/`subcategory`, because a control that collapsed to the value you
    /// just picked is one you cannot get back out of.
    public static func search(_ table: SpellTable, _ names: DbStr.CategoryNames, _ query: Query) -> Found {
        // (sort key, canon key, row) for everything that matched; the key rides along so the sort
        // never re-derives.
        var matched: [(UInt8, String, Row)] = []
        // The facet accumulator: category -> its subcategories, sorted at the end into the
        // byte-wise order a `BTreeMap` would have kept them in.
        var facets: [String: Set<String>] = [:]
        // Lower-cased once: the corpus is ~48,000 rows and this is the inner loop of a search box.
        let needle = query.text.map { $0.lowercased() }

        for (key, info) in table {
            if !playable(info.classLevels) { continue }
            guard let (level, classes) = scoped(info.classLevels, query.classes) else { continue }
            // The words are resolved before the text filter because the text filter reads them: a
            // `tap` search finds `Leech` through its category, never through its name.
            let category = info.category.flatMap { names[$0] }
            let subcategory = info.subcategory.flatMap { names[$0] }
            if let needle, !matchesText(info.name, category, subcategory, needle) { continue }

            // The facets are accumulated after the class and text scope and BEFORE the category
            // filter.
            if let cat = category {
                var entry = facets[cat] ?? []
                if let sub = subcategory { entry.insert(sub) }
                facets[cat] = entry
            }

            if let want = query.category {
                guard let c = category, same(c, want) else { continue }
            }
            if let want = query.subcategory {
                guard let s = subcategory, same(s, want) else { continue }
            }

            matched.append((level, key, Row(name: info.name, level: level, classes: classes,
                                            category: category, subcategory: subcategory)))
        }

        switch query.sort {
        // Level descending, then the key ascending — the in-game window's order, made total.
        case .level:
            matched.sort { a, b in a.0 != b.0 ? a.0 > b.0 : utf8Less(a.1, b.1) }
        // Alphabetical by the name a reader sees, then by key: names are not unique across keys, so
        // the second term is load-bearing here too.
        case .name:
            matched.sort { a, b in
                let x = a.2.name.lowercased(), y = b.2.name.lowercased()
                return x != y ? utf8Less(x, y) : utf8Less(a.1, b.1)
            }
        }

        let total = matched.count
        let window = matched.dropFirst(query.offset).prefix(query.limit).map(\.2)
        return Found(rows: Array(window), total: total,
                     categories: facets.keys.sorted(by: utf8Less).map {
                         Facet(name: $0, subcategories: (facets[$0] ?? []).sorted(by: utf8Less))
                     })
    }

    // MARK: - The op

    /// The most spell rows one `spells.search` window may hold. A bound on a stranger's request,
    /// generous because this is a browse as much as a search.
    public static let MAX_SPELL_ROWS: Int64 = 200

    /// What a `spells.search` with no `limit` gets.
    public static let DEFAULT_SPELL_ROWS: Int64 = 50

    /// Clamped, never refused — the same rule `combat.searchFights` applies to the same kind of
    /// number.
    public static func clampSpellRows(_ limit: Int64?) -> Int {
        guard let limit else { return Int(DEFAULT_SPELL_ROWS) }
        return Int(Swift.max(0, Swift.min(MAX_SPELL_ROWS, limit)))
    }

    /// A negative offset is no offset; past the end is an empty page.
    public static func clampOffset(_ offset: Int64?) -> Int {
        guard let offset, offset >= 0 else { return 0 }
        return Int(Swift.min(offset, Int64(Int.max)))
    }

    /// `spells.search` — the whole op below the params decode.
    ///
    /// The class codes become the client file's columns through the parser that owns the file's
    /// column order, never a second copy of it. Sorted and deduped is where this list's bound lives:
    /// the schema carries no `maxItems`, so a stranger may send the same class ten thousand times.
    ///
    /// Absent and empty classes are one state: both mean every class.
    ///
    /// No table is an empty answer, not a failure; `spellTable` beside it says which of the three
    /// situations produced it.
    public static func answer(_ spells: ClientSpells, text: String? = nil, category: String? = nil,
                              subcategory: String? = nil, classes: [String] = [],
                              sort: SpellSort = .level, offset: Int64? = nil,
                              limit: Int64? = nil) -> SpellsSearchResult {
        let columns = Array(Set(classes.compactMap { SpellsUs.classColumn($0) })).sorted()
        let window = clampSpellRows(limit)
        let start = clampOffset(offset)
        let query = Query(text: text, category: category, subcategory: subcategory,
                          classes: columns.isEmpty ? nil : columns,
                          sort: sort, offset: start, limit: window)
        let found = spells.table().map { search($0, spells.categoryNames(), query) }
        return SpellsSearchResult(found: found, spells: spells, offset: start, limit: window)
    }
}

// MARK: - The wire shapes

/// One class that can cast a spell, and when it learns it.
public struct SpellClassLevel: Sendable, Hashable {
    public var `class`: String
    public var level: Int64

    public init(class cls: String, level: Int64) { self.class = cls; self.level = level }

    public var json: JSONValue { .object(["class": .string(`class`), "level": .int(level)]) }
}

/// One spell as the Actions/Spells window draws it: a name, a level, and the two words it is filed
/// under. The category and subcategory arrive as WORDS and never as ids — a client receiving `114`
/// would have to join it against a table it is not allowed to have.
public struct SpellCatalogueRow: Sendable, Hashable {
    public var name: String
    public var level: Int64
    public var classes: [SpellClassLevel]
    public var category: String?
    public var subcategory: String?

    public init(_ row: SpellSearch.Row) {
        name = row.name
        level = Int64(row.level)
        // Both lists are the same sixteen classes, so no code here is ever unknown to the wire.
        classes = row.classes.map { SpellClassLevel(class: $0.class, level: Int64($0.level)) }
        category = row.category
        subcategory = row.subcategory
    }

    public var json: JSONValue {
        var o: [String: JSONValue] = [
            "name": .string(name),
            "level": .int(level),
            "classes": .array(classes.map(\.json))
        ]
        if let category { o["category"] = .string(category) }
        if let subcategory { o["subcategory"] = .string(subcategory) }
        return .object(o)
    }
}

/// A category and the subcategories found under it IN THIS SCOPE — never the whole vocabulary, so a
/// control never offers a value that would return nothing. Alphabetical, both levels.
public struct SpellCategoryFacet: Sendable, Hashable {
    public var name: String
    public var subcategories: [String]

    public init(name: String, subcategories: [String]) {
        self.name = name; self.subcategories = subcategories
    }

    public var json: JSONValue {
        .object(["name": .string(name), "subcategories": .array(subcategories.map(JSONValue.string))])
    }
}

/// A window onto the client's spell catalogue, already filtered, already sorted.
///
/// `spellTable` and `path` ride EVERY answer for `ResistSpellResult`'s reason exactly — an empty list
/// means several different things to a person. It is `spellTable` rather than `table` because
/// `resist.spell` already owns the bare word `table` as its discriminator.
public struct SpellsSearchResult: Sendable, Hashable {
    public var spells: [SpellCatalogueRow]
    public var total: Int64
    public var offset: Int64
    public var limit: Int64
    public var categories: [SpellCategoryFacet]
    public var spellTable: SpellTableState
    public var path: String

    /// `found` is `nil` when there is no table to search: an empty answer rather than a failure.
    public init(found: SpellSearch.Found?, spells table: ClientSpells, offset: Int, limit: Int) {
        spells = found?.rows.map(SpellCatalogueRow.init(_:)) ?? []
        total = Int64(found?.total ?? 0)
        self.offset = Int64(offset)
        self.limit = Int64(limit)
        categories = found?.categories.map { SpellCategoryFacet(name: $0.name, subcategories: $0.subcategories) } ?? []
        spellTable = table.state
        path = table.path
    }

    public var json: JSONValue {
        .object([
            "spells": .array(spells.map(\.json)),
            "total": .int(total),
            "offset": .int(offset),
            "limit": .int(limit),
            "categories": .array(categories.map(\.json)),
            "spellTable": .string(spellTable.rawValue),
            "path": .string(path)
        ])
    }
}
