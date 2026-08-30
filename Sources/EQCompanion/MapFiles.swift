// The classic-EQ map-file corpus: the parser, the pack index, and the per-layer cross-pack
// resolution. A faithful port of `src/main/maps/parseMap.ts` + `src/main/maps/packs.ts` and the
// data model in `src/shared/maps.ts`.
//
// `<install root>/maps` holds ~1,900 `.txt` files in exactly two record shapes:
//
//     L  x1, y1, z1, x2, y2, z2, r, g, b        (9 fields)
//     P  x,  y,  z,  r,  g,  b,  size, label    (8 fields, the label may itself contain commas)
//
// The rules that are easy to get wrong, all measured against the real corpus by the Electron
// port and re-verified here:
//
//   * A LABEL MAY CONTAIN COMMAS. Everything from field 7 onward is re-joined with commas.
//   * LAYER 2 IS A LEGEND, drawn at fixed off-map coordinates. It contributes geometry (the
//     viewer may toggle it on) but never bounds and never z-levels.
//   * A MALFORMED LINE IS COUNTED, NEVER THROWN ON — `MapData.skipped` makes a bad pack
//     diagnosable instead of blank.
//   * GEOMETRY AND LABELS COME FROM DIFFERENT PACKS. The game's default set holds a few hundred
//     label points; Brewall holds tens of thousands. So the pack choice is PER LAYER, and the
//     outcome is recorded in `MapData.sources` rather than silently merged.
import Foundation

typealias ZoneShort = String

// MARK: - The parsed model (src/shared/maps.ts)

/// One labelled point of interest. Small in every zone (measured max 316), so a plain struct.
struct MapPoint: Sendable, Hashable {
    var x: Double
    var y: Double
    var z: Double
    var r: UInt8
    var g: UInt8
    var b: UInt8
    /// Text size class 1...3 (small / medium / large). NOT a radius.
    var size: Int
    /// RAW label, underscores intact, exactly as the file spells it.
    var label: String
    /// `label` with underscores turned into spaces — what the user reads and search matches.
    var display: String
    var layer: Int
}

/// Line geometry in COLUMNAR, COLOUR-BUCKETED form: one stroked path per palette entry rather
/// than one per segment (measured worst case 26,383 segments in everfrost.txt).
struct MapLines: Sendable {
    /// [x1,y1,z1,x2,y2,z2] × count, flattened.
    var coords: [Float] = []
    /// Distinct colours, packed [r,g,b] × paletteSize.
    var palette: [UInt8] = []
    /// Palette slot per segment; length == count.
    var colorIndex: [UInt8] = []
    /// Layer per segment; length == count.
    var layer: [UInt8] = []
    var count: Int = 0
}

struct MapBounds: Sendable, Equatable {
    var minX: Double
    var maxX: Double
    var minY: Double
    var maxY: Double
    var minZ: Double
    var maxZ: Double

    static let empty = MapBounds(minX: -1, maxX: 1, minY: -1, maxY: 1, minZ: 0, maxZ: 0)
}

/// Where one layer's records actually came from. Layers may be sourced from DIFFERENT packs.
struct MapSource: Sendable, Hashable {
    var layer: Int
    var packId: String
    var file: String
}

/// The pack's recommended z-slice band, mined from a layer-2 `Height_Filter:_N/M` label.
struct MapHeightHint: Sendable, Equatable {
    var low: Double
    var high: Double
}

/// Everything the viewer needs for one zone, from one pack selection.
struct MapData: Sendable {
    var zone: ZoneShort
    var sources: [MapSource]
    var lines: MapLines
    var points: [MapPoint]
    /// Bounds over layers 0/1/3 only. Never includes the legend layer.
    var bounds: MapBounds
    /// Distinct `min(z1, z2)` per segment, ascending — the floor picker's raw input.
    var zLevels: [Double]
    var heightHint: MapHeightHint?
    /// Attribution mined from the legend layer's credit points.
    var credits: [String]
    /// Lines that failed to parse. Non-zero ⇒ a diagnosable bad pack, never an error.
    var skipped: Int
}

// MARK: - Packs

