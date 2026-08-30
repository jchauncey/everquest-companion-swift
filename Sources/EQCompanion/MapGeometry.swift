// The PURE map-viewer geometry: the projection, the /loc seam, the floor bands and the label
// declutter. A port of `src/renderer/src/features/maps/mapGeometry.ts`, `floorSlice.ts`,
// `labelLayout.ts` and `locMarker.ts`.
//
// ONE STATE, BOTH PROJECTIONS DERIVED. The camera is `{cx, cy, scale}` — the map coordinate
// under the centre of the viewport, plus points per map unit. Centre+scale rather than a rect
// because the scale is UNIFORM on both axes by construction: a rect window would silently
// stretch a zone whose aspect differs from the pane's, and a stretched map is a lie about
// distance.
//
// THERE IS NO NEGATION AT RENDER TIME. Map-file y grows SOUTH, which is the same direction
// screen y grows, so the projection is a pure scale-and-translate on BOTH axes. A `-` on y here
// renders every zone mirrored north-for-south. The file format's own negation is already baked
// into the bytes on disk; `mapFromLoc` below is where a typed `/loc` crosses over, and it is the
// ONLY place that conversion happens.
import Foundation

// MARK: - The camera

struct MapXY: Equatable, Sendable {
    var x: Double
    var y: Double
}

struct MapScreenPos: Equatable, Sendable {
    var px: Double
    var py: Double
}

struct MapViewRect: Equatable, Sendable {
    var minX: Double
    var minY: Double
    var maxX: Double
    var maxY: Double
}

/// The map coordinate under the viewport centre, plus points per map unit.
struct MapCamera: Equatable, Sendable {
    var cx: Double
    var cy: Double
    var scale: Double
}

/// An EverQuest `/loc` reading, in the game's own axes.
struct EqLoc: Equatable, Sendable, Codable {
    /// North/south — the FIRST number the game prints.
    var ns: Double
    /// West/east — the SECOND.
    var ew: Double
    /// Elevation.
    var z: Double
}

enum MapGeo {
    /// Layer visibility, indexed by layer. Legend off by default.
    static let defaultLayers: [Bool] = [true, true, false, true]
    static let fitPad = 0.04
    static let zoomStep = 1.35
    static let minZoom = 0.25
    static let maxZoom = 200.0
    static let minSpan = 1.0

    // ---- THE ONE /loc -> map SEAM ----
    //
    // `/loc` prints north/south first and west/east second, and both run opposite to the map
    // file's x/y. Every mark on the map — the typed marker and every wiki mob pin — crosses over
    // here and nowhere else.

    static func mapFromLoc(_ loc: EqLoc) -> (x: Double, y: Double, z: Double) {
        (x: -loc.ew, y: -loc.ns, z: loc.z)
    }

    static func locFromMap(x: Double, y: Double, z: Double) -> EqLoc {
        EqLoc(ns: -y, ew: -x, z: z)
    }

    // ---- projection ----

    private static func spanOf(_ lo: Double, _ hi: Double) -> Double { max(minSpan, hi - lo) }

    static func fitScale(_ bounds: MapBounds, _ vp: CGSize, pad: Double = fitPad) -> Double {
        if vp.width <= 0 || vp.height <= 0 { return 1 }
        let sx = Double(vp.width) / spanOf(bounds.minX, bounds.maxX)
        let sy = Double(vp.height) / spanOf(bounds.minY, bounds.maxY)
        return min(sx, sy) * (1 - pad)
    }

    static func fit(_ bounds: MapBounds, _ vp: CGSize, pad: Double = fitPad) -> MapCamera {
        MapCamera(cx: (bounds.minX + bounds.maxX) / 2,
                  cy: (bounds.minY + bounds.maxY) / 2,
                  scale: fitScale(bounds, vp, pad: pad))
    }

