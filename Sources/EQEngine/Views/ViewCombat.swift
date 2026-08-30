// `combat.live` — level 1 of the damage meter, cut off the fold's combat engine
// (engined/src/views/combat.rs).
//
// Two separate bundles draw this row — the Combat tab's entity row and the overlay's meter bars —
// and the cells are what both of them print: rank, name, kind, the one-word tag, a `~` ambiguity
// count, hit/resist/crit badges, total, dps, and the bar's `pct`.
//
// Rules the cells follow:
//   * The total and the rate are two cells, never the one string a bar prints: their order and
//     separator differ between the two surfaces, so composing them here would break one of them.
//   * `kind` is the engine's attribution and decides the bar's colour, which stays the renderer's;
//     `tag` is the word printed after the name, and the two are not the same map.
//   * A badge that is not shown is null, never an empty string or a zero — an absent cell means
//     unchanged and a null cell means cleared, and there is no third spelling.
//   * `pct` is a number because the bar's fill is a CSS length; every other magnitude is the
//     k/M-scaled string the reader actually sees.
//
// Outgoing only, level 1 only. A meter is a ranking, and one that interleaved incoming damage would
// put a hard-hitting mob among your group; a drill into a source's ability lanes is a different row
// shape with its own key space. Each gets its own source when its surface arrives.
import Foundation
import EQCompanionCore

public extension Views {
    /// See the file header.
    enum Combat {
        /// The registry entry. See `SourceDef`.
        public static let live = SourceDef(
            id: "combat.live",
            // `id` is a field with no cell — the row's key already is it. It is declared because the
            // tiebreak must name a field, and it is the only value guaranteed unique within a segment.
            fields: ["rank", "name", "kind", "total", "id"],
            // The meter's own ranking, which is the order the fold already put the rows in.
            //
            // No `dps` field, for arithmetic rather than taste: every row of one segment divides the
            // same duration, so a sort by dps is the sort by total.
            defaultSort: [("total", .desc)],
            tiebreak: ("id", .asc),
            defaultLimit: Views.defaultLimit)

        /// Build every row of the meter, in the fold's own ranked order.
        ///
        /// `selected` is one segment view as JSON, or null when the selection resolves to no fight at
        /// all. Read as JSON rather than as a struct because the segment view's serialization is its
        /// published contract — the same one the app's renderer reads.
        public static func rows(_ selected: JSONValue) -> [SourceRow] {
            guard let entities = selected["entities"].array else { return [] }
            return entities.enumerated().map { index, e in row(index, e) }
        }

        static func row(_ index: Int, _ e: JSONValue) -> SourceRow {
            let id = e["id"].string ?? ""
            let name = e["name"].string ?? ""
            let kind = e["kind"].string ?? ""
            let total = e["total"].int64 ?? 0
            // The rank is the meter's, not the window's: both renderers number the fold's already-ranked
            // array, so a client that sorts by name does not renumber the meter.
            let rank = Int64(index) + 1

            var cells: [String: JSONValue] = [:]
            cells["rank"] = .int(rank)
            cells["name"] = .string(name)
            cells["kind"] = .string(kind)
            cells["tag"] = kindTag(kind).map { .string($0) } ?? .null
            cells["pct"] = .double(float(e, "pct"))
            cells["total"] = .string(formatNum(Double(total)))
            cells["dps"] = .string(formatRate(float(e, "dps")))
            // The three conditional badges. Each gate is the renderer's own, and each absence is a null
            // because the diff protocol needs a cell it can clear.
            cells["crit"] = gated(float(e, "critPct") >= 1.0, "\(jsRound(float(e, "critPct")))% crit")
            cells["hit"] = gated(int(e, "misses") > 0, "\(jsRound(float(e, "hitPct")))% hit")
            cells["resist"] = gated(int(e, "resists") > 0, "\(jsRound(float(e, "resistPct")))% resist")
            // The `~` badge stands for a hit count on both surfaces, so the count is the cell. The
            // sentence the Combat tab's tooltip composes is a tab-only affordance; the overlay bars have
            // no hover.
            let ambiguous = int(e, "ambiguousHits")
            cells["ambiguous"] = ambiguous > 0 ? .int(ambiguous) : .null

            return SourceRow(key: id, cells: cells, fields: [
                ("rank", .int(rank)),
                ("name", .text(name)),
                ("kind", .text(kind)),
                ("total", .int(total)),
                ("id", .text(id))
            ])
        }