/// An installed map pack — a directory of `<zone>[_N].txt` files.
struct MapPack: Sendable, Hashable, Identifiable {
    /// Stable id: `default` for `<root>/maps` itself, else the lowercased subdirectory name.
    var id: String
    /// Display name — the subdirectory's real casing, or "Game default maps".
    var name: String
    var dir: URL
    /// `game` = inside the EverQuest folder; `user` = installed by us.
    var origin: String
    var zoneCount: Int
    var fileCount: Int
}

/// One pack plus its stem -> layer -> real filename index (casing preserved for the read).
struct PackIndex: Sendable {
    var pack: MapPack
    var files: [ZoneShort: [Int: String]]
}

/// Per-layer pack preference. A missing side falls back to the resolution order.
struct MapPackPrefs: Sendable, Equatable {
    var geometry: String?
    var labels: String?

    static let key = "eq.maps.packs"

    static func load(_ d: UserDefaults = .standard) -> MapPackPrefs {
        guard let raw = d.string(forKey: key), let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return MapPackPrefs() }
        func nonEmpty(_ v: Any?) -> String? {
            guard let s = v as? String, !s.isEmpty else { return nil }
            return s
        }
        return MapPackPrefs(geometry: nonEmpty(obj["geometry"]), labels: nonEmpty(obj["labels"]))
    }

    func save(_ d: UserDefaults = .standard) {
        var obj: [String: String] = [:]
        if let g = geometry { obj["geometry"] = g }
        if let l = labels { obj["labels"] = l }
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        d.set(String(decoding: data, as: UTF8.self), forKey: Self.key)
    }

    /// The cache key one zone is parsed under.
    func cacheKey(_ zone: ZoneShort) -> String { "\(geometry ?? "")|\(labels ?? "")|\(zone)" }
}

// MARK: - The parser

/// One layer's line geometry, accumulated flat. Typed arrays come later, in `build`.
struct MapRawLines: Sendable {
    var coords: [Double] = []
    var rgb: [UInt8] = []
    var count = 0
}

/// What one map file yields. `layer` travels with it so `build` needs no side table.
struct MapParseResult: Sendable {
    var layer: Int
    var lines: MapRawLines
    var points: [MapPoint]
    var skipped: Int
}

enum MapFile {
    /// `zone_2.txt` conventionally holds the colour key, the coordinate grid and the credits,
    /// all drawn well outside the zone's real extent.
    static let legendLayer = 2
    /// Layers looked for on disk. 0 = `<zone>.txt`, 1...3 = `<zone>_N.txt`.
    static let allLayers = [0, 1, 2, 3]
    /// Layers sourced from the LABELS pack rather than the geometry pack: the POI layer and the
    /// legend, whose credits and height hint are authored by whoever drew the labels.
    static let labelLayers: Set<Int> = [1, 2]
    /// Palette slots are addressed by a UInt8, so there are at most 256. Measured max in a real
    /// file is 19; beyond the ceiling a colour folds onto slot 0 rather than dropping geometry.
    static let paletteMax = 256

    // ---- field helpers ----

    @inline(__always)
    static func trim(_ s: Substring) -> Substring {
        var t = s
        while let f = t.first, f == " " || f == "\t" || f == "\r" || f == "\n" { t = t.dropFirst() }
        while let l = t.last, l == " " || l == "\t" || l == "\r" || l == "\n" { t = t.dropLast() }
        return t
    }

    /// A numeric field, or nil when it is absent or not a number. The empty guard is
    /// load-bearing: a truncated `L 1, 2, 3, 4, 5, 6, 0, 0,` must count as malformed, not parse
    /// as a black segment.
    @inline(__always)
    static func num(_ field: Substring) -> Double? {
        let t = trim(field)
        if t.isEmpty { return nil }
        guard let v = Double(t), v.isFinite else { return nil }
        return v
    }

    /// Colour channels are documented 0-255 integers; clamp rather than trust a user pack.
    @inline(__always)
    static func byte(_ v: Double) -> UInt8 {
        UInt8(min(255, max(0, v.rounded())))
    }

    /// `size` is a TEXT SIZE CLASS 1...3, not a radius. Out of range clamps to the nearest class
    /// rather than dropping the point.
    @inline(__always)
    static func sizeClass(_ v: Double) -> Int {
        let n = Int(v.rounded())
        if n <= 1 { return 1 }
        if n >= 3 { return 3 }
        return 2
    }

