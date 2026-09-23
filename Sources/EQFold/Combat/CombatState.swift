// The combat engine's mutable state — `fold/src/combat/state.rs`.
//
// Routing, lifecycle and the view builders are plain functions over one explicit state object rather
// than methods on a 1,400-line class. `CombatEngine` owns exactly one of these.
//
// Two flags decide the whole live half. `hydrating` is true from `reset()` until `setLive()` and
// gates the snapshot-time sweep block, because a replay is not a moment in time; `recording` opens
// the classification ring (`EngineState.recent`). A historical fold clears neither, so its `recent`
// is empty and no session mark can enter it.
import Foundation
import EQLog
import EQCompanionCore

/// One half of the combat-modifier pair — the last stance (or invocation) the player committed to,
/// with the ts of that commit. Session-scoped: a stance is not tied to a zone, so it survives every
/// zone line and the epoch boundary alike, and only `reset()` clears it.
public struct Modifier {
    public var name: String
    public var ts: Int64
    public init(name: String, ts: Int64) { self.name = name; self.ts = ts }
}

/// The roster, pulled once per event rather than once per decision — and the two are exactly
/// equivalent, not merely close. The roster module is registered BEFORE the engine, so by the time
/// the engine folds a line the roster has already advanced for it.
public struct RosterFacts {
    /// Keys currently in the roster — the "never a hostile" test.
    public var members: Set<String> = []
    /// Keys admitted since the last epoch or self-leave — the attribution test.
    public var admitted: Set<String> = []
    /// The roster's own spelling for an admitted key, for the meter row's label.
    public var names: [String: String] = [:]

    public init() {}

    static func pull(_ roster: RosterSource?) -> RosterFacts {
        guard let r = roster else { return RosterFacts() }
        let snap = r.snap()
        var f = RosterFacts()
        f.members = Set(r.members())
        f.admitted = Set(r.admitted())
        for m in snap.members { f.names[m.key] = m.name }
        return f
    }
}

/// One line as the engine classified it — `shared/combat.ts ClassifiedLine`, for the live processing
/// log. `cat` and `role` are strings rather than enums: the call sites pass an event's own `dtype`
/// straight through beside this file's own words.
public struct ClassifiedLine {
    public var ts: Int64
    public var cat: String
    /// Who it was attributed to — the four source kinds plus two commentary roles: `info` for a
    /// state transition the engine narrates, `dropped` for a line it deliberately refused.
    public var role: String
    public var text: String

    public init(ts: Int64, cat: String, role: String, text: String) {
        self.ts = ts; self.cat = cat; self.role = role; self.text = text
    }

    public var json: JSONValue {
        ["ts": .int(ts), "cat": .string(cat), "role": .string(role), "text": .string(text)]
    }
}

/// Everything the engine folds into.
public final class EngineState {
    /// Canonical name keys of your live pets — charmed and summoned alike — kept in lockstep with
    /// the world model's pet instances. An ATTRIBUTION set, not a charm roster.
    public var petNames: Set<String> = []
    public var world = WorldModel()
    /// Ownership for the two caster-less broadcasts. Nothing enters `petNames` from a charm line
    /// unless this model says the broadcast resolved one of the owner's casts.
    public var charm = CharmModel()
    /// Ownership for somebody else's charm pet, strictly disjoint from your rows.
    public var ally = AllyCharms()
    /// Every other combatant the log names — the refusal ladder. The weakest model here, asked last.
    public var others = OtherCombatants()
    /// Canonical name keys of entities known to be PLAYERS — never hostiles, never a pet's target.
    public var knownPlayers: Set<String> = []
    /// Every name key that has ever been one of your pets this session. Small, never pruned.
    public var everPet: Set<String> = []
    /// Every name key you have landed damage on this session — the third absolute refusal.
    public var everStruck: Set<String> = []
    public var playerKey: String?
    public var playerKeyInjected = false

