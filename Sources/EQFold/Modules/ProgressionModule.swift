// Port of fold/src/modules/progression.rs — the range-queryable time series behind the leveling
// analytics. Experience, CREDITED kills, WITNESSED kills, loot (an activity signal), the zone
// timeline, the offline intervals and a mirror of the level/AA series, folded into ONE columnar
// snapshot so `progressionStats.rangeStats` has a single input.
//
// `killTs` holds only kills the log attributes to YOU: your own killing blow, plus a bound pet's.
// Third-party kills go to `witnessTs` and enter no rate, so a busy zone cannot inflate your farming.
//
// Pet binding: SUMMONED pets persist across zones, CHARMED pets do not, so a zone line clears only
// the charmed set. A charmed mob also sends the pet-claim tell, so a claim for a name already
// charmed re-arms the charm rather than being promoted.
//
// The experience join looks BACKWARD: a kill takes the most recent UNCLAIMED line within
// `killExpJoinMs` before it, the claim CONSUMES the line, and every kill line consumes — witnessed
// ones included. A kill with no line in its window carries no exp at all.
//
// Offline intervals are the `offlineGap` events the session detector synthesizes, folded VERBATIM.
import Foundation
import EQLog
import EQCompanionCore

/// Drop-oldest caps — a retention FLOOR, not a hard length (see `trimBatch`). Nothing is persisted.
private let expCap = 40_000
private let killCap = 40_000
private let witnessCap = 20_000
private let lootCap = 20_000
/// Zone bands are the cheapest and most valuable column — this covers months.
private let zoneCap = 4_000
/// Like the zone bands but rarer by orders of magnitude; it exists only so no column here can grow
/// without a stated bound.
private let offlineCap = 4_000
/// The named recent-kills ring, capped by COUNT rather than by the column policy.
private let recentKillCap = 50

/// How much slack a full column is allowed before it is trimmed back to its cap. A column can
/// transiently hold up to this many entries more than its cap, and it never holds fewer.
private let trimBatch = 1024

/// `shared/kills.ts KILL_EXP_JOIN_MS` — how far BACK a kill may reach for its experience line.
private let killExpJoinMs: Int64 = 2500

/// A named row for a credited kill — a display duplicate; no statistic reads it. Public because
/// `kills.recent` is a view over this ring, and a view reads the module's own rows.
public struct ProgressionKill {
    /// When, on the log's own clock.
    public var ts: Int64
    /// The mob's raw display name — what the deep link into the Mobs surface is built from.
    public var name: String
    /// `0` for your own killing blow, `1` for a bound pet's.
    public var credit: Int64
    /// Raw zone name, or `''` before the first zone line.
    public var zone: String
    /// Bitfield: `1` the exp line stated no percentage, `2` it was party exp. Absent means there
    /// was no exp line at all.
    public var expFlag: Int64?
    /// The percentage the line stated, when it stated one.
    public var expPct: Double?

    public init(ts: Int64, name: String, credit: Int64, zone: String, expFlag: Int64? = nil, expPct: Double? = nil) {
        self.ts = ts; self.name = name; self.credit = credit; self.zone = zone
        self.expFlag = expFlag; self.expPct = expPct
    }

    var json: JSONValue {
        var o: [String: JSONValue] = ["ts": .int(ts), "name": .string(name), "credit": .int(credit),
                                      "zone": .string(zone)]
        if let f = expFlag { o["expFlag"] = .int(f) }
        if let p = expPct { o["expPct"] = .double(p) }
        return .object(o)
    }
}

/// An experience line waiting to be claimed by the kill line that follows it.
private struct PendingExp {
    var ts: Int64
    var pct: Double?
    var party: Bool
}

/// `ProgressionSnap` — the published columns, index-aligned in groups.
private struct Snap {
    var expTs: [Int64] = []
    var expPct: [Double] = []
    var expFlag: [Int64] = []
    var killTs: [Int64] = []
    var killZone: [Int64] = []
    var killCredit: [Int64] = []
    var witnessTs: [Int64] = []
    var recentKills: [ProgressionKill] = []
    var lootTs: [Int64] = []
    var zoneStart: [Int64] = []
    var zoneEnd: [Int64] = []
    var zoneName: [String] = []
    var offlineStart: [Int64] = []
    var offlineEnd: [Int64] = []
    var offlineCamped: [Int64] = []
    var levelTs: [Int64] = []
    var levelValue: [Int64] = []
    var aaGainTs: [Int64] = []
    var aaGainAmount: [Int64] = []
    var lastTs: Int64 = 0
    var windowStart: Int64 = 0
    var dropped: Int64 = 0