    private static func pushSegment(_ fields: [Substring], _ out: inout MapRawLines) -> Bool {
        if fields.count != 9 { return false }
        var v = [Double]()
        v.reserveCapacity(9)
        for f in fields {
            guard let n = num(f) else { return false }
            v.append(n)
        }
        out.coords.append(contentsOf: [v[0], v[1], v[2], v[3], v[4], v[5]])
        out.rgb.append(contentsOf: [byte(v[6]), byte(v[7]), byte(v[8])])
        out.count += 1
        return true
    }

    /// A `P` record. Everything from index 7 onward is re-joined with commas — the whole fix for
    /// the 4.5% of labels that contain one.
    private static func parsePoint(_ fields: [Substring], layer: Int) -> MapPoint? {
        if fields.count < 8 { return nil }
        var v = [Double]()
        v.reserveCapacity(7)
        for i in 0..<7 {
            guard let n = num(fields[i]) else { return nil }
            v.append(n)
        }
        let label = String(trim(Substring(fields[7...].joined(separator: ","))))
        return MapPoint(x: v[0], y: v[1], z: v[2],
                        r: byte(v[3]), g: byte(v[4]), b: byte(v[5]),
                        size: sizeClass(v[6]),
                        label: label,
                        display: label.replacingOccurrences(of: "_", with: " "),
                        layer: layer)
    }

