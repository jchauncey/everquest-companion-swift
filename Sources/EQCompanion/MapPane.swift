// The PURE half of the Maps tab's right-hand pane: what is in this zone, and where.
//
// A port of `src/renderer/src/features/maps/mobPins.ts`. The pane answers one question with TWO
// authorities and never lets them blur into one:
//
//   1. THE WIKI'S BESTIARY — the committed mob catalog, joined to the zone on screen by the same
//      fold the Mobs tab uses (`GameData.mobs(inLogZone:)`). Not re-implemented here: two folds
//      that could disagree about a zone would be an invisible bug.
//   2. THE MAP FILE'S OWN LABELS — `MapData.points`, already extracted by the parser.
//
// COORDINATES ARE REAL OR THEY ARE ABSENT. A mob is PINNED only when its wiki page stated
// numbers under `location`; a mob whose page says "Various" or "?" is still listed — it lives
// here, that is a fact — with no pin and nothing that looks like one. There is no interpolation,
// no zone-centre fallback, no "probably near the entrance". A page that names SEVERAL zones and
// one position cannot say which zone the position belongs to, so it gets no pin either and says
// so per row.
//
// THE CONVERSION IS `MapGeo.mapFromLoc` AND NOTHING ELSE — the same seam the typed `/loc` marker
// crosses.
import Foundation

/// One stated spawn position, already in map coordinates.
struct MobPin: Sendable, Equatable {
    var x: Double
    var y: Double
    /// The page's own elevation, when it stated one — 2% of positions do. Nil is NOT zero: a label
    /// written at zero in a dungeon that lives below it is one the game will not draw, so a nil
    /// here is answered from the map's own geometry rather than filled in with a number.
    var z: Double?
    /// The page's OWN percentage, verbatim — never rounded into "likely" or "rare".
    var pct: Double?
}

/// A pane row: a wiki mob, or one of this map file's own label points.
struct MapPaneRow: Identifiable, Equatable {
    enum Kind: Equatable { case mob, label }

    var kind: Kind
    var id: String
    var name: String
    var level: String?
    /// The `MobNameConvention.isNamed` verdict, stamped when the row is built (the rare-loot leg
    /// needs the item corpus, which the pure grouping must not reach for). Labels are never named.
    var named = false
    var pins: [MobPin]
    var zoneCount: Int
    /// The page stated a position but names several zones, so it cannot be attributed here.
    var unattributable: Bool
    /// Set when `mobLocFixes.json` replaced the wiki's position: the reason, for the row's note.
    var locFix: String?
    var searchKey: String
    var point: MapPoint?

    /// Where clicking this row centres the map, or nil when nothing stated a position.
    var target: MapXY? {
        if let p = point { return MapXY(x: p.x, y: p.y) }
        guard let first = pins.first else { return nil }
        return MapXY(x: first.x, y: first.y)
    }

    var locatable: Bool { target != nil }

    /// The line under the name. Says which of the two authorities fell short, per row.
    var note: String? {
        guard kind == .mob else { return nil }
        if unattributable { return "position stated, but the page lists \(zoneCount) zones" }
        if pins.isEmpty { return "no location on the wiki page" }
        if locFix != nil { return pins.count > 1 ? "\(pins.count) spawn points \u{00B7} corrected" : "position corrected" }
        return pins.count > 1 ? "\(pins.count) spawn points" : nil
    }
}

/// The one classifier for named vs common everywhere in the app — the Maps pane's split and
/// `MapAnnotations.Filter` both ask here, so the pack generator and the on-screen groups can
/// never disagree about a mob.
///
/// Three signals, any one of which makes a mob NAMED:
///   1. A capitalized name — the wiki's own convention ("Skeleton Lrodd", "Raster of Guk").
///   2. A "the " prefix — the definite article is the wiki naming a unique ("the ghoul lord").
///   3. A SINGLE fixed level AND loot few others drop. This wiki spells most camp nameds like
///      common spawns ("a ghoul sage", "a frenzied ghoul"), but a named is one creature — its
///      page states one level, not a range — and its reason to exist is its drop. Either half
///      alone is far too loose (half the trash in the bestiary states one level; plenty of
///      trash is the sole recorded dropper of nothing), together they recover exactly the camp
///      rosters ("a ghoul executioner" in, "a dar ghoul knight" out).
enum MobNameConvention {
    static func isCommon(_ name: String) -> Bool {
        name.first.map { $0.isLowercase } ?? true
    }