    var json: JSONValue {
        // Built key by key: one 22-entry literal is more than the type checker will chew through.
        var o: [String: JSONValue] = [:]
        o["expTs"] = ints(expTs)
        o["expPct"] = .array(expPct.map { .double($0) })
        o["expFlag"] = ints(expFlag)
        o["killTs"] = ints(killTs)
        o["killZone"] = ints(killZone)
        o["killCredit"] = ints(killCredit)
        o["witnessTs"] = ints(witnessTs)
        o["recentKills"] = .array(recentKills.map(\.json))
        o["lootTs"] = ints(lootTs)
        o["zoneStart"] = ints(zoneStart)
        o["zoneEnd"] = ints(zoneEnd)
        o["zoneName"] = .array(zoneName.map { .string($0) })
        o["offlineStart"] = ints(offlineStart)
        o["offlineEnd"] = ints(offlineEnd)
        o["offlineCamped"] = ints(offlineCamped)
        o["levelTs"] = ints(levelTs)
        o["levelValue"] = ints(levelValue)
        o["aaGainTs"] = ints(aaGainTs)
        o["aaGainAmount"] = ints(aaGainAmount)
        o["lastTs"] = .int(lastTs)
        o["windowStart"] = .int(windowStart)
        o["dropped"] = .int(dropped)
        return .object(o)
    }
}

/// Each `Vec<i64>` column, as JSON.
private func ints(_ a: [Int64]) -> JSONValue { .array(a.map { .int($0) }) }

/// Cumulative drops per capped column — feeds `windowStart`.
private struct DropFront {
    var exp: Int64 = 0
    var kill: Int64 = 0
    var witness: Int64 = 0
    var loot: Int64 = 0
    var zone: Int64 = 0
    var offline: Int64 = 0
}

/// Drop-oldest across parallel columns that must stay index-aligned. Returns how many leading
/// entries go (0 while the column is still inside `cap + trimBatch`).
private func capDrop(_ cap: Int, _ len: Int) -> Int {
    len < cap + trimBatch ? 0 : len - cap
}

public final class ProgressionModule: EqModule {
    public let id = "progression"

    private var s = Snap()
    private var seq: Int64 = 0
    private var droppedBy = DropFront()
    /// Summoned pets (pet-claim tells, never charmed). They follow you through a zone line.
    private var claimed: Set<String> = []
    /// Pets bound right now by charm. Charm cannot survive a zone transition (law 4).
    private var charmed: Set<String> = []
    /// Every name ever charmed this epoch — a charmed mob tells you it is your pet too, and that
    /// claim must never promote it to a zone-surviving summoned pet.
    private var everCharmed: Set<String> = []
    private var pendingExp: PendingExp?
    /// The announce cursor. It moves on the `lastTs` advance as well as on every column push:
    /// `lastTs` is a published field the zone bands clamp the open interval's right edge to.
    private var announce = Announce()

    public init() {}

    /// The recent-kills pull seam — the ring the Overview's kill feed draws, oldest first as the
    /// module keeps it. The view reverses it.
    public func recentKills() -> [ProgressionKill] { s.recentKills }

    /// The level column — `(ts, level)` pairs, in fold order. Uncapped, because the chart needs
    /// every ding.
    public func levels() -> [(Int64, Int64)] { Array(zip(s.levelTs, s.levelValue)) }

    /// The AA column — `(ts, amount)` pairs, in fold order.
    public func aaGains() -> [(Int64, Int64)] { Array(zip(s.aaGainTs, s.aaGainAmount)) }

    /// The view layer's change signal — the source revision, and deliberately NOT the announce
    /// cursor. The two answer different questions.
    public func revision() -> Int64 { seq }

    /// A pet addressed you as master. For a name never seen charmed this binds permanently; for a
    /// name we HAVE seen charmed it re-arms the charmed set instead.
    private func onClaim(_ key: String) {
        if everCharmed.contains(key) { charmed.insert(key) } else { claimed.insert(key) }
    }

    private func pushExp(_ ts: Int64, _ pct: Double?, _ party: Bool) {
        // A line that stated no pct is stored as -1 plus flag bit 1 — never 0.
        let flag = (pct == nil ? Int64(1) : 0) | (party ? 2 : 0)
        s.expTs.append(ts)
        s.expPct.append(pct ?? -1.0)
        s.expFlag.append(flag)
        // Offer it to the kill line that follows. An unclaimed older line is simply replaced.
        pendingExp = PendingExp(ts: ts, pct: pct, party: party)
        trim()
        announce.changed(seq)
    }

