// The op table: every client message answered. Port of engined/src/ops.rs.
//
// No game logic lives here, and none may be added. Dispatch is a pure function of
// (world, session, message) that returns messages rather than writing them, so the whole table is
// testable with no transport in the room.
//
// The Rust reads its frames through generated types; this port has no codegen, so the two jobs that
// serde did there are done explicitly here: `knownOps` decides whether an op exists at all, and
// `paramShape` states each op's params as a shape a frame either matches or does not. A frame that
// names an op nobody implements is `unknownOp`; a frame whose params are the wrong shape is
// `badParams`, in the same two sentences the Rust's `refuse` writes. Both checks happen before any
// arm runs, exactly as a failed deserialize does over the socket.
import Foundation
import EQCompanionCore
import EQFold
import EQKnowledge
import EQLog

// The op table asks the World for everything — the fold, the subscriptions, the corpus, the client
// spell table, the pushed log directory — and reaches past it for nothing.

// MARK: - The session and its outcome

/// One connection's own state — everything that belongs to this conversation rather than to the
/// world.
///
/// Subscriptions live in the world, not here. Request ids are client-chosen, so the world keys them
/// by (listener, id) and one client can never unsubscribe another's stream; and a landing fold must
/// reset every subscription on every connection, which a set held out here would hide. This session
/// is the membership receipt and nothing else.
public final class Session {
    /// This connection's membership of the world.
    public let listener: ListenerId
    public init(listener: ListenerId) { self.listener = listener }
}

/// What a dispatched message produced.
public enum Outcome {
    /// Engine messages to send to THIS connection, in the order given.
    case send([JSONValue])
    /// The connection must end. The string is a diagnostic, never sent to the peer: there is no
    /// request id to hang an error on.
    case close(String)
}

/// The wire's error codes.
public enum ErrorCode: String, Sendable {
    case protocolMismatch, unauthorized, unknownOp, badParams, notFound, unavailable, `internal`, timeout
}

// MARK: - The table

public enum Ops {
    /// How many creatures one `resist.levels` may name — the schema's `maxItems`, restated where it
    /// is enforced. A bound on a stranger's request, not a tuned number.
    public static let maxMobLevelAsks = 32

    /// Spell → classes for `combat.laneClasses`, built once from the shared spell DB on first ask.
    static let spellClasses: SpellClassIndex = spellClassIndex(SpellDb.shared())
    /// Spell → the level each class gets it at, for the same op.
    static let spellClassLevels: SpellClassLevelIndex = spellClassLevelIndex(SpellDb.shared())

    /// The most hits this engine will rank, whoever asks.
    static let maxFightHits: Int64 = 500

    /// The hits a request that named no limit gets. The UI shows a ranked list, not a page of 1,400.
    static let defaultFightHits: Int64 = 50

    /// The longest op string this engine will quote back in an error message.
    ///
    /// A refusal is a diagnostic and a diagnostic gets pasted into bug reports, so a hostile peer
    /// must not be able to choose a megabyte of it.
    static let maxQuotedOp = 64

    /// The app's own default for an absent `maxSegments`.
    static let defaultMaxSegments: Int64 = 100

    // MARK: Dispatch

    /// Answer one client request. Classification comes first, exactly as a failed deserialize does
    /// over the socket: an op nobody implements is `unknownOp` and never reaches an arm, and params
    /// of the wrong shape are `badParams`.
    public static func dispatch(_ world: World, _ session: Session,
                                id: Int64, op: String, params: JSONValue) -> Outcome {
        // A hello ends the conversation: it carries no request id, so it is the one message that
        // cannot be answered with an error, and a peer that handshakes on an in-process link has a
        // state machine that disagrees with this one's.
        if op == "hello" {
            return .close("a hello arrived on a connection that has no handshake")
        }
        let quoted = quote(String(op.prefix(maxQuotedOp)))
        guard let shape = paramShape(op) else {
            return error(id, .unknownOp, "this engine has no op named \(quoted)")
        }
        // Absent params are the empty object, which is what `NoParams` deserializes from.
        let params = params.isNull ? JSONValue.object([:]) : params
        guard matches(params, shape) else {
            return error(id, .badParams,
                         "the params of \(quoted) are not the shape this protocol version states")
        }
        return answer(world, session, id: id, op: op, params: params)
    }