    public var zone: String?
    public var seq: UInt64 = 0
    public var current: Encounter?
    public var history: [Encounter] = []
    public var zoneAgg = Agg()
    public var zoneFinalizedMs: Int64 = 0
    public var zoneActiveMs: Int64 = 0
    /// First/last attributed-damage ts in the LIVE zone session (0 = none yet).
    public var zoneStartTs: Int64 = 0
    public var zoneLastTs: Int64 = 0
    public var zoneHistory: [ZoneSession] = []
    public var zoneSeq: UInt64 = 0

    /// True from `reset()` until `setLive()`; gates the snapshot-time sweeps.
    public var hydrating = true
    /// True from `setLive()`; gates the classification ring.
    public var recording = false
    /// The classification ring — newest last, capped drop-oldest at `RECENT_CAP`.
    public var recent: [ClassifiedLine] = []
    /// ts of the last encounter-relevant activity (attributed damage OR a CC event).
    public var lastActivityTs: Int64 = 0

    public var stance: Modifier?
    public var invocation: Modifier?
    public var specials = SpecialAttacks()

    /// Rolling time-to-slow samples, newest last, capped at `SLOW_SAMPLE_CAP`. One entry per
    /// finalized pull that opened with a slow-capable coat on: the ms to the first slow landing, or
    /// `nil` when the pull ended without one. The nils are counted, never averaged in as zero.
    public var slowSamples: [Int64?] = []

    /// Blade coats, four concurrent because that is what the game has. Session-scoped like the
    /// stance pair. Never assign these two anywhere but `routeCoat` / `routeDry` / `clearCoats`.
    public var coatUtility: CoatSlot?
    public var coatCombat: [CoatSlot] = []
    /// Log-clock ts of the last combo consultation (0 = never) — the throttle half of the class-swap
    /// coat clear. This fold installs no combo provider, so the consultation never happens.
    public var coatClassCheckedTs: Int64 = 0
    /// The active-state timeline — "what was on at time T". Session-level and purely additive.
    public var stateTimeline = StateTimeline()
    /// Rank-normalized own-casts, for the cast-less proc detector.
    public var recentCasts = RecentCasts()
    /// Which spells this character owns an instant clicky for. Empty without the inventory dump, and
    /// then `castlessKind` is the identity function so no lane name moves.
    public var heldClickies: Set<String> = []
    /// The one-sentence nudge for an unbound summoned pet. Armed only when live.
    public var petNudge = PetNudgeState()
    /// ts of the last `You activate Quick Buff.` (0 = never).
    public var quickBuffTs: Int64 = 0

    /// See `RosterFacts`. Refreshed once per ingested event and once per snapshot.
    public var roster = RosterFacts()

    public init() {}

    /// Append a point annotation to an encounter's marker ring, drop-oldest at `MARKER_CAP`.
    /// Draw-only: no count, DPS or attribution ever reads this.
    public static func pushMarker(_ enc: Encounter, _ m: MarkerRaw) {
        enc.markers.append(m)
        if enc.markers.count > MARKER_CAP { enc.markers.removeFirst() }
    }

    /// Append one instant to an encounter's timeline ring, capped drop-oldest at `TIMELINE_CAP`.
    /// `eventsTotal` counts every push, so a fight that outgrows the cap still knows its true instant
    /// count and the view can declare the loss rather than report the ring length as the fight.
    public static func pushTimeline(_ enc: Encounter, _ rec: TimelineRaw) {
        enc.events.append(rec)
        enc.eventsTotal += 1
        if enc.events.count > TIMELINE_CAP { enc.events.removeFirst() }
    }

