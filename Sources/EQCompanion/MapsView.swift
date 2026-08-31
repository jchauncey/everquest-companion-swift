// The Maps tab: the game's own map files, drawn.
//
// A port of `src/renderer/src/features/maps/MapsView.tsx` and the toolbar/pane around it. The
// pieces live next door: MapFiles.swift parses `<install>/maps`, MapGeometry.swift owns the
// projection and the `/loc` seam, MapPane.swift folds the wiki bestiary into rows,
// MapCanvasView.swift draws.
//
// THE LOG NEVER STATES A POSITION. It states the zone you entered and nothing else positional,
// so there is no automatic "you are here" and this tab does not pretend otherwise: the one
// position it can hold is one the user typed, and it says so in the header.
import SwiftUI
import AppKit
import EQCompanionCore

struct MapsView: View {
    @Environment(AppModel.self) private var model
    @State private var store = MapStore()
    @State private var character = ModuleSnapshot()

    @State private var sel = MapZoneSelection.load()
    @State private var prefs = MapPackPrefs.load()
    @State private var layers = MapGeo.defaultLayers
    @State private var floor: Int?

    // The camera. nil means "fitted" — the Electron viewport's `zoomed ?? fit` in one field.
    @State private var zoomed: MapCamera?
    @State private var canvasSize: CGSize = .zero
    @State private var dragBase: MapCamera?
    @State private var magnifyBase: MapCamera?
    @State private var hover: CGPoint?
    @State private var scrollMonitor: Any?

    @State private var query = ""
    @State private var selectedId: String?
    @State private var selectedAt: MapXY?
    /// The mob card popover a pin click (or a cross-tab jump) opens, and where it points.
    @State private var cardMob: String?
    @State private var cardAnchor: CGRect = .zero
    @State private var allMobs: [MapPaneRow] = []

    @State private var locs = LocMarkers.load()
    @State private var locText = ""
    @State private var locError: String?
    @State private var paneOpen = UserDefaults.standard.string(forKey: MapsView.paneKey) != "0"

    static let paneKey = "eq.maps.pane"
    /// Which pack drew each layer. Geometry and labels routinely come from DIFFERENT packs, and
    /// merging two while naming one would be exactly the unlabelled inference the app forbids.
    private static let layerName = [0: "Geometry", 1: "Labels", 2: "Legend", 3: "Extra"]
    /// Centring on a search hit from a fitted map zooms in; from an already-zoomed map it keeps
    /// the scale the user chose.
    private static let jumpZoom = 6.0

    // MARK: - Derived

    private var rawZone: String? {
        let z = character.state["zone"].string
        return (z?.isEmpty ?? true) ? nil : z
    }

    /// The zone stem the character's zone maps to, through the app's one zone fold.
    private var autoZone: ZoneShort? {
        guard let rawZone else { return nil }
        return GameData.shared.zone(forLogName: rawZone)?.short
    }

    private var zoneName: String? {
        guard let zone = sel.zone else { return nil }
        if let rawZone, GameData.shared.zone(forLogName: rawZone)?.short == zone { return rawZone }
        return GameData.shared.zones.first { $0.short == zone }?.name ?? zone
    }

    private var data: MapData? { store.data }
    private var bounds: MapBounds { data?.bounds ?? .empty }
    private var camera: MapCamera { zoomed ?? MapGeo.fit(bounds, canvasSize) }
    private var zoomedIn: Bool { MapGeo.isZoomedIn(camera, bounds, canvasSize) }

    private var bands: [FloorBand] {
        guard let data else { return [] }
        return MapFloors.bands(data.zLevels, hint: data.heightHint)
    }

    private var locMarker: EqLoc? { locs[sel.zone] }

