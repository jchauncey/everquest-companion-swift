// Bard songs (fold/src/modules/resist/songs.rs): which spells are songs, which song a landing
// sentence belongs to, and how a denominator is reconstructed for the ones whose landings the log
// never prints.
//
// A cast rolls resistance once and the log prints the outcome either way. A song re-rolls on every
// pulse and the log prints only the resists, so a naive denominator reads a song that landed forty
// times and resisted twice as 100% resisted.
//
// Identity, not the begin line, decides what a song is: EQ Legends bards run under the Symphonic
// Aura, which re-pulses every six seconds with no cast line at all. So a spell only the Bard can
// learn is a song whether or not the log announced it, and the begin line is a corroborating signal
// that can only add to the set.
//
// Two ways to count attempts, and the first reconstructs nothing:
//
//   1. The landing sentence is known. Every pulse that lands prints it and every pulse that misses
//      prints a resist, so attempts are lands + resists per (song, mob) exactly. The pulse rules are
//      deliberately not applied on top; they would count the same pulses twice.
//   2. It is not known. Only then does the reconstruction run, on the witnesses there are: resist
//      lines, DoT ticks, and the aura's own heartbeat.
//
// The four rules:
//
//   1. Witnessed. A pulse of song S at t is witnessed iff the log printed, within +-1 s, a resist, a
//      landing emote or a DoT tick for S on any target.
//   2. Interpolated. Pulses at t+6k strictly between two witnesses no more than 30 s apart are
//      counted. Nothing is extrapolated before the first or after the last witness of a run. A
//      begin-singing line inside the gap re-anchors and the interior pulses before it are dropped.
//   3. In range. A pulse is an attempt against mob M only if M was alive and in melee contact inside
//      the previous 6 s. This file owns 1 and 2; the fold owns 3, which needs the world.
//   4. Separable. Songs are their own evidence family, so they can be excluded from R in one place.
//
// A stranger's songs print a landing sentence naming no caster, so they have no denominator anyone
// could see. Every arm below answers "handled" for a non-self caster without filing anything.
//
// Emissions are handed back to the caller in order rather than through a sink callback. The order is
// the only thing the fold can observe: interpolated pulses precede the witnessed pulse that closed
// them.
import Foundation
import EQLog

/// Measured, not chosen: consecutive song resists on one mob are 6, 12, 18, 24 s apart.
public let SONG_PULSE_MS: Int64 = 6_000
/// Two witnesses further apart than this are two runs, and nothing is interpolated between them.
public let SONG_RUN_GAP_MS: Int64 = 30_000
/// Everything the log prints for one pulse lands inside this window of it.
public let SONG_WITNESS_JOIN_MS: Int64 = 1_000
/// Rule 3's window: melee contact inside the last pulse interval is "in range".
public let SONG_CONTACT_MS: Int64 = SONG_PULSE_MS

/// How many aura heartbeat instants to remember. A run is 30 s, so five pulses is plenty.
private let heartbeatMemory = 32

/// One reconstructed pulse. `witnessed == false` means rule 2 put it there.
public struct SongPulse {
    public var spellKey: String
    public var ts: Int64
    public var witnessed: Bool
    /// Mobs the log named as resisting this pulse. Empty for an interpolated pulse, always.
    public var resisted: [String]
}

/// What the song half asks the fold to do, in the order the TS's sink would have been called.
public enum SongOut {
    /// The landing sentence is known, so the pulse files directly.
    case file(mobDisplay: String, songKey: String, ts: Int64, resisted: Bool)
    /// A reconstructed pulse, to be spread over the mobs rule 3 admits.
    case pulse(SongPulse)
}

private struct Run {
    /// The last witnessed pulse's instant, or nil when no run is open.
    var lastWitness: Int64?
    /// A begin-singing line inside the current gap, which re-anchors interpolation.
    var reanchor: Int64?
}

private struct Open {
    var ts: Int64
    var resisted: [String]
}

