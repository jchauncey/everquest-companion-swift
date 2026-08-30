// The keys (knowledge/src/names.rs). Three folds, each with exactly one definition.
//
// A name is a JOIN KEY, which is why these live here rather than at each use site: the committed
// item DB, the quest index, the posky index and the runtime overlay must key an item the same way
// four times, or a lookup answers for one spelling and not another.
import Foundation

public enum ItemNames {
    /// Strip a trailing ` +N` item-level suffix, then trim.
    ///
    /// `Cloak of Flames +4` and `Cloak of Flames` are one item to every counting boundary, and the
    /// wiki has a page for exactly one of them.
    public static func itemBaseName(_ name: String) -> String {
        stripPlusSuffix(name).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The ` +N` suffix, removed if it is there. The rule is ` \+\d+$` spelled as a scan — a trailing
    /// run of ASCII digits preceded by ` +`.
    private static func stripPlusSuffix(_ name: String) -> String {
        let u = Array(name.utf8)
        var end = u.count
        while end > 0, u[end - 1] >= 0x30, u[end - 1] <= 0x39 { end -= 1 }
        if end == u.count { return name }
        guard end >= 2, u[end - 1] == 0x2B, u[end - 2] == 0x20 else { return name }
        return String(decoding: u[0..<(end - 2)], as: UTF8.self)
    }

    /// The canonical item key, for the committed DB, the overlay and every index built over either.
    /// Strip the ` +N` suffix and fold case: loot lines and wiki titles disagree about casing
    /// constantly.
    public static func itemKey(_ name: String) -> String { itemBaseName(name).lowercased() }

    /// The DISPLAY name a lookup answers with. Identical to `itemBaseName` and named separately
    /// because the two say different things: one is a key, the other is what the card prints.
    public static func normalizeItemName(_ name: String) -> String { itemBaseName(name) }

    /// The quest index's key: `normalizeItemName` through the rename overlay, lowercased. The app's
    /// item-rename table is empty today, so no overlay is ported.
    public static func questItemKey(_ name: String) -> String { normalizeItemName(name).lowercased() }
}