    /// A reset always precedes a fresh full-log scan, so the engine is hydrating again until that
    /// scan hands off to a tail.
    public func reset() {
        let injected = playerKeyInjected ? playerKey : nil
        petNames = []
        world = WorldModel()
        charm = CharmModel()
        ally = AllyCharms()
        others = OtherCombatants()
        knownPlayers = []
        everPet = []
        everStruck = []
        playerKey = nil
        playerKeyInjected = false
        zone = nil
        seq = 0
        current = nil
        history = []
        zoneAgg = Agg()
        zoneFinalizedMs = 0
        zoneActiveMs = 0
        zoneStartTs = 0
        zoneLastTs = 0
        zoneHistory = []
        zoneSeq = 0
        hydrating = true
        recording = false
        recent = []
        lastActivityTs = 0
        stance = nil
        invocation = nil
        specials = SpecialAttacks()
        slowSamples = []
        coatUtility = nil
        coatCombat = []
        coatClassCheckedTs = 0
        stateTimeline = StateTimeline()
        recentCasts = RecentCasts()
        heldClickies = []
        petNudge = PetNudgeState()
        quickBuffTs = 0
        roster = RosterFacts()
        // `setPlayerName` is called after `reset()` by every construction path, so this only matters
        // for a reset that arrives later, where the name is still this character's.
        if let name = injected {
            playerKey = name
            playerKeyInjected = true
            knownPlayers.insert(name)
        }
    }

    /// The handover from the scan to the tail — the whole difference between a replay and a present
    /// moment. `hydrating` false opens the snapshot-time sweep block; `recording` true opens the
    /// classification ring. Idempotent, and it has to be: `hydrating` is a latch.
    public func setLive() {
        recording = true
        hydrating = false
    }

    /// Inject the player's own character name, keyed canonically. Wins over any heal-learned name.
    public func setPlayerName(_ name: String) {
        let key = Names.idKey(name)
        knownPlayers.insert(key)
        playerKey = key
        playerKeyInjected = true
    }

    /// Refresh the per-event roster snapshot. Once per event is exactly the live pull.
    public func refreshRoster(_ roster: RosterSource?) {
        self.roster = RosterFacts.pull(roster)
    }

    /// The roster as the SNAPSHOT serializes it. A pull, never a stored copy.
    public func rosterSnap(_ roster: RosterSource?) -> RosterSnap {
        roster.map { $0.snap() } ?? RosterSnap.empty
    }

    /// Drain the world model's retirement announcements, immediately after every world call that can
    /// retire. A retired instance cannot redeem its CC hold: the hold claims a mez'd mob is still
    /// alive, and once retired that claim is false forever.
    public func drainRetirements() {
        if world.retiredIds.isEmpty { return }
        let ids = world.retiredIds
        world.retiredIds = []
        guard let enc = current else { return }
        for id in ids { _ = enc.ccActiveUntil.remove(id) }
    }

    /// `world.resolve` with the retirement queue drained — the one door every routing path uses.
    public func resolve(_ name: String, _ ts: Int64, _ preferCharmed: Bool) -> Resolved {
        let r = world.resolve(name, ts, preferCharmed)
        drainRetirements()
        return r
    }

    /// True when `nameKey` is a player (the owner, or someone the heal stream tied to them).
    public func isKnownPlayer(_ nameKey: String) -> Bool {
        nameKey == "you" || knownPlayers.contains(nameKey)
    }

    /// True when `nameKey` is on the roster right now — the "never a hostile" test. The live roster
    /// rather than `admitted`: someone who left your group and is now duelling you is not protected.
    public func isMember(_ nameKey: String) -> Bool { roster.members.contains(nameKey) }

    /// True when `nameKey` is someone the engine may book outgoing damage for as a group member —
    /// the deliberately wider `admitted` set.
    public func isAdmittedMember(_ nameKey: String) -> Bool {
        if nameKey == "you" { return false }
        // A pet is never a member, the same absolute guard `notePlayer` uses.
        if petNames.contains(nameKey) || everPet.contains(nameKey) { return false }
        return roster.admitted.contains(nameKey)
    }

    /// True if `nameKey` currently resolves to an engaged hostile instance.
    public func isEngagedHostile(_ nameKey: String) -> Bool {
        guard let enc = current else { return false }
        return enc.engaged.contains { nameKeyOf($0) == nameKey }
    }

    /// The in-progress encounter, but only while it is fresh — so a non-damage event attaches to the
    /// fight it belongs to without reviving a stale one, and without ever opening one.
    public func freshEncounterId(_ ts: Int64) -> Bool {
        guard let e = current else { return false }
        return ts - e.lastTs <= FALLBACK_IDLE_MS
    }

