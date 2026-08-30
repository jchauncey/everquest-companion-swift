// Port of fold/src/modules/consider.rs — what have I been sizing up, and what does it drop.
//
// ONE ROW PER MOB: a mob conned five times during one pull is one row with `cons: 5`, carrying the
// MOST RECENT con's facts, and a re-con moves it to the front. That is why the ring is an array with
// a move-to-end rather than a `JSMap`, whose `insert` would keep an existing key's position.
//
// THE RING IS A STATE, not a feed, so the startup replay DOES fold into it and the card is populated
// the moment the app opens. What replay must not do is walk the corpus once per con: enrichment is
// live-only plus a bounded backfill on the first tick, and `knowledge` is therefore ABSENT from a row
// nothing has answered for — never an empty record meaning "we checked".
//
// THE OWN-LOOT INDEX is folded here, owned here, and published nowhere; it reaches a client only
// through `knowledge.mob`'s `dropsSeen`, a join made on demand. Its refusals are the part that
// matters: a destroy names no mob and is not a drop, and a `loot` event returns before the consider
// fold.
//
// THE KNOWLEDGE PROBE IS SYNCHRONOUS and arrives through `EqModule.installKnowledge`. The corpus is
// in this process, so a live con enriches inside the same fold and the row is published complete.
//
// A CON CARD IS A HAND-BACK, not a callback: `ConEvent`s buffered on the live path and taken by the
// ingest. The card is a thing that happened and the ring is a state, which is why the two are folded
// side by side.
import Foundation
import EQLog
import EQCompanionCore

/// How many considered mobs the ring keeps. Oldest fall off the FRONT.
public let considerCap = 50

/// How many of the ring's newest rows get enriched when the live tail takes over.
///
/// The newest handful is what a user looks at right after opening the app; everything else resolves
/// on hover. The number is the app's, kept verbatim.
public let considerBackfill = 12

private let mobKeyCopy = Re("\(JS.S)*\\([0-9]+\\)$")
private let mobKeyQuote = Re("[`\\u{2019}\\u{00b4}]")
private let mobKeySpaces = Re("\(JS.S)+")

/// The canonical identity key for a mob name: trim + lowercase, plus two folds.
///
/// The QUOTE FOLD lets one mob be one key across three sources — the log writes ``Innoruuk`s
/// Chosen`` with a backtick where the wiki writes a typographic or a straight apostrophe. The
/// COPY-NUMBER STRIP removes a trailing ` (N)`, which is ours and not the game's: `combat/world.ts
/// label()` appends the spawn generation when more than one instance of a name has been engaged, and
/// a copy number is not part of an identity. Only DIGITS are stripped — a parenthesized WORD is part
/// of the name (the instance tiers, "(Awakened)" and friends).
///
/// It does NOT strip the leading article: "a giant rat" and "giant rat" are different wiki pages and
/// the log always prints the article, so keeping it is honest and lossless.
public func mobKey(_ name: String) -> String { mobKeyImpl(name) }

private func mobKeyImpl(_ name: String) -> String {
    // The TS chain in its own order: trim, strip the copy number, lowercase, fold the quotes,
    // collapse whitespace runs. Lowercasing before the quote fold is free and is kept in place.
    let a = mobKeyCopy.replaceFirst(JS.trim(name), with: "")
    let b = a.lowercased()
    let c = mobKeyQuote.replaceAll(b, with: "'")
    return mobKeySpaces.replaceAll(c, with: " ")
}

/// Pick the display name to keep for a mob seen under two casings.
///
/// A lowercase-initial spelling is the mob's true name ("a zol ghoul knight"); a sentence-start
/// capital is an artifact of the line it appeared in, and a consider line always sentence-cases the
/// leading article. So a lowercase spelling wins, and otherwise the first one seen is kept.
private func adoptDisplay(_ current: String?, _ incoming: String) -> String {
    guard let current else { return incoming }
    if current == incoming { return current }
    // ASCII, as the JS `/^[a-z]/` spells it.
    func lowerInitial(_ s: String) -> Bool {
        guard let u = s.unicodeScalars.first else { return false }
        return u.value >= 97 && u.value <= 122
    }
    return (lowerInitial(incoming) || !lowerInitial(current)) ? incoming : current
}

