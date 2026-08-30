// Port of fold/src/modules/event_feed.rs — the live "things worth noticing" ring behind the events
// overlay.
//
// The hydration rule IS the module: nothing historical is admitted. `onEvent` records the seq and
// returns the instant `live` is false, so the ring starts empty and only ever holds what the tail
// observed.
//
// Two of the four sources are live here. The LOOT source admits a row only through the knowledge
// lookup installed by `installKnowledge` — production only — under the shared predicate: lore,
// quest-flagged, or used by at least one known quest. The CONSIDER source needs no lookup but does
// need the anti-spam window and the difficulty-clause table.
//
// The other two stay off the bus: `noteAlertFire` and `report` arrive out of band.
import Foundation
import EQLog
import EQCompanionCore

/// How many entries the feed keeps. Oldest fall off the back.
public let feedCap = 100

/// Consider anti-spam window — `CONSIDER_FEED_DEDUPE_MS`, verbatim. Per mob; the feed is the only
/// surface a re-con burst could spam.
public let considerFeedDedupeMs: Int64 = 10_000

/// The difficulty clause → a short label for a dense row — `CONSIDER_DIFFICULTY_SHORT`, verbatim.
/// Keys are the phrases observed in the full-log sweep, with the gendered pronoun folded onto the
/// neuter form. An unseen phrase returns nothing and the caller shows the verbatim clause.
private let considerDifficultyShort: [(String, String)] = [
    ("what would you like your tombstone to say?", "suicide"),
    ("looks like it would wipe the floor with you!", "wipes the floor"),
    ("it appears to be quite formidable.", "formidable"),
    ("looks like quite a gamble.", "a gamble"),
    ("looks kind of dangerous.", "dangerous"),
    ("you would probably win this fight... it's not certain though.", "probably win"),
    ("looks quite risky, but might be worth a try.", "worth a try"),
    ("looks kind of risky, but you might win.", "might win"),
    ("looks kind of risky... you might win.", "might win"),
    ("you could probably win this fight.", "likely win"),
    ("looks like a reasonably safe opponent.", "safe")
]

/// Short label for a difficulty clause, or nil when nobody has seen the phrase.
///
/// `\b(?:he|she)\b → it` plus a whitespace collapse, spelled without a regex: for this table the JS
/// word boundary is exactly "the whole token is `he` or `she`".
public func difficultyShort(_ difficulty: String) -> String? {
    let folded = JS.trim(difficulty).lowercased()
        .split(whereSeparator: { $0.isWhitespace })
        .map { word -> String in
            // The boundary is around the letters, so trailing punctuation stays put: `she.` folds
            // to `it.`, as the JS replace does.
            let head = String(word.prefix { $0.isASCII && $0.isLetter })
            if head == "he" || head == "she" { return "it" + word.dropFirst(head.count) }
            return String(word)
        }
        .joined(separator: " ")
    return considerDifficultyShort.first { $0.0 == folded }?.1
}

/// The consider context of a `con` row, carried structurally so the overlay draws the faction rung
/// rather than re-deriving it from prose.
public struct FeedConsider {
    /// The faction rung the con line printed.
    public var faction: String
    /// The level it stated, when it stated one.
    public var level: Int64?
    /// The rare infix was on the line.
    public var rare: Bool
    /// Verbatim difficulty clause.
    public var difficulty: String

    public init(faction: String, level: Int64?, rare: Bool, difficulty: String) {
        self.faction = faction; self.level = level; self.rare = rare; self.difficulty = difficulty
    }

    var json: JSONValue {
        var o: [String: JSONValue] = ["faction": .string(faction), "rare": .bool(rare),
                                      "difficulty": .string(difficulty)]
        if let l = level { o["level"] = .int(l) }
        return .object(o)
    }
}

/// One row of the feed. Every optional field is absent rather than null because the published shape
/// came through `JSON.stringify`, which drops an `undefined`.
public struct FeedEvent {
    /// `f1`, `f2`, … — monotonic per session, the React key and the dedupe handle.
    public var id: String
    /// Which of the feed's four kinds this is.
    public var kind: String
    /// When, on the log's own clock.
    public var ts: Int64
    /// The line the overlay draws.
    public var title: String
    /// The second line, when there is one.
    public var detail: String?
    /// The wiki page this row deep-links to.
    public var page: String?
    /// The consider context, on a `con` row.
    public var con: FeedConsider?

    public init(id: String, kind: String, ts: Int64, title: String, detail: String? = nil,
                page: String? = nil, con: FeedConsider? = nil) {
        self.id = id; self.kind = kind; self.ts = ts; self.title = title
        self.detail = detail; self.page = page; self.con = con
    }

    var json: JSONValue {
        var o: [String: JSONValue] = ["id": .string(id), "kind": .string(kind), "ts": .int(ts),
                                      "title": .string(title)]
        if let d = detail { o["detail"] = .string(d) }
        if let p = page { o["page"] = .string(p) }
        if let c = con { o["con"] = c.json }
        return .object(o)
    }
}