    /// The fresh in-progress encounter. `nil` both when nothing is open and when what is open is
    /// stale.
    public func freshEncounter(_ ts: Int64) -> Encounter? {
        guard let e = current, ts - e.lastTs <= FALLBACK_IDLE_MS else { return nil }
        return e
    }

    /// Record player-shaped evidence for a name.
    ///
    /// A pet is never a player, and the guard is absolute. Something you have been killing is never a
    /// player either — your own lifetap names the DRAINED MOB as the healer. The signal is your own
    /// SWING: being hit happens to you; hitting is something you do, and only the second names a mob.
    public func notePlayer(_ nameKey: String?) {
        guard let nameKey else { return }
        if nameKey.isEmpty || nameKey == "you" { return }
        if everPet.contains(nameKey) || charm.everCharmed(nameKey) { return }
        if everStruck.contains(nameKey) { return }
        knownPlayers.insert(nameKey)
        // …and a heal landing on you outranks a swing at you, so it also un-marks the
        // record-everything ladder's hostile flag.
        others.clearHostile(nameKey)
    }

    /// Record that YOU landed damage on `nameKey` — the only writer of `everStruck`. Your pet's
    /// swings are deliberately not evidence.
    public func noteStruck(_ nameKey: String) {
        if nameKey.isEmpty || nameKey == "you" { return }
        everStruck.insert(nameKey)
    }

    /// Bind `nameKey` into the attribution set. The one door, so "was this ever a pet?" has a single
    /// answer and a player can never shadow one.
    public func notePet(_ nameKey: String) {
        petNames.insert(nameKey)
        everPet.insert(nameKey)
        knownPlayers.remove(nameKey)
        retractOther(nameKey, "bound as your pet")
    }

    /// A stronger model has claimed a name — take back the row the record-everything ladder booked
    /// for it, so a pet that swung before its binding line arrived ends up with ONE row.
    ///
    /// A roster member is never retracted: their row is the roster's, not this ladder's. It reaches
    /// the live aggregates — the open fight, the finalized fights still in history (whose memoized
    /// summary is dropped so it re-derives) and the live zone session.
    public func retractOther(_ nameKey: String, _ why: String) {
        if nameKey.isEmpty || roster.admitted.contains(nameKey) { return }
        if !others.notePet(nameKey) { return }
        if !others.isRecorded(nameKey) { return }
        others.forget(nameKey)
        let id = "member:\(nameKey)"
        _ = zoneAgg.dropOut(id)
        if let enc = current, enc.agg.dropOut(id) { enc.summary = nil }
        for enc in history where enc.agg.dropOut(id) { enc.summary = nil }
        // The last activity ts, not a clock: a retraction is triggered by a line the engine folded.
        let ts = lastActivityTs
        log(ts, "charm", "dropped", "✕ \(nameKey): \(why) - its recorded row is now the pet's")
    }

    /// Re-index `petNames` off the world model's live pets, and report the name keys that fell out.
    /// `everPet` is untouched: a retired pet is still a pet, never a candidate player.
    public func syncPetNames() -> [String] {
        let live = Set(world.petNameKeys())
        let dropped = petNames.filter { !live.contains($0) }.sorted()
        for key in dropped { petNames.remove(key) }
        return dropped
    }

    /// Demote the charm binds whose corroboration window has closed. Driven by the LOG clock, so a
    /// replay and a live tail demote at exactly the same instants.
    public func sweepCharm(_ now: Int64) {
        if charm.idle() { return }
        for d in charm.sweep(now) {
            world.uncharm(d.display, now)
            drainRetirements()
            petNames.remove(d.nameKey)
            log(now, "charm", "dropped", "✕ \(d.display): charm bind never corroborated - unbound")
        }
    }

    /// End the ally binds whose charm can no longer be running. Same clock, same two callers.
    public func sweepAlly(_ now: Int64) {
        if ally.idle() { return }
        for e in ally.sweep(now) {
            log(now, "charm", "dropped",
                "✕ \(e.display): \(e.charmer)'s charm has run its full duration - unbound")
        }
    }