    static func project(_ c: MapCamera, _ vp: CGSize, _ p: MapXY) -> MapScreenPos {
        MapScreenPos(px: Double(vp.width) / 2 + (p.x - c.cx) * c.scale,
                     py: Double(vp.height) / 2 + (p.y - c.cy) * c.scale)
    }

    static func unproject(_ c: MapCamera, _ vp: CGSize, _ s: MapScreenPos) -> MapXY {
        MapXY(x: c.cx + (s.px - Double(vp.width) / 2) / c.scale,
              y: c.cy + (s.py - Double(vp.height) / 2) / c.scale)
    }

    static func viewRect(_ c: MapCamera, _ vp: CGSize) -> MapViewRect {
        let halfW = Double(vp.width) / (2 * c.scale)
        let halfH = Double(vp.height) / (2 * c.scale)
        return MapViewRect(minX: c.cx - halfW, minY: c.cy - halfH, maxX: c.cx + halfW, maxY: c.cy + halfH)
    }

    static func expand(_ r: MapViewRect, by m: Double) -> MapViewRect {
        MapViewRect(minX: r.minX - m, minY: r.minY - m, maxX: r.maxX + m, maxY: r.maxY + m)
    }

    private static func clampTo(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        min(max(v, min(lo, hi)), max(lo, hi))
    }

    static func clampScale(_ scale: Double, _ bounds: MapBounds, _ vp: CGSize) -> Double {
        let base = fitScale(bounds, vp)
        return clampTo(scale, base * minZoom, base * maxZoom)
    }

    static func clamp(_ c: MapCamera, _ bounds: MapBounds, _ vp: CGSize) -> MapCamera {
        MapCamera(cx: clampTo(c.cx, bounds.minX, bounds.maxX),
                  cy: clampTo(c.cy, bounds.minY, bounds.maxY),
                  scale: clampScale(c.scale, bounds, vp))
    }

    static func zoomAround(_ c: MapCamera, bounds: MapBounds, vp: CGSize,
                           anchor: MapScreenPos, factor: Double) -> MapCamera {
        let at = unproject(c, vp, anchor)
        let scale = clampScale(c.scale * factor, bounds, vp)
        return clamp(MapCamera(cx: at.x - (anchor.px - Double(vp.width) / 2) / scale,
                               cy: at.y - (anchor.py - Double(vp.height) / 2) / scale,
                               scale: scale),
                     bounds, vp)
    }

    static func panBy(_ c: MapCamera, bounds: MapBounds, vp: CGSize, dx: Double, dy: Double) -> MapCamera {
        clamp(MapCamera(cx: c.cx - dx / c.scale, cy: c.cy - dy / c.scale, scale: c.scale), bounds, vp)
    }

    static func isZoomedIn(_ c: MapCamera, _ bounds: MapBounds, _ vp: CGSize) -> Bool {
        c.scale > fitScale(bounds, vp) * 1.001
    }

    // ---- culling ----

    /// Segment indices inside `rect` on a visible layer, written into a caller-owned buffer so a
    /// 26k-segment zone costs one allocation for the map's lifetime rather than one per frame.
    static func cullSegments(_ lines: MapLines, rect: MapViewRect, layers: [Bool],
                             into out: inout [Int32]) -> Int {
        var n = 0
        let cap = out.count
        lines.coords.withUnsafeBufferPointer { coords in
            for i in 0..<lines.count {
                let l = Int(lines.layer[i])
                if l >= layers.count || !layers[l] { continue }
                let o = i * 6
                let x1 = Double(coords[o]), x2 = Double(coords[o + 3])
                if (x1 < rect.minX && x2 < rect.minX) || (x1 > rect.maxX && x2 > rect.maxX) { continue }
                let y1 = Double(coords[o + 1]), y2 = Double(coords[o + 4])
                if (y1 < rect.minY && y2 < rect.minY) || (y1 > rect.maxY && y2 > rect.maxY) { continue }
                if n >= cap { break }
                out[n] = Int32(i)
                n += 1
            }
        }
        return n
    }

