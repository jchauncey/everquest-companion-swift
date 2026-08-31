// The wiki markup that survives into a record's prose, and the links inside it.
//
// An item's `statsBlock` is the wiki's own text, and the wiki writes its cross-references as
// markup: `Effect: [[Soul Leech|<span class='itemeff'>Soul Leech</span>]] (Combat, …)`. Shown
// verbatim that is unreadable, and shown flattened it throws away the one thing the line is FOR -
// the effect has a page saying what it does, and the player wants to read it.
//
// So the block is split into runs of plain text and links. The link's TARGET is the page name (the
// half before the pipe); its DISPLAY is the half after, with HTML tags stripped, because the wiki's
// display half is styled markup rather than prose. `[[Steal Strength]]` has no pipe and is both.
//
// Nothing here rewrites the corpus - the record still carries exactly what the engine sent. This is
// display, at the last moment, which is the only place markup should ever be interpreted.
import Foundation

enum WikiMarkup {
    struct Run: Equatable {
        var text: String
        /// The page this run links to, or nil for plain prose.
        var link: String?
    }

    private static let tag = try! NSRegularExpression(pattern: "<[^>]+>")

    /// Strip HTML tags. The surrounding whitespace is PROSE and is left alone: the space after
    /// "Effect:" is what keeps the label off the link when the runs are laid end to end.
    static func stripTags(_ s: String) -> String {
        let range = NSRange(s.startIndex..., in: s)
        return tag.stringByReplacingMatches(in: s, range: range, withTemplate: "")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }

    /// A page name: tags off and trimmed, because a link's own halves are markup, not prose.
    private static func pageName(_ s: String) -> String {
        stripTags(s).trimmingCharacters(in: .whitespaces)
    }

    /// One line of wiki prose split into plain runs and link runs, in order.
    static func runs(_ line: String) -> [Run] {
        var out: [Run] = []
        var rest = Substring(line)
        while let open = rest.range(of: "[["), let close = rest.range(of: "]]", range: open.upperBound..<rest.endIndex) {
            let before = stripTags(String(rest[rest.startIndex..<open.lowerBound]))
            if !before.isEmpty { out.append(Run(text: before, link: nil)) }
            let inner = String(rest[open.upperBound..<close.lowerBound])
            let parts = inner.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            let target = pageName(String(parts.first ?? ""))
            let shown = parts.count > 1 ? pageName(String(parts[1])) : target
            if !target.isEmpty { out.append(Run(text: shown.isEmpty ? target : shown, link: target)) }
            rest = rest[close.upperBound...]
        }
        let tail = stripTags(String(rest))
        if !tail.isEmpty { out.append(Run(text: tail, link: nil)) }
        return out
    }

    /// True when a line carries markup worth interpreting - the cheap test that keeps every other
    /// line on the plain path.
    static func hasMarkup(_ s: String) -> Bool { s.contains("[[") || s.contains("<") }
}