/// Reconstructs song pulses from what the log printed. Feed it witnesses in timestamp order; it hands
/// back every pulse it can justify, in order, once it is sure of them.
final class SongPulses {
    private var runs: [String: Run] = [:]
    private var open = JSMap<Open>()
    /// Instants the Symphonic Aura stated outright, from the self-landing sentences it prints once
    /// per pulse. Interior pulses snap to these when the gap holds any: a real instant the log printed
    /// beats six-second arithmetic, which drifts as soon as the server tick does.
    private var beats: [Int64] = []

    init() {}

    func reset() {
        runs.removeAll()
        open.clear()
        beats.removeAll()
    }

    /// The aura printed one of its own landing sentences: a pulse happened at `ts`.
    func noteHeartbeat(_ ts: Int64) {
        if let last = beats.last, ts - last < SONG_WITNESS_JOIN_MS { return }
        beats.append(ts)
        if beats.count > heartbeatMemory { beats.removeFirst(beats.count - heartbeatMemory) }
    }

    /// `You begin singing S` — a restart, which drops interpolation across the gap it sits in.
    func noteSing(_ spellKey: String, _ ts: Int64, _ out: inout [SongOut]) {
        closeOpen(spellKey, ts, &out)
        runs[spellKey, default: Run()].reanchor = ts
    }

    /// The log printed something for song S at `ts`: a resist naming `mobKey`, or a landing/tick
    /// naming nobody in particular. Everything inside `SONG_WITNESS_JOIN_MS` of the first such line is
    /// one pulse.
    func witness(_ spellKey: String, _ ts: Int64, _ mobKey: String?, _ out: inout [SongOut]) {
        if var o = open[spellKey], ts - o.ts <= SONG_WITNESS_JOIN_MS {
            if let mob = mobKey, !o.resisted.contains(mob) {
                o.resisted.append(mob)
                open.insert(spellKey, o)
            }
            return
        }
        closeOpen(spellKey, ts, &out)
        var fresh = Open(ts: ts, resisted: [])
        if let mob = mobKey { fresh.resisted.append(mob) }
        open.insert(spellKey, fresh)
    }

    /// Close any pulse that can no longer gain witnesses, without ending the runs they belong to. The
    /// live tail's heartbeat: a bard mid-rotation has an open pulse and an open run, and ending the
    /// run would forfeit every interpolated pulse across the next gap.
    func settle(_ now: Int64, _ out: inout [SongOut]) {
        for key in open.keys { closeOpen(key, now, &out) }
    }

    /// End everything: close the buffered pulses AND end every run, so nothing is interpolated across
    /// the boundary. A zone change and the end of a fold are both real discontinuities.
    func flush(_ out: inout [SongOut]) {
        settle(Int64.max, &out)
        runs.removeAll()
    }

    /// Close the buffered pulse: interpolate back to the previous witness if the gap allows, then emit
    /// the witnessed pulse itself. `now` is only used to decide whether the buffer is stale.
    func closeOpen(_ spellKey: String, _ now: Int64, _ out: inout [SongOut]) {
        guard let o = open[spellKey] else { return }
        if now &- o.ts <= SONG_WITNESS_JOIN_MS { return }
        let ts = o.ts
        let resisted = o.resisted
        open.remove(spellKey)
        interpolate(spellKey, ts, &out)
        out.append(.pulse(SongPulse(spellKey: spellKey, ts: ts, witnessed: true, resisted: resisted)))
        var run = runs[spellKey] ?? Run()
        run.lastWitness = ts
        run.reanchor = nil
        runs[spellKey] = run
    }

    /// Rule 2, in full: the interior pulses of one gap, minus anything before a restart.
    private func interpolate(_ spellKey: String, _ ts: Int64, _ out: inout [SongOut]) {
        let run = runs[spellKey] ?? Run()
        runs[spellKey] = run
        guard let prev = run.lastWitness else { return }
        if ts - prev > SONG_RUN_GAP_MS { return }
        let floor = run.reanchor ?? prev
        for at in interiorPulses(prev, ts) where at > floor {
            out.append(.pulse(SongPulse(spellKey: spellKey, ts: at, witnessed: false, resisted: [])))
        }
    }