    private var mobs: [MapPaneRow] { MapPaneRows.filter(allMobs, query: query) }
    private var labelRows: [MapPaneRow] { MapPaneRows.filter(MapPaneRows.labelRows(data?.points ?? []), query: query) }
    private var counts: MapPaneRows.Counts {
        MapPaneRows.counts(mobs: allMobs, labels: MapPaneRows.labelRows(data?.points ?? []))
    }
    private var placed: (pins: [MapPaneRows.PlacedPin], capped: Bool) { MapPaneRows.placedPins(mobs) }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            MapFlow(spacing: 8, lineSpacing: 8) { toolbar }
            HStack(alignment: .top, spacing: 12) {
                surface
                if paneOpen { pane.frame(width: 288) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            credits
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.background)
        .task(id: "\(model.moduleSeqs["character"] ?? 0)|\(model.epoch ?? 0)") {
            await character.refresh(model, module: "character")
        }
        .task(id: model.install?.root.path ?? "") { await store.scan(root: model.install?.root) }
        .task(id: "\(autoZone ?? "")|\(rawZone ?? "")") {
            guard rawZone != nil else { return }
            let next = sel.onCharacterZone(autoZone)
            if next != sel { sel = next; next.save() }
        }
        .task(id: "\(sel.zone ?? "")|\(prefs.geometry ?? "")|\(prefs.labels ?? "")|\(store.ready)") {
            await store.load(zone: sel.zone, prefs: prefs)
        }
        .task(id: zoneName ?? "") {
            allMobs = zoneName.map { MapPaneRows.mobRows(zoneName: $0) } ?? []
            consumeJump()
        }
        .task(id: MapJump.shared.pending?.seq ?? 0) { consumeJump() }
        .onChange(of: store.data?.zone) { _, _ in
            zoomed = nil
            floor = nil
            selectedId = nil
            selectedAt = nil
        }
        .onAppear { installScrollMonitor() }
        .onDisappear {
            if let m = scrollMonitor { NSEvent.removeMonitor(m); scrollMonitor = nil }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "map").font(.system(size: 15)).foregroundStyle(Theme.textFaint)
                Text(zoneName ?? "Maps").font(.title3.weight(.semibold)).foregroundStyle(Theme.text)
                if let z = sel.zone { Chip(text: z) }
                if let d = data {
                    ForEach(d.sources, id: \.self) { s in
                        Chip(text: "\(Self.layerName[s.layer] ?? String(s.layer)): \(s.packId)")
                    }
                    if !d.points.isEmpty { Chip(text: "\(d.points.count) labels") }
                    if d.skipped > 0 { Chip(text: "\(d.skipped) unparsed lines", color: Theme.orange) }
                }
                Spacer(minLength: 0)
            }
            Text("The log states the zone you entered and nothing else positional - so there is no automatic \u{201C}you are here\u{201D}. Type /loc in game and paste the line into the toolbar to mark where you are; the mark stays with this zone until you replace or clear it.")
                .font(.caption)
                .foregroundStyle(Theme.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Toolbar

    @ViewBuilder private var toolbar: some View {
        MapZonePicker(zones: store.zones, zone: sel.zone, ready: store.ready) { pick($0) }

        // Beside the selector and OUTSIDE the `hasMap` gate, for the same reason the selector is:
        // "which rule is choosing the map" is exactly the question a user has when none drew.
        Button {
            sel = MapZoneSelection(zone: sel.zone, pinned: !sel.pinned)
            sel.save()
        } label: {
            Label(sel.pinned ? "Pinned" : "Following you", systemImage: sel.pinned ? "pin.fill" : "location.north.line")
                .font(.caption)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(sel.pinned ? Theme.gold.opacity(0.16) : Color.clear))
        .overlay(Capsule().stroke(sel.pinned ? Theme.gold.opacity(0.6) : Theme.border))
        .foregroundStyle(sel.pinned ? Theme.gold : Theme.textDim)
        .help(sel.pinned
              ? "This map is the one you picked. Zoning will not change it."
              : "This map follows the zone your character is in.")

        if sel.pinned {
            Button("Current zone") {
                sel = sel.onFollowCurrent(autoZone, stated: rawZone != nil)
                sel.save()
            }
            .buttonStyle(OutlineButtonStyle())
            .help("Show the zone your character is in - and follow it again from now on.")
        }

        if data != nil {
            HStack(spacing: 2) {
                iconButton("plus.magnifyingglass", "Zoom in") { zoomBy(MapGeo.zoomStep) }
                iconButton("minus.magnifyingglass", "Zoom out") { zoomBy(1 / MapGeo.zoomStep) }
                iconButton("viewfinder", "Fit the whole zone") { zoomed = nil }
                    .disabled(!zoomedIn)
            }

            MapLayerToggle(layers: $layers)

            floorMenu

            MapPackMenu(label: "Geometry", value: prefs.geometry, packs: store.packs) {
                prefs.geometry = $0
                prefs.save()
            }
            MapPackMenu(label: "Labels", value: prefs.labels, packs: store.packs) {
                prefs.labels = $0
                prefs.save()
            }

            // The generated pack: every mob position the wiki states, as an ordinary labels pack.
            // Regenerating rewrites it and selects it; the pack menus switch back any time.
            Button {
                Task {
                    guard let r = try? MapAnnotations.generate() else { return }
                    store.invalidateScan()
                    await store.scan(root: model.install?.root)
                    prefs.labels = MapAnnotations.packId
                    prefs.save()
                    model.note("wiki annotations pack: \(r.labels) labels across \(r.zones) zones")
                }
            } label: {
                Label("Wiki pins", systemImage: "wand.and.stars").font(.caption)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(prefs.labels == MapAnnotations.packId ? Theme.gold.opacity(0.16) : Color.clear))
            .overlay(Capsule().stroke(prefs.labels == MapAnnotations.packId ? Theme.gold.opacity(0.6) : Theme.border))
            .foregroundStyle(prefs.labels == MapAnnotations.packId ? Theme.gold : Theme.textDim)
            .help("Write the \u{201C}Wiki annotations\u{201D} labels pack - one label at every mob position the wiki states - and use it for this map's labels. Pick another pack from the Labels menu to switch back.")

            locField
        }
    }

    private func iconButton(_ system: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system).font(.system(size: 13))
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Theme.textDim)
        .padding(4)
        .help(help)
    }

    private var floorMenu: some View {
        Menu {
            Button("All levels") { floor = nil }
            ForEach(Array(bands.enumerated()), id: \.offset) { i, b in
                Button("Level \(i + 1) of \(bands.count)  ·  \(b.label)") { floor = i }
            }
        } label: {
            Text(floor.map { "Level \($0 + 1) of \(bands.count)" } ?? "All levels").font(.caption)
        }
        .menuStyle(.borderlessButton)
        .frame(width: 150)
        .disabled(bands.count < 2)
        .help(bands.count < 2 ? "This map has one elevation." : "Draw only one elevation band.")
    }

    // The one position the app can hold, and the only way one gets in.
    @ViewBuilder private var locField: some View {
        HStack(spacing: 4) {
            TextField("/loc marker", text: $locText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 190)
                .onSubmit { placeLoc() }
                .onChange(of: locText) { _, _ in locError = nil }
                .help("Type /loc in game and paste the line here - north/south, west/east, elevation.")
            Button {
                placeLoc()
            } label: {
                Image(systemName: "mappin.and.ellipse").font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .disabled(locText.trimmingCharacters(in: .whitespaces).isEmpty)
            .help("Place the marker")

            if let m = locMarker {
                Button { showLoc(m) } label: {
                    Label(MapLoc.format(m), systemImage: "mappin").font(.caption)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .overlay(Capsule().stroke(Theme.blue.opacity(0.6)))
                .foregroundStyle(Theme.blue)
                .help("The location you entered. Click to centre on it.")
                Button {
                    guard let zone = sel.zone else { return }
                    locs.byZone.removeValue(forKey: zone)
                    locs.save()
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.textFaint)
                .help("Remove this marker")
            }
            if let e = locError {
                Text(e).font(.caption).foregroundStyle(Theme.red).frame(maxWidth: 380, alignment: .leading)
            }
        }
    }

    // MARK: - The surface

    private var surface: some View {
        GeometryReader { geo in
            ZStack {
                if let d = data {
                    MapCanvasView(data: d, camera: camera, layers: layers, bands: bands, floor: floor,
                                  pins: placed.pins, selectedPinId: selectedId, selectedAt: selectedAt,
                                  locMarker: locMarker)
                } else {
                    emptyState
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onAppear { canvasSize = geo.size }
            .onChange(of: geo.size) { _, s in canvasSize = s }
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): hover = p
                case .ended: hover = nil
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { v in
                        if dragBase == nil { dragBase = camera }
                        guard let base = dragBase else { return }
                        zoomed = MapGeo.panBy(base, bounds: bounds, vp: canvasSize,
                                              dx: v.translation.width, dy: v.translation.height)
                    }
                    .onEnded { _ in dragBase = nil }
            )
            .simultaneousGesture(
                SpatialTapGesture().onEnded { v in tapPin(at: v.location) }
            )
            .simultaneousGesture(
                MagnifyGesture(minimumScaleDelta: 0.005)
                    .onChanged { v in
                        if magnifyBase == nil { magnifyBase = camera }
                        guard let base = magnifyBase else { return }
                        let anchor = MapScreenPos(px: canvasSize.width / 2, py: canvasSize.height / 2)
                        zoomed = MapGeo.zoomAround(base, bounds: bounds, vp: canvasSize,
                                                   anchor: anchor, factor: v.magnification)
                    }
                    .onEnded { _ in magnifyBase = nil }
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.paper))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        // An in-window card, not an NSPopover: a popover dies the moment the app deactivates,
        // and looking something up mid-fight means alt-tabbing back to the game.
        .overlay(alignment: .topLeading) {
            if let m = cardMob {
                MobCardView(name: m, onClose: { cardMob = nil })
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
                    .shadow(color: .black.opacity(0.55), radius: 18, y: 6)
                    .offset(x: max(8, min(cardAnchor.midX - 190, canvasSize.width - 396)),
                            y: max(8, min(cardAnchor.midY + 14, max(8, canvasSize.height - 536))))
            }
        }
        .overlay(alignment: .topTrailing) {
            if !paneOpen {
                Button {
                    paneOpen = true
                    UserDefaults.standard.removeObject(forKey: Self.paneKey)
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .buttonStyle(.borderless)
                .padding(6)
                .help("Find a mob or label")
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !store.ready {
                Text("Looking for map files\u{2026}").font(.callout).foregroundStyle(Theme.textDim)
            } else if store.zones.isEmpty {
                Text("No map files were found in your EverQuest folder. The game ships them under maps\\ - set your install folder in Preferences if this looks wrong.")
                    .font(.callout).foregroundStyle(Theme.textDim)
                if let e = store.scanError {
                    Text(e).font(.caption).foregroundStyle(Theme.textFaint)
                }
            } else if let raw = rawZone, autoZone == nil, sel.zone == nil {
                Text("We don\u{2019}t have a map name for \u{201C}\(raw)\u{201D} yet - pick one above.")
                    .font(.callout).foregroundStyle(Theme.textDim)
            } else if sel.zone == nil {
                Text("Pick a zone above to open its map.").font(.callout).foregroundStyle(Theme.textDim)
            } else if store.loading {
                Text("Reading \(sel.zone ?? "")\u{2026}").font(.callout).foregroundStyle(Theme.textDim)
            }
            if let e = store.error, sel.zone != nil, !store.loading {
                Text(e).font(.callout).foregroundStyle(Theme.textDim)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16)
    }

    // MARK: - The pane

    private var pane: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                TextField("Find a mob or label\u{2026}", text: $query)
                    .textFieldStyle(.roundedBorder)
                if !query.isEmpty {
                    // The X clears the filter — every mob comes back on the map.
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Theme.textFaint)
                        .help("Clear the search - every mob and label comes back")
                }
                Button {
                    paneOpen = false
                    UserDefaults.standard.set("0", forKey: Self.paneKey)
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.textFaint)
                .help("Hide this panel")
            }
            HStack(spacing: 6) {
                Chip(text: "\(counts.located)/\(counts.mobs) placed")
                    .help("\(counts.located) of \(counts.mobs) named mobs here state a position")
                Chip(text: "\(counts.labels) labels")
                if placed.capped { Chip(text: "first \(MapPaneRows.maxPins) pinned", color: Theme.orange) }
                Spacer(minLength: 0)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    section(title: "Named mobs", note: "wiki", rows: mobs,
                            empty: zoneName == nil ? "No zone is open."
                                : counts.mobs == 0 ? "The mob catalog has no rows for this zone."
                                : "No mob matches.")
                    section(title: "Map labels", note: "this map", rows: labelRows,
                            empty: data == nil ? "No map is open."
                                : counts.labels == 0 ? "This map has no label points."
                                : "No label matches.")
                }
            }
        }
        .padding(8)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.paper))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
    }

    @ViewBuilder
    private func section(title: String, note: String, rows: [MapPaneRow], empty: String) -> some View {
        HStack(spacing: 5) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(Theme.textDim)
            Text(note).font(.caption).foregroundStyle(Theme.textFaint)
        }
        .padding(.horizontal, 4).padding(.top, 6).padding(.bottom, 2)

        if rows.isEmpty {
            Text(empty).font(.caption).foregroundStyle(Theme.textFaint).padding(.horizontal, 4).padding(.bottom, 4)
        } else {
            ForEach(rows.prefix(300)) { row in
                Button { select(row) } label: { paneRow(row) }
                    .buttonStyle(.plain)
                    .disabled(!row.locatable)
            }
            if rows.count > 300 {
                Text("\(rows.count - 300) more - narrow the search.")
                    .font(.caption).foregroundStyle(Theme.textFaint).padding(.horizontal, 4).padding(.vertical, 4)
            }
        }
    }

    private func paneRow(_ row: MapPaneRow) -> some View {
        HStack(alignment: .top, spacing: 6) {
            // The pin column states whether this row lands on a SPOT. A map label always does; a
            // wiki mob does only when its page stated a position it can attribute to this zone.
            Image(systemName: "mappin")
                .font(.system(size: 10))
                .foregroundStyle(row.locatable ? Theme.gold : .clear)
                .frame(width: 12)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name).font(.callout).foregroundStyle(row.locatable ? Theme.text : Theme.textDim).lineLimit(1)
                if let n = row.note { Text(n).font(.caption).foregroundStyle(Theme.textFaint).lineLimit(1) }
            }
            Spacer(minLength: 0)
            if let l = row.level, !l.isEmpty {
                Text(l).font(.caption).foregroundStyle(Theme.textFaint)
            }
        }
        .padding(.horizontal, 4).padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 4)
            .fill(row.id == selectedId ? Theme.gold.opacity(0.12) : Color.clear))
        .contentShape(Rectangle())
    }

    // MARK: - Credits

    @ViewBuilder private var credits: some View {
        let line = data?.credits.joined(separator: " · ") ?? ""
        // A NO-BREAK space, spelled out: an ordinary one collapses and the reserved footer would
        // be zero pixels tall, which moves the map every time a pack with credits loads.
        Text(line.isEmpty ? "\u{00a0}" : line)
            .font(.caption)
            .foregroundStyle(Theme.textFaint)
            .lineLimit(1)
            .help(line)
    }

    // MARK: - Actions

    private func pick(_ zone: ZoneShort) {
        sel = MapZoneSelection.onPick(zone)
        sel.save()
    }

    private func zoomBy(_ factor: Double) {
        zoomAt(MapScreenPos(px: canvasSize.width / 2, py: canvasSize.height / 2), factor)
    }

    private func zoomAt(_ anchor: MapScreenPos, _ factor: Double) {
        zoomed = MapGeo.zoomAround(camera, bounds: bounds, vp: canvasSize, anchor: anchor, factor: factor)
    }

    private func centerOn(_ at: MapXY) {
        let scale = zoomedIn ? camera.scale : camera.scale * Self.jumpZoom
        zoomed = MapGeo.clamp(MapCamera(cx: at.x, cy: at.y, scale: scale), bounds, canvasSize)
    }

    private func select(_ row: MapPaneRow) {
        guard let at = row.target else { return }
        selectedId = row.id
        selectedAt = at
        centerOn(at)
    }

    /// A click on the canvas: the nearest mob pin within reach opens its card, anchored there.
    private func tapPin(at p: CGPoint) {
        var best: (MapPaneRows.PlacedPin, Double)?
        for pin in placed.pins {
            let sp = MapGeo.project(camera, canvasSize, MapXY(x: pin.pin.x, y: pin.pin.y))
            let d = hypot(sp.px - p.x, sp.py - p.y)
            if d <= 14, d < (best?.1 ?? .infinity) { best = (pin, d) }
        }
        guard let (pin, _) = best else { cardMob = nil; return }   // empty ground closes the card
        selectedId = pin.rowId
        selectedAt = MapXY(x: pin.pin.x, y: pin.pin.y)
        cardAnchor = CGRect(x: p.x, y: p.y, width: 1, height: 1)
        cardMob = pin.name
    }

    /// A "Show on map" from another tab: open the zone, then put the camera on the mob once its
    /// rows are in. Consumed exactly once.
    private func consumeJump() {
        guard let j = MapJump.shared.pending else { return }
        if let z = j.zone, z != sel.zone { pick(z); if j.mob.isEmpty { MapJump.shared.clear() }; return }
        if j.mob.isEmpty { MapJump.shared.clear(); return }   // a zone-only jump is done here
        guard !allMobs.isEmpty || MapJump.shared.pending?.zone == nil else { return }
        if let row = allMobs.first(where: { $0.kind == .mob && $0.name.caseInsensitiveCompare(j.mob) == .orderedSame })
            ?? allMobs.first(where: { $0.kind == .mob && $0.name.localizedCaseInsensitiveContains(j.mob) }) {
            query = ""
            select(row)
            if row.target != nil {
                cardAnchor = CGRect(x: canvasSize.width / 2, y: canvasSize.height / 2, width: 1, height: 1)
                cardMob = row.name
            }
            MapJump.shared.clear()
        } else if !allMobs.isEmpty {
            // The zone is open but the catalog places no such row: leave the search saying why.
            query = j.mob
            MapJump.shared.clear()
        }
    }

    private func placeLoc() {
        switch MapLoc.parse(locText) {
        case .bad(let reason):
            locError = reason
        case .ok(let loc):
            locError = nil
            locText = ""
            guard let zone = sel.zone else { return }
            locs.byZone[zone] = loc
            locs.save()
            showLoc(loc)
        }
    }

    private func showLoc(_ loc: EqLoc) {
        let p = MapGeo.mapFromLoc(loc)
        centerOn(MapXY(x: p.x, y: p.y))
    }

    /// Scroll-wheel zoom, anchored where the pointer is. The hover phase is the gate: without a
    /// pointer over the surface the event belongs to whatever else is scrolling.
    private func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { ev in
            guard let h = hover, canvasSize.width > 0 else { return ev }
            let delta = Double(ev.scrollingDeltaY) * (ev.hasPreciseScrollingDeltas ? 0.01 : 0.08)
            if delta == 0 { return ev }
            let factor = min(MapGeo.zoomStep, max(1 / MapGeo.zoomStep, exp(delta)))
            zoomAt(MapScreenPos(px: h.x, py: h.y), factor)
            return nil
        }
    }
}

