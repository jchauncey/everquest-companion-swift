// What height to write a generated label at.
//
// A map label carries an elevation, and the game uses it: EQ draws the labels near the floor you
// are standing on and hides the rest, which is how a multi-level dungeon stays readable. So the
// number matters as much as the position.
//
// THE WIKI ALMOST NEVER SAYS. Of the 9,019 spawn positions the corpus states, 202 carry a third
// number - 2%. Lower Guk states none at all. The generator used to write `0.0000` for the rest,
// which is not a missing value but a WRONG one: Lower Guk's own geometry runs from about -68 to
// -282, so every pin we wrote sat hundreds of units above the dungeon and the game filtered them
// out. The pins were in the file the whole time; the game just never drew them.
//
// So the height comes from the map itself: a label stands on the floor nearest it. The pack's
// geometry carries a z per vertex, and the nearest vertex to a pin is the floor that pin is on.
// That is an inference, not a fact the wiki stated - but it is an inference about OUR OWN drawing
// of someone else's fact, and the alternative on offer is a number that is definitely wrong.
import Foundation

/// A coarse spatial index over a zone's geometry, for "what is the floor under this point".
///
/// A zone is tens of thousands of segments and a pack is a hundred-odd zones, so the lookup cannot
/// be a linear scan per pin. Vertices are bucketed into square cells; a query reads its own cell
/// first and widens by a ring at a time until it finds something.
struct MapElevation {
    /// Cell size in map units. Large enough that most queries hit on the first ring, small enough
    /// that a hit is genuinely nearby - Guk's floors are tens of units apart, not hundreds.
    static let cell: Double = 100

    private var buckets: [Cell: [(x: Double, y: Double, z: Double)]] = [:]
    /// The fallback when a pin is nowhere near any geometry: the zone's middle height, which at
    /// least puts the label in the building.
    private(set) var median: Double = 0

    struct Cell: Hashable { var cx: Int; var cy: Int }

    /// The furthest cell index a coordinate may land in. Real maps span thousands of units, so a
    /// bound here costs nothing real - and without one, `Int(_:)` traps on the finite-but-enormous
    /// coordinate a third-party pack is free to contain (`num` admits any finite Double). Kept well
    /// inside `Int.max` so the ring arithmetic in `z(x:y:)` cannot overflow either.
    private static let maxCell = 1 << 40

    private static func cellOf(_ x: Double, _ y: Double) -> Cell {
        func index(_ v: Double) -> Int {
            guard v.isFinite else { return 0 }
            let scaled = (v / cell).rounded(.down)
            return Int(min(Double(maxCell), max(Double(-maxCell), scaled)))
        }
        return Cell(cx: index(x), cy: index(y))
    }

    /// Index every segment endpoint the map draws, EXCEPT the legend's.
    ///
    /// The legend layer is a colour key, drawn at fixed coordinates that are not a place in the
    /// zone and at whatever height its author chose - usually zero. Left in, it answers elevation
    /// queries with its own: one Lower Guk pin resolved to exactly 0.0 in a dungeon whose floors
    /// are all below -140, which is the very number this whole file exists to stop writing.
    init(_ lines: MapLines) {
        var zs: [Double] = []
        zs.reserveCapacity(lines.count * 2)
        var i = 0
        while i + 5 < lines.coords.count {
            let segment = i / 6
            if segment < lines.layer.count && Int(lines.layer[segment]) == MapFile.legendLayer {
                i += 6
                continue
            }
            for k in 0..<2 {
                let x = Double(lines.coords[i + k * 3])
                let y = Double(lines.coords[i + k * 3 + 1])
                let z = Double(lines.coords[i + k * 3 + 2])
                buckets[Self.cellOf(x, y), default: []].append((x, y, z))
                zs.append(z)
            }
            i += 6
        }
        if !zs.isEmpty {
            zs.sort()
            median = zs[zs.count / 2]
        }
    }

    var isEmpty: Bool { buckets.isEmpty }

    /// The z of the drawn geometry nearest `(x, y)`, or the zone median when nothing is close.
    ///
    /// Widening ring by ring means the first hit is not necessarily the nearest, so a ring that
    /// finds anything is finished by also reading the ring beyond it - the nearest point to a cell
    /// can always sit just over its edge.
    func z(x: Double, y: Double) -> Double {
        guard !buckets.isEmpty else { return median }
        let home = Self.cellOf(x, y)
        var best: Double?
        var bestDistance = Double.infinity
        var ring = 0
        // Four rings of 100 units is 400 out; past that the "floor under this pin" is a fiction.
        while ring <= 4 {
            for cx in (home.cx - ring)...(home.cx + ring) {
                for cy in (home.cy - ring)...(home.cy + ring) {
                    // Only the new edge each time round; the inside was read already.
                    if ring > 0 && abs(cx - home.cx) != ring && abs(cy - home.cy) != ring { continue }
                    for v in buckets[Cell(cx: cx, cy: cy)] ?? [] {
                        let d = (v.x - x) * (v.x - x) + (v.y - y) * (v.y - y)
                        if d < bestDistance { bestDistance = d; best = v.z }
                    }
                }
            }
            // One more ring after the first hit, then stop: a nearer point may be just outside.
            if best != nil && ring > 0 { break }
            ring += 1
        }
        return best ?? median
    }
}