    /// The instants strictly inside a gap. The aura's own heartbeat wins where it has anything to say
    /// — those are instants the log printed rather than arithmetic, so they cannot drift against the
    /// server's tick. Six-second stepping is the fallback for a gap with no heartbeat.
    private func interiorPulses(_ prev: Int64, _ ts: Int64) -> [Int64] {
        let inside = beats.filter { $0 > prev + SONG_WITNESS_JOIN_MS && $0 < ts - SONG_WITNESS_JOIN_MS }
        if !inside.isEmpty { return inside }
        var at = prev + SONG_PULSE_MS
        var all: [Int64] = []
        while at < ts - SONG_WITNESS_JOIN_MS {
            all.append(at)
            at += SONG_PULSE_MS
        }
        return all
    }
}

/// True when the Bard is the only class the catalog says can learn it.
func isSongSpell(_ spellKey: String) -> Bool { ResistCatalog.factsForKey(spellKey).song }

/// Does the catalog know a landing sentence? When it does, the denominator is exact and nothing is
/// reconstructed.
func songLandingObservable(_ spellKey: String) -> Bool { ResistCatalog.factsForKey(spellKey).landing }

/// A song you have not learned yet is not the song you are singing: narrow the candidates by the
/// catalog's bard level against the level the log states for the character.
///
/// Two guards keep it from deciding more than it knows. An unknown level narrows nothing, and a
/// narrowing that would empty the list is discarded whole.
func learnable(_ keys: [String], _ casterLevel: Int64?) -> [String] {
    guard let level = casterLevel else { return keys }
    let kept = keys.filter { k in
        guard let at = ResistCatalog.factsForKey(k).learnedAt else { return true }
        return at <= level
    }
    return kept.isEmpty ? keys : kept
}

/// Which song a landing sentence belongs to.
///
/// EQ prints one sentence per spell family, so the parser hands over a candidate list: narrow it first
/// by what the character could have learned, then by what the log has named, which for a song is its
/// resist lines. Candidates with nothing to separate them are refused rather than guessed at.
///
/// The level narrowing comes first because `named` is a running tally that says nothing about the
/// pulses before the log first spelled the song out, while the level is known from the first `/who`.
func resolveSongEmote(_ candidates: [String], _ named: [String], _ casterLevel: Int64?) -> String? {
    var songs: [String] = []
    for name in candidates {
        let key = Names.spellCanonKey(name)
        if isSongSpell(key) { songs.append(key) }
    }
    if songs.isEmpty { return nil }
    var unique: [String] = []
    for key in songs where !unique.contains(key) { unique.append(key) }
    unique = learnable(unique, casterLevel)
    if unique.count == 1 { return unique[0] }
    for key in named where unique.contains(key) { return key }
    return nil
}

/// Everything the fold does about songs, in one place.
public final class SongFold {
    private let pulses = SongPulses()
    /// Songs the log has named in a resist line, newest first. Resolves an ambiguous sentence.
    private var named: [String] = []
    /// Per mob: the songs a resist line named there. The better half of the same resolution.
    private var namedByMob: [String: [String]] = [:]
    /// Songs a begin-singing line announced. Additive only; identity is the real answer.
    private var sung = Set<String>()

    public init() {}

    public func reset() {
        pulses.reset()
        named.removeAll()
        namedByMob.removeAll()
        sung.removeAll()
    }

    /// The live tail's heartbeat: decide what the passage of wall-clock time has settled, and leave
    /// open what is genuinely still open.
    ///
    /// Unlike `flush` it does not end a run: a bard mid-rotation has an open pulse and an open run,
    /// and ending the run would forfeit every interpolated pulse across the next gap. A historical
    /// fold never reaches this, so a golden's world has a song's last open pulse unclosed and the
    /// interpolation leading up to it unemitted.
    public func settle(_ now: Int64, _ out: inout [SongOut]) { pulses.settle(now, &out) }

    public func flush(_ out: inout [SongOut]) { pulses.flush(&out) }

