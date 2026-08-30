// The map surface: one SwiftUI `Canvas`, one stroked path per colour, and the marks on top.
//
// A port of `MapCanvas.tsx` + `MapPointsLayer.tsx` + `MapMobPins.tsx` + `MapLocMarker.tsx`. The
// Electron app splits these because the DOM wants labels and pins to be real elements it can
// hover; here everything is one immediate-mode pass, which is why the declutter (MapLabels) is
// the thing that has to be right — nothing else stops 26k segments and 300 labels from becoming
// a smear.
//
// COLOUR BUCKETING IS THE WHOLE PERFORMANCE ARGUMENT. `MapLines` arrives columnar and grouped by
// palette slot, so a zone strokes ~10-20 paths per frame instead of 26,383.
import SwiftUI

struct MapCanvasView: View {
    var data: MapData
    var camera: MapCamera
    var layers: [Bool]
    var bands: [FloorBand]
    var floor: Int?
    var pins: [MapPaneRows.PlacedPin]
    var selectedPinId: String?
    var selectedAt: MapXY?
    var locMarker: EqLoc?

    /// Near-black file colours are re-inked: a #000 wall on a #0f1115 background is invisible.
    static let ink = Color(hex: 0xc8d0de)
    private static let nearBlack = 32
    private static let offBandAlpha = 0.14
    /// Labels considered per frame. Above this the map is a smear anyway and the cost is real.
    private static let labelBudget = 1500
    private static let overscanPx = 220.0

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { ctx, size in
            draw(ctx: &ctx, size: size)
        }
    }

    private var zBand: (lo: Double, hi: Double)? {
        guard let floor, !bands.isEmpty else { return nil }
        return MapFloors.range(bands, floor)
    }

    private func draw(ctx: inout GraphicsContext, size: CGSize) {
        let rect = MapGeo.viewRect(camera, size)
        drawLines(&ctx, size: size, rect: rect)
        drawPoints(&ctx, size: size, rect: rect)
        drawPins(&ctx, size: size)
        drawSelection(&ctx, size: size)
        drawLoc(&ctx, size: size)
    }

    // MARK: - Geometry

    private func strokeStyles() -> [Color] {
        let p = data.lines.palette
        var out: [Color] = []
        var i = 0
        while i + 2 < p.count {
            let r = Int(p[i]), g = Int(p[i + 1]), b = Int(p[i + 2])
            out.append(max(r, max(g, b)) < Self.nearBlack
                       ? Self.ink
                       : Color(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255))
            i += 3
        }
        return out
    }

    private func drawLines(_ ctx: inout GraphicsContext, size: CGSize, rect: MapViewRect) {
        let lines = data.lines
        let styles = strokeStyles()
        if styles.isEmpty || lines.count == 0 { return }
        let band = zBand
        let onPaths = (0..<styles.count).map { _ in CGMutablePath() }
        let offPaths = band == nil ? nil : (0..<styles.count).map { _ in CGMutablePath() }

        let hw = size.width / 2, hh = size.height / 2
        let cx = camera.cx, cy = camera.cy, scale = camera.scale
        lines.coords.withUnsafeBufferPointer { coords in
            for i in 0..<lines.count {
                let l = Int(lines.layer[i])
                if l >= layers.count || !layers[l] { continue }
                let o = i * 6
                let x1 = Double(coords[o]), x2 = Double(coords[o + 3])
                if (x1 < rect.minX && x2 < rect.minX) || (x1 > rect.maxX && x2 > rect.maxX) { continue }
                let y1 = Double(coords[o + 1]), y2 = Double(coords[o + 4])
                if (y1 < rect.minY && y2 < rect.minY) || (y1 > rect.maxY && y2 > rect.maxY) { continue }
                let slot = Int(lines.colorIndex[i])
                if slot >= onPaths.count { continue }
                let inBand = band.map { z in
                    let zz = min(Double(coords[o + 2]), Double(coords[o + 5]))
                    return zz >= z.lo && zz <= z.hi
                } ?? true
                let path = (inBand ? onPaths : (offPaths ?? onPaths))[slot]
                path.move(to: CGPoint(x: hw + (x1 - cx) * scale, y: hh + (y1 - cy) * scale))
                path.addLine(to: CGPoint(x: hw + (x2 - cx) * scale, y: hh + (y2 - cy) * scale))
            }
        }

        // The off-band pass first and faint: it is context, not the floor you asked for.
        if let offPaths {
            for (i, p) in offPaths.enumerated() where !p.isEmpty {
                ctx.stroke(Path(p), with: .color(styles[i].opacity(Self.offBandAlpha)), lineWidth: 1)
            }
        }
        for (i, p) in onPaths.enumerated() where !p.isEmpty {
            ctx.stroke(Path(p), with: .color(styles[i]), lineWidth: 1)
        }
    }

    // MARK: - Labels

    private func colour(_ p: MapPoint) -> Color {
        Color(.sRGB, red: Double(p.r) / 255, green: Double(p.g) / 255, blue: Double(p.b) / 255)
    }

    private func drawPoints(_ ctx: inout GraphicsContext, size: CGSize, rect: MapViewRect) {
        if data.points.isEmpty { return }
        let wide = MapGeo.expand(rect, by: Self.overscanPx / camera.scale)
        var vis = MapGeo.visiblePoints(data.points, rect: wide, layers: layers)
        if vis.count > Self.labelBudget {
            vis = Array(vis.sorted { MapLabels.rank($0.point) < MapLabels.rank($1.point) }.prefix(Self.labelBudget))
        }
        let items = vis.map { v -> MapLabelItem in
            let s = MapGeo.project(camera, size, MapXY(x: v.point.x, y: v.point.y))
            return MapLabelItem(index: v.index, point: v.point, px: s.px, py: s.py,
                                inBand: MapFloors.inActiveBand(bands, floor, v.point.z))
        }
        let slots = MapLabels.layout(items)

        // Dots for everything the declutter dropped — the point is still THERE, only its name
        // did not fit.
        for s in slots where !s.shown {
            let r = 2.5
            let box = CGRect(x: s.px - r, y: s.py - r, width: r * 2, height: r * 2)
            ctx.fill(Path(ellipseIn: box), with: .color(colour(s.point).opacity(0.85)))
        }
        // One layer with one shadow filter gives every label a halo for the cost of one filter.
        ctx.drawLayer { layer in
            layer.addFilter(.shadow(color: .black.opacity(0.9), radius: 1.5))
            for s in slots where s.shown {
                let font = MapLabels.fontPx[s.point.size] ?? 12
                layer.draw(Text(s.point.display).font(.system(size: font)).foregroundStyle(colour(s.point)),
                           at: CGPoint(x: s.px, y: s.py), anchor: .center)
            }
        }
    }

    // MARK: - Wiki mob pins

    private func drawPins(_ ctx: inout GraphicsContext, size: CGSize) {
        if pins.isEmpty { return }
        for placed in pins {
            let s = MapGeo.project(camera, size, MapXY(x: placed.pin.x, y: placed.pin.y))
            if s.px < -20 || s.py < -20 || s.px > size.width + 20 || s.py > size.height + 20 { continue }
            let selected = placed.rowId == selectedPinId
            let r = selected ? 6.0 : 4.5
            let box = CGRect(x: s.px - r, y: s.py - r, width: r * 2, height: r * 2)
            ctx.fill(Path(ellipseIn: box), with: .color(Theme.gold.opacity(selected ? 1 : 0.85)))
            ctx.stroke(Path(ellipseIn: box), with: .color(.black.opacity(0.85)), lineWidth: 1)
        }
    }

    private func drawSelection(_ ctx: inout GraphicsContext, size: CGSize) {
        guard let selectedAt else { return }
        let s = MapGeo.project(camera, size, selectedAt)
        let r = 13.0
        ctx.stroke(Path(ellipseIn: CGRect(x: s.px - r, y: s.py - r, width: r * 2, height: r * 2)),
                   with: .color(Theme.gold), lineWidth: 2)
    }

    // MARK: - The typed /loc marker

    private func drawLoc(_ ctx: inout GraphicsContext, size: CGSize) {
        guard let locMarker else { return }
        // THE ONE SEAM, AGAIN: the typed reading reaches the screen through `mapFromLoc` and then
        // the same projection every other mark uses. Nothing here knows which way north is.
        let m = MapGeo.mapFromLoc(locMarker)
        let s = MapGeo.project(camera, size, MapXY(x: m.x, y: m.y))
        let ring = 9.0, tick = 7.0
        ctx.stroke(Path(ellipseIn: CGRect(x: s.px - ring, y: s.py - ring, width: ring * 2, height: ring * 2)),
                   with: .color(Theme.blue), lineWidth: 2)
        var arms = Path()
        arms.move(to: CGPoint(x: s.px, y: s.py - ring - tick)); arms.addLine(to: CGPoint(x: s.px, y: s.py - ring))
        arms.move(to: CGPoint(x: s.px, y: s.py + ring)); arms.addLine(to: CGPoint(x: s.px, y: s.py + ring + tick))
        arms.move(to: CGPoint(x: s.px - ring - tick, y: s.py)); arms.addLine(to: CGPoint(x: s.px - ring, y: s.py))
        arms.move(to: CGPoint(x: s.px + ring, y: s.py)); arms.addLine(to: CGPoint(x: s.px + ring + tick, y: s.py))
        ctx.stroke(arms, with: .color(Theme.blue), lineWidth: 2)
    }
}
