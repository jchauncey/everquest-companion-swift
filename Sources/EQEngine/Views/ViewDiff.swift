// The diff between two window states — the engine half of the client's `applyDiff`
// (engined/src/views/diff.rs).
//
// The client's `applyDiff` is the specification: it refuses rather than guesses (an anchor it does
// not hold, a key it does not hold, a key it already holds), and a refused op is a client whose
// window has silently parted from the engine's. So every op emitted here must be applicable as
// sent.
//
//   * `drop` — emitted first, all of them, so every anchor a later `insert` names is a row the
//     client still holds.
//   * `insert` — anchored `after` the row that will precede it or `before` the row that will follow
//     it, with neither anchor exactly when the window is empty at that point. Anchors are computed
//     against a working copy this file advances op by op, because "the row before it" means after
//     the earlier ops applied, not in either input.
//   * `update` — changed cells only. A cell that did not move is omitted and the client leaves it
//     alone; a cell the row no longer has is sent as an explicit null, which the client stores, so
//     a cleared cell stays distinguishable from one the view never had.
//
// There is no move op: a row whose position changed is a drop and an insert, found by a greedy
// forward scan rather than a longest-increasing-subsequence. Greedy is not minimal, and minimal is
// not the bar — the bar is that the ops are correct and that a window nobody reordered produces
// none of them. A wholesale permutation is what a reset is for.
import Foundation
import EQCompanionCore

public enum ViewDiff {
    /// The ops that turn `held` into `next`, in the order the client must apply them.
    ///
    /// An empty answer means the two windows are identical, which is the caller's signal to send
    /// nothing at all — a diff frame with no ops is a frame that says nothing.
    public static func diff(_ held: [Row], _ next: [Row]) -> [DiffOp] {
        var wanted: [String: Int] = [:]
        wanted.reserveCapacity(next.count)
        for (at, row) in next.enumerated() { wanted[row.key] = at }

        // Pass 1: a survivor is a row the next window still holds and whose position is ahead of the
        // last survivor's. Everything else leaves, and the ops that say so go out first.
        var ops: [DiffOp] = []
        var work: [Row] = []
        work.reserveCapacity(held.count)
        var furthest: Int?
        for row in held {
            let at = wanted[row.key]
            let stays = at.map { position in furthest.map { position > $0 } ?? true } ?? false
            if stays {
                furthest = at
                work.append(row)
            } else {
                ops.append(.drop(key: row.key))
            }
        }

        // Pass 2: `work` is now a subsequence of `next`, so one forward walk settles both — at every
        // position the working copy either already holds the right key (an update, or nothing) or
        // does not (an insert). Anchors come off `work` as it stands at that moment, which is what
        // the client will be holding when it reaches the op.
        for (at, row) in next.enumerated() {
            if at < work.count, work[at].key == row.key {
                if let cells = changed(work[at].cells, row.cells) {
                    ops.append(.update(key: row.key, cells: cells))
                }
                continue
            }
            // Neither anchor means the window is empty, so an insert into a non-empty one must
            // always name one. Preferring `after` keeps an append anchored on a row that is already
            // settled.
            let before: String?
            let after: String?
            if at == 0 {
                before = work.first?.key
                after = nil
            } else {
                before = nil
                after = at - 1 < work.count ? work[at - 1].key : nil
            }
            ops.append(.insert(row: row, before: before, after: after))
            work.insert(row, at: min(at, work.count))
        }
        return ops
    }

    /// The cells that moved between two states of one row, or nil when none did.
    ///
    /// A cell present in `next` with a different value is sent; a cell present in `held` and absent
    /// from `next` is sent as an explicit null. The client's `applyUpdate` merges, so an omitted
    /// cell means "unchanged" and the null is the only way to say a cell was cleared.
    static func changed(_ held: [String: JSONValue], _ next: [String: JSONValue]) -> [String: JSONValue]? {
        var moved: [String: JSONValue] = [:]
        for (name, value) in next where held[name] != value { moved[name] = value }
        for name in held.keys where next[name] == nil { moved[name] = .null }
        return moved.isEmpty ? nil : moved
    }

    /// Apply one batch to a window, exactly as the client's `applyDiff` does.
    ///
    /// The oracle this file is tested against, and a port rather than a paraphrase: every refusal
    /// the client makes is a refusal here too, and it is counted, so a test that drives ops through
    /// it proves what the client would do with them. The engine never applies a diff, it only
    /// computes one.
    ///
    /// Returns the window and the number of ops refused. A correct diff refuses none.
    public static func apply(_ held: [Row], _ ops: [DiffOp]) -> (rows: [Row], refused: Int) {
        var rows = held
        var refused = 0
        func indexOf(_ key: String) -> Int? { rows.firstIndex { $0.key == key } }
        for op in ops {
            switch op {
            case .insert(let row, let before, let after):
                if indexOf(row.key) != nil { refused += 1; continue }
                guard let key = before ?? after else { rows.append(row); continue }
                guard let at = indexOf(key) else { refused += 1; continue }
                rows.insert(row, at: before == nil ? at + 1 : at)
            case .update(let key, let cells):
                guard let at = indexOf(key) else { refused += 1; continue }
                var merged = rows[at].cells
                for (name, value) in cells { merged[name] = value }
                rows[at] = Row(key: key, cells: merged)
            case .drop(let key):
                guard let at = indexOf(key) else { refused += 1; continue }
                rows.remove(at: at)
            }
        }
        return (rows, refused)
    }
}

public extension Views {
    /// The ops that turn `held` into `next` — see `ViewDiff.diff`. Named on the registry because
    /// the serve loop reads the whole view layer through one door.
    static func diff(_ held: [Row], _ next: [Row]) -> [DiffOp] { ViewDiff.diff(held, next) }
}
