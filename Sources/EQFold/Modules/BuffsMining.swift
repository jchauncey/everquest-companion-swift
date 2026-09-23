// Which log lines are offered to the message-overlay miner.
//
// It mines the same way in replay and live, which is what makes the overlay a FOLD rather than a
// session artifact, and therefore reproducible.
//
// There is deliberately no dirty-cache around `build()`: a `Fold` takes exactly one snapshot.
// (fold/src/modules/buffs_mining.rs)
import Foundation
import EQLog
import EQCompanionCore

public final class OverlayMining {
    private let miner: MessageOverlayMiner
    /// `looksLandingMessage` by text. It is a pure function behind an ICU alternation, asked of every
    /// unclassified line, and those repeat: a log says the same few thousand things. Bounded, and
    /// dropped whole when full — a memo, not state, so it is no part of a checkpoint.
    private var landingShaped: [String: Bool] = [:]
    private static let landingShapedCap = 1 << 16

    /// Seeded warm with the committed baseline, so a fresh install benefits from the shipped counts.
    /// Each seed carries its SOURCE KEY: the bucket a log is filed under is what lets `beginSource`
    /// replace it when that log is folded again.
    public init(facts: SpellFacts, seeds: [(String, [OverlaySeedMessage])]) {
        miner = MessageOverlayMiner(facts: facts)
        for (key, counts) in seeds { miner.merge(counts, key) }
    }

    private func landingShapedMemo(_ t: String) -> Bool {
        if let known = landingShaped[t] { return known }
        if landingShaped.count >= Self.landingShapedCap { landingShaped.removeAll(keepingCapacity: true) }
        let v = looksLandingMessage(t)
        landingShaped[t] = v
        return v
    }

    /// A log is about to be folded from its first byte — file what it teaches under `key` and drop
    /// whatever that key held.
    public func beginSource(_ key: String) { miner.beginSource(key) }

    /// Offer one event to the miner. A cast is the association ANCHOR; the message-bearing events
    /// are candidate messages associated to the nearest anchor within the window.
    ///
    /// Returns whether it fed the miner. The answer is deliberately the CALL and not the miner's own
    /// verdict: "unsure whether this mutated" is the case the announce law says to bump on.
    @discardableResult
    public func observe(_ ev: Event) -> Bool {
        switch ev.kindOf {
        case .castBegin:
            miner.observeCast(ev.str(.spell) ?? "", ev.ts)
            return true
        case .buffApply, .spellEmote:
            note(ev, "landing")
            return true
        case .buffWearOff, .illusionFade, .buffFade:
            note(ev, "wearsOff")
            return true
        // The AA potion quaff is a landing message the leveling analytics claim as their own kind,
        // but it is absent from spells.json so the overlay learned it here.
        case .aaPotion, .unknown:
            // A line the parser classified as nothing but that could be an un-catalogued landing
            // message. Only flavor-SHAPED lines are fed; the miner's unambiguous-anchor and count
            // rules discard coincidental pairings.
            let t = messageTextOf(ev.raw)
            if landingShapedMemo(t) {
                miner.observeMessage(t, ev.ts, "landing")
                return true
            }
            return false
        default:
            return false
        }
    }

    private func note(_ ev: Event, _ role: String) {
        miner.observeMessage(messageTextOf(ev.raw), ev.ts, role)
    }

    /// Seed one persisted bucket, through the same `merge` the committed baseline arrives by.
    ///
    /// Separate from `init` on purpose: the baseline is a fact about committed data, while the user
    /// register is a file, and a constructor that could reach a file would not be reproducible by
    /// the goldens.
    public func seed(_ key: String, _ counts: [OverlaySeedMessage]) { miner.merge(counts, key) }

    /// The persistence view — every bucket's raw counts, filed under the source that produced them.
    public func register() -> OverlayRegister { miner.register() }

    /// The served overlay.
    public func build() -> JSONValue { miner.build() }

    // MARK: - Checkpoint

    /// The miner in full — see `MessageOverlayMiner.checkpointState`.
    func checkpointState() -> JSONValue { miner.checkpointState() }

    /// Replaces the miner's state wholesale, the construction-time seeds included: the blob's
    /// buckets already carry whatever the seeds had contributed by the checkpoint instant.
    func restoreCheckpoint(_ v: JSONValue) -> Bool { miner.restoreCheckpoint(v) }
}