    /// One stated level, no range, no "~", no "?" — the page describes a single creature.
    static func singleLevel(_ level: String?) -> Bool {
        guard let l = level?.trimmingCharacters(in: .whitespaces), !l.isEmpty else { return false }
        return l.allSatisfy(\.isNumber)
    }

    static func isNamed(_ name: String, level: String?, dropsRareLoot: Bool) -> Bool {
        if !isCommon(name) { return true }
        if name.lowercased().hasPrefix("the ") { return true }
        return singleLevel(level) && dropsRareLoot
    }
}

enum MapPaneRows {
    /// Pins draw before the pane is filtered, so a zone with thousands of stated positions can
    /// never stall a frame. The chip says when the cap bit.
    static let maxPins = 400

    static func pins(_ mob: GameData.Mob) -> [MobPin] {
        mob.loc.compactMap { l in
            guard let ns = l["ns"].double, let ew = l["ew"].double else { return nil }
            let stated = l["z"].double
            let p = MapGeo.mapFromLoc(EqLoc(ns: ns, ew: ew, z: stated ?? 0))
            // The projection's z is the page's own when it gave one, and meaningless when it did
            // not - so an unstated elevation stays absent rather than becoming a zero.
            return MobPin(x: p.x, y: p.y, z: stated == nil ? nil : p.z, pct: l["pct"].double)
        }
    }

    /// The wiki's rows for the zone on screen. The zone JOIN is `GameData.mobs(inLogZone:)` —
    /// the same fold the Mobs tab uses, never a second one.
    @MainActor
    static func mobRows(zoneName: String) -> [MapPaneRow] {
        rows(from: GameData.shared.mobs(inLogZone: zoneName),
             rareLoot: { GameData.shared.dropsRareLoot($0) })
    }

    /// Catalog entries to pane rows, level-ascending then by name — the Mobs tab's order.
    /// `rareLoot` answers the third leg of the named verdict (see `MobNameConvention.isNamed`).
    static func rows(from catalog: [GameData.Mob],
                     rareLoot: (String) -> Bool = { _ in false }) -> [MapPaneRow] {
        func sortLevel(_ m: GameData.Mob) -> Int? {
            guard let r = m.level.range(of: #"\d+"#, options: .regularExpression) else { return nil }
            return Int(m.level[r])
        }
        let mobs = catalog.sorted { a, b in
            let la = sortLevel(a), lb = sortLevel(b)
            if la != lb {
                if la == nil { return false }
                if lb == nil { return true }
                return la! < lb!
            }
            let na = a.name.lowercased(), nb = b.name.lowercased()
            if na != nb { return na < nb }
            return a.page < b.page
        }
        return mobs.map { m in
            let zoneCount = m.zones.count
            let ambiguous = zoneCount > 1
            let all = pins(m)
            return MapPaneRow(kind: .mob,
                              id: m.page,
                              name: m.name,
                              level: m.level.isEmpty ? nil : m.level,
                              named: MobNameConvention.isNamed(m.name, level: m.level,
                                                              dropsRareLoot: rareLoot(m.name)),
                              pins: ambiguous ? [] : all,
                              zoneCount: zoneCount,
                              unattributable: ambiguous && !all.isEmpty,
                              locFix: ambiguous ? nil : m.locFix,
                              searchKey: "\(m.name) \(m.level)".lowercased(),
                              point: nil)
        }
    }

    /// The map file's own labels. The legend layer is never listed — it is a colour key, not a
    /// place.
    static func labelRows(_ points: [MapPoint]) -> [MapPaneRow] {
        points.filter { $0.layer != MapFile.legendLayer }.map { p in
            MapPaneRow(kind: .label,
                       id: "\(p.label)#\(p.x),\(p.y),\(p.layer)",
                       name: p.display,
                       level: nil,
                       pins: [],
                       zoneCount: 0,
                       unattributable: false,
                       searchKey: p.display.lowercased(),
                       point: p)
        }
    }

    /// Every word must appear somewhere in the row — the same substring-AND the Electron pane
    /// uses, so the two apps agree about what a query matches.
    static func filter(_ rows: [MapPaneRow], query: String) -> [MapPaneRow] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        if words.isEmpty { return rows }
        return rows.filter { r in words.allSatisfy { r.searchKey.contains($0) } }
    }

