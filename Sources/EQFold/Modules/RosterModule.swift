// Port of fold/src/modules/roster.rs plus its fan-out detector and the provenance ladder they share
// — WHO YOU ARE GROUPED WITH.
//
// REGISTERED SECOND, and that is load-bearing: the combat engine pulls the roster through a seam
// installed before it folds a line, so within one bus delivery the roster must already be advanced.
//
// WHAT CLEARS IT: `epoch` (a rebirth means the group belonged to somebody else) and `selfLeave`.
// `offlineGap` does NOT — EQ drops groups silently on camp, so members are marked STALE rather than
// emptied. `zone` does not either: a group survives zoning.
//
// THE RECOVERY RUNGS. EQ prints a join line ONCE. `confirmed` needs somebody to talk. `buffed` is a
// CONJUNCTION of two facts the log states outright: one Quick Buff burst naming recipients in a
// single instant, and `You gain party experience!` earlier in the session. The gate is STICKY
// rather than windowed, and BACKWARD-ONLY.
//
// NEVER-A-MEMBER. A burst also lands on your own pets, so the weakest rung is refused for the
// tailed character, every charmed mob and every claimed pet — RETROACTIVELY for that rung only.
// `joined` / `stated` / `user` are never touched.
import Foundation
import EQLog
import EQCompanionCore

/// Strongest first. A rank, not just a label: a weaker signal never overwrites a stronger one's
/// provenance.
private func sourceRank(_ source: String) -> Int {
    switch source {
    case "user": return 4
    case "joined": return 3
    case "stated": return 2
    case "confirmed": return 1
    default: return 0 // 'buffed'
    }
}

/// At least as authoritative as what is already there.
private func outranks(_ next: String, _ cur: String) -> Bool { sourceRank(next) >= sourceRank(cur) }

/// Which provenance rung each membership-bearing `change` writes.
private func changeSource(_ change: String) -> String? {
    switch change {
    case "join": return "joined"
    case "leader": return "stated"
    case "confirm": return "confirmed"
    default: return nil
    }
}

/// The one action that makes EQ Legends enumerate, by name and in a single instant, the people your
/// buffs reach.
///
/// The bucket is keyed on the log's SECOND rather than a tolerance window: every line of a burst
/// carries the identical timestamp. HoT ticks are excluded — a tick is cast-detached.
private struct BuffFanOut {
    private struct Bucket {
        var ts: Int64
        /// Canonical spell key — two casts of two different spells in one second are two casts.
        var spell: String
        /// Display names in ARRIVAL order, deduped by canonical key. The order is published.
        var names: JSMap<String>
        /// True once reported: later arrivals in the same cast report only themselves.
        var announced: Bool
    }

    private var bucket: Bucket?

    mutating func reset() { bucket = nil }

    /// The display names this line newly proves were reached by one cast of yours, or nil.
    mutating func onHeal(_ ev: Event) -> [String]? {
        if ev.bool(.overTime) { return nil }
        guard let spell = ev.str(.spell), let healer = ev.str(.healer) else { return nil }
        // Only your OWN casts: another player's group buff enumerates THEIR group.
        if healer.lowercased() != "you" { return nil }
        let key = spell.lowercased()
        let target = ev.str(.target) ?? ""
        let fresh = bucket.map { $0.ts != ev.ts || $0.spell != key } ?? true
        if fresh { bucket = Bucket(ts: ev.ts, spell: key, names: JSMap(), announced: false) }
        let nameKey = target.lowercased()
        if bucket!.names.containsKey(nameKey) { return nil }
        bucket!.names.insert(nameKey, target)
        if bucket!.names.count < 2 { return nil }
        if bucket!.announced { return [target] }
        bucket!.announced = true
        return bucket!.names.values
    }
}

/// One persisted user edit.
private struct RosterEdit {
    var key: String
    var name: String
    /// True for `add`, false for `remove`. A closed pair, so a bool rather than a second enum.
    var add: Bool
    var setAt: Int64