    /// May `nameKey` be a third-party charmer? The behavioural half of the caster gate; the name
    /// shape answers the other half. The three refusals are the same absolute guards `notePlayer`
    /// wears.
    public func allyCasterAllowed(_ nameKey: String) -> Bool {
        if nameKey.isEmpty || nameKey == "you" || nameKey == playerKey { return false }
        if petNames.contains(nameKey) || everPet.contains(nameKey) { return false }
        if everStruck.contains(nameKey) || charm.everCharmed(nameKey) { return false }
        return true
    }

    /// Is `nameKey` on the friendly side of an ally charm? Five sources, widest first: you, your own
    /// live pets, the group roster, anyone the heal stream proved a player, and the ally model's own
    /// caster/charmer set.
    public func allyFriendly(_ nameKey: String) -> Bool {
        if nameKey.isEmpty || nameKey == "you" { return true }
        if petNames.contains(nameKey) { return true }
        if isKnownPlayer(nameKey) || isMember(nameKey) { return true }
        return ally.isFriendly(nameKey)
    }

    /// Learn the player's proper name as a FALLBACK only (an injected name wins): `You healed
    /// <Player>` where the target is not a pet and not an engaged hostile → that name IS the player.
    /// EQ never writes literal "You" as a heal target; it uses the character name.
    public func learnPlayerKey(_ healerKey: String?, _ tKey: String, _ isYouTgt: Bool, _ isPetTgt: Bool) {
        if !playerKeyInjected && healerKey == "you" && !isYouTgt && !isPetTgt
            && !isEngagedHostile(tKey) && playerKey == nil {
            playerKey = tKey
        }
        if let k = playerKey { knownPlayers.insert(k) }
    }

    /// Presence refresh — record that `name` is still in the current fight as of `ts`. The LIVENESS
    /// axis only: it moves nothing on the damage timeline.
    ///
    /// Conservative in both directions: it never engages anything and it never resolves or creates a
    /// world instance, matching engaged ids by name prefix instead.
    public func notePresence(_ name: String, _ ts: Int64) {
        if current == nil { return }
        let key = Names.idKey(name)
        if isKnownPlayer(key) { return }
        // …and a group member is never a hostile either.
        if isMember(key) { return }
        // Keep the world's per-instance clock in lockstep with the encounter's presence axis.
        world.noteSeen(key, ts)
        drainRetirements()
        guard let enc = current else { return }
        let ids = enc.engaged.filter { nameKeyOf($0) == key }
        for id in ids { notePresenceId(id, ts) }
    }

    /// Presence refresh for an already-resolved engaged instance id. Two entities can never be
    /// refreshed here: a known player (never a hostile) and a live pet of ours.
    public func notePresenceId(_ instanceId: String, _ ts: Int64) {
        if world.isLivePet(instanceId) { return }
        if let nameKey = nameKeyOf(instanceId) {
            if isKnownPlayer(nameKey) || isMember(nameKey) { return }
        }
        guard let enc = current else { return }
        if !enc.engaged.contains(instanceId) { return }
        let prev = enc.engagedSeen[instanceId]
        if prev == nil || ts > prev! { enc.engagedSeen.insert(instanceId, ts) }
    }

    /// Instance-resolved defender label for a damage-free instant (miss / resist), so twins read as
    /// `a deadly black widow (7)` rather than piling onto a bare-named ghost row.
    ///
    /// It is NOT a pure read, which is why callers make it even when they discard the label: the
    /// `resolve()` inside refreshes `lastSeenTs`, retires stale instances, and adopts the sighting's
    /// casing as the instance display.
    public func defenderLabel(_ name: String, _ ts: Int64) -> String {
        let key = Names.idKey(name)
        if key == "you" { return "You" }
        let engaged = current?.engaged.contains { nameKeyOf($0) == key } ?? false
        return engaged ? resolve(name, ts, false).label : name
    }