/// Rust's `str::cmp` is byte-wise over UTF-8; Swift's `<` is not. Ordering is a claim in an answer.
private func considerLexLess(_ a: String, _ b: String) -> Bool {
    var x = a.utf8.makeIterator(), y = b.utf8.makeIterator()
    while true {
        switch (x.next(), y.next()) {
        case (nil, nil): return false
        case (nil, _): return true
        case (_, nil): return false
        case (let p?, let q?): if p != q { return p < q }
        }
    }
}

/// Every optional field is omitted rather than null because the shape it is checked against was
/// recorded through `JSON.stringify`, which DROPS an `undefined`: a row conned before any zone line
/// carries no `zone` at all.
private struct ConsiderRow {
    var id: String
    var mob: String
    var ts: Int64
    var rare: Bool
    var level: Int64?
    var faction: String
    var difficulty: String
    var zone: String?
    var cons: Int64
    /// The mob's drop knowledge, once a lookup has answered for it. ABSENT until then, and absent for
    /// the whole of every historical fold — never an empty record meaning "we checked".
    ///
    /// Enrichment is per-MOB rather than per-con: a re-con keeps whatever was already learned.
    var knowledge: JSONValue?

    var json: JSONValue {
        var o: [String: JSONValue] = [
            "id": .string(id), "mob": .string(mob), "ts": .int(ts), "rare": .bool(rare),
            "faction": .string(faction), "difficulty": .string(difficulty), "cons": .int(cons)
        ]
        if let level { o["level"] = .int(level) }
        if let zone { o["zone"] = .string(zone) }
        if let knowledge { o["knowledge"] = knowledge }
        return .object(o)
    }
}

/// The own-loot index: the note, the reset, and the read the mob knowledge join is built on.
///
/// Published in no snapshot — what it accumulates reaches a client through `knowledge.mob`'s
/// `dropsSeen`, a join made on demand rather than module state. Its refusals are the load-bearing
/// part: a destroy that reached this index would become a documented-looking drop on a mob card.
final class OwnLootIndex: OwnLoot {
    /// mob key → LOWERCASED item key → (display spelling, count, newest ts).
    ///
    /// The display spelling kept is the first one recorded for that key. Insertion order is not
    /// published — see `dropsAcross` for the tiebreak that makes the read total without it.
    private var byMob: [String: [String: (String, Int64, Int64)]] = [:]

    func reset() { byMob.removeAll() }

    /// A row with NO SOURCE is refused, which is what makes every drop-rate surface built on this
    /// index structurally immune to the destroy line. An EMPTY item is refused too: a nameless row is
    /// not a drop.
    func note(_ item: String, _ source: String?, _ ts: Int64, _ count: Int64) {
        guard let source else { return }
        let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return }
        let key = trimmed.lowercased()
        var items = byMob[mobKeyImpl(source)] ?? [:]
        var entry = items[key] ?? (trimmed, 0, 0)
        entry.1 += count
        entry.2 = max(entry.2, ts)
        items[key] = entry
        byMob[mobKeyImpl(source)] = items
    }

    /// The read side, for the knowledge join.
    ///
    /// Most-looted first, ties broken by recency, over the union of every spelling one creature
    /// answers to. Counts ADD and `lastTs` takes the later, because two spellings of one corpse's
    /// owner are one mob's history.
    ///
    /// A single spelling is not a special case here, unlike the TS, which short-circuits: the merge
    /// below IS that path for one key.
    func dropsAcross(_ spellings: [String]) -> [SeenDrop] {
        var merged: [String: SeenDrop] = [:]
        for spelling in spellings {
            guard let items = byMob[mobKeyImpl(spelling)] else { continue }
            for (key, entry) in items {
                var row = merged[key] ?? SeenDrop(item: entry.0, count: 0, lastTs: 0)
                row.count += entry.1
                row.lastTs = max(row.lastTs, entry.2)
                merged[key] = row
            }
        }
        // Count, then recency, then BY NAME. The TS sort falls back to a `Map`'s insertion order,
        // which `byMob` does not have — so the third term is what makes this answer the same answer
        // twice.
        return merged.values.sorted { a, b in
            if a.count != b.count { return a.count > b.count }
            if a.lastTs != b.lastTs { return a.lastTs > b.lastTs }
            return considerLexLess(a.item, b.item)
        }
    }
}

