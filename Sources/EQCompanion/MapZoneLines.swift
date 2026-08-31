// Where a zone's exits are, mined from the map packs already installed.
//
// WHY THIS EXISTS. The generated pack is a LABELS pack, and the labels layer is sourced from ONE
// pack (`MapFile.labelLayers`), so choosing `Labels: EQC` replaces Brewall's and Good's labels
// wholesale - and their `to_<Zone>` markers, the only thing on a dungeon map telling you where the
// way out is, go with them. A pack of mob pins that costs you the exits is a bad trade.
//
// THE SOURCE IS THE PACKS THE PLAYER ALREADY HAS, never a guess and never the wiki: a zone page
// states its adjacent zones by NAME but not where the line is (the one coordinate it does carry is
// the succor point), while the packs state a real position for every exit. So this reads their
// labels back and carries them into ours - nothing is invented, and nothing leaves the machine.
//
// WHAT COUNTS AS AN EXIT. `to_<something>` where the something names a zone the catalog knows.
// That last clause is the whole filter: `to_King`, `to_library` and `to_Ghoul_Lord` are room
// pointers wearing the same prefix, and only asking the zone catalog tells them apart. The target
// is matched through `zoneKey` and the leading-article seam, because the packs write
// `to_Greater_Faydark` where the catalog says "The Greater Faydark".
import Foundation

enum MapZoneLines {
    /// One exit: a position in map coordinates and the zone it leads to, in the catalog's spelling.
    ///
    /// `z` is the source pack's own elevation, carried through rather than flattened. The game
    /// draws map labels by height, so a door written at z=0 in a dungeon that lives at z=-200 is a
    /// door the player never sees.
    struct Marker: Equatable {
        var x: Double
        var y: Double
        var z: Double
        var zone: String
    }

    /// The zone a `to_…` label names, in the catalog's own spelling, or nil when it names no zone.
    @MainActor
    static func target(ofLabel label: String) -> String? {
        // The pack convention writes spaces as underscores; the parser has already restored them
        // for `display`, but a raw label may still carry them.
        let text = label.replacingOccurrences(of: "_", with: " ")
        guard let r = text.range(of: #"^\s*to\s+"#, options: [.regularExpression, .caseInsensitive])
        else { return nil }
        // A trailing parenthetical is a note about the exit ("(get Spire Stone…)"), not the name.
        var name = String(text[r.upperBound...])
        if let p = name.firstIndex(of: "(") { name = String(name[..<p]) }
        name = name.trimmingCharacters(in: .whitespaces)
        guard name.count > 1 else { return nil }  // "to_A", "to_B" label a door, not a zone

        let zones = GameData.shared.zones
        func match(_ s: String) -> String? {
            let k = GameData.zoneKey(s)
            guard !k.isEmpty else { return nil }
            let hit = zones.first {
                GameData.zoneKey($0.name) == k || GameData.zoneKey($0.short) == k
                    || $0.aliases.contains { GameData.zoneKey($0) == k }
            }
            // The destination must be a zone this companion COVERS, which the catalog states by
            // giving it an era. The six it leaves untagged are all post-Velious travel hubs - the
            // Plane of Knowledge, the Bazaar, the Nexus, the Guild Lobby, the Barter Hall, New
            // Sebilis - and the modern packs mark doors to them in classic zones. On this server
            // those doors are not there, and a marker for one sends a player to a wall.
            guard let hit, hit.era != nil else { return nil }
            return hit.name
        }
        if let hit = match(name) { return hit }
        // `to_Greater_Faydark` for "The Greater Faydark", and the reverse.
        for v in NameArticles.variants(of: name) {
            if let hit = match(v) { return hit }
        }
        return nil
    }

    /// How far apart two markers naming the SAME zone must be to count as two different doorways.
    ///
    /// Not a tolerance for sloppiness - a measured fact about the packs. Brewall and Good's both
    /// mark all four Lower Guk lines to Upper Guk, and their coordinates for one doorway differ by
    /// up to ~40 units (each author clicked their own map), while the doorways themselves are 150+
    /// apart. Exact-position dedupe therefore leaves eight overlapping labels where there are four
    /// doors. Anything nearer than this is two authors pointing at one door.
    static let sameDoorRadius: Double = 60

    /// The exits out of one zone: for each DESTINATION, whatever the first pack that mentions that
    /// destination says - never two packs' opinions about the same door.
    ///
    /// The union was wrong, and Nektulos Forest is why. The zone was revamped, so its door to
    /// Neriak moved: the game's own file and Brewall's `nektulos_1_original` put it at
    /// (1108, -2276), while Brewall's revamped `nektulos_1` and Good's put it at (1001, -1798).
    /// Both are honest; they describe different versions of the zone. Unioning them drew TWO "to
    /// Neriak - Foreign Quarter" labels 480 units apart, and no proximity merge can fix that
    /// without also merging doors that genuinely are that close.
    ///
    /// The destination is the right unit to claim, not the whole zone. Claiming the whole zone from
    /// one pack also removes duplicates, but it loses real exits: the game's own pack states all
    /// four Lower Guk lines to Upper Guk and says nothing about the one-way drop to Innothule, so
    /// taking Guk's exits from it alone silently deletes an exit that exists. Per destination, the
    /// game's pack answers for Upper Guk and Brewall still answers for Innothule.
    ///
    /// Discovery order puts the game's own maps first, which is the right default for a
    /// classic-era server: it ships the zone the client actually loads.
    ///
    /// Within a pack all four layers are read - the packs disagree about where an exit belongs
    /// (Brewall files them at layer 1, Good's at layer 3) - and near-identical positions still
    /// merge, because one pack can state the same door on two layers.
    @MainActor
    static func markers(zone: ZoneShort, packs: [PackIndex], excluding packId: String) -> [Marker] {
        var out: [Marker] = []
        var claimed = Set<String>()
        for p in packs where p.pack.id != packId {
            // Everything this pack says about a destination is taken together, or not at all: the
            // four doors to one zone are one pack's coherent account of them.
            var answered = Set<String>()
            for m in markers(zone: zone, from: p) where !claimed.contains(m.zone) {
                out.append(m)
                answered.insert(m.zone)
            }
            claimed.formUnion(answered)
        }
        return out
    }

    /// What one pack states, across its layers, deduped on position and target.
    @MainActor
    static func markers(zone: ZoneShort, from p: PackIndex) -> [Marker] {
        guard let byLayer = p.files[zone] else { return [] }
        var out: [Marker] = []
        for (layer, file) in byLayer.sorted(by: { $0.key < $1.key }) {
            guard let text = MapFile.readText(p.pack.dir.appendingPathComponent(file)) else { continue }
            for point in MapFile.parse(text: text, layer: layer).points {
                guard let zoneName = target(ofLabel: point.display) else { continue }
                let duplicate = out.contains {
                    $0.zone == zoneName
                        && abs($0.x - point.x) <= sameDoorRadius
                        && abs($0.y - point.y) <= sameDoorRadius
                }
                if !duplicate {
                    out.append(Marker(x: point.x, y: point.y, z: point.z, zone: zoneName))
                }
            }
        }
        return out
    }
}