/// `shared/itemKnowledge.ts isNotableKnowledge` — lore, quest-flagged, or used by at least one
/// known quest. Everything else is ordinary vendor trash. Tradeskill recipes deliberately do not
/// count: this predicate drives the PUSH surfaces.
public func isNotable(_ record: JSONValue) -> Bool {
    if record["lore"].bool == true { return true }
    if record["quest"].bool == true { return true }
    if let uses = record["questUses"].array { return !uses.isEmpty }
    return false
}

public final class EventFeedModule: EqModule {
    public let id = "eventFeed"

    /// Newest last (the UI reverses it). Never grows on a historical fold — see the header.
    private var feed: [FeedEvent] = []
    private var seq: Int64 = 0
    private var idCounter: Int64 = 0
    /// mob name (trimmed, lowercased) → the ts of the last con admitted.
    private var lastCon: [String: Int64] = [:]
    /// The item lookup, or nil in every construction but the production one.
    private var knowledge: Knowledge?
    /// The announce cursor. Every path into the ring goes through `append`, so that one function is
    /// the whole announce surface.
    private var announce = Announce()

    public init() {}

    /// The feed pull seam — the ring as the module keeps it, oldest first. The view reverses it.
    public func ring() -> [FeedEvent] { feed }

    /// The change signal — the module's published `seq`, bumped on every append as well as on every
    /// event. Coarse, because there is no separate revision counter to read.
    public func revision() -> Int64 { seq }

    /// Append one row and bump the seq. An append carries no fresh event seq, so the module bumps
    /// its own and the client's gap check accepts the delta.
    private func append(_ row: FeedEvent) {
        idCounter += 1
        var r = row
        r.id = "f\(idCounter)"
        feed.append(r)
        while feed.count > feedCap { feed.removeFirst() }
        seq += 1
        announce.changed(seq)
    }

    /// Append a consider row, unless the same mob was already admitted inside the anti-spam window.
    ///
    /// No lookup gates admission — every field came off the log line. `page` is deliberately absent:
    /// the wiki page is not known here, and a fabricated link is worse than none.
    private func noteConsider(_ ev: Event) {
        let mob = ev.str(.mob) ?? ""
        let ts = ev.ts
        let key = JS.trim(mob).lowercased()
        if let last = lastCon[key], ts - last < considerFeedDedupeMs { return }
        lastCon[key] = ts
        let level = ev.int(.level)
        let rare = ev.bool(.rare)
        let difficulty = ev.str(.difficulty) ?? ""
        // `Lvl 38 · suicide`, with a `· rare` marker when the line carried the rare-creature infix.
        // An unrecognized clause falls back to the verbatim clause rather than a guessed label.
        var bits: [String] = []
        if let level { bits.append("Lvl \(level)") }
        bits.append(difficultyShort(difficulty) ?? difficulty)
        if rare { bits.append("rare") }
        append(FeedEvent(id: "", kind: "con", ts: ts, title: mob,
                         detail: bits.joined(separator: " · "), page: nil,
                         con: FeedConsider(faction: ev.str(.faction) ?? "", level: level,
                                           rare: rare, difficulty: difficulty)))
    }

    /// Probe a freshly-looted item and append a row iff it is notable — `probeLoot`.
    ///
    /// A destroy is admitted and says so: still worth noticing, but not a pickup, so it never
    /// borrows the `from <mob>` caption.
    private func probeLoot(_ ev: Event) {
        guard let knowledge else { return }
        let item = ev.str(.item) ?? ""
        if item.isEmpty { return }
        let destroyed = ev.str(.disposition) == "destroyed"
        let source = ev.str(.source)
        let answer = knowledge.item(item)
        if !isNotable(answer.record) { return }
        let name = answer.record["name"].string
        let title = (name?.isEmpty == false ? name! : item)
        let detail: String? = destroyed ? "destroyed" : source.map { "from \($0)" }
        append(FeedEvent(id: "", kind: "loot", ts: ev.ts, title: title, detail: detail,
                         page: answer.record["page"].string, con: nil))
    }

    public func reset() {
        // A character switch is a different world: drop the feed with the rest of the
        // character-scoped state. The lookup is not cleared — it is a handle on committed data.
        feed.removeAll()
        seq = 0
        idCounter = 0
        lastCon.removeAll()
        announce.reset()
    }

    /// Records the seq of every event, then returns unless `live`. That gate is the module.
    public func onEvent(_ ev: Event, live: Bool) {
        seq = ev.seq
        if !live { return }
        switch ev.kindOf {
        case .consider: noteConsider(ev)
        case .loot: probeLoot(ev)
        default: break
        }
    }

    /// Moves on a row that reached the ring, and nothing else.
    public var publishedSeq: Int64? { announce.cursor }

    public func snapshot() -> JSONValue { ["seq": .int(seq), "state": .array(feed.map(\.json))] }

    /// The view pull seam.
    public var asEventFeed: EventFeedModule? { self }

    public func installKnowledge(_ k: Knowledge) { knowledge = k }
}
