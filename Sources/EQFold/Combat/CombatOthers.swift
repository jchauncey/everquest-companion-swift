// Who else is in this fight: the evidence-accreting classifier behind the record-everything meter,
// plus the active-special-attack lane state beside it (fold/src/combat/others.rs).
//
// Any combatant the log names gets a recorded row unless one of the app's stronger models claims
// the name; SCOPE filters at display time rather than at admission.
//
// It is a refusal ladder, not an inference. Nothing here decides that a name is a PERSON — the log
// cannot say that. Every rung is something the log stated and only then is the NAME SHAPE asked.
// Shape is the weakest rung and is deliberately last.
//
// The honest limit: an unbound stranger's SUMMONED PET is indistinguishable from a player by name
// alone. That is why nothing here is called a "player".
import Foundation
import EQLog
import EQCompanionCore

public final class OtherCombatants {
    /// nameKey → is it shaped like a player? Cached because the SHAPE of a name cannot change and
    /// the question is asked on every mob-vs-mob line a busy raid log carries.
    private var shapes: [String: Bool] = [:]
    /// Names a stronger model has claimed as a pet — yours, somebody else's, or self-declared. Once
    /// one speaks this ladder never books the name again and any row it already booked is
    /// retracted. Permanent for the session.
    private var pets: Set<String> = []
    /// Names that have landed damage ON YOU while shaped like a player.
    ///
    /// The rung is deliberately this narrow. The wider "it hit anything of OURS" was measured wrong
    /// on the owner's full log — dozens of real players marked as mobs, because other people in the
    /// zone attack the mob YOU have charmed.
    ///
    /// It yields to the heal stream (`clearHostile`): a heal landing on you cannot come from a mob.
    private var hostiles: Set<String> = []
    /// Recorded name keys → the log's own spelling (law 2: canonical key, raw display).
    /// Insertion-ordered because `names()` publishes it.
    private var seen: JSMap<String> = JSMap()

    public init() {}

    public func reset() {
        shapes.removeAll()
        pets.removeAll()
        hostiles.removeAll()
        seen.clear()
    }

    /// Is `name` shaped the way EQ spells a one-word proper name? Cached per key.
    public func shaped(_ name: String, _ key: String) -> Bool {
        if let hit = shapes[key] { return hit }
        let v = isPlayerShapedName(name)
        shapes[key] = v
        return v
    }

    /// A stronger model claimed this name as a pet. Returns true the FIRST time, so the caller knows
    /// whether there is a row to retract.
    @discardableResult
    public func notePet(_ key: String) -> Bool {
        if key.isEmpty || pets.contains(key) { return false }
        pets.insert(key)
        return true
    }

    public func isPet(_ key: String) -> Bool { pets.contains(key) }

    /// It landed damage on you (see `hostiles`).
    public func noteHostile(_ key: String) {
        if !key.isEmpty { hostiles.insert(key) }
    }

    /// The heal stream named it a player, which outranks a swing at you (see `hostiles`).
    public func clearHostile(_ key: String) { hostiles.remove(key) }

    public func isHostile(_ key: String) -> Bool { hostiles.contains(key) }

    /// Remember that this name has a recorded row, and how the log spells it.
    public func note(_ key: String, _ display: String) {
        if !seen.containsKey(key) { seen.insert(key, display) }
    }

    /// True once this name has booked at least one recorded row.
    public func isRecorded(_ key: String) -> Bool { seen.containsKey(key) }

    /// The log's spelling for a recorded name — the meter row's label when the roster has none.
    public func nameOf(_ key: String) -> String? { seen[key] }

    /// A recorded row was retracted — the name stops being one of ours to display.
    public func forget(_ key: String) { seen.remove(key) }
}