    /// Append one classified line — the whole of the classification ring. The `recording` gate lives
    /// INSIDE this method rather than at its forty call sites, which is what makes "a replay writes
    /// nothing" a structural fact. A display buffer and nothing else.
    ///
    /// `text` is an autoclosure so a replay, which records nothing, never builds the sentence.
    public func log(_ ts: Int64, _ cat: String, _ role: String, _ text: @autoclosure () -> String) {
        if !recording { return }
        recent.append(ClassifiedLine(ts: ts, cat: cat, role: role, text: text()))
        if recent.count > RECENT_CAP { recent.removeFirst() }
    }

    /// Freeze the live zone aggregate into the capped history, before the aggregate is reset. A stay
    /// that saw no attributed damage is dropped.
    public func finalizeZoneSession(_ closedBy: ZoneSessionClose) {
        if zoneAgg.isEmpty { return }
        zoneSeq += 1
        let id = "zs\(zoneSeq)"
        let z = zone ?? "Session"
        let agg = zoneAgg
        zoneAgg = Agg()
        zoneHistory.append(ZoneSession(id: id, zone: z, agg: agg, closedBy: closedBy,
                                       startTs: zoneStartTs, lastTs: zoneLastTs,
                                       finalizedMs: zoneFinalizedMs, activeMs: zoneActiveMs))
        if zoneHistory.count > ZONE_HISTORY_CAP { zoneHistory.removeFirst() }
    }

    /// Mint fresh zone accumulators — the second half of every stay boundary, its own function
    /// because two callers share it and must not drift: the zone line and the session mark.
    public func resetZoneAccumulators() {
        zoneAgg = Agg()
        zoneFinalizedMs = 0
        zoneActiveMs = 0
        zoneStartTs = 0
        zoneLastTs = 0
    }
}

/// The nameKey half of an instance id `<nameKey>#<gen>`. `nil` when the id carries no `#` at a
/// splittable position — the `you` sentinel and nothing else.
public func nameKeyOf(_ instanceId: String) -> String? {
    guard let hash = instanceId.lastIndex(of: "#") else { return nil }
    if hash == instanceId.startIndex { return nil }
    return String(instanceId[instanceId.startIndex..<hash])
}

// MARK: - Checkpoint

// The shared codec vocabulary for the combat checkpoint. A `Set` has no order of its own, so it is
// encoded SORTED — the re-encode the oracle compares must be reproducible, and a hash order is not.
// Dictionaries whose order is not state encode as JSON objects (order-free by construction).

func ckStringSet(_ s: Set<String>) -> JSONValue {
    .array(s.sorted().map { .string($0) })
}

func ckStringSetBack(_ v: JSONValue) -> Set<String>? {
    guard let rows = v.array else { return nil }
    var out = Set<String>()
    out.reserveCapacity(rows.count)
    for r in rows {
        guard let s = r.string else { return nil }
        out.insert(s)
    }
    return out
}

func ckInt64Dict(_ d: [String: Int64]) -> JSONValue {
    .object(d.mapValues { .int($0) })
}

func ckInt64DictBack(_ v: JSONValue) -> [String: Int64]? {
    guard let obj = v.object else { return nil }
    var out: [String: Int64] = [:]
    out.reserveCapacity(obj.count)
    for (k, val) in obj {
        guard let i = val.int64 else { return nil }
        out[k] = i
    }
    return out
}

extension Modifier {
    func checkpointState() -> JSONValue {
        ["name": .string(name), "ts": .int(ts)]
    }

    static func fromCheckpoint(_ v: JSONValue) -> Modifier? {
        guard let name = v["name"].string, let ts = v["ts"].int64 else { return nil }
        return Modifier(name: name, ts: ts)
    }
}

extension RosterFacts {
    /// Carried even though `refreshRoster` overwrites it at the top of every `onEvent`: the sweeps a
    /// live snapshot runs between events read it too (`retractOther` asks `roster.admitted`), so the
    /// pre-event value is reachable state, not scratch.
    func checkpointState() -> JSONValue {
        ["members": ckStringSet(members),
         "admitted": ckStringSet(admitted),
         "names": .object(names.mapValues { .string($0) })]
    }