    /// The pane's two mob groups, each alphabetical: named and rare mobs first, common spawns
    /// under them. A group whose toggle is off comes back EMPTY — the caller renders nothing for
    /// it and, because the pins are drawn from these same rows, its positions leave the map too.
    struct Grouped: Equatable {
        var named: [MapPaneRow] = []
        var common: [MapPaneRow] = []
        var all: [MapPaneRow] { named + common }
    }

    static func grouped(_ rows: [MapPaneRow], showNamed: Bool, showCommon: Bool) -> Grouped {
        func alpha(_ a: MapPaneRow, _ b: MapPaneRow) -> Bool {
            let na = a.name.lowercased(), nb = b.name.lowercased()
            return na != nb ? na < nb : a.id < b.id
        }
        var g = Grouped()
        for row in rows where row.kind == .mob {
            if row.named {
                if showNamed { g.named.append(row) }
            } else if showCommon {
                g.common.append(row)
            }
        }
        g.named.sort(by: alpha)
        g.common.sort(by: alpha)
        return g
    }

    struct PlacedPin: Identifiable {
        var id: String
        var rowId: String
        var name: String
        var pin: MobPin
    }

    static func placedPins(_ rows: [MapPaneRow], limit: Int = maxPins) -> (pins: [PlacedPin], capped: Bool) {
        var out: [PlacedPin] = []
        for row in rows {
            for (i, pin) in row.pins.enumerated() {
                if out.count >= limit { return (out, true) }
                out.append(PlacedPin(id: "\(row.id)#\(i)", rowId: row.id, name: row.name, pin: pin))
            }
        }
        return (out, false)
    }

    struct Counts: Equatable {
        var mobs = 0
        var located = 0
        var labels = 0
    }

    static func counts(mobs: [MapPaneRow], labels: [MapPaneRow]) -> Counts {
        Counts(mobs: mobs.count,
               located: mobs.reduce(0) { $0 + ($1.pins.isEmpty ? 0 : 1) },
               labels: labels.count)
    }
}

// MARK: - Which zone the map is showing

/// Follow the character, or stay on the zone the user picked. Persisted so the tab reopens where
/// it was left.
struct MapZoneSelection: Equatable {
    static let zoneKey = "eq.maps.zone"
    static let modeKey = "eq.maps.zoneMode"

    var zone: ZoneShort?
    var pinned: Bool

    static func load(_ d: UserDefaults = .standard) -> MapZoneSelection {
        let raw = d.string(forKey: zoneKey)
        let zone = (raw?.isEmpty ?? true) ? nil : raw
        return MapZoneSelection(zone: zone, pinned: d.string(forKey: modeKey) == "pinned" && zone != nil)
    }

    func save(_ d: UserDefaults = .standard) {
        d.set(pinned ? "pinned" : "follow", forKey: Self.modeKey)
        if let zone { d.set(zone, forKey: Self.zoneKey) }
    }

    /// The character zoned. A pinned map ignores it; a following map moves.
    func onCharacterZone(_ auto: ZoneShort?) -> MapZoneSelection {
        if pinned { return self }
        if zone == auto { return self }
        return MapZoneSelection(zone: auto, pinned: false)
    }

    /// Picking a zone by hand pins it — zoning must not yank the map out from under the user.
    static func onPick(_ zone: ZoneShort) -> MapZoneSelection {
        MapZoneSelection(zone: zone, pinned: true)
    }

    /// "Current zone": go back to the character's zone and follow it again. When the log has not
    /// stated a zone yet there is nothing to go to, so only the mode changes.
    func onFollowCurrent(_ auto: ZoneShort?, stated: Bool) -> MapZoneSelection {
        MapZoneSelection(zone: stated ? auto : zone, pinned: false)
    }
}
