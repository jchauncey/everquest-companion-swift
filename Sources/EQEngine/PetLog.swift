// A pet's own side of a fight, read back from the log: the spells it began casting, the ones that
// were resisted, the damage it took and from whom, the heals it got, and the buffs that landed on
// it. NOT A PORT: the combat engine folds the pet's damage into the meter (its source row and
// lanes) but keeps none of this.
//
// Matched by the pet's name, case-insensitively, over the fight's window. A cast line names no
// target, so the casts are the whole window's even when the app shows one mob of a pull; damage
// taken carries its attacker, so the app can keep one mob's share.
import Foundation
import EQCompanionCore
import EQFold
import EQLog

enum PetLog {
    static func read(log: URL, from: Int64, to: Int64, pet: String, clock: Clock, character: String?) -> JSONValue? {
        let parser = Parser(clock: clock, db: SpellDb.shared(), character: character)
        let ev = Ev(json: false)
        let me = pet.lowercased()
        func isPet(_ s: String?) -> Bool { s?.lowercased() == me }

        var casts = JSMap<Int64>(), resists = JSMap<Int64>()
        var taken = JSMap<(total: Int64, hits: Int64, misses: Int64)>()
        var healedBy = JSMap<(total: Int64, raw: Int64)>()
        var buffs: [String] = []
        let ok = LogWindow.scan(log: log, from: from, to: to, clock: clock) { line, _ in
            guard parser.parseEvent(line, seq: 0, into: ev) else { return true }
            let p = ev.payload
            switch p.kind {
            case .otherCastBegin where isPet(p.str(.caster)):
                if let s = p.str(.spell) { casts.insert(s, (casts[s] ?? 0) + 1) }
            case .resist where isPet(p.str(.caster)):
                if let s = p.str(.spell) { resists.insert(s, (resists[s] ?? 0) + 1) }
            case .damage where isPet(p.str(.target)):
                let a = p.str(.attacker) ?? "unknown"
                var t = taken[a] ?? (0, 0, 0)
                t.total += p.int(.amount) ?? 0
                t.hits += 1
                taken.insert(a, t)
            case .miss where isPet(p.str(.target)):
                let a = p.str(.attacker) ?? "unknown"
                var t = taken[a] ?? (0, 0, 0)
                t.misses += 1
                taken.insert(a, t)
            case .heal where isPet(p.str(.target)):
                let h = isPet(p.str(.healer)) ? "itself" : (p.str(.healer) ?? "unknown")
                var t = healedBy[h] ?? (0, 0)
                t.total += p.int(.amount) ?? 0
                t.raw += p.int(.rawAmount) ?? p.int(.amount) ?? 0
                healedBy.insert(h, t)
            case .buffApply where isPet(p.str(.target)):
                if let s = p.str(.spell), !buffs.contains(s) { buffs.append(s) }
            default:
                break
            }
            return true
        }
        guard ok else { return nil }
        var spells = casts.keys
        for s in resists.keys where casts[s] == nil { spells.append(s) }
        return [
            "casts": .array(spells.map { ["spell": .string($0), "casts": .int(casts[$0] ?? 0), "resisted": .int(resists[$0] ?? 0)] }),
            "taken": .array(taken.keys.map { a in
                let t = taken[a]!
                return ["attacker": .string(a), "total": .int(t.total), "hits": .int(t.hits), "misses": .int(t.misses)]
            }),
            "healed": .array(healedBy.keys.map { h in
                let t = healedBy[h]!
                return ["healer": .string(h), "total": .int(t.total), "raw": .int(t.raw)]
            }),
            "buffs": .array(buffs.map { .string($0) }),
        ]
    }
}
