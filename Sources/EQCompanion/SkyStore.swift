// The Plane of Sky tab's state: the three modules it reads, the `/outputfile inventory` dump it
// finds on disk, the preferences it remembers, and the one recompute that turns all of that into
// 95 quest rows. The Electron equivalent is `useProgress` + `useQuestList`; the arithmetic is in
// SkyCounts/SkyProgress/SkyDerivations and this file only sequences it.
import Foundation
import Observation
import EQCompanionCore

@MainActor
@Observable
final class SkyStore {
    // MARK: Persisted preferences

    private enum Key {
        static let countSource = "eq.countSource"
        static let questFavorites = "eq.questFavorites"
        static let questIgnored = "eq.questIgnored"
        static let classFavorites = "eq.classFavorites"
        static let itemFavorites = "eq.favorites"
        static let selectedClasses = "eq.selectedClasses"
        static let islands = "eq.posky.islands"
        static let bosses = "eq.posky.bosses"
        static let sort = "eq.questSort"
        static let hideCompleted = "eq.posky.hideCompleted"
        static let hideTurnedIn = "eq.posky.hideTurnedIn"
        static let readyFirstTime = "eq.posky.readyFirstTimeOnly"
        static let targetsFirstTime = "eq.posky.targetsFirstTimeOnly"
        static let overrides = "eq.posky.itemOverrides"
        static let ledger = "eq.posky.questTurnIns"
    }

    private let defaults = UserDefaults.standard

    var countSource: SkyCountSource { didSet { defaults.set(countSource.rawValue, forKey: Key.countSource); recompute() } }
    var sort: SkySort { didSet { defaults.set(sort.rawValue, forKey: Key.sort) } }
    var selectedClasses: [String] { didSet { defaults.set(selectedClasses, forKey: Key.selectedClasses) } }
    var islands: [String] { didSet { defaults.set(islands, forKey: Key.islands) } }
    var bosses: [String] { didSet { defaults.set(bosses, forKey: Key.bosses) } }
    var hideCompleted: Bool { didSet { defaults.set(hideCompleted, forKey: Key.hideCompleted) } }
    var hideTurnedIn: Bool { didSet { defaults.set(hideTurnedIn, forKey: Key.hideTurnedIn) } }
    var readyFirstTimeOnly: Bool { didSet { defaults.set(readyFirstTimeOnly, forKey: Key.readyFirstTime); recomputeDerived() } }
    var targetsFirstTimeOnly: Bool { didSet { defaults.set(targetsFirstTimeOnly, forKey: Key.targetsFirstTime); recomputeDerived() } }
    private(set) var questFavorites: Set<String>
    private(set) var questIgnored: Set<String>
    private(set) var classFavorites: Set<String>
    private(set) var itemFavorites: Set<String>
    private(set) var overrides: [String: SkyItemOverride]
    /// Turn-ins the player recorded by hand, merged with the log's own witnesses on every read.
    private(set) var handLedger: [String: [Int64]]

    /// Not persisted, matching the Electron tab: a session-scoped narrowing, on by default.
    var hideNoItems = true
    var favoritesOnly = false
    var query = ""

    // MARK: Engine + disk inputs

    private(set) var loot: [SkyLootEvent] = []
    private(set) var turnInEvents: [SkyTurnInEvent] = []
    /// True when a module snapshot in the last `refresh` did not answer, so the quest state is
    /// partial. A reader that diffs refreshes (the celebration watch) must not take it as a baseline.
    private(set) var lastRefreshFailed = false
    private(set) var classUnlocks: [(className: String, ts: Int64)] = []
    private(set) var inventory: [String: Int] = [:]
    private(set) var inventoryPath: String?
    private(set) var inventoryUpdatedAt: Int64?
    private(set) var inventoryLoadedAt: Int64?
    private(set) var inventoryError: String?
    private(set) var loading = true

    // MARK: Derived

    private(set) var defs: [SkyQuestDef] = []
    private(set) var quests: [SkyQuestProgress] = []
    private(set) var sharedItems: [String: [SkySharedItem]] = [:]
    private(set) var ambiguousNames: Set<String> = []
    private(set) var inventoryRows: [SkyInventoryRow] = []
    private(set) var detectedInstants: [String: [Int64]] = [:]