    /// The experience line this kill line claims, or nil. Claiming CONSUMES it.
    private func takeExp(_ ts: Int64) -> PendingExp? {
        guard let p = pendingExp else { return nil }
        pendingExp = nil
        if ts < p.ts || ts - p.ts > killExpJoinMs { return nil }
        return p
    }

    /// Self kill / bound-pet kill (credited) vs everybody else's (witnessed).
    private func onDeath(_ ev: Event) {
        let ts = ev.ts
        let exp = takeExp(ts)
        let name = ev.str(.name) ?? ""
        if ev.bool(.bySelf) {
            pushKill(ts, 0, name, exp)
            return
        }
        // `X has been slain by You` is the third-person twin of the self shape, so counting it
        // would double every one of your own kills.
        let killer = ev.str(.killer) ?? ""
        if killer.isEmpty || JSFn.startsWithYouWord(killer) { return }
        let k = Names.idKey(killer)
        if claimed.contains(k) || charmed.contains(k) {
            pushKill(ts, 1, name, exp)
            return
        }
        s.witnessTs.append(ts)
        trim()
        announce.changed(seq)
    }

    private func pushKill(_ ts: Int64, _ credit: Int64, _ name: String, _ exp: PendingExp?) {
        // -1 before the first zone line: unknown zone, never a fabricated one.
        let zone = Int64(s.zoneStart.count) - 1
        s.killTs.append(ts)
        s.killZone.append(zone)
        s.killCredit.append(credit)
        pushKillRow(ts, credit, name, exp)
        trim()
        announce.changed(seq)
    }

    private func pushKillRow(_ ts: Int64, _ credit: Int64, _ name: String, _ exp: PendingExp?) {
        var row = ProgressionKill(ts: ts, name: name, credit: credit, zone: s.zoneName.last ?? "",
                                  expFlag: nil, expPct: nil)
        if let e = exp {
            row.expFlag = (e.pct == nil ? Int64(1) : 0) | (e.party ? 2 : 0)
            row.expPct = e.pct
        }
        s.recentKills.append(row)
        // Drop-oldest by COUNT, exactly, and deliberately outside the trim path: this ring's churn
        // must not move `dropped`.
        if s.recentKills.count > recentKillCap {
            s.recentKills.removeFirst(s.recentKills.count - recentKillCap)
        }
    }

    /// A derived absence: the character was out of the world between two known instants. Both edges
    /// arrive stated, so this is a plain append. Non-positive spans are dropped.
    private func pushOffline(_ fromTs: Int64, _ toTs: Int64, _ camped: Bool) {
        if toTs <= fromTs { return }
        s.offlineStart.append(fromTs)
        s.offlineEnd.append(toTs)
        s.offlineCamped.append(camped ? 1 : 0)
        trim()
        announce.changed(seq)
    }

    /// Close the open interval at the new zone's start, then open the next one.
    private func onZone(_ ts: Int64, _ zone: String) {
        let n = s.zoneStart.count
        if n > 0 && s.zoneEnd[n - 1] == 0 { s.zoneEnd[n - 1] = ts }
        s.zoneStart.append(ts)
        s.zoneEnd.append(0)
        s.zoneName.append(zone)
        // Charm cannot survive a zone transition; a summoned pet does (law 4).
        charmed.removeAll()
        trim()
        announce.changed(seq)
    }