    /// Read one pushed edit. nil for anything that is not the shape the store writes: refused
    /// whole, never silently repaired.
    static func read(_ v: JSONValue) -> RosterEdit? {
        guard let action = v["action"].string, let key = v["key"].string, !key.isEmpty,
              let name = v["name"].string, let setAt = v["setAt"].int64 else { return nil }
        let add: Bool
        switch action {
        case "add": add = true
        case "remove": add = false
        default: return nil
        }
        return RosterEdit(key: key, name: name, add: add, setAt: setAt)
    }
}

public final class RosterModule: EqModule, Defines, RosterSource {
    /// One roster member as this module publishes it — wider than the combat shape, which does not
    /// draw `lastConfirmedTs` or `stale`.
    public struct Member {
        /// Canonical (lowercased) identity key.
        public var key: String
        /// Display name, spelled the way the log spelled it.
        public var name: String
        public var source: String
        public var sinceTs: Int64
        public var lastConfirmedTs: Int64
        /// An offline gap has passed with no signal since. A stale member is rendered dimmed and
        /// STILL PASSES the allowlist.
        public var stale: Bool

        var json: JSONValue {
            ["key": .string(key), "name": .string(name), "source": .string(source),
             "sinceTs": .int(sinceTs), "lastConfirmedTs": .int(lastConfirmedTs), "stale": .bool(stale)]
        }
    }

    public let id = "roster"

    /// The log-derived roster, keyed canonically. INSERTION ORDER IS JOIN ORDER, which is what the
    /// published `members` array carries.
    private var log = JSMap<Member>()
    /// Every key admitted since the last epoch/self-leave. Wider than the roster on purpose, and a
    /// user REMOVE must never shrink it; not published, so its order is free.
    private var admittedKeys = JSMap<String>()
    /// Any group signal at all this epoch — the "no roster yet" vs "solo" distinction.
    private var seen = false
    private var lastSignalTs: Int64 = 0
    private var seq: Int64 = 0
    /// The announce cursor. Only `members`, `seen` and `lastSignalTs` are published; everything
    /// else here is how a name earns its way onto the roster.
    private var announce = Announce()
    private var fanOut = BuffFanOut()
    /// The party-experience gate. Sticky rather than windowed; it gates the `buffed` rung and
    /// nothing else, never puts a name on the roster and never sets `seen`.
    private var partyExp = false
    /// Canonical keys the weakest rung refuses: the tailed character, charmed mobs, claimed pets.
    private var neverMember: Set<String> = []
    /// The tailed character's own key, installed at construction when the session knows it.
    private var selfKey: String
    /// The user's own edits, via `roster.define`.
    private var edits: [RosterEdit] = []
    /// The ts of the last epoch boundary, and of the last `You have been removed from the group.`
    /// Kept as instants rather than by clearing the list, because the list is the APP's.
    private var epochTs: Int64 = 0
    private var leftTs: Int64 = 0

    public init(selfName: String?) {
        selfKey = selfName.map { Names.idKey($0) } ?? ""
    }

    /// A name the log has shown to be a PET. The refusal reaches BACKWARD into a roster the burst
    /// got in ahead of; a `joined`/`stated`/`user` member is left alone.
    private func refusePet(_ name: String) {
        let key = Names.idKey(name)
        if neverMember.contains(key) { return }
        neverMember.insert(key)
        // The refusal is knowledge about a NAME and is not published. Only evicting a member the
        // weakest rung had already admitted changes the roster anybody can read.
        if log[key]?.source == "buffed" {
            log.remove(key)
            admittedKeys.remove(key)
            announce.changed(seq)
        }
    }