    init() {
        countSource = SkyCountSource(rawValue: defaults.string(forKey: Key.countSource) ?? "") ?? .default
        sort = SkySort(rawValue: defaults.string(forKey: Key.sort) ?? "") ?? .default
        selectedClasses = defaults.stringArray(forKey: Key.selectedClasses) ?? []
        islands = defaults.stringArray(forKey: Key.islands) ?? []
        bosses = defaults.stringArray(forKey: Key.bosses) ?? []
        hideCompleted = defaults.bool(forKey: Key.hideCompleted)
        hideTurnedIn = defaults.bool(forKey: Key.hideTurnedIn)
        readyFirstTimeOnly = defaults.object(forKey: Key.readyFirstTime) as? Bool ?? true
        targetsFirstTimeOnly = defaults.object(forKey: Key.targetsFirstTime) as? Bool ?? true
        questFavorites = Set(defaults.stringArray(forKey: Key.questFavorites) ?? [])
        questIgnored = Set(defaults.stringArray(forKey: Key.questIgnored) ?? [])
        classFavorites = Set(defaults.stringArray(forKey: Key.classFavorites) ?? [])
        itemFavorites = Set(defaults.stringArray(forKey: Key.itemFavorites) ?? [])
        overrides = Self.decode([String: SkyItemOverride].self, defaults.data(forKey: Key.overrides)) ?? [:]
        handLedger = Self.decode([String: [Int64]].self, defaults.data(forKey: Key.ledger)) ?? [:]
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ data: Data?) -> T? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Flags

    func toggleQuestFavorite(_ key: String) {
        let k = key.lowercased()
        if questFavorites.contains(k) { questFavorites.remove(k) } else { questFavorites.insert(k) }
        defaults.set(Array(questFavorites), forKey: Key.questFavorites)
    }

    func toggleQuestIgnored(_ key: String) {
        let k = key.lowercased()
        if questIgnored.contains(k) { questIgnored.remove(k) } else { questIgnored.insert(k) }
        defaults.set(Array(questIgnored), forKey: Key.questIgnored)
        recomputeDerived()
    }

    func toggleClassFavorite(_ name: String) {
        if classFavorites.contains(name) { classFavorites.remove(name) } else { classFavorites.insert(name) }
        defaults.set(Array(classFavorites), forKey: Key.classFavorites)
        recomputeDerived()
    }

    func toggleItemFavorite(_ name: String) {
        let k = name.lowercased()
        if itemFavorites.contains(k) { itemFavorites.remove(k) } else { itemFavorites.insert(k) }
        defaults.set(Array(itemFavorites), forKey: Key.itemFavorites)
    }

    func isQuestFavorite(_ key: String) -> Bool { questFavorites.contains(key.lowercased()) }
    func isQuestIgnored(_ key: String) -> Bool { questIgnored.contains(key.lowercased()) }
    func isItemFavorite(_ name: String) -> Bool { itemFavorites.contains(name.lowercased()) }

    /// State how many of an item you hold, or clear the statement. A hand-stated count is a fact
    /// about one item at ONE MOMENT: loot after it counts on top, turn-ins after it come off, and
    /// removing it falls back to the log and the export.
    func setItemCount(_ name: String, _ count: Int?) {
        let key = SkyName.countKey(name)
        if let count {
            overrides[key] = SkyItemOverride(key: key, name: SkyName.normalize(name),
                                             count: max(0, count), setAt: nowMs())
        } else {
            overrides.removeValue(forKey: key)
        }
        defaults.set(try? JSONEncoder().encode(overrides), forKey: Key.overrides)
        recompute()
    }

    /// Record another turn-in by hand. The items it required are subtracted, so the quest goes back
    /// to what you hold toward running it again.
    func recordTurnIn(_ key: String) {
        handLedger[key, default: []].append(nowMs())
        persistLedger()
    }

    /// Take back the most recent turn-in you recorded by hand. A log-witnessed one cannot be undone
    /// here — the log is the record.
    func undoTurnIn(_ key: String) {
        let fromLog = Set(detectedInstants[key] ?? [])
        let list = handLedger[key] ?? []
        guard let cut = list.reversed().first(where: { !fromLog.contains($0) }) else { return }
        handLedger[key] = list.filter { $0 != cut }
        if handLedger[key]?.isEmpty == true { handLedger.removeValue(forKey: key) }
        persistLedger()
    }