    /// True once any song has been seen; the fold uses it to skip melee-contact bookkeeping.
    public func active() -> Bool { !named.isEmpty || !sung.isEmpty }

    /// A song, by identity. A begin-singing line is a corroborating signal for the rare song a bard
    /// starts by hand, and can only ever add to the set.
    func isSong(_ spellKey: String) -> Bool { sung.contains(spellKey) || isSongSpell(spellKey) }

    /// `You begin singing X.` — rare under the aura, and still worth believing when it appears.
    public func noteSung(_ spellKey: String, _ ts: Int64, _ out: inout [SongOut]) {
        sung.insert(spellKey)
        pulses.noteSing(spellKey, ts, &out)
    }

    /// A landing sentence on yourself. When it belongs to a song it is the aura's heartbeat: the
    /// self-landing sentence prints once per pulse whether or not anything was in range, and it is the
    /// only line that states a pulse instant directly.
    public func onSelfLanding(_ ts: Int64, _ candidates: [String]) {
        for name in candidates {
            if !isSong(Names.spellCanonKey(name)) { continue }
            pulses.noteHeartbeat(ts)
            return
        }
    }

    /// A resist line naming a song. Returns false when it was not a song at all.
    public func onResist(_ mobDisplay: String, _ mobKey: String, _ spellKey: String, _ isSelf: Bool,
                         _ ts: Int64, _ out: inout [SongOut]) -> Bool {
        if !isSong(spellKey) { return false }
        if !isSelf { return true }
        // A resist line spells the song out, so the key it carries is the answer.
        noteNamed(mobKey, spellKey)
        if songLandingObservable(spellKey) {
            out.append(.file(mobDisplay: mobDisplay, songKey: spellKey, ts: ts, resisted: true))
        } else {
            pulses.witness(spellKey, ts, mobKey, &out)
        }
        return true
    }

    /// A landing sentence naming a mob. Returns true when it belonged to a song — handled or refused,
    /// because either way no armed cast may claim it afterwards.
    public func onEmote(_ mobDisplay: String, _ mobKey: String, _ ts: Int64, _ candidates: [String]?,
                        _ casterLevel: Int64?, _ out: inout [SongOut]) -> Bool {
        guard let candidates else { return false }
        if candidates.isEmpty { return false }
        let named = namedFor(mobKey)
        guard let songKey = resolveSongEmote(candidates, named, casterLevel) else {
            // Either not a song, or two songs share the sentence and nothing separates them. An
            // ambiguous pulse is refused, and still counts as handled so no cast claims it.
            return candidates.contains { isSong(Names.spellCanonKey($0)) }
        }
        if songLandingObservable(songKey) {
            out.append(.file(mobDisplay: mobDisplay, songKey: songKey, ts: ts, resisted: false))
        } else {
            pulses.witness(songKey, ts, nil, &out)
        }
        return true
    }

    /// A song's own damage line. Where the landing sentence is known, the sentence is the observation
    /// and the tick is the same pulse printing twice. Where it is not, the tick is one of the few
    /// witnesses there are.
    public func onDamage(_ spellKey: String, _ isSelf: Bool, _ ts: Int64, _ out: inout [SongOut]) -> Bool {
        if !isSong(spellKey) { return false }
        if !isSelf { return true }
        if !songLandingObservable(spellKey) { pulses.witness(spellKey, ts, nil, &out) }
        return true
    }

    private func noteNamed(_ mobKey: String, _ songKey: String) {
        var next = [songKey]
        next.append(contentsOf: named.filter { $0 != songKey })
        if next.count > 8 { next.removeSubrange(8...) }
        named = next
        let here = namedByMob[mobKey] ?? []
        var mine = [songKey]
        mine.append(contentsOf: here.filter { $0 != songKey })
        if mine.count > 4 { mine.removeSubrange(4...) }
        namedByMob[mobKey] = mine
    }

    private func namedFor(_ mobKey: String) -> [String] {
        var out = namedByMob[mobKey] ?? []
        out.append(contentsOf: named)
        return out
    }
}