// MARK: - Zone picker

/// The zone list is the map STEMS on disk (what the files are called), labelled with the long
/// name where the app knows one. Both spellings are shown, and either can be typed.
private struct MapZonePicker: View {
    var zones: [ZoneShort]
    var zone: ZoneShort?
    var ready: Bool
    var onPick: (ZoneShort) -> Void

    @State private var open = false
    @State private var filter = ""
    /// The row the arrow keys are on; Return picks it. Follows the filter, never survives it.
    @State private var highlighted = 0

    private func longName(_ short: ZoneShort) -> String {
        GameData.shared.zones.first { $0.short == short }?.name ?? short
    }

    private var options: [ZoneShort] {
        let q = filter.lowercased().trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return Array(zones.prefix(400)) }
        let scored: [(ZoneShort, Int)] = zones.compactMap { z in
            let name = longName(z).lowercased()
            if z.hasPrefix(q) { return (z, 0) }
            if name.hasPrefix(q) { return (z, 1) }
            if z.contains(q) { return (z, 2) }
            if name.contains(q) { return (z, 3) }
            return nil
        }
        return scored.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 < $1.1 }.prefix(200).map(\.0)
    }

    var body: some View {
        Button { open = true } label: {
            HStack(spacing: 6) {
                Text(zone.map(longName) ?? "Zone").font(.caption).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9))
            }
            .frame(width: 200, alignment: .leading)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.paperRaised))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border))
            .foregroundStyle(Theme.text)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Find a zone\u{2026}", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: filter) { _, _ in highlighted = 0 }
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onSubmit { pickHighlighted() }
                if options.isEmpty {
                    Text(zones.isEmpty ? (ready ? "No map files were found." : "Looking for map files\u{2026}")
                                       : "No zone matches.")
                        .font(.caption).foregroundStyle(Theme.textFaint)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(options.enumerated()), id: \.element) { i, z in
                                    Button {
                                        pick(z)
                                    } label: {
                                        VStack(alignment: .leading, spacing: 0) {
                                            Text(longName(z)).font(.callout).foregroundStyle(Theme.text)
                                            Text(z).font(.caption).foregroundStyle(Theme.textFaint)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 6).padding(.vertical, 3)
                                        .background(RoundedRectangle(cornerRadius: 4)
                                            .fill(i == highlighted ? Theme.gold.opacity(0.22)
                                                  : z == zone ? Theme.gold.opacity(0.12) : Color.clear))
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .id(z)
                                }
                            }
                        }
                        .frame(height: 320)
                        .onChange(of: highlighted) { _, i in
                            if options.indices.contains(i) { proxy.scrollTo(options[i]) }
                        }
                    }
                }
            }
            .padding(10)
            .frame(width: 280)
        }
    }

    private func move(_ d: Int) {
        guard !options.isEmpty else { return }
        highlighted = min(max(0, highlighted + d), options.count - 1)
    }

    /// Return in the field picks the highlighted row (the first row until the arrows move it).
    private func pickHighlighted() {
        guard options.indices.contains(highlighted) else { return }
        pick(options[highlighted])
    }

    private func pick(_ z: ZoneShort) {
        onPick(z)
        open = false
        filter = ""
        highlighted = 0
    }
}