    /// One `heal` line through the fan-out detector. A burst proves RECIPIENTS; the gate proves a
    /// group exists to receive them. Both, or nothing.
    private func foldHeal(_ ev: Event) {
        guard let reached = fanOut.onHeal(ev) else { return }
        if !partyExp { return }
        for name in reached {
            let key = Names.idKey(name)
            if key == selfKey || key == "you" || neverMember.contains(key) { continue }
            // A burst comes WITH NAMES, unlike the party-exp line, and a roster with names in it is
            // what `seen` is for.
            seen = true
            lastSignalTs = max(lastSignalTs, ev.ts)
            add(key, name, "buffed", ev.ts)
            announce.changed(seq)
        }
    }

    private func foldGroup(_ ev: Event) {
        // Every group line is a published change, the usually-declined invite and the `selfJoin`
        // that names nobody included: both set `seen` and `lastSignalTs`.
        announce.changed(seq)
        // An INVITE is not a membership fact, but it proves a group is in play.
        seen = true
        lastSignalTs = max(lastSignalTs, ev.ts)
        let change = ev.str(.change) ?? ""
        if change == "invite" || change == "selfJoin" { return }
        if change == "selfLeave" {
            log.clear()
            admittedKeys.clear()
            // …and every user edit written before the group ended described THAT group.
            leftTs = ev.ts
            // The group itself is over, so the licence to read a future burst as membership is too.
            partyExp = false
            fanOut.reset()
            return
        }
        guard let name = ev.str(.name) else { return }
        let key = Names.idKey(name)
        if change == "leave" {
            log.remove(key)
            // Not removed from `admittedKeys`: their recorded damage stays real. Only a self-leave
            // or an epoch resets admission.
            return
        }
        guard let source = changeSource(change) else { return }
        add(key, name, source, ev.ts)
    }

    /// Add or re-assert one member. Provenance only ever moves UP the ladder.
    private func add(_ key: String, _ name: String, _ source: String, _ ts: Int64) {
        admittedKeys.insert(key, name)
        guard var cur = log[key] else {
            log.insert(key, Member(key: key, name: name, source: source, sinceTs: ts,
                                   lastConfirmedTs: ts, stale: false))
            return
        }
        cur.lastConfirmedTs = max(cur.lastConfirmedTs, ts)
        // Any fresh signal ends staleness: the group demonstrably still exists.
        cur.stale = false
        if outranks(source, cur.source) { cur.source = source }
        // The log's own spelling wins on a re-assert: a name typed lowercase into an invite is not
        // how the game spells it in the join line.
        if name != key { cur.name = name }
        log.insert(key, cur)
    }

    /// The persisted edits that STILL APPLY: written after the last epoch AND after the last
    /// self-leave. Everything older described a character or a group that is gone.
    private var liveEdits: [RosterEdit] {
        edits.filter { $0.setAt >= epochTs && $0.setAt > leftTs }
    }

    /// The effective roster: the log's roster, PLUS your adds, MINUS your removes.
    ///
    /// User edits are a LAYER over the log rather than a mutation of it: a later join line cannot
    /// undo a remove, and a later leave line cannot undo an add.
    private func effective() -> [Member] {
        let live = liveEdits
        if live.isEmpty { return log.values }
        var out = JSMap<Member>()
        for m in log.values { out.insert(m.key, m) }
        for e in live {
            if !e.add {
                out.remove(e.key)
                continue
            }
            if var cur = out[e.key] {
                cur.source = "user"
                out.insert(e.key, cur)
                continue
            }
            out.insert(e.key, Member(key: e.key, name: e.name, source: "user", sinceTs: e.setAt,
                                     lastConfirmedTs: e.setAt, stale: false))
        }
        return out.values
    }

    public func reset() {
        log.clear()
        admittedKeys.clear()
        seen = false
        lastSignalTs = 0
        seq = 0
        announce.reset()
        partyExp = false
        fanOut.reset()
        // The never-a-member set is NOT cleared with the roster: it is knowledge about which names
        // are PETS, and a pet does not stop being one because the character was reborn. `selfKey`
        // outlives it for the same reason.
    }

