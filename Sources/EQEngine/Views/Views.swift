// The view layer: a source registry, descriptor validation, and the window one subscription is
// served from (engined/src/views/mod.rs).
//
// The subscription diff protocol, as held here:
// 1. Reset-then-diffs. A subscription whose window state is nil is owed a reset, and nothing else
//    may be sent to it.
// 2. Coalescing at a cadence, not a push per event — see `SERVE_EVERY`.
// 3. Every message carries the epoch; the stamp happens inside the world's critical section, which
//    is why the serving loop lives there and not here.
// 4. Rows are render-ready. This file owns the query — filter, sort, window — and each source owns
//    what a row of it looks like.
//
// A query field and a cell are different values even under the same name: the cell is what the
// pixel says (`Aug 19, 04:21 PM`), the field is the comparable value underneath it. Sources declare
// both and the two are looked up separately; a field with no cell, or a cell with no field, is
// intended.
//
// Two things cross as numbers rather than as their wording: a value read against now (`startedTs`,
// `durationMs`, `mode`), because text would be stale between two frames and the renderer would
// recompute it anyway; and a value whose phrasing is a derivation several surfaces share, so the
// wire carries no second copy of that vocabulary. A cell is a scalar, and nothing is stringified
// into one for a client to parse back out.
//
// Every sort ends in its source's `tiebreak` so the order is total. EQ log timestamps are
// second-resolution, so ties are the common case rather than the corner, and a window whose order
// is not total shuffles between services — reorder churn for a list nobody changed.
//
// A subscription is serviced only when its source's revision moved or when it is owed a reset, so
// an idle session pays nothing; building a source's rows and cutting a window are each O(the whole
// source), and the meter measures what that costs.
import Foundation
import EQCompanionCore

public extension Views {
    /// The floor between two services of the same subscription — rule 2's ~10 Hz ceiling.
    ///
    /// A ceiling on frame rate, not a promise of one: nothing is sent when nothing moved. Stated as
    /// a duration because an events-based rule would fire a hundred times a second on a raid slice
    /// and never on a quiet one.
    static let serveEvery: TimeInterval = 0.100

    /// The window a source hands back when the descriptor states none. An absent window means the
    /// engine's default for that source and never `everything`, which is how a payload budget gets
    /// blown.
    static let defaultLimit: Int64 = 50

    /// The largest window this engine will cut, whoever asks.
    ///
    /// A client-chosen number is untrusted even from a renderer we wrote: a typo'd `limit` of
    /// 10_000_000 would allocate ten million rows on the ingest thread, the one the fold runs on.
    static let maxLimit: Int64 = 1_000
}

/// Which way a sort term runs.
public enum Order: String, Sendable, Equatable {
    /// Smallest first; a missing value first.
    case asc
    /// Largest first; a missing value last.
    case desc

    /// The wire spelling — the second element of a sort term.
    static func parse(_ word: String) -> Order? { Order(rawValue: word) }
}

/// One comparable value of a row — what a `sort` or `filter` term names.
///
/// Deliberately not a cell: a cell is display text and this is the value underneath it. `missing`
/// is a value rather than an absence so ordering stays total over a sometimes-empty column.
public enum Field: Equatable, Sendable {
    /// A whole number: an instant in epoch millis, a count, an index.
    case int(Int64)
    /// Text, compared by code point and never by locale: a host collation in the serve path is a
    /// host-dependent answer, and determinism is cacheability. The consequence is stated rather
    /// than hidden — an accented name sorts differently here than the app's `localeCompare` sorts
    /// it.
    case text(String)
    /// The row has no value for this field.
    case missing

    /// Total order over one column: missing first, then numbers, then text.
    ///
    /// The cross-type arms cannot happen for a well-formed source and are ordered rather than
    /// raising, because a serve path is not a place to raise.
    func compare(_ other: Field) -> Int {
        switch (self, other) {
        case (.missing, .missing): return 0
        case (.missing, _): return -1
        case (_, .missing): return 1
        case (.int(let a), .int(let b)): return a == b ? 0 : (a < b ? -1 : 1)
        case (.text(let a), .text(let b)): return Views.codePointCompare(a, b)
        case (.int, .text): return -1
        case (.text, .int): return 1
        }
    }