        /// The one word printed after a bar's name, or nil for a row that gets none.
        ///
        /// Mirrors the two renderers' kind-to-word maps. `you` and `enemy` get no word: the direction
        /// filter has already said which of the two the reader is looking at. `other` is not `player` —
        /// EQ spells a summoned pet's name with the same grammar it gives people, so the word must not
        /// pick one.
        static func kindTag(_ kind: String) -> String? {
            switch kind {
            case "pet": return "pet"
            case "member": return "group"
            case "allyPet": return "ally"
            case "other": return "other"
            default: return nil
            }
        }

        static func gated(_ shown: Bool, _ text: String) -> JSONValue { shown ? .string(text) : .null }

        /// The app's one spelling of a damage figure — k/M-scaled magnitude with no unit word. `21.7k`
        /// is what the pixel says, so the engine renders it rather than making the client scale and
        /// round.
        public static func formatNum(_ n: Double) -> String {
            if n >= 1_000_000.0 { return toFixed(n / 1_000_000.0, 2) + "M" }
            if n >= 1_000.0 { return toFixed(n / 1_000.0, 1) + "k" }
            return String(jsRound(n))
        }

        /// The k/M-scaled number followed by the word `dps`. The word rather than `/s`, which appears
        /// nowhere in the app.
        public static func formatRate(_ n: Double) -> String { "\(formatNum(n)) dps" }

        /// `Number.prototype.toFixed`, written out rather than left to a format specifier because the
        /// two round ties in opposite directions: ECMA-262 picks the larger integer on a tie, the
        /// platform formatter rounds half to even. Ties are common here — a damage total is an integer,
        /// and `1250` renders `1.3k` in the app but `1.2k` through `%.1f`.
        ///
        /// The tie is judged on the double, not on the decimal somebody typed: the nearest double to
        /// `21.65` is 21.6499999999999985…, which is not a tie and rounds down in both languages. So
        /// this rounds the exact decimal expansion of the double, half up, with no floating-point step —
        /// the arithmetic shortcut `floor(v * 10 + 0.5)` manufactures ties the value never had.
        public static func toFixed(_ v: Double, _ digits: Int) -> String {
            if !v.isFinite { return "\(v)" }
            // Far more digits than the answer needs: they exist only to tell a true tie from a value
            // that merely looks like one. Two doubles differ by at least one ulp (~1e-14 in the band a
            // k/M-scaled figure lives in), so twenty-five extra places settle it.
            let exact = String(format: "%.\(digits + 25)f", abs(v))
            let parts = exact.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
            let whole = String(parts[0])
            let frac = parts.count > 1 ? String(parts[1]) : ""
            let keepCount = min(digits, frac.count)
            let keep = String(frac.prefix(keepCount))
            let rest = String(frac.dropFirst(keepCount))
            var out = Array((whole + keep).utf8)
            // First dropped digit >= 5 rounds up, which covers both halves of the rule: above the tie
            // because it is nearer, on the tie because the spec says larger.
            if let first = rest.utf8.first, first >= UInt8(ascii: "5") {
                var at = out.count
                while true {
                    if at == 0 { out.insert(UInt8(ascii: "1"), at: 0); break }
                    at -= 1
                    if out[at] == UInt8(ascii: "9") { out[at] = UInt8(ascii: "0") } else { out[at] += 1; break }
                }
            }
            let sign = v < 0.0 ? "-" : ""
            let text = String(decoding: out, as: UTF8.self)
            if digits == 0 { return sign + text }
            let point = max(text.count - digits, 0)
            let idx = text.index(text.startIndex, offsetBy: point)
            return "\(sign)\(text[..<idx]).\(text[idx...])"
        }

        /// `Math.round` — round half up, which is not `rounded()` (half away from zero). They differ
        /// only for negatives; a percentage here is never one, and it is spelled out so it is not
        /// "simplified".
        public static func jsRound(_ v: Double) -> Int64 { Int64((v + 0.5).rounded(.down)) }

        static func int(_ value: JSONValue, _ key: String) -> Int64 {
            if case .int(let i) = value[key] { return i }
            return 0
        }

        static func float(_ value: JSONValue, _ key: String) -> Double { value[key].double ?? 0 }
    }
}