    private static func answer(_ world: World, _ session: Session,
                               id: Int64, op: String, params: JSONValue) -> Outcome {
        switch op {

        // Echo proves the envelope, the framing and the reply correlation all work before a single
        // log byte exists.
        case "echo":
            return reply(id, ["text": params["text"]])

        case "session.health":
            return reply(id, world.health().json)

        // Attach bumps the generation, announces it, and starts an ingest over the named log: scan
        // at full speed, then tail live.
        case "session.attach":
            return reply(id, world.attach(params["logPath"].string ?? "",
                                          stateDir: params["stateDir"].string).json)

        // Progress IS a subscription — to the connection-wide progress channel — so it is
        // acknowledged with a `SubscribeAck`. Its frames are epoch messages carrying `progress`,
        // not a stream kind of their own, and they are connection-wide: an attach on another
        // connection is heard here too.
        case "session.progress":
            return reply(id, subscribeAck(id, subscribed: true))

        // The answer is the ingest thread's, fetched through the one door; the wait is bounded and
        // owned by the world, so this stays a pure function.
        //
        // Three outcomes: a module the registry does not carry is `notFound`, since an empty state
        // would be a lie about a module that does not exist. A world with no fold is `unavailable`
        // — nothing is wrong with the request — and `notFound` there would send a client hunting
        // for a typo in a perfectly good name.
        case "module.snapshot":
            let module = params["module"].string ?? ""
            switch world.moduleSnapshot(module) {
            case .snapshot(let snapshot):
                return reply(id, ["module": .string(module),
                                  "seq": .int(snapshot.seq),
                                  "state": snapshot.state])
            case .notFound:
                return error(id, .notFound, "this engine folds no module named \(quote(module))")
            case .unavailable(let why):
                return error(id, .unavailable, why)
            }

        // The one op whose subject is this process rather than the game. Two outcomes, not three:
        // the request names nothing that could be absent, and an engine with nothing attached is
        // idle rather than unavailable. The single refusal is a fold that had a door and did not
        // answer through it.
        case "perf.snapshot":
            switch world.perfSnapshot() {
            case .perf(let result): return reply(id, result.json)
            case .unavailable(let why): return error(id, .unavailable, why)
            }

        // Same outcomes as the arm above, for the same reasons. Two ops rather than one because
        // they have different lifetimes: a budget verdict judges the whole generation and changes
        // rarely, while the timeline moves on every beat.
        case "perf.budgets":
            switch world.perfBudgets() {
            case .perf(let result): return reply(id, result.json)
            case .unavailable(let why): return error(id, .unavailable, why)
            }

        case "perf.timeline":
            switch world.perfTimeline() {
            case .perf(let result): return reply(id, result.json)
            case .unavailable(let why): return error(id, .unavailable, why)
            }

        // Validate the descriptor, acknowledge, then open the stream with a reset: reset-then-diffs
        // is rule 1 of the diff protocol and holds even when the window is empty, so a client can
        // always tell an empty view from a view that never opened.
        //
        // The view registry refuses every bad name in the descriptor BY NAME — an unknown source, a
        // sort term over a field the source does not carry, an over-budget window — because a
        // client that silently gets a window it did not ask for cannot notice.
        //
        // The opening reset is empty even over a live fold: the rows are on the ingest thread, and
        // the full window arrives from the fold at the next boundary it already reaches.
        case "view.subscribe":
            let view: View
            do {
                view = try Views.validate(RawDescriptor(json: params))
            } catch let refusal as ViewError {
                return error(id, ErrorCode(rawValue: refusal.code) ?? .internal, refusal.message)
            } catch let unexpected {
                return error(id, .internal, "\(unexpected)")
            }
            // The registration, the epoch stamp and the empty reset are one act inside the world's
            // lock, so the reset cannot name a superseded epoch nor arrive behind the fold's own.
            world.openSubscription(session.listener, id, view)
            return reply(id, subscribeAck(id, subscribed: true))

        // `notFound` for a subscription this connection does not hold, including one it held a
        // moment ago: `subscribed: false` for a stream that was never open would tell a client its
        // bookkeeping is fine when it is not.
        case "view.unsubscribe":
            let named = params["subscription"].int64 ?? 0
            if world.closeSubscription(session.listener, named) {
                return reply(id, subscribeAck(named, subscribed: false))
            }
            return error(id, .notFound, "no subscription \(named) is open on this connection")

        // The five `*.define` commands: app preferences flow in here and nowhere else. The store
        // stays persistence truth app-side — the engine never reads a settings file — and every
        // preference the fold used to read out of it is pushed on connect and on change.
        //
        // Each is an idempotent full-set replace. The payload is typed per family (that is what
        // `count` is read off), which is why five arms rather than one generic one.
        //
        // No refusal path: a payload that reached here matched the shape, so `applied` is pinned
        // true and the honest failure is a `badParams` up in the classifier.
        case "alerts.define":
            return define(world, id, "alerts", params["defs"], counted: true)

        case "buffTrust.define":
            // Not a list: the family's knowledge is one object, so the ack carries no `count`.
            return define(world, id, "buffTrust", params["trust"], counted: false)

        case "respawn.define":
            return define(world, id, "respawn", params["prefs"], counted: false)

        case "combo.define":
            return define(world, id, "combo", params["corrections"], counted: true)

        case "roster.define":
            return define(world, id, "roster", params["edits"], counted: true)

        // The one command here that can be refused without being wrong, and the refusal is not an
        // error: the frame is well formed, the op exists, the instant is well formed, and the
        // answer is "not now" — the world's own hydrating law wearing the status's clothes. An
        // error would put a routine press in every error log the app collects.
        //
        // The instant is the caller's clock and this arm does not second-guess it: the app applies
        // the same number to its own half of the split.
        case "sessionMarks.add":
            let (accepted, status) = world.sessionMark(params["at"].int64 ?? 0)
            return reply(id, ["accepted": .bool(accepted), "status": .string(status.rawValue)])

        // `confirmed: false` is not an error either, for a narrower reason than the mark's: there is
        // simply nothing to re-base — the row is gone, or nothing has been seen on it since the
        // clock started. Both are what a click that raced a death looks like.
        //
        // No status rides the ack, unlike the mark's: both refusals are about the ROW.
        case "respawn.confirmSighting":
            return reply(id, ["confirmed": .bool(world.confirmSighting(params["rowId"].string ?? ""))])

        // Swift-only: a finished fight's full timeline, rebuilt by folding its stretch of the log
        // (CombatReplay.swift), for a fight whose ring the engine no longer keeps. `notFound` when
        // the stretch replays to no fight starting near `from`.
        case "combat.replay":
            guard let log = world.mark().log else {
                return error(id, .unavailable, "no log is attached")
            }
            guard let tl = CombatReplay.timeline(log: log, startTs: params["from"].int64 ?? 0,
                                                 endTs: params["to"].int64 ?? 0, clock: EQLog.Clock.host(),
                                                 character: Ingest.characterOf(log)) else {
                return error(id, .notFound, "no fight was found in the log at that time")
            }
            return reply(id, ["timeline": tl])

        // Swift-only: which classes can land each combat lane ({lane, category}), in order — the
        // combo module's own spell and skill tables. The Combat tab colours your abilities by class.
        case "combat.laneClasses":
            // `levels`, beside it: the level each class gets the lane's spell at, so the app can credit a
            // spell two of your classes share to the one that has it first.
            let lanes = params["lanes"].array ?? []
            return reply(id, [
                "classes": .array(lanes.map { l in
                    .array(laneClassCandidates(Ops.spellClasses, lane: l["lane"].string ?? "",
                                               category: l["category"].string ?? "").map { .string($0) })
                }),
                "levels": .array(lanes.map { l in
                    .object(laneClassLevels(Ops.spellClassLevels, lane: l["lane"].string ?? "",
                                            category: l["category"].string ?? "").mapValues { .int(Int64($0)) })
                }),
            ])

        // Swift-only: a pet's own side of a fight between two instants — its casts, resists, damage
        // taken, heals and buffs, matched by its name (PetLog.swift).
        case "combat.petLog":
            guard let log = world.mark().log else {
                return error(id, .unavailable, "no log is attached")
            }
            guard let r = PetLog.read(log: log, from: params["from"].int64 ?? 0, to: params["to"].int64 ?? 0,
                                      pet: params["pet"].string ?? "", clock: EQLog.Clock.host(),
                                      character: Ingest.characterOf(log)) else {
                return error(id, .unavailable, "the log could not be read")
            }
            return reply(id, r)

        // Swift-only: the kills, experience, ability points, loot and corpse coin stamped between two
        // instants (FightRewards.swift), for the Combat tab's fight stats. Unattributed: the app
        // knows the pull's mobs and decides which mob earned what.
        case "combat.rewards":
            guard let log = world.mark().log else {
                return error(id, .unavailable, "no log is attached")
            }
            guard let r = FightRewards.read(log: log, from: params["from"].int64 ?? 0, to: params["to"].int64 ?? 0,
                                            clock: EQLog.Clock.host(), character: Ingest.characterOf(log)) else {
                return error(id, .unavailable, "the log could not be read")
            }
            return reply(id, r)

        // Swift-only: the attached log's own fight lines between two instants, read from disk
        // (LogWindow.swift). A finished fight from before this launch has no combat log in memory.
        // No log attached is `unavailable`; a window with no fight lines is an empty list.

        case "log.window":
            guard let log = world.mark().log else {
                return error(id, .unavailable, "no log is attached")
            }
            let limit = Int(Swift.min(Swift.max(params["limit"].int64 ?? 2000, 1), 5000))
            guard let got = LogWindow.read(log: log, from: params["from"].int64 ?? 0, to: params["to"].int64 ?? 0,
                                           limit: limit, clock: EQLog.Clock.host(),
                                           character: Ingest.characterOf(log)) else {
                return error(id, .unavailable, "the log could not be read")
            }
            return reply(id, ["lines": .array(got.lines), "truncated": .bool(got.truncated)])

        // How old is this creature, as the resist fold knows it. It cannot ride the resist module's
        // snapshot: that publishes two integers, and an answer keyed by creature name would mean
        // holding every name anybody ever cons.
        //
        // The bound is refused by name rather than truncated — a caller that believed it asked
        // about forty creatures and was answered about eight has no way to notice. An empty list is
        // refused for the same reason.
        //
        // Two outcomes, no `notFound`: a creature nothing states a level for is a perfectly good
        // question that arrives back as a MISSING ROW. The one refusal is having nobody to ask.
        case "resist.levels":
            let mobs = (params["mobs"].array ?? []).compactMap(\.string)
            if mobs.isEmpty || mobs.count > maxMobLevelAsks {
                return error(id, .badParams,
                             "resist.levels takes between 1 and \(maxMobLevelAsks) names; this "
                             + "request named \(mobs.count)")
            }
            switch world.resistLevels(mobs) {
            case .failure(let why): return error(id, .unavailable, "\(why)")
            case .success(let found):
                let levels: [JSONValue] = found.map { row in
                    let (mob, fact) = row
                    return .object(["mob": .string(mob),
                             "level": .int(fact.level),
                             "lo": .int(fact.lo),
                             "hi": .int(fact.hi),
                             // The fold's string becomes the schema's closed set here rather than
                             // in the fold. A wrong provenance on a right number beats a card that
                             // never draws.
                             "from": .string(fact.from == "con" ? "con" : "catalog")])
                }
                return reply(id, ["levels": .array(levels)])
            }

        // One spell out of the client's own table, beside the install the attach named. It is the
        // only source that states how a spell is RESISTED — the committed wiki scrape knows a
        // spell's messages and neither its resist type nor its resist adjust.
        //
        // No `notFound`: a row that is absent, a missing file and an unreadable file are things a
        // card has to say in different words, so `table` and `path` ride every answer and `spell`
        // rides a hit. The one refusal is having no install to speak of.
        case "resist.spell":
            guard let spells = world.clientSpells() else {
                return error(id, .unavailable, ClientSpells.noInstallSentence)
            }
            return reply(id, spells.resistSpell(name: params["name"].string ?? "").json)

        // The client's spell catalogue, searched by type. A window, never the table: the engine
        // filters, sorts and cuts so the renderer draws the rows in the order they arrive.
        //
        // The one refusal is `resist.spell`'s. Everything else is an answer — a missing table, an
        // unreadable one, a filter that excludes everything — and `spellTable` and `path` ride every
        // reply.
        case "spells.search":
            guard let spells = world.clientSpells() else {
                return error(id, .unavailable, ClientSpells.noInstallSentence)
            }
            let answer = SpellSearch.answer(spells,
                                            text: params["text"].string,
                                            category: params["category"].string,
                                            subcategory: params["subcategory"].string,
                                            classes: (params["classes"].array ?? []).compactMap(\.string),
                                            sort: params["sort"].string == "name" ? .name : .level,
                                            offset: params["offset"].int64,
                                            limit: params["limit"].int64)
            return reply(id, answer.json)

        // The instant is the engine's to choose, not the caller's: only the thread holding the fold
        // knows whether this world has reached its tail. The reply says which it chose.
        case "combat.snapshot":
            switch world.combatSnapshot(combatOpts(params["opts"])) {
            case .unavailable(let why): return error(id, .unavailable, why)
            case .answer(let snapshot):
                // The shape is checked rather than coerced: an empty object on the wire would be
                // indistinguishable from a session with no fights. An engine bug says it is one.
                guard snapshot.state.object != nil else {
                    return error(id, .internal,
                                 "the combat engine published a \(shapeOf(snapshot.state)) where "
                                 + "the protocol states an object")
                }
                return reply(id, ["now": .int(snapshot.now), "snapshot": snapshot.state])
            }

        // A `limit` is clamped rather than refused, and the clamp is here rather than in the fold
        // because it is a payload decision about a wire message.
        case "combat.searchFights":
            switch world.searchFights(params["query"].string ?? "",
                                      clampHits(params["limit"].int64)) {
            case .unavailable(let why): return error(id, .unavailable, why)
            case .answer(let found):
                return reply(id, ["corpus": .int(found.corpus),
                                  "hits": .array(found.hits.map { hit in
                                      // A summary is an object by construction; an empty one is the
                                      // honest floor, and unlike the snapshot above it costs a row
                                      // rather than the whole answer.
                                      .object(["score": .double(hit.score),
                                               "summary": hit.summary.object == nil ? .object([:]) : hit.summary])
                                  })])
            }

        // Four reads and a push, none of which can fail. No `notFound` arm anywhere below, by
        // design: a name no corpus holds is an answer — `found: false` beside every local
        // association the engine could still gather — because a card with a name in it is never
        // nothing to draw.
        //
        // Nor an `unavailable` arm: a corpus question names nothing that could be absent, being
        // committed data in this binary. Only `knowledge.mob` touches the fold, for the own-loot
        // half of its join, which is honestly empty on an engine that folded nothing.
        //
        // A miss is announced after the reply is built: the asker gets its answer, and every
        // connection — including this one — hears the name that could not be answered.
        case "knowledge.item":
            let name = params["name"].string ?? ""
            return knowledgeReply(world, id, "item", name, world.knowledge.item(name))

        case "knowledge.mob":
            let name = params["name"].string ?? ""
            return knowledgeReply(world, id, "mob", name, world.knowledgeMob(name))

        // The one read that announces no miss: the spell catalog has no app-side fetcher, so a name
        // it does not carry is not a question anybody can answer.
        case "knowledge.spell":
            let name = params["name"].string ?? ""
            let answer = world.knowledge.spell(name)
            return reply(id, knowledgeResult(domain: "spell", name: name, answer: answer))

        case "knowledge.search":
            return reply(id, world.knowledge.search(params["query"].string ?? "",
                                                    domain: params["domain"].string,
                                                    limit: params["limit"].int))

        // `applied` is pinned true by the schema, and the shape refuses the impossible: the push
        // domain has two members, so a `spell` push is a `badParams` refusal in the classifier
        // rather than a runtime check here. No `count` — one entry is not a list.
        case "knowledge.define":
            world.knowledge.define(params["domain"].string ?? "",
                                   params["name"].string ?? "",
                                   params["entry"])
            return reply(id, ["applied": .bool(true)])

        // The app names the log directory. It answers the `*.define` ack but is deliberately not one
        // of that family: those five are fold inputs re-applied at every attach and part of the fold
        // cache key, and this changes no fold — so no fold is told anything.
        //
        // No refusal path. A directory that does not exist is not a refusal either: that produces a
        // `logs.list` answering `missing`, which is a separate question on purpose.
        case "logs.setDir":
            world.setLogDir(params["dir"].string ?? "")
            // Not a list: one directory, so the ack carries no `count`.
            return reply(id, ["applied": .bool(true)])

        // Never having been told a directory is `unavailable` rather than an empty answer: an
        // install with no character logs is a real state a player is told how to fix (`/log on`),
        // and a question nobody armed is a bug in the app's connect sequence. A caller handed `[]`
        // for both would draw the empty picker for the second.
        //
        // Every other outcome is an answer: a missing folder, an unreadable one and an empty one all
        // carry `readable` and the directory they are about.
        case "logs.list":
            switch world.listLogs() {
            case .failure(let why): return error(id, .unavailable, "\(why)")
            case .success(let (dir, found)):
                let rows: [JSONValue] = found.characters.map { $0.json }
                return reply(id, ["dir": .string(dir),
                                  "readable": .string(found.readable.rawValue),
                                  "characters": .array(rows)])
            }

        default:
            // Unreachable: `paramShape` answered for this op, so the table above has an arm for it.
            return error(id, .unknownOp, "this engine has no op named \(quote(op))")
        }
    }

