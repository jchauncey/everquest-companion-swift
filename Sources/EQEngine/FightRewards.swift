// What a fight paid out, read back from the log: the kills, the experience and ability points they
// gave, and the loot and coin taken from the corpses. NOT A PORT: the combat engine does not track
// rewards, and the leveling and loot modules fold them for the whole log, not per fight.
//
// The engine returns the raw facts in the window, each with its stamp; which mob earned which line
// is decided in the app (`fightRewards`, CombatData.swift), where the pull's mobs are known. The
// window should run well past the fight's last swing: the kill message, the experience and the
// looting all come after it.
import Foundation
import EQCompanionCore
import EQLog

enum FightRewards {
    static func read(log: URL, from: Int64, to: Int64, clock: Clock, character: String?) -> JSONValue? {
        let parser = Parser(clock: clock, db: SpellDb.shared(), character: character)
        let ev = Ev(json: false)
        var deaths: [JSONValue] = [], exp: [JSONValue] = [], aa: [JSONValue] = []
        var loot: [JSONValue] = [], coin: [JSONValue] = []
        let ok = LogWindow.scan(log: log, from: from, to: to, clock: clock) { line, ts in
            guard parser.parseEvent(line, seq: 0, into: ev) else { return true }
            let p = ev.payload
            switch p.kind {
            case .death:
                var o: [String: JSONValue] = ["ts": .int(ts), "name": .string(p.str(.name) ?? ""),
                                              "bySelf": .bool(p.bool(.bySelf) ?? false)]
                if let k = p.str(.killer) { o["killer"] = .string(k) }
                deaths.append(.object(o))
            case .expGain:
                var o: [String: JSONValue] = ["ts": .int(ts), "party": .bool(p.bool(.party) ?? false)]
                if let pct = p.double(.pct) { o["pct"] = .double(pct) }
                exp.append(.object(o))
            case .aaGain:
                aa.append(["ts": .int(ts), "amount": .int(p.int(.amount) ?? 0)])
            case .loot:
                var o: [String: JSONValue] = ["ts": .int(ts), "item": .string(p.str(.item) ?? ""),
                                              "count": .int(p.int(.count) ?? 1)]
                if let s = p.str(.source) { o["source"] = .string(s) }
                if let d = p.str(.disposition) { o["disposition"] = .string(d) }
                loot.append(.object(o))
            case .coin where p.str(.source) == "corpse":
                coin.append(["ts": .int(ts), "copper": .int(copper(p.coins(.coins) ?? []))])
            default:
                break
            }
            return true
        }
        guard ok else { return nil }
        return ["deaths": .array(deaths), "exp": .array(exp), "aa": .array(aa),
                "loot": .array(loot), "coin": .array(coin)]
    }

    static func copper(_ coins: [(String, Int64)]) -> Int64 {
        coins.reduce(0) { sum, c in
            switch c.0 {
            case "platinum": return sum + c.1 * 1000
            case "gold": return sum + c.1 * 100
            case "silver": return sum + c.1 * 10
            default: return sum + c.1
            }
        }
    }
}