    static func fromCheckpoint(_ v: JSONValue) -> RosterFacts? {
        guard let members = ckStringSetBack(v["members"]),
              let admitted = ckStringSetBack(v["admitted"]),
              let namesObj = v["names"].object else { return nil }
        var f = RosterFacts()
        f.members = members
        f.admitted = admitted
        for (k, val) in namesObj {
            guard let s = val.string else { return nil }
            f.names[k] = s
        }
        return f
    }
}

extension EngineState {
    /// The engine's complete fold state — EXCEPT the two live latches (`hydrating` / `recording`)
    /// and the classification ring they gate. Those are session-local: `setLive()` belongs to the
    /// NEW generation's first tick, and a restore always precedes a rescan of the log's tail.
    /// Every real checkpoint is cut from a live engine (the landing save runs after the first
    /// beat), so a verbatim carry would fold that tail with the ring recording and the nudge gate
    /// open — bytes the from-zero canon folds hydrating. The restore leaves all three at their
    /// reset defaults and the tail scan replays exactly as a full scan would.
    ///
    /// No field here is wall-clock-derived: every timestamp is stamped from event `ts` or from the
    /// injected `now` a snapshot's sweeps ran with, so each restores verbatim.
    func checkpointState() -> JSONValue {
        var o: [String: JSONValue] = [
            "petNames": ckStringSet(petNames),
            "world": world.checkpointState(),
            "charm": charm.checkpointState(),
            "ally": ally.checkpointState(),
            "others": others.checkpointState(),
            "knownPlayers": ckStringSet(knownPlayers),
            "everPet": ckStringSet(everPet),
            "everStruck": ckStringSet(everStruck),
            "playerKeyInjected": .bool(playerKeyInjected),
            "seq": .int(Int64(seq)),
            "history": .array(history.map { $0.checkpointState() }),
            "zoneAgg": zoneAgg.checkpointState(),
            "zoneFinalizedMs": .int(zoneFinalizedMs),
            "zoneActiveMs": .int(zoneActiveMs),
            "zoneStartTs": .int(zoneStartTs),
            "zoneLastTs": .int(zoneLastTs),
            "zoneHistory": .array(zoneHistory.map { $0.checkpointState() }),
            "zoneSeq": .int(Int64(zoneSeq)),
            "lastActivityTs": .int(lastActivityTs),
            "specials": specials.checkpointState(),
            "slowSamples": .array(slowSamples.map { s -> JSONValue in
                // A nil sample is a qualifying pull that never slowed — data, not absence.
                guard let s else { return .null }
                return .int(s)
            }),
            "coatCombat": .array(coatCombat.map { $0.checkpointState() }),
            "coatClassCheckedTs": .int(coatClassCheckedTs),
            "stateTimeline": stateTimeline.checkpointState(),
            "recentCasts": recentCasts.checkpointState(),
            "heldClickies": ckStringSet(heldClickies),
            "petNudge": petNudge.checkpointState(),
            "quickBuffTs": .int(quickBuffTs),
            "roster": roster.checkpointState(),
        ]
        if let playerKey { o["playerKey"] = .string(playerKey) }
        if let zone { o["zone"] = .string(zone) }
        if let current { o["current"] = current.checkpointState() }
        if let stance { o["stance"] = stance.checkpointState() }
        if let invocation { o["invocation"] = invocation.checkpointState() }
        if let coatUtility { o["coatUtility"] = coatUtility.checkpointState() }
        return .object(o)
    }

    /// Reset, then apply the blob as the whole truth. On failure the state is reset again, so a
    /// half-applied blob never survives (the caller's answer to `false` is a full rescan).
    func restoreCheckpoint(_ v: JSONValue) -> Bool {
        reset()
        if !apply(v) {
            reset()
            return false
        }
        return true
    }