    /// Enforce every cap, then re-derive the retention floor.
    private func trim() {
        var n = capDrop(expCap, s.expTs.count)
        if n > 0 {
            s.expTs.removeFirst(n); s.expPct.removeFirst(n); s.expFlag.removeFirst(n)
            droppedBy.exp += Int64(n); s.dropped += Int64(n)
        }
        n = capDrop(killCap, s.killTs.count)
        if n > 0 {
            s.killTs.removeFirst(n); s.killZone.removeFirst(n); s.killCredit.removeFirst(n)
            droppedBy.kill += Int64(n); s.dropped += Int64(n)
        }
        n = capDrop(witnessCap, s.witnessTs.count)
        if n > 0 {
            s.witnessTs.removeFirst(n)
            droppedBy.witness += Int64(n); s.dropped += Int64(n)
        }
        n = capDrop(lootCap, s.lootTs.count)
        if n > 0 {
            s.lootTs.removeFirst(n)
            droppedBy.loot += Int64(n); s.dropped += Int64(n)
        }
        n = capDrop(zoneCap, s.zoneStart.count)
        if n > 0 {
            s.zoneStart.removeFirst(n); s.zoneEnd.removeFirst(n); s.zoneName.removeFirst(n)
            // `killZone` is an index into `zoneName`, so a front-drop shifts every one of them. A
            // kill whose zone aged out becomes -1 (unknown), never a WRONG zone.
            let drop = Int64(n)
            for i in s.killZone.indices { s.killZone[i] = max(s.killZone[i] - drop, -1) }
            droppedBy.zone += drop; s.dropped += drop
        }
        n = capDrop(offlineCap, s.offlineStart.count)
        if n > 0 {
            s.offlineStart.removeFirst(n); s.offlineEnd.removeFirst(n); s.offlineCamped.removeFirst(n)
            droppedBy.offline += Int64(n); s.dropped += Int64(n)
        }
        recomputeWindow()
    }

    /// The retention floor: 0 while nothing has aged out, else the max first-timestamp across the
    /// columns that HAVE dropped.
    private func recomputeWindow() {
        var w: Int64 = 0
        let pairs: [(Int64, Int64?)] = [
            (droppedBy.exp, s.expTs.first),
            (droppedBy.kill, s.killTs.first),
            (droppedBy.witness, s.witnessTs.first),
            (droppedBy.loot, s.lootTs.first),
            (droppedBy.zone, s.zoneStart.first),
            (droppedBy.offline, s.offlineStart.first)
        ]
        for (dropped, first) in pairs where dropped > 0 {
            if let f = first { w = max(w, f) }
        }
        s.windowStart = w
    }

    private func clear() {
        s = Snap()
        droppedBy = DropFront()
        claimed.removeAll()
        charmed.removeAll()
        everCharmed.removeAll()
        pendingExp = nil
    }

    private func fold(_ ev: Event) {
        switch ev.kindOf {
        case .expGain: pushExp(ev.ts, ev.double(.pct), ev.bool(.party))
        case .death: onDeath(ev)
        case .zone: onZone(ev.ts, ev.str(.zone) ?? "")
        case .offlineGap:
            pushOffline(ev.int(.fromTs) ?? 0, ev.int(.toTs) ?? 0, ev.bool(.camped))
        case .loot:
            // A destroy counts here: `lootTs` is timestamps only, an ACTIVITY signal, never a drop
            // count. Emptying your bags is you at the keyboard.
            s.lootTs.append(ev.ts)
            trim()
            announce.changed(seq)
        case .level:
            // Uncapped (with aaGain): ~5k rows/year, and the chart needs every ding.
            s.levelTs.append(ev.ts)
            s.levelValue.append(ev.int(.level) ?? 0)
            announce.changed(seq)
        case .aaGain:
            s.aaGainTs.append(ev.ts)
            s.aaGainAmount.append(ev.int(.amount) ?? 0)
            announce.changed(seq)
        // The three pet arms publish nothing: they move the claimed/charmed/ever-charmed sets,
        // which decide whether a LATER kill is credited or witnessed and appear in no snapshot.
        case .petClaim: onClaim(Names.idKey(ev.str(.name) ?? ""))
        case .charm:
            let key = Names.idKey(ev.str(.mob) ?? "")
            charmed.insert(key)
            everCharmed.insert(key)
        case .uncharm:
            charmed.remove(Names.idKey(ev.str(.mob) ?? ""))
        default: break
        }
    }

    public func reset() {
        clear()
        seq = 0
        announce.reset()
    }

    public func onEvent(_ ev: Event, live: Bool) {
        seq = ev.seq
        // Character rebirth: everything before the boundary belongs to a dead same-name character.
        // Note the early return — `lastTs` is not advanced by the boundary event itself.
        if ev.kindOf == .epoch {
            clear()
            announce.changed(seq)
            return
        }
        if ev.ts > s.lastTs {
            s.lastTs = ev.ts
            // A published field moved. Every column push below bumps for itself.
            announce.changed(seq)
        }
        fold(ev)
    }

    /// Moves on a column push, a rebirth, or the log's clock advancing.
    public var publishedSeq: Int64? { announce.cursor }

    public func snapshot() -> JSONValue { ["seq": .int(seq), "state": s.json] }

    /// The view pull seam.
    public var asProgression: ProgressionModule? { self }
}
