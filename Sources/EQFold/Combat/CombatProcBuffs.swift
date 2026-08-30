// The proc-buff catalog (fold/src/combat/procbuffs.rs) — the curated self-buffs whose up/down span
// is worth tracking as an active state.
//
// Curated, not the whole spell DB: feeding every spell into a span tracker would flood the model
// with irrelevant states and make every co-occurrence number meaningless. A state earns a row only
// when it plausibly modulates a proc rate and its landing and wear-off messages are unambiguous in
// the shipped spell DB — otherwise the span edges would be guesses.
//
// `grantsProc` is a hint only. It pre-seeds a link label so the UI can put the two rows together; it
// never attributes a proc. A proc line names no source, so a link's strength always comes from the
// observed co-occurrence counts and the inactive-side exposure.
import Foundation

/// One tracked self-buff. Every field is copied verbatim from `spells.json` except `grantsProc`,
/// which is wiki-sourced.
public struct ProcBuffDef: Sendable {
    /// DB spell name, display casing.
    public let name: String
    /// The proc this buff grants, per the wiki.
    public let grantsProc: String?
}

public let PROC_BUFF_CATALOG: [ProcBuffDef] = [
    ProcBuffDef(name: "Instrument of Nife", grantsProc: "Condemnation of Nife")
]

/// The catalog entry a candidate spell name names, or `nil`. Case-insensitive: buff landing
/// candidates arrive in DB display casing, wears-off candidates need not.
private func procBuffFor(_ name: String) -> ProcBuffDef? {
    let key = name.lowercased()
    return PROC_BUFF_CATALOG.first { $0.name.lowercased() == key }
}

/// The first catalog entry named by a candidate list, or `nil`. Landings and wear-offs both arrive
/// as candidate lists because messages are shared between spells, so the gate is an intersection and
/// never a single-name equality.
public func procBuffInCandidates(_ candidates: [String]) -> ProcBuffDef? {
    for c in candidates { if let d = procBuffFor(c) { return d } }
    return nil
}