    // MARK: Helpers

    /// The limit a search actually gets. Clamped, never refused, unlike a view's `window.limit`: a
    /// search is one answer to one keystroke and the ranking is already truncated, so the smaller
    /// list IS the answer.
    static func clampHits(_ limit: Int64?) -> Int {
        let wanted = limit.map { Swift.min(Swift.max($0, 1), maxFightHits) } ?? defaultFightHits
        return Int(wanted)
    }

    /// The wire's opts in the ingest's vocabulary, with every absence resolved to the app's own
    /// default.
    ///
    /// The defaults are the app's, not zero: a `maxSegments` cap of zero would serve a meter with no
    /// fight list at all to a client that asked for the ordinary thing.
    static func combatOpts(_ opts: JSONValue) -> CombatOpts {
        guard opts.object != nil else {
            return CombatOpts(maxSegments: Int(defaultMaxSegments))
        }
        return CombatOpts(selectedId: opts["selectedId"].string,
                          showUnparsed: opts["showUnparsed"].bool ?? false,
                          maxSegments: Int(Swift.max(opts["maxSegments"].int64 ?? defaultMaxSegments, 0)),
                          timeline: opts["timeline"].bool ?? false,
                          digest: opts["digest"].bool ?? false,
                          targets: opts["targets"].bool ?? false)
    }