/// Which special attack is live in each verb lane.
///
/// Upgraded specials never announce themselves in the damage line. The game states the switch ONCE —
/// `You will now use Dragon Punch instead of Eagle Strike while attacking.` — and from then on every
/// one of those specials lands as the generic verb `strike`. This joins the log's own state line to
/// the swing by VERB.
///
/// A lane earns a row only when its generic verb is EXCLUSIVE to the chain, and only two are:
/// `strike` and `kick`. The shield lane (Slam/Bash) is not distinguishable and gets no row.
///
/// Skill-ups are not an input. Pre-state is honest by omission: until a `You will now use` line has
/// been seen for a lane this answers nothing.
///
/// SELF ONLY. The state line has no third-person grammar; the caller gates on the attacker being You.
public final class SpecialAttacks {
    /// verb lane → the special the log last SAID was active there.
    private var active: [String: String] = [:]

    public init() {}

    public func reset() { active.removeAll() }

    /// Fold one `You will now use …` line in. Returns the lane it moved, or nil when the named
    /// special belongs to no lane there is evidence for.
    ///
    /// `replaces` is deliberately not consulted: the bare GRANT form carries no `replaces` at all.
    @discardableResult
    public func note(_ skill: String) -> String? {
        guard let lane = laneOfSpecial(skill) else { return nil }
        active[lane] = JS.trim(skill)
        return lane
    }

    /// The lane label for a swing that printed `verb`, or nil to leave the parser's ordinary skill
    /// name alone — for a verb with no lane, and for a lane the log has not spoken about.
    public func laneSkill(_ verb: String?) -> String? {
        guard let verb else { return nil }
        return active[verb]
    }
}

/// verb → the specials that print with it. The order is the observed progression, but nothing reads
/// it as an ordering: membership is the contract.
private let LANES: [(String, [String])] = [
    ("strike", ["Tiger Claw", "Eagle Strike", "Dragon Punch", "Tail Rake"]),
    ("kick", ["Kick", "Round Kick", "Flying Kick"]),
]

/// The verb lane a special attack belongs to, or nil for one with no evidence behind it (Smite,
/// Backstab and Frenzy print their own verb and need no attribution; Bash/Slam is the refused lane).
public func laneOfSpecial(_ skill: String) -> String? {
    let want = JS.trim(skill).lowercased()
    for (verb, skills) in LANES where skills.contains(where: { $0.lowercased() == want }) {
        return verb
    }
    return nil
}

// MARK: - Checkpoint

extension OtherCombatants {
    /// `shapes` is carried, not rebuilt: it is a first-answer-wins cache keyed by canonical key but
    /// computed from the RAW spelling of the first sighting, and two spellings of one key can shape
    /// differently — so it is not provably pure per key.
    func checkpointState() -> JSONValue {
        .object([
            "shapes": .object(shapes.mapValues { .bool($0) }),
            "pets": ckStringSet(pets),
            "hostiles": ckStringSet(hostiles),
            "seen": seen.checkpoint { .string($0) },
        ])
    }

    func restoreCheckpoint(_ v: JSONValue) -> Bool {
        reset()
        guard let shapesObj = v["shapes"].object,
              let petsV = ckStringSetBack(v["pets"]),
              let hostilesV = ckStringSetBack(v["hostiles"]),
              let seenV = JSMap<String>.fromCheckpoint(v["seen"], { $0.string }) else {
            reset()
            return false
        }
        var newShapes: [String: Bool] = [:]
        for (k, val) in shapesObj {
            guard let b = val.bool else { reset(); return false }
            newShapes[k] = b
        }
        shapes = newShapes
        pets = petsV
        hostiles = hostilesV
        seen = seenV
        return true
    }
}

extension SpecialAttacks {
    func checkpointState() -> JSONValue {
        .object(active.mapValues { .string($0) })
    }

    func restoreCheckpoint(_ v: JSONValue) -> Bool {
        reset()
        guard let obj = v.object else { return false }
        var out: [String: String] = [:]
        for (k, val) in obj {
            guard let s = val.string else { return false }
            out[k] = s
        }
        active = out
        return true
    }
}
