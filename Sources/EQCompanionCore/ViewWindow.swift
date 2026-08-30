// The subscription diff protocol, applied to one window. Pure.
//
// The four rules: (1) reset-then-diffs; (2) an update carries only changed cells — an absent cell is
// unchanged, an explicit null is a clear; (3) every message carries the epoch and a client never
// reconciles across a bump; (4) rows are render-ready and this file NEVER sorts, filters or derives
// anything from them. Ops apply positionally exactly as sent; one that cannot be applied (an anchor
// the window does not hold, an update for a row it lacks) is dropped with a note and never guessed
// at — the next reset is the repair.
import Foundation

public struct ViewState: Sendable, Equatable {
    /// `nil` is the loading state: no window at all. An empty view is `[]`.
    public var rows: [Row]?
    /// How many rows the view holds in total, ignoring the window.
    public var total: Int
    public var epoch: Int?
    public var loading: Bool
    public var error: String?

    public static let loading = ViewState(rows: nil, total: 0, epoch: nil, loading: true, error: nil)

    public init(rows: [Row]?, total: Int, epoch: Int?, loading: Bool, error: String?) {
        self.rows = rows
        self.total = total
        self.epoch = epoch
        self.loading = loading
        self.error = error
    }

    public static func failed(_ message: String) -> ViewState {
        ViewState(rows: nil, total: 0, epoch: nil, loading: false, error: message)
    }
}

public enum ViewWindow {
    public static func applyReset(epoch: Int, total: Int, rows: [Row]) -> ViewState {
        ViewState(rows: rows, total: total, epoch: epoch, loading: false, error: nil)
    }

    /// Apply one coalesced batch. Returns the new state and the notes for ops that could not apply.
    public static func applyDiff(_ state: ViewState, epoch: Int, total: Int?, ops: [DiffOp]) -> (ViewState, [String]) {
        var notes: [String] = []
        guard var rows = state.rows else {
            return (state, ["diff before any reset; dropped \(ops.count) op(s)"])
        }
        for op in ops {
            switch op {
            case .insert(let row, let before, let after):
                if let i = rows.firstIndex(where: { $0.key == row.key }) {
                    // A key already in the window is replaced in place rather than duplicated.
                    rows[i] = row
                } else if let b = before {
                    if let i = rows.firstIndex(where: { $0.key == b }) { rows.insert(row, at: i) }
                    else { notes.append("insert before unknown anchor \(b)") }
                } else if let a = after {
                    if let i = rows.firstIndex(where: { $0.key == a }) { rows.insert(row, at: i + 1) }
                    else { notes.append("insert after unknown anchor \(a)") }
                } else if rows.isEmpty {
                    rows.append(row)
                } else {
                    notes.append("anchorless insert into a non-empty window (\(row.key))")
                }
            case .update(let key, let cells):
                if let i = rows.firstIndex(where: { $0.key == key }) {
                    for (k, v) in cells { rows[i].cells[k] = v }
                } else {
                    notes.append("update for a row not in the window (\(key))")
                }
            case .drop(let key):
                if let i = rows.firstIndex(where: { $0.key == key }) { rows.remove(at: i) }
                else { notes.append("drop for a row not in the window (\(key))") }
            }
        }
        let next = ViewState(rows: rows, total: total ?? state.total, epoch: epoch, loading: false, error: nil)
        return (next, notes)
    }
}