    /// Parse one map file's text. Never throws: an unparseable line increments `skipped`.
    /// The corpus is CRLF; splitting on `\n` and trimming makes LF, CRLF and a stray `\r` equal.
    static func parse(text: String, layer: Int) -> MapParseResult {
        var lines = MapRawLines()
        var points: [MapPoint] = []
        var skipped = 0
        // NOT `split(separator: "\n")`: Swift treats CRLF as ONE grapheme, so splitting on the
        // line feed alone matches nothing in this CRLF corpus and the whole file parses as a
        // single malformed record. `isNewline` sees CRLF, LF and a lone CR alike.
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = trim(raw)
            guard let first = line.first else { continue } // blank line — nothing to count
            if first != "L" && first != "P" { skipped += 1; continue }
            let fields = line.dropFirst().split(separator: ",", omittingEmptySubsequences: false)
            if first == "L" {
                if !pushSegment(fields, &lines) { skipped += 1 }
            } else if let point = parsePoint(fields, layer: layer) {
                points.append(point)
            } else {
                skipped += 1
            }
        }
        return MapParseResult(layer: layer, lines: lines, points: points, skipped: skipped)
    }

    // ---- assembly ----

    private static func buildLines(_ parts: [MapParseResult]) -> MapLines {
        var count = 0
        for p in parts { count += p.lines.count }
        var out = MapLines()
        out.count = count
        out.coords.reserveCapacity(count * 6)
        out.colorIndex.reserveCapacity(count)
        out.layer.reserveCapacity(count)
        var slots: [UInt32: Int] = [:]
        var palette: [UInt8] = []
        for part in parts {
            for c in part.lines.coords { out.coords.append(Float(c)) }
            for i in 0..<part.lines.count {
                let r = part.lines.rgb[i * 3], g = part.lines.rgb[i * 3 + 1], b = part.lines.rgb[i * 3 + 2]
                let key = (UInt32(r) << 16) | (UInt32(g) << 8) | UInt32(b)
                let slot: Int
                if let s = slots[key] {
                    slot = s
                } else if slots.count >= paletteMax {
                    slot = 0
                } else {
                    slot = slots.count
                    slots[key] = slot
                    palette.append(contentsOf: [r, g, b])
                }
                out.colorIndex.append(UInt8(slot))
                out.layer.append(UInt8(part.layer))
            }
        }
        out.palette = palette
        return out
    }

    /// Union of every coordinate in `parts` — BOTH line endpoints and every point. Points must
    /// be included: a Brewall `_1` label layer is almost all points and almost no segments.
    private static func computeBounds(_ parts: [MapParseResult]) -> MapBounds {
        var minX = Double.infinity, maxX = -Double.infinity
        var minY = Double.infinity, maxY = -Double.infinity
        var minZ = Double.infinity, maxZ = -Double.infinity
        var seen = false
        @inline(__always) func grow(_ x: Double, _ y: Double, _ z: Double) {
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
            minZ = min(minZ, z); maxZ = max(maxZ, z)
        }
        for part in parts {
            let c = part.lines.coords
            // Stride 3, not 6: both endpoints fall out of one walk.
            var i = 0
            while i + 2 < c.count {
                grow(c[i], c[i + 1], c[i + 2])
                i += 3
            }
            for p in part.points { grow(p.x, p.y, p.z) }
            seen = seen || !c.isEmpty || !part.points.isEmpty
        }
        guard seen else { return MapBounds(minX: 0, maxX: 0, minY: 0, maxY: 0, minZ: 0, maxZ: 0) }
        return MapBounds(minX: minX, maxX: maxX, minY: minY, maxY: maxY, minZ: minZ, maxZ: maxZ)
    }

    /// Distinct `min(z1, z2)` per segment, ascending. `min` rather than both endpoints so a
    /// sloped segment spanning two floors does not smear the clusters.
    private static func computeZLevels(_ parts: [MapParseResult]) -> [Double] {
        var seen = Set<Double>()
        for part in parts {
            let c = part.lines.coords
            var i = 0
            while i + 5 < c.count {
                seen.insert(min(c[i + 2], c[i + 5]))
                i += 6
            }
        }
        return seen.sorted()
    }

    private static func legendPoints(_ parts: [MapParseResult]) -> [MapPoint] {
        parts.filter { $0.layer == legendLayer }.flatMap(\.points)
    }

    /// `Height_Filter:_25/25` — present in a minority of Brewall `_2` files. The file writes
    /// `N/M`; we take the first number as `low`. It seeds a slider default, nothing more.
    private static let heightFilterRE = try? NSRegularExpression(
        pattern: "^height_filter:_*(\\d+(?:\\.\\d+)?)/(\\d+(?:\\.\\d+)?)", options: [.caseInsensitive])

    private static func mineHeightHint(_ parts: [MapParseResult]) -> MapHeightHint? {
        guard let re = heightFilterRE else { return nil }
        for p in legendPoints(parts) {
            let ns = p.label as NSString
            guard let m = re.firstMatch(in: p.label, range: NSRange(location: 0, length: ns.length)),
                  m.numberOfRanges >= 3,
                  let low = Double(ns.substring(with: m.range(at: 1))),
                  let high = Double(ns.substring(with: m.range(at: 2)))
            else { continue }
            return MapHeightHint(low: low, high: high)
        }
        return nil
    }

    /// Attribution, mined from the legend layer's label points — the ONLY attribution signal
    /// these packs ship. Deduped, first-seen order preserved.
    private static let creditRE = try? NSRegularExpression(
        pattern: "^(?:original|revised)\\s+map\\s*:|^https?://|\\bwww\\.", options: [.caseInsensitive])

    private static func mineCredits(_ parts: [MapParseResult]) -> [String] {
        guard let re = creditRE else { return [] }
        var out: [String] = []
        var seen = Set<String>()
        for p in legendPoints(parts) {
            let ns = p.display as NSString
            guard re.firstMatch(in: p.display, range: NSRange(location: 0, length: ns.length)) != nil else { continue }
            if seen.insert(p.display).inserted { out.append(p.display) }
        }
        return out
    }

    /// Fold every layer of one zone into the viewer-ready `MapData`. Parts may arrive in any
    /// order and any layer may be missing; an empty layer file is a valid empty layer.
    static func build(_ parts: [MapParseResult], zone: ZoneShort, sources: [MapSource]) -> MapData {
        // Layer 2 contributes GEOMETRY (the viewer may toggle the legend on) but never extent.
        let drawn = parts.filter { $0.layer != legendLayer }
        let skipped = parts.reduce(0) { $0 + $1.skipped }
        return MapData(zone: zone,
                       sources: sources,
                       lines: buildLines(parts),
                       points: parts.flatMap(\.points),
                       bounds: computeBounds(drawn),
                       zLevels: computeZLevels(drawn),
                       heightHint: mineHeightHint(parts),
                       credits: mineCredits(parts),
                       skipped: skipped)
    }
}

