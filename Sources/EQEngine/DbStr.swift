// fold/src/dbstr.rs — the client's string table (`<eqRoot>/dbstr_us.txt`), parsed: the words behind
// the category ids `spells_us.txt` stores.
//
// Pure over bytes, exactly as `SpellsUs` is: no file, no thread, no state. The IO belongs to whoever
// owns the directory (`ClientSpells`).
//
// Every row is `id^type^string^flag^`, and `type` partitions the file into unrelated namespaces
// (races, tooltips, achievements, …). Type 5 is the spell-category namespace: small and closed, 179
// rows on a current install. Every id appearing in field 86 or 87 is named by type 5, so a reader
// never has to invent a word.
//
// Unlike `SpellsUs` this is not a port of a shipped TypeScript parser, so it parses in ordinary
// arithmetic rather than through `jsNumber`: there is no second implementation to agree with.
import Foundation

public enum DbStr {
    /// The `type` column that partitions `dbstr_us.txt` into namespaces. Type 5 is the
    /// spell-category vocabulary — the words the in-game window prints in its Category column.
    static let SPELL_CATEGORY_TYPE: [UInt8] = Array("5".utf8)

    /// The narrowest row this parser will read: `id^type^string`. Real rows carry five fields, but
    /// nothing reads past the third, so the bound is stated at the need rather than at the file's
    /// observed width — a client patch that appends a column must not empty this table.
    static let MIN_FIELDS = 3

    /// Category id → the word the game prints for it.
    public typealias CategoryNames = [UInt32: String]

    /// Parse `dbstr_us.txt` text, keeping only the spell-category namespace.
    public static func parseSpellCategories(_ text: String) -> CategoryNames {
        parse(Array(text.utf8), SpellsUs.utf8)
    }

    /// Parse the client's own latin-1 bytes.
    public static func parseSpellCategories(latin1 bytes: [UInt8]) -> CategoryNames {
        parse(bytes, SpellsUs.latin1)
    }

    /// The filters, in order: a trailing `\r` is stripped from the line (it lands on the last column
    /// today, but a name is both a display string and a join key); an empty line, a row with fewer
    /// than `MIN_FIELDS` fields, a `type` other than `SPELL_CATEGORY_TYPE`, a non-`UInt32` id and an
    /// empty name are all skipped rather than guessed at. Filtering by type is why a 9.4 MB table
    /// becomes a map of 179 entries.
    ///
    /// First-wins on a repeated id, matching `parseSpellsUs`. No install carries a duplicate today;
    /// the rule exists so that a patch introducing one gives a stable answer rather than a
    /// build-order-dependent one.
    static func parse(_ bytes: [UInt8], _ decode: SpellsUs.Decode) -> CategoryNames {
        var out = CategoryNames()
        var fields: [Range<Int>] = []
        let n = bytes.count
        var lineStart = 0
        while true {
            var lineEnd = lineStart
            while lineEnd < n, bytes[lineEnd] != 0x0A { lineEnd += 1 }
            let next = lineEnd + 1
            var end = lineEnd
            if end > lineStart, bytes[end - 1] == 0x0D { end -= 1 }
            if end > lineStart {
                fields.removeAll(keepingCapacity: true)
                var fieldStart = lineStart
                var i = lineStart
                while i < end {
                    if bytes[i] == 0x5E { // '^'
                        fields.append(fieldStart..<i)
                        fieldStart = i + 1
                    }
                    i += 1
                }
                fields.append(fieldStart..<end)
                if fields.count >= MIN_FIELDS,
                   equals(bytes[fields[1]], SPELL_CATEGORY_TYPE),
                   let id = parseU32(bytes[fields[0]]),
                   !fields[2].isEmpty,
                   out[id] == nil {
                    out[id] = decode(bytes[fields[2]])
                }
            }
            if lineEnd >= n { break }
            lineStart = next
        }
        return out
    }

    private static func equals(_ a: ArraySlice<UInt8>, _ b: [UInt8]) -> Bool {
        a.count == b.count && !zip(a, b).contains { $0 != $1 }
    }

    /// `str::parse::<u32>` — an optional `+`, then at least one ASCII digit, and nothing else.
    static func parseU32(_ s: ArraySlice<UInt8>) -> UInt32? {
        var i = s.startIndex
        if i < s.endIndex, s[i] == 0x2B { i += 1 } // '+'
        if i == s.endIndex { return nil }
        var v: UInt64 = 0
        while i < s.endIndex {
            let b = s[i]
            guard b >= 0x30, b <= 0x39 else { return nil }
            v = v * 10 + UInt64(b - 0x30)
            if v > UInt64(UInt32.max) { return nil }
            i += 1
        }
        return UInt32(v)
    }
}