public final class ConsiderModule: EqModule {
    public let id = "consider"

    /// Newest LAST (the UI reverses it), one entry per mob key. A linear scan is `indexOf`'s own cost
    /// and the ring is capped at fifty.
    private var ring: [ConsiderRow] = []
    private var zone: String?
    private var seq: Int64 = 0
    /// The live cons folded since the last drain, in fold order, waiting for the ingest. Empty for a
    /// historical fold by construction — see `onEvent`'s gate.
    private var cons: [ConEvent] = []
    /// The own-loot index's accumulation, kept because this module owns its lifetime. Published
    /// nowhere, read through `asOwnLoot`.
    private let ownLoot = OwnLootIndex()
    /// `deps.lookupMob`, or nil in every construction but the production one.
    private var knowledge: Knowledge?
    /// The first live tick has run ⇒ the historical replay is over.
    private var backfilled = false
    /// The announce cursor. `ring` is the whole snapshot: the own-loot index is published nowhere and
    /// `zone` is the label the NEXT row will carry. So every `loot` line this module folds — most of
    /// what it sees on a farming session — changes real state that no client can read, and says
    /// nothing.
    ///
    /// The backfill announces too: `onTick`'s first beat rewrites published rows with no event behind
    /// it, and `probe` bumps per row it actually fills, so an empty backfill is silent.
    private var announce = Announce()

    public init() {}

    /// The live cons this module saw since the last drain. See `ConEvent`.
    public func takeCons() -> [ConEvent] {
        let out = cons
        cons = []
        return out
    }

    /// The change signal: the last event folded. Coarse — this module keeps no revision counter — but
    /// it never misses a change to the ring.
    public func revision() -> Int64 { seq }

    /// Ask the knowledge lookup about one row.
    ///
    /// Two refusals: no lookup installed (every construction but the production one), and a row that
    /// already carries knowledge (enrichment is per-MOB, so a re-con keeps what was learned). The
    /// TS's third — a row that fell off the ring — cannot happen without an await.
    ///
    /// It asks with the row's DISPLAY name, because the alias boundary lives inside the lookup and
    /// the display name is what the log said.
    private func probe(_ index: Int) {
        guard let knowledge else { return }
        guard index >= 0, index < ring.count else { return }
        if ring[index].knowledge != nil { return }
        let answer = knowledge.mob(ring[index].mob, loot: ownLoot)
        guard index < ring.count else { return }
        ring[index].knowledge = answer.record
        announce.changed(seq)
    }