// MARK: - Pack menus and layer toggles

private struct MapPackMenu: View {
    var label: String
    var value: String?
    var packs: [MapPack]
    var onChange: (String?) -> Void

    var body: some View {
        Menu {
            Button("Auto") { onChange(nil) }
            ForEach(packs) { p in
                Button(p.name) { onChange(p.id) }
            }
        } label: {
            Text("\(label): \(value.flatMap { id in packs.first { $0.id == id }?.name } ?? "Auto")")
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .frame(width: 190)
        .help(label == "Geometry"
              ? "Which pack draws the walls. Auto prefers the game's own files."
              : "Which pack supplies the labels and the legend. Auto prefers an installed pack over the game's own thin set.")
    }
}

/// Layer visibility. Not a SegmentPicker: these are three independent toggles, and a
/// single-selection control would lie about that.
private struct MapLayerToggle: View {
    @Binding var layers: [Bool]
    private static let toggleable: [(layer: Int, name: String)] = [(1, "LABELS"), (2, "LEGEND"), (3, "EXTRA")]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Self.toggleable, id: \.layer) { t in
                let on = t.layer < layers.count && layers[t.layer]
                Button {
                    var next = layers
                    while next.count <= t.layer { next.append(false) }
                    next[t.layer] = !on
                    layers = next
                } label: {
                    Text(t.name)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .foregroundStyle(on ? Theme.gold : Theme.textDim)
                        .background(on ? Theme.gold.opacity(0.14) : Color.clear)
                }
                .buttonStyle(.plain)
            }
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.paperRaised))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border))
    }
}