    /// The apply half, assuming a freshly reset state; assignments may land before a later guard
    /// fails, which is why `restoreCheckpoint` resets again on `false`.
    private func apply(_ v: JSONValue) -> Bool {
        guard let petNamesV = ckStringSetBack(v["petNames"]),
              world.restoreCheckpoint(v["world"]),
              charm.restoreCheckpoint(v["charm"]),
              ally.restoreCheckpoint(v["ally"]),
              others.restoreCheckpoint(v["others"]),
              let knownPlayersV = ckStringSetBack(v["knownPlayers"]),
              let everPetV = ckStringSetBack(v["everPet"]),
              let everStruckV = ckStringSetBack(v["everStruck"]),
              let injected = v["playerKeyInjected"].bool,
              let seqV = v["seq"].int64, seqV >= 0,
              let historyRows = v["history"].array,
              let zoneAggV = Agg.fromCheckpoint(v["zoneAgg"]),
              let zoneFinalizedMsV = v["zoneFinalizedMs"].int64,
              let zoneActiveMsV = v["zoneActiveMs"].int64,
              let zoneStartTsV = v["zoneStartTs"].int64,
              let zoneLastTsV = v["zoneLastTs"].int64,
              let zoneHistoryRows = v["zoneHistory"].array,
              let zoneSeqV = v["zoneSeq"].int64, zoneSeqV >= 0,
              let lastActivityTsV = v["lastActivityTs"].int64,
              specials.restoreCheckpoint(v["specials"]),
              let slowRows = v["slowSamples"].array,
              let coatCombatRows = v["coatCombat"].array,
              let coatClassCheckedTsV = v["coatClassCheckedTs"].int64,
              stateTimeline.restoreCheckpoint(v["stateTimeline"]),
              let recentCastsV = RecentCasts.fromCheckpoint(v["recentCasts"]),
              let heldClickiesV = ckStringSetBack(v["heldClickies"]),
              petNudge.restoreCheckpoint(v["petNudge"]),
              let quickBuffTsV = v["quickBuffTs"].int64,
              let rosterV = RosterFacts.fromCheckpoint(v["roster"]) else { return false }
        petNames = petNamesV
        knownPlayers = knownPlayersV
        everPet = everPetV
        everStruck = everStruckV
        // The blob wholesale: `reset()` re-injected the prior character's key above, and the blob's
        // word — key AND injection flag — replaces it, absent meaning nil.
        playerKey = v["playerKey"].string
        playerKeyInjected = injected
        zone = v["zone"].string
        seq = UInt64(seqV)
        if let curV = v["current"].presentValue {
            guard let e = Encounter.fromCheckpoint(curV) else { return false }
            current = e
        }
        for r in historyRows {
            guard let e = Encounter.fromCheckpoint(r) else { return false }
            history.append(e)
        }
        zoneAgg = zoneAggV
        zoneFinalizedMs = zoneFinalizedMsV
        zoneActiveMs = zoneActiveMsV
        zoneStartTs = zoneStartTsV
        zoneLastTs = zoneLastTsV
        for r in zoneHistoryRows {
            guard let s = ZoneSession.fromCheckpoint(r) else { return false }
            zoneHistory.append(s)
        }
        zoneSeq = UInt64(zoneSeqV)
        lastActivityTs = lastActivityTsV
        if let sv = v["stance"].presentValue {
            guard let m = Modifier.fromCheckpoint(sv) else { return false }
            stance = m
        }
        if let iv = v["invocation"].presentValue {
            guard let m = Modifier.fromCheckpoint(iv) else { return false }
            invocation = m
        }
        for r in slowRows {
            if r.isNull {
                slowSamples.append(nil)
                continue
            }
            guard let ms = r.int64 else { return false }
            slowSamples.append(ms)
        }
        if let cv = v["coatUtility"].presentValue {
            guard let c = CoatSlot.fromCheckpoint(cv) else { return false }
            coatUtility = c
        }
        for r in coatCombatRows {
            guard let c = CoatSlot.fromCheckpoint(r) else { return false }
            coatCombat.append(c)
        }
        coatClassCheckedTs = coatClassCheckedTsV
        recentCasts = recentCastsV
        heldClickies = heldClickiesV
        quickBuffTs = quickBuffTsV
        roster = rosterV
        return true
    }
}