    /// Fold ONE `consider` line into the ring: upsert the mob's single row (moving it to the front and
    /// bumping `cons`), then evict past the cap.
    private func foldConsider(_ ev: Event, _ live: Bool) {
        let mob = ev.str(.mob) ?? ""
        let id = mobKeyImpl(mob)
        if id.isEmpty { return }
        let prev = ring.firstIndex { $0.id == id }
        let display: String, consCount: Int64, held: JSONValue?
        if let i = prev {
            display = adoptDisplay(ring[i].mob, mob)
            consCount = ring[i].cons + 1
            held = ring[i].knowledge
        } else {
            display = adoptDisplay(nil, mob)
            consCount = 1
            held = nil
        }
        let row = ConsiderRow(id: id, mob: display, ts: ev.ts, rare: ev.bool(.rare), level: ev.int(.level),
                              faction: ev.str(.faction) ?? "", difficulty: ev.str(.difficulty) ?? "",
                              zone: zone, cons: consCount,
                              // Enrichment is per-MOB, not per-con: a re-con keeps what was learned.
                              knowledge: held)
        if let i = prev { ring.remove(at: i) }
        ring.append(row)
        while ring.count > considerCap { ring.removeFirst() }
        announce.changed(seq)
        // Live cons enrich immediately; historical ones wait for the bounded backfill on the first
        // tick, so a startup replay of a month of logs never walks the corpus once per con.
        if live { probe(ring.count - 1) }
    }

    // MARK: - EqModule

    public func reset() {
        ring.removeAll()
        zone = nil
        seq = 0
        announce.reset()
        ownLoot.reset()
        // A card for the world that just ended is not a card: anything undrained when a rebirth or
        // switch landed describes a creature nobody is looking at any more.
        cons.removeAll()
        // A character (re)load is a new replay, so the tick that follows is the new replay's "the
        // history is over" edge. The LOOKUP is not cleared: it is a handle on committed data, not on
        // this character's world.
        backfilled = false
    }

    /// `live` decides two different things: it keeps the knowledge PROBE off the replay path, and it
    /// keeps the CON CARD off it — a card is a thing that happens, and a historical line never draws
    /// one.
    public func onEvent(_ ev: Event, live: Bool) {
        seq = ev.seq
        switch ev.kind {
        // Character rebirth: everything before the boundary belongs to a dead same-name character,
        // the loot history included, which would otherwise credit this character with drops it never
        // saw. The ZONE is not cleared: the character has not moved.
        case "epoch":
            ring.removeAll()
            ownLoot.reset()
            announce.changed(seq)
        // Neither of the next two publishes anything: `zone` is the label the next row carries, and
        // the own-loot index appears in no snapshot.
        case "zone":
            zone = ev.str(.zone)
        case "loot":
            // `You successfully destroyed 38 Bone Chips.` rides the loot lane and names no mob, and
            // this index answers "what has this MOB handed me". Refused at the decision.
            if ev.str(.disposition) == "destroyed" { return }
            // Stacked loots add their COUNT, not 1.
            ownLoot.note(ev.str(.item) ?? "", ev.str(.source), ev.ts, ev.int(.count) ?? 1)
        case "consider":
            foldConsider(ev, live)
            // Beside the fold rather than inside it, because the two answer different questions:
            // `foldConsider` maintains a state, and this is a thing that happened.
            if live {
                cons.append(ConEvent(ts: ev.ts, mob: ev.str(.mob) ?? "", level: ev.int(.level),
                                     rare: ev.bool(.rare), zone: zone))
            }
        default: break
        }
    }

    /// The dirty bit: a con that reached the ring, a backfill that enriched a row, or a rebirth.
    public var publishedSeq: Int64? { announce.cursor }

    /// The first live tick is "the historical replay is over". A historical fold never reaches here,
    /// so `knowledge` stays absent from every row it produced. `nowMs` is unused deliberately: this is
    /// an EDGE, not a clock reading.
    public func onTick(nowMs: Int64, timerRows: [BuffTimerRow]) {
        if backfilled { return }
        backfilled = true
        let from = max(0, ring.count - considerBackfill)
        for index in from..<ring.count { probe(index) }
    }

    public func snapshot() -> JSONValue { ["seq": .int(seq), "state": .array(ring.map(\.json))] }

    public var asOwnLoot: OwnLoot? { ownLoot }

    public func installKnowledge(_ k: Knowledge) { knowledge = k }

    /// The one spelling rule this engine has, reachable where the Rust says
    /// `fold::modules::consider::mob_key`.
    public static func mobKey(_ name: String) -> String { mobKeyImpl(name) }
}