    /// What a JSON value IS, for a diagnostic that has to say why an answer was refused.
    static func shapeOf(_ value: JSONValue) -> String {
        switch value {
        case .null: return "null"
        case .bool: return "boolean"
        case .int, .double: return "number"
        case .string: return "string"
        case .array: return "array"
        case .object: return "object"
        }
    }

    /// A record onto the wire's open object. A non-object answer is impossible, and an empty map is
    /// the honest fallback rather than a crash in an op table.
    static func knowledgeResult(domain: String, name: String, answer: KnowledgeAnswer) -> JSONValue {
        .object(["domain": .string(domain),
                 "name": .string(name),
                 "found": .bool(answer.found),
                 "record": answer.record.object == nil ? .object([:]) : answer.record])
    }

    /// The reply for a lookup, plus the announcement a miss owes every connection.
    static func knowledgeReply(_ world: World, _ id: Int64, _ domain: String,
                               _ name: String, _ answer: KnowledgeAnswer) -> Outcome {
        let out = reply(id, knowledgeResult(domain: domain, name: name, answer: answer))
        world.announceKnowledgeMisses(world.knowledge.takeMisses())
        return out
    }

    /// Record one family's push, apply it to the live fold, and acknowledge it.
    ///
    /// `counted` says whether the payload is a list: the number of entries a list carried, and
    /// nothing for a payload that is one object.
    static func define(_ world: World, _ id: Int64, _ family: String,
                       _ payload: JSONValue, counted: Bool) -> Outcome {
        world.define(family, payload)
        var ack: [String: JSONValue] = ["applied": .bool(true)]
        if counted { ack["count"] = .int(Int64(payload.array?.count ?? 0)) }
        return reply(id, .object(ack))
    }

