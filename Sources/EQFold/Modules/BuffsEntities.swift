// The buffs model's ENTITY state — a tiny parallel to the combat world model, sharing its rules.
//
// Entities, not names; disposition, not identity. A buff binds to the entity a landing message
// named, and retiring that entity censors every instance bound to its key. A "pet" is simply the
// entity currently claimed: there are no pet-specific branches in the instance store.
// (fold/src/modules/buffs_entities.rs)
import Foundation
import EQLog
import EQCompanionCore

public final class PetEntities {
    public var charmedKey: String?
    public var charmedDisplay: String?
    /// A charm that just BROKE but whose entity is not yet retired. Charm and uncharm change an
    /// entity's disposition, never its identity: the mob keeps its buffs and is merely
    /// hostile-capable until you re-charm it.
    public var brokenCharmKey: String?
    public var brokenCharmDisplay: String?
    public var summonedKey: String?
    public var summonedDisplay: String?
    /// The pet's CURRENT hostile fight target (canonical key + display), if cheaply known.
    public var petTargetKey: String?
    public var petTargetDisplay: String?
    /// Display casing for arbitrary bound entities, so the row's chip reads "Cazic-Thule" and not
    /// the lowercased key.
    public var namedEntityDisplay = JSMap<String>()

    public init() {}

    public func reset() {
        clearForGap()
        namedEntityDisplay.clear()
    }

    /// Session-gap / rebirth clear: every live pet binding goes, learned display casing stays.
    public func clearForGap() {
        charmedKey = nil
        charmedDisplay = nil
        brokenCharmKey = nil
        brokenCharmDisplay = nil
        summonedKey = nil
        summonedDisplay = nil
        petTargetKey = nil
        petTargetDisplay = nil
    }

    /// Current pet identities, for the fade classifier. During a charm-break window the ex-pet is
    /// still the SAME entity.
    private var charmedOrBroken: String? { charmedKey ?? brokenCharmKey }

    /// The current pet's canonical entity key (summoned preferred, else charmed).
    private var currentPetKey: String? { summonedKey ?? charmedKey }

    /// The current pet's display name (summoned preferred, else charmed).
    private var currentPetDisplay: String? { summonedDisplay ?? charmedDisplay }

    /// Disposition for a named message target: a live pet, else hostile.
    public func dispForNamedTarget(_ target: String) -> Disposition {
        let k = Names.idKey(target)
        if charmedKey == k { return .charmed }
        if summonedKey == k { return .summoned }
        return .hostile
    }

    /// A fade-target NAME against the current pet identities. A targetless fade is yours; the
    /// literal `pet` form prefers the SUMMONED pet and falls back to the charmed one; with no known
    /// pet it is still a pet-form fade and reads summoned.
    private func classifyFadeTarget(_ targetNameKey: String?) -> Disposition {
        guard let key = targetNameKey else { return .zelf }
        if key == "pet" {
            if summonedKey != nil { return .summoned }
            if charmedOrBroken != nil { return .charmed }
            return .summoned
        }
        if summonedKey == key { return .summoned }
        if charmedOrBroken == key { return .charmed }
        return .hostile
    }

    /// Resolve a `buffFade`'s raw target into an entity key + disposition.
    public func fadeTargetEntity(_ rawTarget: String?) -> (String, Disposition) {
        // An EMPTY target is a targetless fade, not a named one.
        guard let raw = rawTarget, !raw.isEmpty else { return (BuffsShapes.selfKey, .zelf) }
        if raw == "pet" {
            // Possessive `Your pet's …` — resolve against the CURRENT pet entity.
            let disp = classifyFadeTarget("pet")
            return (currentPetKey ?? "pet", disp)
        }
        let nameKey = Names.idKey(raw)
        return (nameKey, classifyFadeTarget(nameKey))
    }

    /// The expiry target display for a fade: targetless is self; the possessive `pet` form is the
    /// current pet's display name; a named mob is its raw name, because the fade line keeps casing.
    public func buffFadeTargetDisplay(_ rawTarget: String?, _ entityKey: String) -> String {
        guard let raw = rawTarget, !raw.isEmpty else { return BuffsShapes.selfKey }
        if raw == "pet" {
            return namedEntityDisplay[entityKey] ?? currentPetDisplay ?? "pet"
        }
        return raw
    }

    /// Map an entity key to an expiry target: self, or the entity's display name.
    public func targetDisplayFor(_ entityKey: String) -> String {
        if entityKey == BuffsShapes.selfKey { return BuffsShapes.selfKey }
        return namedEntityDisplay[entityKey] ?? entityKey
    }

    /// Best display name for an entity key (a pet, the inferred target, a named mob, else the key).
    public func entityDisplayFor(_ entityKey: String) -> String? {
        if summonedKey == entityKey { return summonedDisplay }
        if charmedKey == entityKey { return charmedDisplay }
        if petTargetKey == entityKey { return petTargetDisplay }
        if entityKey == "unknown-hostile" || entityKey == "pet" { return nil }
        return namedEntityDisplay[entityKey] ?? entityKey
    }

    /// Clear the entity from pet state if it was a pet (charmed / broken-charm / summoned).
    public func retireSlots(_ entityKey: String) {
        if charmedKey == entityKey { charmedKey = nil; charmedDisplay = nil }
        if brokenCharmKey == entityKey { brokenCharmKey = nil; brokenCharmDisplay = nil }
        if summonedKey == entityKey { summonedKey = nil; summonedDisplay = nil }
    }

    /// Zone: the charmed pet is left behind, and so is a broken-charm entity. The inferred fight
    /// target goes unconditionally.
    @discardableResult
    public func clearOnZone() -> Bool {
        var changed = false
        if charmedKey != nil { charmedKey = nil; charmedDisplay = nil; changed = true }
        if brokenCharmKey != nil { brokenCharmKey = nil; brokenCharmDisplay = nil; changed = true }
        petTargetKey = nil
        petTargetDisplay = nil
        return changed
    }
}