    private func persistLedger() {
        defaults.set(try? JSONEncoder().encode(handLedger), forKey: Key.ledger)
        recompute()
    }

    // MARK: - Loading

    func refresh(_ model: AppModel) async {
        if defs.isEmpty {
            defs = SkyCatalog.quests()
            sharedItems = skyComputeSharedItems(defs)
            ambiguousNames = skyAmbiguousQuestNames(defs)
        }
        guard model.client.isReady else { loading = false; return }
        lastRefreshFailed = false
        loot = SkyLootEvent.parse(await snapshot(model, "loot"))
        turnInEvents = SkyTurnInEvent.parse(await snapshot(model, "turnins"))
        classUnlocks = (await snapshot(model, "classUnlocks")).array?.compactMap { v in
            guard let n = v["className"].string else { return nil }
            return (n, v["ts"].int64 ?? 0)
        } ?? []
        loadInventory(model)
        loading = false
        recompute()
    }

    private func snapshot(_ model: AppModel, _ module: String) async -> JSONValue {
        guard let r = try? await model.client.request(Op.moduleSnapshot, ["module": .string(module)], deadline: 15) else {
            lastRefreshFailed = true
            return .null
        }
        return r["state"]
    }

    /// Find and read the newest `/outputfile inventory` dump for the attached character. The game
    /// writes `<Name>_<server>-Inventory.txt` into the install root; the case it uses varies, so the
    /// match is case-insensitive over the directory listing rather than a constructed path.
    func loadInventory(_ model: AppModel) {
        inventoryError = nil
        guard let root = model.install?.root, let who = model.attached else {
            inventory = [:]; inventoryPath = nil; inventoryUpdatedAt = nil
            inventoryError = "No install folder or character yet."
            return
        }
        let wanted = "\(who.name)_\(who.server)-inventory.txt".lowercased()
        let fm = FileManager.default
        let listing = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        guard let url = listing.first(where: { $0.lastPathComponent.lowercased() == wanted }) else {
            inventory = [:]; inventoryPath = nil; inventoryUpdatedAt = nil
            inventoryError = "No \(who.name)_\(who.server)-Inventory.txt in \(root.path) - type /outputfile inventory in game."
            return
        }
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            inventoryError = "Could not read \(url.lastPathComponent)."
            return
        }
        inventory = SkyInventoryDump.parse(text).heldCounts
        inventoryPath = url.path
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        inventoryUpdatedAt = mtime.map { Int64($0.timeIntervalSince1970 * 1000) }
        inventoryLoadedAt = nowMs()
    }

    func reloadInventory(_ model: AppModel) {
        loadInventory(model)
        recompute()
    }

    // MARK: - The recompute

    func recompute() {
        guard !defs.isEmpty else { return }
        let logCounts = SkyHeld.counts(loot)
        let lootNames = SkyHeld.names(loot)
        let lastLooted = SkyHeld.lastLootedAt(loot)
        let detected = SkyTurnIns.detected(turnInEvents, quests: defs)
        detectedInstants = detected
        let resolved = SkyTurnIns.resolve(stored: handLedger, detected: detected)
        var logCountsByQuest: [String: Int] = [:]
        for (k, list) in detected { logCountsByQuest[k] = list.count }

        // The dump anchors the "since it was written" windows. `generatedAt` is the file's own
        // mtime — the moment the player dumped, which is the moment the file describes.
        let dumpAt = countSource.readsInventory ? inventoryUpdatedAt : nil
        let overrideInstants = overrides.mapValues(\.setAt)

        let result = skyReconcile(SkyReconcileInput(
            log: logCounts,
            inv: countSource.readsInventory ? inventory : [:],
            lootNames: lootNames,
            countSource: countSource,
            quests: defs,
            turnInCounts: resolved.all,
            detectedInstants: detected,
            overrides: overrides,
            lootSinceOverride: SkyHeld.countsAfterPerKey(loot, after: overrideInstants),
            destroyedSinceOverride: SkyHeld.destroyedAfterPerKey(loot, after: overrideInstants),
            allInstants: resolved.instants,
            dumpAt: dumpAt,
            lootSinceDump: dumpAt.map { SkyHeld.countsAfter(loot, after: $0) } ?? [:],
            destroyedSinceDump: dumpAt.map { SkyHeld.destroyedAfter(loot, after: $0) } ?? [:]))
        inventoryRows = result.rows

        let vouched = skyRewardInferredQuests(defs, inventory: inventory)
        let droppers = SkyDroppers.shared
        quests = defs.map { def in
            let q = skyComputeQuestProgress(def, held: result.net,
                                            turnInsAll: resolved.all, turnInsLog: logCountsByQuest,
                                            lastLootedAt: lastLooted, overrides: overrides,
                                            droppers: { droppers.droppers(for: $0, who: $1) })
            return skyWithRewardEvidence(q, vouched: vouched)
        }
        recomputeDerived()
    }

    // MARK: - The lists each tab draws
    //
    // Held rather than computed: the tab strip asks four of them for a count on every render, and a
    // derivation that walks 95 quests belongs behind the one recompute that can change its answer.

    /// Every quest the user has not permanently hidden.
    private(set) var visible: [SkyQuestProgress] = []
    private(set) var ignored: [SkyQuestProgress] = []
    /// Every visible quest you are holding every required item for, class then name. It ignores the
    /// two hide-boxes deliberately: "hide completed" hides exactly this predicate, so honouring it
    /// could only empty the list.
    private(set) var allReady: [SkyQuestProgress] = []
    private(set) var ready: [SkyQuestProgress] = []
    private(set) var targets = SkyTargetsModel()
    private(set) var cleanupRows: [SkyCleanupRow] = []
    private(set) var classRows: [SkyClassUnlockRow] = []
    private(set) var facets = SkyFacetOptions()

    var readyRefarmCount: Int { allReady.count - ready.count }

    var targetsRefarmCount: Int {
        targetsFirstTimeOnly ? visible.filter { $0.everTurnedIn && !$0.missing.isEmpty }.count : 0
    }

    var classNames: [String] { Array(Set(defs.map(\.className))).sorted() }

    func recomputeDerived() {
        visible = quests.filter { !isQuestIgnored($0.key) }
        ignored = quests.filter { isQuestIgnored($0.key) }
            .sorted { a, b in a.className == b.className ? a.name < b.name : a.className < b.className }
        allReady = skySortQuests(visible.filter(\.hasEveryItem), .className)
        ready = readyFirstTimeOnly ? allReady.filter { !$0.everTurnedIn } : allReady
        targets = skyTargets(visible, firstTimeOnly: targetsFirstTimeOnly)
        cleanupRows = skyCleanupRows(quests)
        classRows = skyOrderClassUnlockRows(skyClassUnlockRows(visible, observed: classUnlocks)) {
            classFavorites.contains($0.className) ? 1 : 0
        }
        facets = skyFacetOptions(visible)
    }

    /// The Quests tab's list: class, then the two facets, then the three hide-boxes, then favorites,
    /// then the search, then the chosen order with the favorite pin on top of it.
    var filtered: [SkyQuestProgress] {
        var list = visible
        if !selectedClasses.isEmpty { list = list.filter { selectedClasses.contains($0.className) } }
        if !islands.isEmpty { list = list.filter { q in skyQuestIslands(q).contains { islands.contains($0) } } }
        if !bosses.isEmpty { list = list.filter { q in skyQuestBosses(q).contains { bosses.contains($0) } } }
        if hideCompleted { list = list.filter { !$0.hasEveryItem } }
        if hideTurnedIn { list = list.filter { !$0.everTurnedIn } }
        if hideNoItems { list = list.filter { $0.needCount > 0 } }
        if favoritesOnly {
            list = list.filter { q in isQuestFavorite(q.key) || q.items.contains { isItemFavorite($0.name) } }
        }
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        if !needle.isEmpty { list = list.filter { skyQuestMatches($0, needle: needle) } }
        return skyOrderQuests(list, sort) { q in
            if isQuestFavorite(q.key) { return 2 }
            if !q.hasEveryItem && q.items.contains(where: { isItemFavorite($0.name) }) { return 1 }
            return 0
        }
    }

    /// The Quests tab's navigation: show one quest, clearing every narrowing that could hide it.
    func revealQuest(_ name: String) {
        query = name
        selectedClasses = []
        islands = []
        bosses = []
        hideCompleted = false
        hideTurnedIn = false
        hideNoItems = false
        favoritesOnly = false
    }

    func showClassQuests(_ className: String) {
        selectedClasses = [className]
    }
}