    /// Does this field equal the value a filter named? A filter is a cell on the wire, so the
    /// comparison crosses the two vocabularies here, once.
    func matches(_ wanted: JSONValue) -> Bool {
        switch (self, wanted) {
        case (.missing, .null): return true
        case (.text(let text), .string(let s)): return text == s
        // `serde_json::Number::as_i64` answers only for a number that arrived whole, so a filter
        // spelled `50.0` matches nothing — the same refusal the Rust makes.
        case (.int(let n), .int(let m)): return n == m
        default: return false
        }
    }
}

/// One row of a source before any window is cut: its identity, what it renders as, and what it can
/// be queried by.
public struct SourceRow {
    /// Stable identity within the view — `loot:9413`. The key lives outside the cells so a reset
    /// row and a diff update apply the same way.
    public var key: String
    /// The render-ready cells, exactly as the client will draw them.
    public var cells: [String: JSONValue]
    /// The comparable values a descriptor may name. Small enough that a linear lookup beats a map.
    public var fields: [(String, Field)]

    public init(key: String, cells: [String: JSONValue], fields: [(String, Field)]) {
        self.key = key
        self.cells = cells
        self.fields = fields
    }

    func field(_ name: String) -> Field {
        for (id, value) in fields where id == name { return value }
        return .missing
    }

    func row() -> Row { Row(key: key, cells: cells) }
}

/// What a source is to the registry: a name, the fields it can be queried by, the order it takes
/// when nobody states one, and the tiebreak that makes every order total.
public struct SourceDef: Sendable {
    /// The name a descriptor asks for. Not a module id — `loot.ledger` is a view over the `loot`
    /// module, filtered, sorted and windowed, and `module.snapshot` refuses this name.
    public let id: String
    /// Every field a `sort` or `filter` term may name. A term naming anything else is `badParams`:
    /// ignoring it silently would hand a client a window it cannot tell apart from the one it
    /// asked for.
    public let fields: [String]
    /// The order a descriptor with no `sort` gets.
    public let defaultSort: [(String, Order)]
    /// Appended to every sort, so the order is total. The field named here must be unique within
    /// the source.
    public let tiebreak: (String, Order)
    /// The window a descriptor with no `window` gets, at offset 0.
    public let defaultLimit: Int64

    public init(id: String, fields: [String], defaultSort: [(String, Order)],
                tiebreak: (String, Order), defaultLimit: Int64) {
        self.id = id
        self.fields = fields
        self.defaultSort = defaultSort
        self.tiebreak = tiebreak
        self.defaultLimit = defaultLimit
    }
}

/// A validated descriptor — the whole query, with every name resolved against a real source.
///
/// Nothing downstream re-checks anything: if one of these exists, its source is registered, its
/// terms name real fields, and its window is inside the budget.
public struct View {
    /// The source it reads.
    public var source: SourceDef
    /// Field-name to value, ANDed.
    public var filter: [(String, JSONValue)]
    /// The sort terms, defaulted if the descriptor stated none, with the tiebreak appended.
    public var sort: [(String, Order)]
    /// How many rows to skip.
    public var offset: Int
    /// How many rows to take.
    public var limit: Int
}

/// Why a descriptor was refused, in the protocol's own terms.
public struct ViewError: Error, Equatable {
    /// The code the client branches on.
    public var code: String
    /// The sentence a bug report carries.
    public var message: String

    static func notFound(_ source: String) -> ViewError {
        ViewError(code: "notFound",
                  message: "this engine serves no view source named \(Views.quote(source)); it serves "
                      + Views.sources.map(\.id).joined(separator: ", "))
    }

    static func bad(_ message: String) -> ViewError { ViewError(code: "badParams", message: message) }
}

/// One source's rows, built once and cut for every subscription that reads it.
public struct Prepared {
    /// Which source these are.
    public var source: String
    /// The change signal they were built at.
    public var revision: UInt64
    /// Every row of the source, in its natural order.
    public var rows: [SourceRow]

    public init(source: String, revision: UInt64, rows: [SourceRow]) {
        self.source = source
        self.revision = revision
        self.rows = rows
    }
}

