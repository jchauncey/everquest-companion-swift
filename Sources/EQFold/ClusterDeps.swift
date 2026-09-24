// The construction inputs and the wiring (fold/src/lib.rs `ClusterDeps`, `registered`).
import Foundation
import EQLog
import EQCompanionCore

public struct ClusterDeps {
    public var knownSpell: Set<String> = []
    public var spellClasses: SpellClassIndex = [:]
    public var launchMs: Int64 = 0
    public var constructionNowMs: Int64 = 0
    public var character: JSONValue? = nil
    public var selfName: String? = nil
    public var respawnPrefs: RespawnPrefs = RespawnPrefs()
    public var facts: SpellFacts = SpellFacts()
    public init() {}
}

/// Registration in wiring order. combo first (every later module sees an advanced combo state),
/// roster second (the engine's admission gate pulls it), respawn beside kills, eventFeed last.
public func registered(_ deps: ClusterDeps) -> Registry {
    let r = Registry()
    r.register(ComboModule(spellClasses: deps.spellClasses, launchMs: deps.launchMs))
    r.register(RosterModule(selfName: deps.selfName))
    r.register(LootModule())
    r.register(TurnInsModule())
    r.register(ClassUnlocksModule())
    r.register(KillsModule())
    r.register(RespawnModule(constructionNowMs: deps.constructionNowMs, prefs: deps.respawnPrefs))
    r.register(ProgressionModule())
    r.register(LevelingModule())
    r.register(CharacterModule(character: deps.character))
    r.register(OutputFilesModule())
    r.register(SpellSetsModule())
    r.register(ItemTiersModule())
    r.register(ObservedSpellRanksModule(knownSpell: deps.knownSpell))
    r.register(AlertsModule())
    let core = BuffsModule.sharedCore(deps.facts)
    r.register(BuffsModule(facts: deps.facts, core: core))
    r.register(BuffTimersModule(core: core))
    r.register(ConsiderModule())
    r.register(ResistModule())
    r.register(EventFeedModule())
    // Swift-only, and last: nothing upstream reads it, so it changes no ported module's delivery.
    r.register(SalesModule())
    return r
}