// MARK: - Discovery and per-layer resolution

extension MapFile {
    static let mapsSubdir = "maps"
    static let defaultPackId = "default"
    static let defaultPackName = "Game default maps"

    /// Split `Thurgadina1_1.txt` into `(stem: "thurgadina1", layer: 1)`.
    ///
    /// Only `_1`/`_2`/`_3` are admitted, anchored at the end, so a stem's OWN trailing digit can
    /// never be eaten (`thurgadina1` must not become stem `thurgadina`, layer 1).
    static func splitFileName(_ name: String) -> (stem: ZoneShort, layer: Int)? {
        guard name.count > 4, name.lowercased().hasSuffix(".txt") else { return nil }
        let base = String(name.dropLast(4)).lowercased()
        if base.isEmpty { return nil }
        let chars = Array(base)
        if chars.count >= 2, chars[chars.count - 2] == "_",
           let d = chars[chars.count - 1].wholeNumberValue, (1...3).contains(d) {
            let stem = String(chars[0..<(chars.count - 2)])
            if stem.isEmpty { return nil } // `_1.txt` with no stem at all
            return (stem, d)
        }
        return (base, 0)
    }

    private static func entries(_ dir: URL) -> (files: [String], dirs: [String]) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir,
                                                      includingPropertiesForKeys: [.isDirectoryKey],
                                                      options: [.skipsHiddenFiles])
        else { return ([], []) } // a missing maps dir is the fresh-machine case, not an error
        var files: [String] = []
        var dirs: [String] = []
        for url in items {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir == true { dirs.append(url.lastPathComponent) } else { files.append(url.lastPathComponent) }
        }
        return (files, dirs)
    }

    /// Index one directory as a pack. Nil when it holds no `.txt` map file at all.
    static func indexPackDir(_ dir: URL, id: String, name: String, origin: String) -> PackIndex? {
        var files: [ZoneShort: [Int: String]] = [:]
        var fileCount = 0
        for name in entries(dir).files {
            guard let split = splitFileName(name) else { continue }
            fileCount += 1
            var byLayer = files[split.stem] ?? [:]
            // First spelling wins: a pack could ship both `Befallen.txt` and `befallen.txt`, and
            // picking deterministically beats picking last.
            if byLayer[split.layer] == nil { byLayer[split.layer] = name }
            files[split.stem] = byLayer
        }
        if fileCount == 0 { return nil }
        let pack = MapPack(id: id, name: name, dir: dir, origin: origin,
                           zoneCount: files.count, fileCount: fileCount)
        return PackIndex(pack: pack, files: files)
    }

    private static func addPack(_ out: inout [PackIndex], _ pack: PackIndex) {
        // A user pack SHADOWS a game pack of the same id, in place.
        if let at = out.firstIndex(where: { $0.pack.id == pack.pack.id }) { out[at] = pack } else { out.append(pack) }
    }

    private static func addSubdirPacks(_ out: inout [PackIndex], root: URL, origin: String) {
        for name in entries(root).dirs {
            let id = name.lowercased()
            if id == defaultPackId { continue } // reserved for `<root>/maps` itself
            if let idx = indexPackDir(root.appendingPathComponent(name), id: id, name: name, origin: origin) {
                addPack(&out, idx)
            }
        }
    }

    /// Every pack on this machine, in RESOLUTION ORDER for geometry: `<root>/maps` first (it is
    /// the authoritative geometry and the only source for new zones), then its subdirectories
    /// (`brewalls`, `good's maps`), then anything under the user packs root.
    static func discoverPacks(eqRoot: URL?, userPacksRoot: URL?) -> [PackIndex] {
        var out: [PackIndex] = []
        if let eqRoot {
            let mapsDir = eqRoot.appendingPathComponent(mapsSubdir)
            if let def = indexPackDir(mapsDir, id: defaultPackId, name: defaultPackName, origin: "game") {
                addPack(&out, def)
            }
            addSubdirPacks(&out, root: mapsDir, origin: "game")
        }
        if let userPacksRoot { addSubdirPacks(&out, root: userPacksRoot, origin: "user") }
        return out
    }

    /// Packs in preference order for one layer.
    ///
    /// Geometry keeps discovery order (game default first). LABELS INVERT IT: the default set
    /// holds a few hundred label points to Brewall's tens of thousands, so a label layer that
    /// preferred `default` would answer "search this zone" with a near-empty list. An explicit
    /// preference that names a pack that exists always goes first.
    static func packOrder(_ packs: [PackIndex], layer: Int, prefs: MapPackPrefs) -> [PackIndex] {
        let labels = labelLayers.contains(layer)
        var ordered = labels
            ? packs.filter { $0.pack.id != defaultPackId } + packs.filter { $0.pack.id == defaultPackId }
            : packs
        let wanted = labels ? prefs.labels : prefs.geometry
        if let wanted, let at = ordered.firstIndex(where: { $0.pack.id == wanted }), at > 0 {
            let pick = ordered.remove(at: at)
            ordered.insert(pick, at: 0)
        }
        return ordered
    }

    /// One resolved layer: which pack, which file, and the absolute path to read.
    struct LayerPick: Sendable {
        var layer: Int
        var packId: String
        var file: String
        var url: URL
        var source: MapSource { MapSource(layer: layer, packId: packId, file: file) }
    }

    private static func fileSize(_ url: URL) -> Int {
        ((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize) ?? 0
    }

    /// Pick the pack that supplies one layer of one zone:
    ///   1. an explicitly preferred pack that HAS the file wins outright — even if it is empty,
    ///      because "this pack, and I mean it" is an instruction, not a hint;
    ///   2. otherwise the first pack in preference order with a NON-EMPTY file;
    ///   3. otherwise the first pack that has the file at all — an empty layer file is a valid
    ///      empty layer, never an error.
    static func resolveLayer(_ packs: [PackIndex], zone: ZoneShort, layer: Int,
                             prefs: MapPackPrefs) -> LayerPick? {
        let wanted = labelLayers.contains(layer) ? prefs.labels : prefs.geometry
        var fallback: LayerPick?
        for p in packOrder(packs, layer: layer, prefs: prefs) {
            guard let file = p.files[zone]?[layer] else { continue }
            let pick = LayerPick(layer: layer, packId: p.pack.id, file: file,
                                 url: p.pack.dir.appendingPathComponent(file))
            if p.pack.id == wanted { return pick }
            if fallback == nil { fallback = pick }
            if fileSize(pick.url) > 0 { return pick }
        }
        return fallback
    }

    /// Every layer this zone has anywhere, each attributed to the pack it actually came from.
    static func resolveZoneLayers(_ packs: [PackIndex], zone: ZoneShort, prefs: MapPackPrefs) -> [LayerPick] {
        allLayers.compactMap { resolveLayer(packs, zone: zone, layer: $0, prefs: prefs) }
    }

    /// Map files are ASCII in practice; a stray high byte falls back to Latin-1 rather than
    /// blanking a whole zone.
    static func readText(_ url: URL) -> String? {
        if let s = try? String(contentsOf: url, encoding: .utf8) { return s }
        if let d = try? Data(contentsOf: url) { return String(data: d, encoding: .isoLatin1) }
        return nil
    }

    /// Parse (never cached here) one zone under a per-layer pack preference.
    static func load(_ packs: [PackIndex], zone: ZoneShort, prefs: MapPackPrefs) -> MapData? {
        let picks = resolveZoneLayers(packs, zone: zone, prefs: prefs)
        if picks.isEmpty { return nil }
        var parts: [MapParseResult] = []
        var sources: [MapSource] = []
        for pick in picks {
            guard let text = readText(pick.url) else { continue } // drop the layer, keep the map
            parts.append(parse(text: text, layer: pick.layer))
            sources.append(pick.source)
        }
        if parts.isEmpty { return nil }
        return build(parts, zone: zone, sources: sources)
    }

    /// Distinct zone stems across every pack, ascending.
    static func zoneStems(_ packs: [PackIndex]) -> [ZoneShort] {
        var stems = Set<ZoneShort>()
        for p in packs { for stem in p.files.keys { stems.insert(stem) } }
        return stems.sorted()
    }
}