/// Where the rows come from — implemented over the ingest thread's fold.
public protocol ViewRows {
    /// Every row of one source, in its natural order, or nil when this fold carries no such source.
    /// Nil is not an error: a counting sink folds no modules at all, and a subscription over a
    /// source it cannot serve gets an empty window rather than a refusal it can do nothing about.
    func rows(_ source: SourceDef) -> [SourceRow]?
    /// The source's change signal — a number that moves whenever the source could have changed.
    /// Nil for a source this fold does not carry.
    func revision(_ source: SourceDef) -> UInt64?
}

/// A fold that serves no view at all: every window is empty, every revision is zero.
///
/// The world's own unit tests hand this to the serving loop so the epoch, the generation and the
/// subscription laws can be proven with no fold, no thread and no file. In production the same
/// answer comes from a sink that carries no such module.
public struct NoRows: ViewRows {
    public init() {}
    public func rows(_ source: SourceDef) -> [SourceRow]? { nil }
    public func revision(_ source: SourceDef) -> UInt64? { nil }
}

/// The descriptor as it arrives on the wire, before any name is resolved. Kept apart from the
/// client's typed `ViewDescriptor` because a direction is a free string until validation says
/// otherwise, and refusing `"sideways"` by name is part of the contract.
public struct RawDescriptor {
    public var source: String
    /// Sorted by field name — the Rust reads a `BTreeMap`, so which of two bad names is refused
    /// first is the sorted one.
    public var filter: [(String, JSONValue)]
    public var sort: [(String, String)]
    public var window: (offset: Int64, limit: Int64)?

    public init(source: String, filter: [(String, JSONValue)] = [], sort: [(String, String)] = [],
                window: (offset: Int64, limit: Int64)? = nil) {
        self.source = source
        self.filter = filter
        self.sort = sort
        self.window = window
    }

    /// The client's typed descriptor, as this layer reads it.
    public init(_ d: ViewDescriptor) {
        source = d.source
        filter = d.filter.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        sort = d.sort.map { ($0.field, $0.direction.rawValue) }
        window = d.window.map { (Int64($0.offset), Int64($0.limit)) }
    }

    /// One descriptor as JSON — the shape the schema states and the goldens record.
    public init(json: JSONValue) {
        source = json["source"].string ?? ""
        filter = (json["filter"].object ?? [:]).sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        sort = (json["sort"].array ?? []).map { ($0[0].string ?? "", $0[1].string ?? "") }
        if let w = json["window"].object {
            window = (w["offset"]?.int64 ?? 0, w["limit"]?.int64 ?? 0)
        } else {
            window = nil
        }
    }
}

/// The registry and the query over it.
public enum Views {
    /// Every source this build serves. An unknown source is `notFound`, which is only answerable
    /// because there is a list to be absent from.
    ///
    /// Two kinds. `loot.ledger`, `kills.recent`, `progression.recent` and `eventFeed.recent`
    /// append: a row, once written, never changes, so a live window over one produces inserts and
    /// drops and never an `update`. `combat.live`, `timers.rows`, `buffs.active` and
    /// `respawn.watches` edit — the same keys sit in the window while their numbers move.
    public static let sources: [SourceDef] = [
        Loot.ledger,
        Combat.live,
        Buffs.active,
        Timers.rowsSource,
        Respawn.watches,
        Kills.recent,
        Progression.recent,
        EventFeed.recent
    ]

    /// The source by that name, or nil.
    public static func source(_ id: String) -> SourceDef? { sources.first { $0.id == id } }