    static func visiblePoints(_ points: [MapPoint], rect: MapViewRect, layers: [Bool]) -> [(point: MapPoint, index: Int)] {
        var out: [(MapPoint, Int)] = []
        for (index, p) in points.enumerated() {
            if p.layer >= layers.count || !layers[p.layer] { continue }
            if p.x < rect.minX || p.x > rect.maxX { continue }
            if p.y < rect.minY || p.y > rect.maxY { continue }
            out.append((p, index))
        }
        return out
    }
}

// MARK: - Floor slicing (floorSlice.ts)

/// One elevation band: a contiguous run of the zone's distinct z values.
struct FloorBand: Equatable, Sendable {
    var lo: Double
    var hi: Double
    var levels: Int

    var label: String { "\(Int(lo.rounded())) … \(Int(hi.rounded()))" }
}

enum MapFloors {
    static let maxBands = 12
    static let defaultBandHeight = 20.0
    static let minBandHeight = 12.0
    /// Splits are preferred in the middle 60% of a run, so a band is never carved off its edge.
    private static let centreWindow = 0.6

    private struct Run { var lo: Int; var hi: Int }

    private static func targetHeight(extent: Double, hint: MapHeightHint?, maxBands: Int) -> Double {
        let hinted = hint.map { $0.low + $0.high } ?? defaultBandHeight
        return max(hinted, extent / Double(maxBands), minBandHeight)
    }

    private static func splitAt(_ z: [Double], _ r: Run) -> Int {
        let lo = z[r.lo], hi = z[r.hi]
        let inset = ((1 - centreWindow) / 2) * (hi - lo)
        let mid = (lo + hi) / 2
        var best = -1
        var bestGap = 0.0
        var near = -1
        var nearDist = Double.infinity
        var i = r.lo + 1
        while i <= r.hi {
            let gap = z[i] - z[i - 1]
            if gap > 0 {
                let centre = (z[i] + z[i - 1]) / 2
                let dist = abs(centre - mid)
                if dist < nearDist { nearDist = dist; near = i }
                if centre >= lo + inset && centre <= hi - inset && gap > bestGap { bestGap = gap; best = i }
            }
            i += 1
        }
        return best >= 0 ? best : near
    }

    private static func tallest(_ z: [Double], _ runs: [Run], target: Double) -> Int {
        var best = -1
        var bestH = target
        for (i, r) in runs.enumerated() {
            let h = z[r.hi] - z[r.lo]
            if h > bestH { bestH = h; best = i }
        }
        return best
    }

    /// Group the raw distinct z values into human "levels" by repeatedly splitting the tallest
    /// run at its widest interior gap.
    static func bands(_ zLevels: [Double], hint: MapHeightHint? = nil, maxBands limit: Int = maxBands) -> [FloorBand] {
        if zLevels.isEmpty { return [] }
        let z = zLevels
        let cap = max(1, limit)
        let target = targetHeight(extent: z[z.count - 1] - z[0], hint: hint, maxBands: cap)
        var runs: [Run] = [Run(lo: 0, hi: z.count - 1)]
        while runs.count < cap {
            let pick = tallest(z, runs, target: target)
            if pick < 0 { break }
            let at = splitAt(z, runs[pick])
            if at < 0 { break }
            let r = runs[pick]
            runs = Array(runs[0..<pick]) + [Run(lo: r.lo, hi: at - 1), Run(lo: at, hi: r.hi)] + Array(runs[(pick + 1)...])
        }
        return runs.map { FloorBand(lo: z[$0.lo], hi: z[$0.hi], levels: $0.hi - $0.lo + 1) }
    }

