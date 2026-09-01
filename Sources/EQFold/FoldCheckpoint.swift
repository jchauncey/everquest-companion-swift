// Checkpointing the fold, so an attach can resume instead of replaying the whole log.
//
// WHY. The fold is a pure function of the log's bytes, and the log only grows — 42.7 MB and
// ~20 seconds of refold per attach on the owner's character, three times in one morning for the
// same bytes. A checkpoint is that function's value at a byte mark: restore it, then fold only
// what the game appended since. The from-zero fold stays canonical and golden-checked; a
// checkpoint is an ACCELERATOR, never a second source of truth, and anything doubtful about one
// (wrong file, truncated log, changed defines, different build) is answered with a full rescan.
//
// THE CONTRACT, which the oracle in `FoldCheckpointTests` enforces per conforming module:
//
//   1. `checkpointState()` captures EVERYTHING the fold has accumulated — the module's complete
//      internal state, not the published `snapshot()`. Those differ on purpose: `snapshot()` is
//      what readers see; a checkpoint is what folding needs. LootModule's `zone` is in no
//      snapshot, and a checkpoint without it labels every resumed row with the wrong place.
//
//   2. `restoreCheckpoint(_:)` RESETS FIRST, then applies the blob as the whole truth. This is
//      what makes omissions catchable: restore-over-reset turns a forgotten field into virgin
//      state, and the oracle's tail fold diverges. Restore-in-place would silently inherit the
//      very state the codec failed to carry — an oracle that can never fail.
//
//   3. `false` means the blob is unusable, and the module is left RESET — the caller's answer to
//      `false` is a full rescan, so a half-applied blob must never survive it.
//
//   4. Round trip: after `restoreCheckpoint(checkpointState())`, the module is indistinguishable
//      under any further folding, and `checkpointState()` re-encodes to the same value. Enforced
//      behaviorally (fold the tail, compare every snapshot) and structurally (re-encode, compare).
//
// In-process signals — revision counters, announce edges already consumed — are NOT state to
// carry: a restore is a change, and bumping the local signal is the honest reading of one.
import EQCompanionCore

/// A module (or engine) that can save its complete fold state and be rebuilt from it.
public protocol FoldCheckpointable: AnyObject {
    /// The complete internal state, as one JSON value. See the contract above.
    func checkpointState() -> JSONValue
    /// Reset, then rebuild from a `checkpointState()` blob. `false` = unusable; the module is
    /// left reset and the caller falls back to a full rescan.
    func restoreCheckpoint(_ state: JSONValue) -> Bool
}
