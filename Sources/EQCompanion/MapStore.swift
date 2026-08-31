// The Maps tab's data owner: scan the pack directories once, parse one zone at a time off the
// main actor, keep the last few parses.
//
// The Electron app does this in the main process and ships the result over IPC; here the same
// pure functions (MapFiles.swift) run in a detached task, because a 1.2 MB zone file is ~26k
// segments and parsing it inline would drop frames on the tab that is drawing them.
import Foundation
import Observation

@MainActor
@Observable
final class MapStore {
    /// Installed packs, in resolution order for geometry.
    private(set) var packs: [MapPack] = []
    /// Every zone stem any pack provides, ascending.
    private(set) var zones: [ZoneShort] = []
    /// True once the first scan finished — before that, "no maps" is not yet a fact.
    private(set) var ready = false
    private(set) var scanError: String?

    private(set) var data: MapData?
    private(set) var error: String?
    private(set) var loading = false

    @ObservationIgnored private var indexes: [PackIndex] = []
    @ObservationIgnored private var scannedRoot: URL?
    /// Insertion-ordered = LRU. Worst case ~1 MB each, so a handful is a few MB.
    @ObservationIgnored private var cache: [(key: String, data: MapData)] = []
    @ObservationIgnored private var cacheMax = 6
    @ObservationIgnored private var loadedKey: String?
    @ObservationIgnored private var token = 0

    /// Forget the last scan so the next `scan` really walks the disk — for after a pack was
    /// written or deleted while the app runs.
    func invalidateScan() {
        scannedRoot = URL(fileURLWithPath: "/nonexistent-\(token)")
        ready = false
    }

    /// Re-scan when the install root changes. A nil root is the "EverQuest folder not found"
    /// case, which is an empty list and a prose empty state — never an error dialog.
    func scan(root: URL?) async {
        if ready, scannedRoot == root { return }
        scannedRoot = root
        let userPacks = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("EQCompanion/mappacks")
        let found = await Task.detached(priority: .userInitiated) {
            MapFile.discoverPacks(eqRoot: root, userPacksRoot: userPacks)
        }.value
        indexes = found
        packs = found.map(\.pack)
        zones = MapFile.zoneStems(found)
        scanError = root == nil
            ? "No EverQuest folder is set, so no map packs were found. Point Preferences at your EverQuest Legends folder."
            : nil
        ready = true
        // A pack list that just arrived invalidates nothing parsed, but the zone we were asked
        // for may only now be resolvable.
        loadedKey = nil
    }

    /// Parse (or serve from cache) one zone under a per-layer pack preference.
    func load(zone: ZoneShort?, prefs: MapPackPrefs) async {
        guard ready else { return }
        guard let zone, !zone.isEmpty else {
            data = nil
            error = nil
            loading = false
            loadedKey = nil
            return
        }
        let key = prefs.cacheKey(zone)
        if loadedKey == key { return }
        if let hit = cache.first(where: { $0.key == key }) {
            touch(key)
            data = hit.data
            error = nil
            loading = false
            loadedKey = key
            return
        }
        token += 1
        let mine = token
        loading = true
        let idx = indexes
        let parsed = await Task.detached(priority: .userInitiated) {
            MapFile.load(idx, zone: zone, prefs: prefs)
        }.value
        guard mine == token else { return } // a newer request won
        loading = false
        loadedKey = key
        if let parsed {
            cache.append((key, parsed))
            if cache.count > cacheMax { cache.removeFirst() }
            data = parsed
            error = nil
        } else {
            data = nil
            error = "No map files for zone \u{201C}\(zone)\u{201D} in any installed pack."
        }
    }

    private func touch(_ key: String) {
        guard let at = cache.firstIndex(where: { $0.key == key }) else { return }
        let row = cache.remove(at: at)
        cache.append(row)
    }
}
