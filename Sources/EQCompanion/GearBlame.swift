// Why the gear table is empty.
//
// "No gear matches these filters" is true and useless, and the version that GUESSES which control
// is responsible is worse than useless: the table used to blame the Current era toggle whenever it
// was on, so a player looking at an item they could see on a mob's drop list was sent toggling era
// while the Classes picker - defaulted to their own class, off at the right-hand end of the row -
// was what actually hid it.
//
// So nothing here is a guess. Each active filter is DROPPED IN TURN and the corpus re-asked: a
// filter is named only when the table would hold rows without it. That makes the message
// falsifiable - it can only ever name a control that is provably hiding something - and it also
// lets the honest "these filters only empty the table together" case be said out loud.
import Foundation

/// One ACTIVE filter, named as the control that applies it.
struct GearFilter {
    /// How the empty state refers to the control, matching its on-screen label.
    var label: String
    /// The search box: what the player is LOOKING FOR, rather than a constraint laid over it.
    /// See `culprits` - an anchor is held fixed instead of being offered up as the thing to drop.
    var anchor: Bool = false
    var keeps: (GearRow) -> Bool
}

enum GearBlame {
    /// The filters whose removal - alone - would bring rows back, in the order given.
    ///
    /// The search box is deliberately not treated like the rest. "Clear your search" is technically
    /// always true when a query is set and never what the player wants to hear: they typed a name
    /// because that is the item they want. So when the query DOES match something in the corpus,
    /// it is held fixed and only the controls layered on top of it are candidates - the message
    /// becomes "you found it, and this is what is hiding it". The box is named only when nothing in
    /// the corpus answers to what was typed, which is the one case where the query is the problem.
    static func culprits(rows: [GearRow], filters: [GearFilter]) -> [String] {
        var pool = rows
        var candidates = filters
        if let anchor = filters.first(where: { $0.anchor }) {
            let matched = rows.filter(anchor.keeps)
            if matched.isEmpty { return [anchor.label] }
            pool = matched
            candidates = filters.filter { !$0.anchor }
        }
        return candidates.indices.filter { i in
            pool.contains { row in
                candidates.indices.allSatisfy { $0 == i || candidates[$0].keeps(row) }
            }
        }.map { candidates[$0].label }
    }

    /// What the search FOUND and the other controls then removed.
    ///
    /// The empty-table message cannot cover this: a query that matches four items and shows two is
    /// not empty, so nothing was ever said, and the two that vanished vanished silently - which is
    /// how a player ends up staring at a search for "Dark" that lists two swords and not the one
    /// they are looking at on a mob's drop list. Only controls that actually removed one of the
    /// query's own hits are named.
    static func hidden(rows: [GearRow], filters: [GearFilter]) -> (count: Int, labels: [String]) {
        guard let anchor = filters.first(where: { $0.anchor }) else { return (0, []) }
        let matched = rows.filter(anchor.keeps)
        guard !matched.isEmpty else { return (0, []) }
        let others = filters.filter { !$0.anchor }
        let kept = matched.filter { row in others.allSatisfy { $0.keeps(row) } }
        let count = matched.count - kept.count
        guard count > 0 else { return (0, []) }
        return (count, others.filter { f in matched.contains { !f.keeps($0) } }.map(\.label))
    }

    /// One line under the table's caption, or nil when the search is showing everything it found.
    static func hiddenText(rows: [GearRow], filters: [GearFilter]) -> String? {
        let (count, labels) = hidden(rows: rows, filters: filters)
        guard count > 0, !labels.isEmpty else { return nil }
        let what = count == 1 ? "1 more item matches your search" : "\(count) more items match your search"
        let who = labels.count == 1
            ? labels[0]
            : labels.dropLast().joined(separator: ", ") + " and " + labels[labels.count - 1]
        return "\(what) but \(who) \(labels.count == 1 ? "is" : "are") hiding \(count == 1 ? "it" : "them")."
    }

    /// A note some controls carry: what the player is likely to be wrong about, said once they have
    /// been pointed at it, never before.
    private static func aside(_ label: String) -> String? {
        switch label {
        case "the Classes picker":
            return "It defaults to the classes your log says you are playing; an item whose page states no class list is never hidden by it."
        case "the Owned or looted toggle":
            return "Ownership is read from your newest /outputfile inventory dump plus this character's loot history."
        case "the Zones picker":
            return "It keeps only gear the wiki states a drop for in those zones - quest, crafted and bought items name no zone, so they are never in a zone's list."
        default:
            return nil
        }
    }

    static func text(rows: [GearRow], filters: [GearFilter]) -> String {
        guard !filters.isEmpty else { return "No gear matches these filters." }
        let names = culprits(rows: rows, filters: filters)
        if names.count == 1, let a = filters.first(where: { $0.anchor }), a.label == names[0] {
            return "Nothing in the item database is called that."
        }
        switch names.count {
        case 0:
            return "No gear matches all of these filters at once - relaxing any single one of them still finds nothing."
        case 1:
            let s = "No gear matches these filters - \(names[0]) is hiding what is left."
            return aside(names[0]).map { "\(s) \($0)" } ?? s
        default:
            let list = names.dropLast().joined(separator: ", ") + " or " + names[names.count - 1]
            return "No gear matches these filters - relaxing \(list) would bring rows back."
        }
    }
}
