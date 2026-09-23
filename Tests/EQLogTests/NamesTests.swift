// The rank-tail fold without the regex, proven against the regex it replaced: every spell name the
// database knows, every name with each numeral appended in both cases, and the edges the pattern's
// shape makes interesting (no space, a bare numeral, trailing space, non-ASCII tails).
import XCTest
@testable import EQLog

final class NamesTests: XCTestCase {
    static let numerals = ["I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X"]

    static let edges = [
        "", " ", "I", " I", "  I", "X ", "Spell I ", "Spell  II", "Spell\tIII", "Spell\u{00A0}IV",
        "Spell XI", "Spell IIII", "Spell VX", "Spell iv", "Spell Iv", "Spell ı", "Spell İ",
        "Spell \u{0130}V", "Spell ⅣI", "Spell I I", "Rain of Fire", "Rain of Fire II",
        "Tears of Druzzil III", "Name with Ünïcödé V", "Name with Ünïcödé vi", "a b c d X",
    ]

    func corpus() -> [String] {
        var out = Self.edges
        for e in SpellDb.shared().spells.prefix(4000) {
            out.append(e.name)
            for n in Self.numerals { out.append("\(e.name) \(n)"); out.append("\(e.name) \(n.lowercased())") }
        }
        return out
    }

    func testStripRankTailMatchesTheRegex() {
        for s in corpus() {
            XCTAssertEqual(Names.stripRankTail(s), Names.stripRankTailByRegex(s), "strip: \(s.debugDescription)")
        }
    }

    func testDbCanonKeyMatchesTheRegex() {
        for s in corpus() {
            let viaRegex = JS.trim(Names.dbStripByRegex(JS.trim(s))).lowercased()
            XCTAssertEqual(Names.dbCanonKey(s), viaRegex, "dbCanonKey: \(s.debugDescription)")
        }
    }

    func testSpellRankMatchesTheRegex() {
        for s in corpus() {
            XCTAssertEqual(Names.spellRank(s), Names.spellRankByRegex(s), "rank: \(s.debugDescription)")
        }
    }
}