// MARK: - A wrapping row

/// The toolbar is a row that must WRAP rather than clip: every control in it is how you get out
/// of the state you are in, so none of them may fall off the end at a narrow window.
struct MapFlow: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    private func rows(_ sizes: [CGSize], width: CGFloat) -> [[Int]] {
        var out: [[Int]] = [[]]
        var x: CGFloat = 0
        for (i, s) in sizes.enumerated() {
            let w = s.width
            if !out[out.count - 1].isEmpty && x + spacing + w > width {
                out.append([i])
                x = w
            } else {
                if !out[out.count - 1].isEmpty { x += spacing }
                out[out.count - 1].append(i)
                x += w
            }
        }
        return out
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        // An unbounded proposal (a split view probing) must not be echoed back as our width —
        // an infinite answer wrecks every ancestor. Answer with the one-line width instead.
        // Nil ("what is your ideal?") gets the widest child — the flow can wrap to that; a flow
        // whose ideal is one unwrapped line makes every ancestor want to be that wide.
        let width: CGFloat
        if let w = proposal.width, w.isFinite { width = w }
        else if proposal.width == nil { width = sizes.map(\.width).max() ?? 0 }
        else { width = sizes.reduce(CGFloat(0)) { $0 + $1.width } + spacing * CGFloat(max(0, sizes.count - 1)) }
        let lines = rows(sizes, width: width)
        var h: CGFloat = 0
        for (i, line) in lines.enumerated() {
            let lh = line.map { sizes[$0].height }.max() ?? 0
            h += lh + (i > 0 ? lineSpacing : 0)
        }
        return CGSize(width: width, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        var y = bounds.minY
        for line in rows(sizes, width: bounds.width) {
            let lh = line.map { sizes[$0].height }.max() ?? 0
            var x = bounds.minX
            for i in line {
                subviews[i].place(at: CGPoint(x: x, y: y + (lh - sizes[i].height) / 2),
                                  proposal: ProposedViewSize(sizes[i]))
                x += sizes[i].width + spacing
            }
            y += lh + lineSpacing
        }
    }
}