    public func onEvent(_ ev: Event, live: Bool) {
        seq = ev.seq
        switch ev.kindOf {
        case .epoch:
            // Character rebirth: this group belonged to the wiped character. Everything goes, the
            // persisted edits included — and they go by DATE rather than by deletion.
            reset()
            epochTs = ev.ts
            // Off `ev.seq`, not `seq`, which the reset just zeroed: a cursor bumped off the zeroed
            // field would land BELOW the seq a client still holds from the wiped character.
            announce.changed(ev.seq)
        case .offlineGap:
            // The world stopped being observable. Nothing SAID the group broke, so every member is
            // marked stale rather than removed, and stays in the allowlist.
            let fromTs = ev.int(.fromTs) ?? 0
            // `stale` is a published field, so a member flipping it is a change a client draws.
            // Counted rather than assumed.
            var flipped = false
            log.mutateValues { m in
                if m.lastConfirmedTs <= fromTs && !m.stale {
                    m.stale = true
                    flipped = true
                }
            }
            if flipped { announce.changed(seq) }
            partyExp = false
            fanOut.reset()
        // `You gain party experience!` — the game's own statement that you are in a group right
        // now. IT NAMES NOBODY, so it opens the gate and touches nothing else.
        case .expGain:
            if ev.bool(.party) { partyExp = true }
        case .charm, .uncharm: refusePet(ev.str(.mob) ?? "")
        case .petClaim: refusePet(ev.str(.name) ?? "")
        case .heal: foldHeal(ev)
        case .group: foldGroup(ev)
        default: break
        }
    }

    /// The dirty bit: a group line, a heal burst that reached a name, a pet evicted from the weakest
    /// rung, a gap that staled somebody, or a rebirth.
    public var publishedSeq: Int64? { announce.cursor }

    public func snapshot() -> JSONValue {
        // With no edits pushed this is the log's map in join order, verbatim.
        ["seq": .int(seq),
         "state": ["members": .array(effective().map(\.json)),
                   "seen": .bool(seen),
                   "lastSignalTs": .int(lastSignalTs)]]
    }

    /// The pull seam, answered by this module and by no other.
    public var asRoster: RosterSource? { self }

    public var asDefines: Defines? { self }

    // MARK: - Defines

    public var family: String { "roster" }

    /// The whole edit list, replaced. A PUSH rather than the TS's pull, because of the process
    /// boundary — and because a define is a full-set replace, a switch is one push.
    public func define(_ payload: JSONValue) {
        guard let list = payload.array else { return }
        edits = list.compactMap(RosterEdit.read)
        // `effective()` folds these into the published `members`, so a pushed edit list is a
        // published change with no event behind it.
        announce.changed(seq)
    }

    // MARK: - RosterSource
    //
    // The combat engine does not FOLD a roster, it ASKS this module for one, during the same
    // delivery and after this module has advanced for the line. `RosterMember` is a NARROWER shape
    // than the one this module publishes; both are built from the same map in the same order.

    public func snap() -> RosterSnap {
        RosterSnap(members: effective().map {
            RosterMember(key: $0.key, name: $0.name, source: $0.source, sinceTs: $0.sinceTs)
        }, seen: seen, lastSignalTs: lastSignalTs)
    }

    public func members() -> [String] { effective().map(\.key) }

    /// Wider than `members`, and it never shrinks within an epoch: a member who left an hour ago is
    /// still the person whose row carries that fight's damage.
    ///
    /// A user ADD joins it and a user REMOVE does not leave it — the same asymmetry.
    public func admitted() -> [String] {
        var out = admittedKeys.keys
        for e in liveEdits where e.add && !out.contains(e.key) { out.append(e.key) }
        return out
    }

    /// The roster's own spelling for a key — a read of the same list.
    public func nameOf(_ key: String) -> String? {
        snap().members.first { $0.key == key }?.name
    }
}