    /// A band's inclusive z window, widened to the midpoints of its neighbours so nothing falls
    /// between two floors. The outermost bands are open-ended.
    static func range(_ bands: [FloorBand], _ index: Int) -> (lo: Double, hi: Double) {
        guard index >= 0, index < bands.count else { return (-.infinity, .infinity) }
        let b = bands[index]
        let below = index > 0 ? bands[index - 1] : nil
        let above = index + 1 < bands.count ? bands[index + 1] : nil
        return (below.map { ($0.hi + b.lo) / 2 } ?? -.infinity,
                above.map { (b.hi + $0.lo) / 2 } ?? .infinity)
    }

    static func inActiveBand(_ bands: [FloorBand], _ active: Int?, _ z: Double) -> Bool {
        guard let active, !bands.isEmpty else { return true }
        let r = range(bands, active)
        return z >= r.lo && z <= r.hi
    }
}

// MARK: - Label declutter (labelLayout.ts)

enum MapLabelKind: Int {
    case connection = 0
    case named = 1
    case service = 2
    case generic = 3
}

/// One candidate label, projected.
struct MapLabelItem {
    var index: Int
    var point: MapPoint
    var px: Double
    var py: Double
    var inBand: Bool
}

/// A placed label: `shown` false means the declutter dropped it and only a dot is drawn.
struct MapLabelSlot {
    var index: Int
    var point: MapPoint
    var px: Double
    var py: Double
    var w: Double
    var h: Double
    var shown: Bool
}

enum MapLabels {
    static let fontPx: [Int: Double] = [1: 10, 2: 12, 3: 14]
    private static let cellPx = 32.0
    private static let padPx = 2.0
    /// Text is never measured — the map draws thousands of candidates per frame and a measure
    /// pass would dominate. 0.55em per character is the average of the app's UI face.
    private static let charW = 0.55
    private static let lineH = 1.25

    static func kind(_ display: String) -> MapLabelKind {
        let d = display.lowercased()
        if d.hasPrefix("to ") { return .connection }
        if d.hasSuffix("(named)") || d.hasSuffix("(hunter)") { return .named }
        for needle in ["merchant", "banker", "bank", "parcel", "guild master", "guildmaster",
                       "tradeskill", "forge", "cultural", "(gm"] where d.contains(needle) {
            return .service
        }
        return .generic
    }

    /// Lower is more important: bigger text first, then connections, named mobs, services.
    static func rank(_ p: MapPoint) -> Int { (3 - p.size) * 4 + kind(p.display).rawValue }

    static func box(_ p: MapPoint) -> (w: Double, h: Double) {
        let px = fontPx[p.size] ?? 12
        return (max(px, Double(p.display.count) * px * charW), px * lineH)
    }

    private struct Box {
        var x0: Double
        var y0: Double
        var x1: Double
        var y1: Double
        func overlaps(_ o: Box) -> Bool { x0 < o.x1 && x1 > o.x0 && y0 < o.y1 && y1 > o.y0 }
    }

    /// Greedy: place in importance order, skip anything that collides with what is already down.
    /// A uniform grid keeps the collision test near-constant rather than O(n²).
    static func layout(_ items: [MapLabelItem], pad: Double = padPx) -> [MapLabelSlot] {
        var grid: [Int64: [Box]] = [:]
        var slots: [Int: MapLabelSlot] = [:]

        @inline(__always) func cells(_ b: Box, _ visit: (Int64) -> Bool) -> Bool {
            let cx0 = Int(floor(b.x0 / cellPx)), cx1 = Int(floor(b.x1 / cellPx))
            let cy0 = Int(floor(b.y0 / cellPx)), cy1 = Int(floor(b.y1 / cellPx))
            if cx1 - cx0 > 512 || cy1 - cy0 > 512 { return false } // a pathological box, off screen
            for cx in cx0...cx1 {
                for cy in cy0...cy1 {
                    if visit(Int64(cx) &* 100_003 &+ Int64(cy)) { return true }
                }
            }
            return false
        }

        let ordered = items.enumerated().sorted { a, b in
            let ra = rank(a.element.point), rb = rank(b.element.point)
            if ra != rb { return ra < rb }
            return a.element.index < b.element.index
        }.map(\.element)

        for item in ordered {
            let (w, h) = box(item.point)
            let b = Box(x0: item.px - w / 2 - pad, y0: item.py - h / 2 - pad,
                        x1: item.px + w / 2 + pad, y1: item.py + h / 2 + pad)
            var hit = false
            if item.inBand {
                hit = cells(b) { key in (grid[key] ?? []).contains { $0.overlaps(b) } }
            }
            let shown = item.inBand && !hit
            if shown { _ = cells(b) { key in grid[key, default: []].append(b); return false } }
            slots[item.index] = MapLabelSlot(index: item.index, point: item.point, px: item.px, py: item.py,
                                             w: w, h: h, shown: shown)
        }
        return items.map { slots[$0.index] ?? MapLabelSlot(index: $0.index, point: $0.point, px: $0.px,
                                                           py: $0.py, w: 0, h: 0, shown: false) }
    }
}