    /// Resolve one descriptor against the registry.
    ///
    /// Every refusal is by name: which term was wrong and, where it helps, what the source does
    /// carry. The alternative is a client that gets a window it did not ask for and no way to
    /// notice.
    public static func validate(_ descriptor: RawDescriptor) throws -> View {
        guard let source = source(descriptor.source) else {
            throw ViewError.notFound(descriptor.source)
        }
        func fieldOf(_ name: String) -> String? { source.fields.first { $0 == name } }
        let known = source.fields.joined(separator: ", ")

        var filter: [(String, JSONValue)] = []
        for (name, value) in descriptor.filter {
            guard let field = fieldOf(name) else {
                throw ViewError.bad("\(source.id) carries no field named \(quote(name)) to filter on; it carries \(known)")
            }
            filter.append((field, value))
        }

        var sort: [(String, Order)] = []
        for (name, direction) in descriptor.sort {
            guard let field = fieldOf(name) else {
                throw ViewError.bad("\(source.id) carries no field named \(quote(name)) to sort by; it carries \(known)")
            }
            guard let order = Order.parse(direction) else {
                throw ViewError.bad("a sort direction is \"asc\" or \"desc\", never \(quote(direction))")
            }
            sort.append((field, order))
        }
        if sort.isEmpty { sort.append(contentsOf: source.defaultSort) }
        // Appended to every sort, the client's own included: an order that is not total is a window
        // that shuffles, and a shuffled window is diff churn.
        sort.append(source.tiebreak)

        let offset: Int64, limit: Int64
        if let window = descriptor.window {
            (offset, limit) = (window.offset, window.limit)
        } else {
            (offset, limit) = (0, source.defaultLimit)
        }
        if offset < 0 {
            throw ViewError.bad("a window offset counts rows from the start of the view and cannot be \(offset)")
        }
        if limit <= 0 {
            throw ViewError.bad("a window limit is how many rows to send and cannot be \(limit)")
        }
        if limit > Views.maxLimit {
            throw ViewError.bad("a window of \(limit) rows is over this engine's budget of \(Views.maxLimit)")
        }
        return View(source: source, filter: filter, sort: sort,
                    offset: Int(clamping: offset), limit: Int(clamping: limit))
    }

    public static func validate(_ descriptor: ViewDescriptor) throws -> View {
        try validate(RawDescriptor(descriptor))
    }

    /// Cut one window out of a source's rows: filter, sort, then slice.
    ///
    /// Returns the window and the view's total — how many rows survived the filter, ignoring the
    /// window, which is what a `1–50 of 1834` line reads off.
    ///
    /// The sort is stable and the tiebreak makes it total, so the same rows and the same descriptor
    /// produce the same window every time; the diff between two window states is the wire protocol,
    /// so an unstable order would send reorder ops for a view nobody touched.
    public static func cut(_ view: View, _ rows: [SourceRow]) -> (window: [Row], total: Int64) {
        var kept: [(Int, SourceRow)] = []
        for (at, row) in rows.enumerated() {
            if view.filter.allSatisfy({ row.field($0.0).matches($0.1) }) { kept.append((at, row)) }
        }
        // Rust's `sort_by` is stable; Swift's `sorted` is not, so the original position is the last
        // resort of the comparison rather than an accident of the algorithm.
        kept.sort { a, b in
            for (field, order) in view.sort {
                var ordering = a.1.field(field).compare(b.1.field(field))
                if order == .desc { ordering = -ordering }
                if ordering != 0 { return ordering < 0 }
            }
            return a.0 < b.0
        }
        let total = Int64(kept.count)
        let start = min(view.offset, kept.count)
        let end = min(start + view.limit, kept.count)
        return (kept[start..<end].map { $0.1.row() }, total)
    }

    /// Rust's `str::cmp` — UTF-8 byte order, which is code point order. Swift's `<` on `String` is
    /// a canonical-equivalence collation, so it is spelled out rather than borrowed.
    static func codePointCompare(_ a: String, _ b: String) -> Int {
        var i = a.utf8.makeIterator()
        var j = b.utf8.makeIterator()
        while true {
            switch (i.next(), j.next()) {
            case (nil, nil): return 0
            case (nil, _): return -1
            case (_, nil): return 1
            case (let x?, let y?): if x != y { return x < y ? -1 : 1 }
            }
        }
    }

    /// Rust's `{:?}` over a string — the quoted, escaped spelling every refusal names a term in.
    static func quote(_ s: String) -> String {
        var out = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.unicodeScalars.append(ch)
            }
        }
        return out + "\""
    }
}

/// A cell that says nothing, or the text it does say.
func optionalCell(_ value: String?) -> JSONValue { value.map { .string($0) } ?? .null }

/// A field that is either text or a place in the order for the rows that have none.
func textOrMissing(_ value: String?) -> Field { value.map { Field.text($0) } ?? .missing }
