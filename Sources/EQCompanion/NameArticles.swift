// The leading-article seam between two wiki spellings of one thing.
//
// A mob page's `known_loot` names an item as the loot line prints it; the item's own page is titled
// however its author titled it, and the two disagree about a leading article on 50 of the corpus's
// drop edges - `Dark Reaver` on the ghoul cavalier's page is `A Dark Reaver` as an item, and
// `A Snake Venom Sac` on one page is `Snake Venom Sac` as an item. Both directions occur, so the
// resolution has to try both.
//
// WHAT THIS IS NOT: a fuzzy matcher. A variant is only ever an article added to or removed from the
// FRONT of the name, and a variant only counts when the corpus HAS a page under that exact spelling.
// Nothing here invents a record, and nothing here reaches a second item that merely looks similar -
// so a miss stays an honest miss rather than becoming a confident wrong answer.
import Foundation

enum NameArticles {
    private static let articles = ["a ", "an ", "the "]

    /// The other spellings of `name` that differ from it only by a leading article, most likely
    /// first. Never includes `name` itself.
    static func variants(of name: String) -> [String] {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        let lower = trimmed.lowercased()
        // Already carries one: the alternative is the name without it.
        for a in articles where lower.hasPrefix(a) {
            let bare = String(trimmed.dropFirst(a.count)).trimmingCharacters(in: .whitespaces)
            return bare.isEmpty ? [] : [bare]
        }
        // Carries none: the alternatives are the name with each, "a" before "an" before "the".
        return articles.map { $0.prefix(1).uppercased() + $0.dropFirst().trimmingCharacters(in: .whitespaces) + " " + trimmed }
    }
}

extension GameData {
    /// The corpus's OWN spelling of a name, when the only thing wrong with it is a leading article.
    /// Nil when the name already resolves, or when no article variant resolves either.
    func articleVariant(domain: String, of name: String) -> String? {
        let resolves: (String) -> String?
        switch domain {
        case "item": resolves = { [weak self] in self?.items[GameData.nameKey($0)].flatMap { v in v["page"].string } }
        case "mob": resolves = { [weak self] in self?.mob(named: $0)?.name }
        default: return nil
        }
        guard resolves(name) == nil else { return nil }
        for v in NameArticles.variants(of: name) {
            if let found = resolves(v) { return found }
        }
        return nil
    }
}