// MARK: - The typed /loc marker (locMarker.ts)

enum MapLoc {
    private static let example =
        "Paste the line the game printed (\u{201C}Your Location is 1414.20, -735.55, 12.19\u{201D}) or just the numbers."

    enum Parsed {
        case ok(EqLoc)
        case bad(String)
    }

    /// Accepts the raw log line, the `/loc` echo, or three bare numbers. Never guesses: two
    /// numbers means elevation 0, anything else is refused with the reason.
    static func parse(_ text: String) -> Parsed {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // A leading `[Wed Aug 27 ...]` log timestamp.
        if body.hasPrefix("["), let close = body.firstIndex(of: "]") {
            body = String(body[body.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        }
        for prefix in ["your location is", "your location", "/loc"] where body.lowercased().hasPrefix(prefix) {
            body = String(body.dropFirst(prefix.count))
            while let f = body.first, f == ":" || f == "=" || f == " " { body = String(body.dropFirst()) }
            break
        }
        if body.hasSuffix(".") { body = String(body.dropLast()) }
        body = body.trimmingCharacters(in: .whitespaces)
        if body.isEmpty { return .bad("Nothing to place. \(example)") }

        let tokens = body.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\t" }).map(String.init)
        var nums: [Double] = []
        for t in tokens {
            guard let v = Double(t), v.isFinite else {
                return .bad("\u{201C}\(t)\u{201D} isn\u{2019}t a number. \(example)")
            }
            nums.append(v)
        }
        if nums.isEmpty { return .bad("That reads as no position at all. \(example)") }
        if nums.count != 2 && nums.count != 3 {
            return .bad("\(nums.count) numbers - a /loc is three (north/south, west/east, elevation). \(example)")
        }
        return .ok(EqLoc(ns: nums[0], ew: nums[1], z: nums.count > 2 ? nums[2] : 0))
    }

    private static func short(_ n: Double) -> String {
        let r = (n * 100).rounded() / 100
        return r == r.rounded() ? String(Int(r)) : String(r)
    }

    static func format(_ loc: EqLoc) -> String { "\(short(loc.ns)), \(short(loc.ew)), \(short(loc.z))" }
}

/// The per-zone typed markers, persisted whole. One position per zone; it stays until it is
/// replaced or cleared.
struct LocMarkers: Equatable {
    static let key = "eq.maps.loc"
    var byZone: [String: EqLoc] = [:]

    static func load(_ d: UserDefaults = .standard) -> LocMarkers {
        guard let raw = d.string(forKey: key), let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: EqLoc].self, from: data)
        else { return LocMarkers() }
        return LocMarkers(byZone: decoded.filter { !$0.key.isEmpty })
    }

    func save(_ d: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(byZone) else { return }
        d.set(String(decoding: data, as: UTF8.self), forKey: Self.key)
    }

    subscript(zone: String?) -> EqLoc? {
        guard let zone else { return nil }
        return byZone[zone]
    }
}