    static func subscribeAck(_ subscription: Int64, subscribed: Bool) -> JSONValue {
        ["subscription": .int(subscription), "subscribed": .bool(subscribed)]
    }

    /// Wrap one result in the reply envelope. The schema pins `ok` to `true`; an unsuccessful answer
    /// is an error message with a different discriminant rather than a flag on this one.
    static func replyFrame(_ id: Int64, _ result: JSONValue) -> JSONValue {
        ["kind": "reply", "id": .int(id), "ok": true, "result": result]
    }

    static func reply(_ id: Int64, _ result: JSONValue) -> Outcome { .send([replyFrame(id, result)]) }

    /// Refuse one request, by its id.
    public static func error(_ id: Int64, _ code: ErrorCode, _ message: String) -> Outcome {
        .send([.object(["kind": .string("error"),
                        "id": .int(id),
                        "ok": .bool(false),
                        "error": .object(["code": .string(code.rawValue),
                                          "message": .string(message)])])])
    }

    /// A string as Rust's `{:?}` writes it — the diagnostics quote op and module names that way, and
    /// the two engines' messages have to be the same bytes.
    static func quote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7f {
                    out += String(format: "\\u{%x}", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}

// MARK: - Classification: is this an op, and are those its params?

extension Ops {
    /// What one field of a params object must be. The Rust gets this from generated types; here it
    /// is stated once per op, from the same schema those types are generated from.
    indirect enum Shape {
        /// A JSON string.
        case string
        /// A JSON integer. Never a float: the engine's decoder refuses `50.0` where an integer is
        /// stated, so a window limit must encode as `50`.
        case integer
        /// An integer or an explicit null (`ComboCorrection.endTs`).
        case nullableInteger
        case boolean
        /// One of a closed set of strings.
        case stringEnum([String])
        /// Any JSON at all — the schema's open cells (`AlertDefinition`, `KnowledgeRecord`).
        case anyValue
        /// An object whose members the schema leaves open.
        case openObject
        /// An object whose values are cells — a string, a number, a boolean or a null, and never a
        /// container. The view filter's own shape.
        case cellMap
        case array(Shape)
        /// An object: required members, optional members, and whether unknown ones are tolerated.
        case object(required: [String: Shape], optional: [String: Shape], open: Bool)
        /// A two-element `[field, "asc"|"desc"]` sort term.
        case sortTerm
    }

    /// Does this value match the shape the contract states?
    static func matches(_ value: JSONValue, _ shape: Shape) -> Bool {
        switch shape {
        case .string: return value.string != nil
        case .integer: if case .int = value { return true }; return false
        case .nullableInteger:
            if case .int = value { return true }
            return value.isNull
        case .boolean: return value.bool != nil
        case .stringEnum(let names): return value.string.map(names.contains) ?? false
        case .anyValue: return true
        case .openObject: return value.object != nil
        case .cellMap:
            guard let members = value.object else { return false }
            return members.values.allSatisfy { cell in
                switch cell {
                case .string, .int, .double, .bool, .null: return true
                case .array, .object: return false
                }
            }
        case .array(let inner):
            guard let items = value.array else { return false }
            return items.allSatisfy { matches($0, inner) }
        case .sortTerm:
            guard let terms = value.array, terms.count == 2 else { return false }
            return matches(terms[0], .string) && matches(terms[1], .stringEnum(["asc", "desc"]))
        case .object(let required, let optional, let open):
            guard let members = value.object else { return false }
            for (key, inner) in required {
                guard let held = members[key], matches(held, inner) else { return false }
            }
            for (key, held) in members where required[key] == nil {
                if let inner = optional[key] {
                    // An explicit null for an optional member is the member absent, which is how
                    // `Option<T>` reads a `null` on the wire.
                    if held.isNull { continue }
                    if !matches(held, inner) { return false }
                } else if !open {
                    return false
                }
            }
            return true
        }
    }

    /// Every op the contract names, with the shape of its params. `nil` is `unknownOp`.
    ///
    /// The names are the schema's `op` constants, which is why `sessionMarks.add` is spelled that
    /// way: a client that sends `session.mark.add` is naming an op this contract does not have, and
    /// gets told so.
    static func paramShape(_ op: String) -> Shape? {
        /// `NoParams` — an empty object, and nothing else in it.
        let none = Shape.object(required: [:], optional: [:], open: false)
        switch op {
        case "echo":
            return .object(required: ["text": .string], optional: [:], open: false)
        case "session.attach":
            return .object(required: ["logPath": .string], optional: ["stateDir": .string], open: false)
        case "session.health", "session.progress", "perf.snapshot", "perf.budgets",
             "perf.timeline", "logs.list":
            return none
        case "module.snapshot":
            return .object(required: ["module": .string], optional: [:], open: false)
        case "view.subscribe":
            return .object(required: ["source": .string],
                           optional: ["filter": .cellMap,
                                      "sort": .array(.sortTerm),
                                      "window": .object(required: ["offset": .integer,
                                                                   "limit": .integer],
                                                        optional: [:], open: false)],
                           open: false)
        case "view.unsubscribe":
            return .object(required: ["subscription": .integer], optional: [:], open: false)
        case "alerts.define":
            return .object(required: ["defs": .array(.openObject)], optional: [:], open: false)
        case "buffTrust.define":
            return .object(required: ["trust": .object(required: ["externals": .array(.string)],
                                                       optional: [:], open: true)],
                           optional: [:], open: false)
        case "respawn.define":
            let watch = Shape.object(required: ["key": .string, "display": .string],
                                     optional: ["customSec": .integer], open: true)
            return .object(required: ["prefs": .object(required: ["watches": .array(watch)],
                                                       optional: [:], open: true)],
                           optional: [:], open: false)
        case "combo.define":
            let correction = Shape.object(required: ["startTs": .integer,
                                                     "endTs": .nullableInteger,
                                                     "classes": .array(.string),
                                                     "setAt": .integer],
                                          optional: [:], open: true)
            return .object(required: ["corrections": .array(correction)], optional: [:], open: false)
        case "roster.define":
            let edit = Shape.object(required: ["key": .string, "name": .string,
                                               "action": .stringEnum(["add", "remove"]),
                                               "setAt": .integer],
                                    optional: [:], open: true)
            return .object(required: ["edits": .array(edit)], optional: [:], open: false)
        case "sessionMarks.add":
            return .object(required: ["at": .integer], optional: [:], open: false)
        case "respawn.confirmSighting":
            return .object(required: ["rowId": .string], optional: [:], open: false)
        case "log.window":
            return .object(required: ["from": .integer, "to": .integer], optional: ["limit": .integer], open: false)
        case "combat.replay":
            return .object(required: ["from": .integer, "to": .integer], optional: [:], open: false)
        case "combat.laneClasses":
            let lane = Shape.object(required: ["lane": .string, "category": .string], optional: [:], open: false)
            return .object(required: ["lanes": .array(lane)], optional: [:], open: false)
        case "combat.petLog":
            return .object(required: ["from": .integer, "to": .integer, "pet": .string], optional: [:], open: false)
        case "combat.rewards":
            return .object(required: ["from": .integer, "to": .integer], optional: [:], open: false)
        case "combat.snapshot":
            let opts = Shape.object(required: [:],
                                    optional: ["selectedId": .string, "showUnparsed": .boolean,
                                               "maxSegments": .integer, "timeline": .boolean,
                                               "digest": .boolean, "targets": .boolean],
                                    open: true)
            return .object(required: [:], optional: ["opts": opts], open: false)
        case "combat.searchFights":
            return .object(required: ["query": .string], optional: ["limit": .integer], open: false)
        case "knowledge.item", "knowledge.mob", "knowledge.spell", "resist.spell":
            return .object(required: ["name": .string], optional: [:], open: false)
        case "knowledge.search":
            return .object(required: ["query": .string],
                           optional: ["domain": .stringEnum(knowledgeDomains),
                                      "limit": .integer],
                           open: false)
        case "knowledge.define":
            return .object(required: ["domain": .stringEnum(knowledgePushDomains),
                                      "name": .string,
                                      "entry": .openObject],
                           optional: [:], open: false)
        case "resist.levels":
            // `minItems`/`maxItems` are NOT checked here: the generated types do not enforce them
            // either, and the bound is refused by name in the arm so the message can say what was
            // asked for.
            return .object(required: ["mobs": .array(.string)], optional: [:], open: false)
        case "spells.search":
            return .object(required: [:],
                           optional: ["text": .string, "category": .string, "subcategory": .string,
                                      "classes": .array(.stringEnum(classAbbrs)),
                                      "sort": .stringEnum(["level", "name"]),
                                      "offset": .integer, "limit": .integer],
                           open: false)
        case "logs.setDir":
            return .object(required: ["dir": .string], optional: [:], open: false)
        default:
            return nil
        }
    }

    /// The four domains a knowledge search may name.
    static let knowledgeDomains = ["item", "mob", "spell", "quest"]

    /// The two domains that have an app-side fetcher, and so can be pushed back.
    static let knowledgePushDomains = ["item", "mob"]

    /// The sixteen class codes, as the wire spells them.
    static let classAbbrs = ["BER", "BRD", "BST", "CLR", "DRU", "ENC", "MAG", "MNK",
                             "NEC", "PAL", "RNG", "ROG", "SHD", "SHM", "WAR", "WIZ"]

    /// Is this one of the ops the contract names?
    public static func isKnownOp(_ op: String) -> Bool { op == "hello" || paramShape(op) != nil }
}
