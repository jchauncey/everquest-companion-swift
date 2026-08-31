// The gear search table: every equippable page in the committed corpus, filtered and sorted on
// numbers that move with the upgrade slider.
//
// THE SLIDER IS A PURE MAP. `rows.map { $0.scaled(state) }` runs BEFORE filter and sort, so a
// threshold filter and a column sort both read the scaled numbers, and moving the slider costs one
// pass over the corpus rather than an index rebuild.
//
// ABSENT IS NOT ZERO. A cell whose item stated no value for that key renders BLANK and sorts LAST
// in both directions — an item with no `HASTE:` line is not an item with 0% haste.
import SwiftUI
import EQCompanionCore

/// The Effect dropdown's options, verbatim.
private let effectOptions: [(String, String)] = [
    ("any", "Any effect"), ("has", "Has an effect"),
    ("proc", "Proc"), ("worn", "Worn"), ("focus", "Focus"), ("click", "Click")
]

struct GearTableView: View {
    @Environment(AppModel.self) private var model
    @State private var index = GearIndex.shared
    @State private var store = InventoryStore.shared
    @State private var wishes = WishListStore.shared
    @State private var combo = ModuleSnapshot()
    @State private var loot = ModuleSnapshot()

    @State private var query = ""
    @State private var slots: Set<String> = []
    @State private var weapons: Set<String> = []
    @State private var effect = "any"
    @State private var classes: Set<String> = []
    @State private var classesPinned = false
    @State private var zones: Set<String> = []
    @State private var eraOnly = true
    @State private var ownedOnly = false
    @State private var tier = 0
    @State private var fraction = 0
    @State private var sortKey = "AC"
    @State private var sortDescending = true
    @State private var opened: GearRow?
    @State private var widths = GearColumnWidths.shared

    private var showsWeaponColumns: Bool {
        GearColumnSet.showsWeaponColumns(slots: slots, weapons: weapons)
    }

    /// The numeric columns the table draws, in order. See `GearColumnSet`.
    private var numericColumns: [String] {
        GearColumnSet.numeric(slots: slots, weapons: weapons, sortKey: sortKey)
    }

    private var upgradeState: ItemUpgradeState {
        ItemUpgradeState(full: tier, fraction: fraction).normalized
    }

    /// The classes the log says you are playing — the picker's default until the player edits it,
    /// which pins it.
    private var detectedClasses: [String] {
        (combo.state["current"]["slots"].array ?? []).compactMap { slot in
            let c = (slot["candidates"].array ?? []).compactMap(\.string)
            return c.count == 1 ? c[0] : nil
        }
    }

    /// Every item name this character's loot history saw.
    ///
    /// READ FROM THE `loot` MODULE SNAPSHOT, NOT THE `loot.ledger` VIEW. The view source is a
    /// windowed table and its window maxes out at 1000 rows; the owner's own ledger is 2,404, so a
    /// view-backed set would have quietly answered "never looted" for the older 1,400 — the exact
    /// shape of a filter that hides gear the player has held in their hands. The module's state is
    /// the whole array.
    private var lootedNames: Set<String> {
        // The ` +N` comes off first: `Cloak of Flames +4` and `Cloak of Flames` are one item at the
        // counting boundary, which is the join the corpus key is on.
        Set((loot.state.array ?? []).compactMap {
            $0["item"].string.map { GameData.nameKey(parseItemName($0).base) }
        })
    }

    var body: some View {
        // ONE pass over the corpus per render: the caption and the table are two readings of the
        // same answer, and computing it twice would double the cost of every keystroke. The loot
        // set is folded once here for the same reason — it is 2,404 rows and both the filter and
        // the Owned column read it.
        let looted = lootedNames
        let result = pipeline(looted)
        return VStack(alignment: .leading, spacing: 8) {
            controls
            caption(result)
            // A search that found more than it is showing says so, and names what removed the rest.
            if index.ready, let n = GearBlame.hiddenText(rows: index.rows, filters: activeFilters(looted)) {
                Text(n).font(.caption).foregroundStyle(Theme.orange)
            }
            if !index.ready {
                Spacer()
                Text("Reading the item database\u{2026}").font(.callout).foregroundStyle(Theme.textDim)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                table(result, looted: looted)
            }
        }
        // A wider gutter than the 12pt the other tabs use: this tab's content runs edge to edge, so
        // it needs visible air between the first column and the sidebar rather than nearly touching it.
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.background)
        .onAppear {
            index.start()
            wishes.bind(character: model.attached)
        }
        .task(id: "combo|\(model.moduleSeqs["combo"] ?? 0)|\(model.epoch ?? 0)") {
            await combo.refresh(model, module: "combo")
            if !classesPinned { classes = Set(detectedClasses) }
        }
        .task(id: "loot|\(model.moduleSeqs["loot"] ?? 0)|\(model.epoch ?? 0)") {
            await loot.refresh(model, module: "loot")
        }
        // Filtering down to armour while sorted by Ratio would otherwise leave the table ordered by
        // a column that is gone and empty for every row in it. The sort falls back to AC, which
        // every armour page states.
        .onChange(of: showsWeaponColumns) { _, shows in
            guard !shows, gearWeaponColumnKeys.contains(sortKey) else { return }
            sortKey = "AC"
            sortDescending = true
        }
        .task(id: "inv|\(model.moduleSeqs["outputFiles"] ?? 0)|\(model.epoch ?? 0)") {
            await store.refresh(model, seq: model.moduleSeqs["outputFiles"] ?? 0)
        }
        .sheet(item: $opened) { row in
            // THE item card — the same surface the map's mob card and the Loot drill-down draw.
            ItemCardView(name: row.name, onClose: { opened = nil })
                .padding(12)
                .frame(width: 560, height: 640)
                .background(Theme.background)
        }
        // The global search's item jump: the table filters to the item and its card opens.
        .task(id: ItemJump.shared.pending?.seq ?? 0) { consumeItemJump() }
        .onChange(of: index.ready) { _, _ in consumeItemJump() }
    }

    // MARK: - Controls

    /// THE FILTERS WRAP, and that is a layout constraint on the whole tab, not a nicety.
    ///
    /// As a plain `HStack` this row reported its ideal width as the whole unwrapped line - wider
    /// than a narrow window's pane. The enclosing `VStack` takes its width from its widest child,
    /// so the stack became wider than the pane, and an oversized child is not clipped but CENTRED:
    /// every sibling, the table included, was dragged left underneath the sidebar, which is what
    /// cut the item names in half. `FlowRow` answers "as narrow as my widest control" instead.
    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            FlowRow(spacing: 8, lineSpacing: 8) {
                TextField("Search gear", text: $query)
                    .textFieldStyle(.roundedBorder).frame(width: 200)
                multiPicker(title: "Slots", empty: "every slot", options: equipSlots, selection: $slots)
                multiPicker(title: "Weapon type", empty: "every kind", options: weaponPicks,
                            selection: $weapons, label: { weaponPickLabel[$0] ?? $0 })
                Picker("", selection: $effect) {
                    ForEach(effectOptions, id: \.0) { Text($0.1).tag($0.0) }
                }
                .labelsHidden().fixedSize()
                multiPicker(title: "Classes", empty: "every class", options: classAbbrs,
                            selection: $classes, onEdit: { classesPinned = true })
                // 155 zones is too many to hunt through a menu, so this one is typed at rather
                // than scrolled - and what is already chosen stays pinned at the top of it.
                FilterMultiPicker(title: "Zones", empty: "everywhere",
                                  options: index.corpus.dropZones, selection: $zones,
                                  placeholder: "Find a zone\u{2026}")
            }
            FlowRow(spacing: 8, lineSpacing: 8) {
                toggleChip("Current era", on: $eraOnly, help: "Hide items from outside \(currentEraLabel)")
                toggleChip("Owned or looted", on: $ownedOnly,
                           help: "Keep only what your newest /outputfile inventory dump names or your loot history saw. Some key rings are not counted - see the Owned column.")
                Divider().frame(height: 18).overlay(Theme.border)
                Text("Simulate upgrade").font(.caption).foregroundStyle(Theme.textDim)
                Slider(value: Binding(
                    get: { Double(tier) },
                    set: { v in
                        tier = Int(v.rounded())
                        fraction = min(fraction, max(0, (1 << max(0, min(9, tier))) - 1))
                    }), in: 0...Double(GearUpgrade.maxTier), step: 1)
                    .frame(width: 170)
                if tier > 0 && tier < GearUpgrade.maxTier {
                    Slider(value: Binding(get: { Double(fraction) }, set: { fraction = Int($0.rounded()) }),
                           in: 0...Double((1 << tier) - 1), step: 1)
                        .frame(width: 110)
                }
                Text(upgradeLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(tier == 0 && fraction == 0 ? Theme.textDim : Theme.gold)
                    .frame(width: 140, alignment: .leading)
                    .help("What the table is showing: every stat scaled to this upgrade state, the way the item window reads it.")
            }
        }
    }

    private func consumeItemJump() {
        guard let j = ItemJump.shared.pending else { return }
        guard index.ready || !index.rows.isEmpty else { index.start(); return }
        query = j.name
        opened = index.rows.first { $0.name.caseInsensitiveCompare(j.name) == .orderedSame }
            ?? index.rows.first { $0.name.lowercased().hasPrefix(j.name.lowercased()) }
        ItemJump.shared.clear()
    }

    private var upgradeLabel: String {
        let s = upgradeState
        var out = "Tier \(s.full)"
        if s.full > 0 && s.full < GearUpgrade.maxTier { out += " \u{00b7} \(s.fraction)/\(1 << s.full)" }
        return out + " \u{00b7} " + s.percentLabel
    }

    private func toggleChip(_ label: String, on: Binding<Bool>, help: String) -> some View {
        Button { on.wrappedValue.toggle() } label: {
            Chip(text: label, color: on.wrappedValue ? Theme.gold : Theme.textDim, filled: on.wrappedValue)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func multiPicker(title: String, empty: String, options: [String],
                             selection: Binding<Set<String>>,
                             label: @escaping (String) -> String = { $0 },
                             onEdit: @escaping () -> Void = {}) -> some View {
        Menu {
            Button("Clear") { selection.wrappedValue = []; onEdit() }
            Divider()
            ForEach(options, id: \.self) { o in
                Button {
                    if selection.wrappedValue.contains(o) { selection.wrappedValue.remove(o) }
                    else { selection.wrappedValue.insert(o) }
                    onEdit()
                } label: {
                    Label(label(o), systemImage: selection.wrappedValue.contains(o) ? "checkmark" : "")
                }
            }
        } label: {
            Text(pickerSummary(title: title, empty: empty, options: options,
                               picked: selection.wrappedValue, label: label))
                .lineLimit(1)
        }
        // The system's own pull-down bezel, sized to its text, and NOTHING after `fixedSize` that
        // could hand it a flexible width again: `.borderlessButton` in a fixed frame drew a
        // chrome-less label floating in a pool of its own padding (the drab look), and a trailing
        // `maxWidth` let each menu stretch into the row's slack (the gaps between them). The label
        // is bounded by shortening the TEXT, so the control is never wider than what it says.
        .menuStyle(.automatic)
        .fixedSize()
    }


    // MARK: - The pipeline

    /// Every row at the slider's state — the map that has to be the whole cost of moving it.
    private struct ScaledRow: Identifiable {
        var row: GearRow
        var stats: [String: Int]
        var id: String { row.key }
    }

    private func value(_ r: ScaledRow, _ key: String) -> Double? {
        switch key {
        case "RATIO": return damageRatio(r.stats)
        case "EFF_HP": return gearEffectiveHp(r.stats).map(Double.init)
        default: return r.stats[key].map(Double.init)
        }
    }

    /// Only the filters that are actually narrowing anything. An inactive control can't be blamed.
    private func activeFilters(_ looted: Set<String>) -> [GearFilter] {
        var out: [GearFilter] = []
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        if !needle.isEmpty {
            out.append(GearFilter(label: "the search box", anchor: true) { $0.searchKey.contains(needle) })
        }
        if !slots.isEmpty {
            let want = slots
            out.append(GearFilter(label: "the Slots picker") { $0.slots.contains(where: { want.contains($0) }) })
        }
        if !weapons.isEmpty {
            let want = weapons
            out.append(GearFilter(label: "the Weapon type picker") { row in
                guard let t = row.weaponType else { return false }
                return want.contains { weaponPickCovers($0, t) }
            })
        }
        switch effect {
        case "any": break
        case "has": out.append(GearFilter(label: "the effect picker") { !$0.effects.isEmpty })
        default:
            let want = effect
            out.append(GearFilter(label: "the effect picker") { $0.effects.contains { $0.socket == want } })
        }
        if !classes.isEmpty {
            let want = classes
            // A page that states NO class list is never hidden by the class picker: `[]` means the
            // wiki declined to say, not that nobody can use it.
            out.append(GearFilter(label: "the Classes picker") {
                $0.classes.isEmpty || $0.classes.contains { want.contains($0) }
            })
        }
        if !zones.isEmpty {
            let want = zones
            // STRICT, unlike the Classes picker. An empty class list means "the wiki declined to
            // say", so hiding those items would hide gear anyone can wear. An empty DROP list means
            // something else: 3,328 of the corpus's 6,984 rows state no zone because they are quest
            // rewards, crafted or bought, not because their zone is unrecorded. Letting those
            // through would answer "what drops in Lower Guk" with 74 Guk items and 3,328 that come
            // from nowhere near it.
            out.append(GearFilter(label: "the Zones picker") { row in
                row.drops.contains { want.contains($0.zone) }
            })
        }
        if eraOnly {
            // Note that an UNKNOWN era hides too — the Electron rule, and the honest one for a
            // control whose promise is "only what you can go and get tonight".
            out.append(GearFilter(label: "the Current era toggle") { $0.era == .inEra })
        }
        if ownedOnly {
            let ownership = store.ownership
            out.append(GearFilter(label: "the Owned or looted toggle") { row in
                let own = ownership[row.key]
                return (own?.owned ?? false) || (own?.exaltations ?? 0) > 0 || looted.contains(row.key)
            })
        }
        return out
    }

    private func pipeline(_ looted: Set<String>) -> (rows: [ScaledRow], total: Int) {
        let all = index.rows
        let state = upgradeState
        let filters = activeFilters(looted)

        var out: [ScaledRow] = []
        out.reserveCapacity(1024)
        for row in all where filters.allSatisfy({ $0.keeps(row) }) {
            out.append(ScaledRow(row: row, stats: row.scaled(state)))
        }

        let key = sortKey
        let sign = sortDescending ? -1.0 : 1.0
        out.sort { a, b in
            // Text columns sort as text, and an EMPTY cell sorts last in both directions - the
            // same rule the numeric columns use for a missing stat, so "sort by zone" opens with
            // the items that state one rather than a screen of blanks.
            if let at = sortText(a, key, looted: looted), let bt = sortText(b, key, looted: looted) {
                if at.isEmpty != bt.isEmpty { return bt.isEmpty }
                if at.caseInsensitiveCompare(bt) != .orderedSame {
                    let c = at.localizedCaseInsensitiveCompare(bt)
                    return sortDescending ? c == .orderedDescending : c == .orderedAscending
                }
                return a.row.name.localizedCaseInsensitiveCompare(b.row.name) == .orderedAscending
            }
            let av = value(a, key), bv = value(b, key)
            // `nil` sorts LAST in both directions; ties break by name, so the order is total.
            if av == nil && bv == nil { return a.row.name < b.row.name }
            guard let av else { return false }
            guard let bv else { return true }
            if av == bv { return a.row.name < b.row.name }
            return sign * av < sign * bv
        }
        return (out, all.count)
    }

    // MARK: - The caption

    private func caption(_ p: (rows: [ScaledRow], total: Int)) -> some View {
        HStack(spacing: 6) {
            Text("\(Format.count(p.rows.count)) of \(Format.count(p.total)) items")
            if let at = index.corpus.scrapedAt { Text("\u{00b7} wiki data from \(at)") }
            if let at = store.updatedAt {
                Text("\u{00b7} dump \(inventoryAge(ms: at, now: nowMs()))")
            }
            Spacer(minLength: 0)
        }
        .font(.caption).foregroundStyle(Theme.textFaint)
    }

    // MARK: - The table

    /// The width the columns actually need, so the table can be SCROLLED to rather than squeezed.
    /// One definition, shared with what the row draws - see `GearColumnSet.totalWidth`.
    private func tableWidth(showOwned: Bool) -> CGFloat {
        GearColumnSet.totalWidth(columns(showOwned: showOwned)) { widths.width($0) }
    }

    /// A column's frame. The flexible column ASKS FOR THE REST rather than being handed a computed
    /// number, and that is the whole point.
    ///
    /// It used to be arithmetic: measure the pane, subtract what the fixed columns need, give the
    /// difference to the flexible one. That makes a row exactly as wide as the space it was
    /// offered - with no give at all - so the moment anything took a few points away, the row was
    /// over-committed. macOS does exactly that: when the rows outgrow the viewport the vertical
    /// scroller claims ~15pt of content width, the row overflowed by that much, and an over-wide
    /// HStack CENTRES its overflow - putting half of it off the left edge, where it sliced the
    /// first thing in every row, the item icon. (`client.log`: `insetFromPane=0` on the first
    /// layout, then `-8` once the scroller appeared.)
    ///
    /// Asking for `maxWidth: .infinity` instead means the row absorbs whatever it is actually
    /// given, whether or not something else took a bite out of it first.
    @ViewBuilder
    private func columnFrame(_ c: GearColumn, _ content: some View) -> some View {
        let alignment: Alignment = c.trailing ? .trailing : .leading
        if c.flexible {
            content.frame(maxWidth: .infinity, alignment: alignment)
        } else {
            content.frame(width: widths.width(c), alignment: alignment)
        }
    }

    private func table(_ result: (rows: [ScaledRow], total: Int), looted: Set<String>) -> some View {
        let rows = result.rows
        let showOwned = !store.ownership.isEmpty || !looted.isEmpty
        let cols = columns(showOwned: showOwned)
        return GeometryReader { geo in
            // WIDER THAN THE PANE, THE TABLE SCROLLS; NARROWER, IT FILLS.
            //
            // An HStack wider than the width it is offered does not clip on the right - it spreads
            // the overflow BOTH ways, and the half that goes left ends up under the sidebar, eating
            // the item names. Inside a horizontal ScrollView the row is offered exactly the width
            // it asked for, so nothing overflows and the columns a narrow window cannot show are
            // scrolled to instead of stolen from the ones it can.
            //
            // The other direction is the dead band this replaces: columns totalling less than the
            // pane used to stop short, leaving a couple of hundred points of empty window. That
            // leftover now goes to the flexible column, so the table always reaches the far edge.
            // Read the proxy ONCE. A `GeometryProxy` is live, not a snapshot: read again later (in
            // an async task, say) it answers with the size at THAT moment, which is how the
            // diagnostic below once reported a pane wider than the content inside it.
            let pane = geo.size.width
            let paneX = geo.frame(in: .global).minX
            let need = tableWidth(showOwned: showOwned)
            // A horizontal ScrollView is only reached for when the columns genuinely do not fit.
            //
            // It is not free: macOS backs it with an NSScrollView that adjusts its own content
            // insets, and with the vertical scroller nested inside it the content sat 8pt LEFT of
            // the pane - which sliced the left edge off the first thing in every row, the item
            // icon. (`insetFromPane=-8` in client.log, against a gutter of exactly 8.) When the
            // table fits, which is the normal case now that the flexible column absorbs the
            // leftover, there is nothing to scroll and nothing to inset.
            let scrolls = need > pane + 0.5
            VStack(spacing: 0) {
                if rows.isEmpty {
                    Text(emptyText(looted)).font(.callout).foregroundStyle(Theme.textDim)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .multilineTextAlignment(.center).padding(.horizontal, 24)
                } else if scrolls {
                    ScrollView(.horizontal) {
                        stack(rows, showOwned: showOwned, looted: looted, width: need, paneX: paneX)
                    }
                } else {
                    stack(rows, showOwned: showOwned, looted: looted, width: nil, paneX: paneX)
                }
            }
            .frame(width: pane, height: geo.size.height, alignment: .topLeading)
            // Nobody working on this app can see it run, so the table states its own geometry to
            // client.log - once per distinct layout, not per frame. Reading these numbers back beats
            // reasoning about a screenshot: they say outright whether the content is wider than the
            // pane (so it scrolls) and where the first cell of the first row actually begins.
            .task(id: layoutDiagnostic(cols: cols, pane: pane, need: need, scrolls: scrolls)) {
                model.note(layoutDiagnostic(cols: cols, pane: pane, need: need, scrolls: scrolls))
            }
        }
    }

    /// The header and the rows, INSIDE the same scroll view.
    ///
    /// The header used to sit above it, outside. That put the two in containers of different width
    /// the moment the vertical scroller claimed its share, so the columns could not stay lined up
    /// without the arithmetic that caused the clipping. Sharing one content width makes them agree
    /// by construction, and pinning the header makes it stay put as you scroll - which a table this
    /// tall wanted anyway.
    ///
    /// `width` is nil when the columns fit: the content then takes the viewport's width and the
    /// flexible column absorbs it. When they do not fit it is the width they need, and the caller
    /// has wrapped this in a horizontal scroll view.
    private func stack(_ rows: [ScaledRow], showOwned: Bool, looted: Set<String>,
                       width: CGFloat?, paneX: CGFloat) -> some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(Array(rows.prefix(500).enumerated()), id: \.element.id) { i, r in
                        row(r, showOwned: showOwned, looted: looted, probe: i == 0 ? paneX : nil)
                        Divider().overlay(Theme.border.opacity(0.5))
                    }
                    if rows.count > 500 {
                        Text("\(Format.count(rows.count - 500)) more - narrow the filters to see them.")
                            .font(.caption).foregroundStyle(Theme.textFaint).padding(8)
                    }
                } header: {
                    VStack(spacing: 0) {
                        header(showOwned: showOwned)
                        Divider().overlay(Theme.border)
                    }
                    .background(Theme.background)
                }
            }
            .frame(width: width, alignment: .leading)
        }
    }

    /// Where the first row's NAME CELL lands, relative to the pane. Always reports, icon or not.
    @ViewBuilder
    private func cellProbe(_ paneX: CGFloat?, item: String) -> some View {
        if let paneX {
            GeometryReader { g in
                let box = g.frame(in: .global)
                Color.clear.task(id: Int(box.minX - paneX)) {
                    model.note("gear first cell: \(item) insetFromPane=\(Int(box.minX - paneX))"
                               + " width=\(Int(box.width))")
                }
            }
        }
    }

    /// Reports where the first row's icon actually lands, relative to the pane it should sit in.
    /// A negative `insetFromPane` means the icon is drawn left of the table's own left edge - which
    /// is the only way its left side can be sliced off.
    @ViewBuilder
    private func iconProbe(_ paneX: CGFloat?, item: String, size: CGSize) -> some View {
        if let paneX {
            GeometryReader { g in
                let box = g.frame(in: .global)
                Color.clear.task(id: Int(box.minX - paneX)) {
                    model.note("gear first icon: \(item) insetFromPane=\(Int(box.minX - paneX))"
                               + " drawn=\(Int(box.width))x\(Int(box.height))"
                               + " source=\(Int(size.width))x\(Int(size.height))")
                }
            }
        }
    }

    /// One line describing the table's real layout, for `client.log`.
    private func layoutDiagnostic(cols: [GearColumn], pane: CGFloat,
                                  need: CGFloat, scrolls: Bool) -> String {
        let each = cols.map { c in
            c.flexible ? "\(c.key)=flex" : "\(c.key)=\(Int(widths.width(c)))"
        }.joined(separator: " ")
        return "gear table layout: pane=\(Int(pane)) need=\(Int(need)) "
            + "scrolls=\(scrolls) gutter=\(Int(GearColumnSet.gutter)) iconBox=24 columns[\(each)]"
    }

    private func emptyText(_ looted: Set<String>) -> String {
        GearBlame.text(rows: index.rows, filters: activeFilters(looted))
    }

    /// The columns, in order. The last three are the ones a player scans for after the numbers:
    /// where it drops, whether they already have it, and the one action the row offers.
    private func columns(showOwned: Bool) -> [GearColumn] {
        var out: [GearColumn] = [
            GearColumn(key: "name", label: "Item", kind: .name, defaultWidth: 300),
            GearColumn(key: "slot", label: "Slot", kind: .text, defaultWidth: 92),
            GearColumn(key: "classes", label: "Classes", kind: .text, defaultWidth: 104),
        ]
        // A stat cell holds two or three digits; the column only has to be as wide as its own
        // heading. Every point saved here is a point the item and zone names get to keep.
        out += numericColumns.map {
            GearColumn(key: $0, label: columnLabel($0), kind: .stat,
                       defaultWidth: $0.count > 4 ? 50 : 42, trailing: true)
        }
        // Zone takes the leftover width. It is the column whose content is most often cut short
        // ("Plane of Hate, Plane of…"), and unlike the item name it was never the one crowding the
        // table - so the space the window has spare goes somewhere it is read.
        out.append(GearColumn(key: "zone", label: "Zone", kind: .text, defaultWidth: 150, flexible: true))
        if showOwned { out.append(GearColumn(key: "owned", label: "Owned", kind: .text, defaultWidth: 96)) }
        out.append(GearColumn(key: "wish", label: "Wish list", kind: .wish, defaultWidth: 128))
        return out
    }

    private func columnLabel(_ key: String) -> String {
        if key == "RATIO" { return "Ratio" }
        return key.replacingOccurrences(of: "_", with: " ")
    }

    /// `spacing: 0` throughout: the gap between columns is the resize handle's own width, counted
    /// once by `tableWidth`. A second gap from the stack would make the drawn row wider than the
    /// frame that holds it, and the overflow would eat both ends of the table.
    private func header(showOwned: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(columns(showOwned: showOwned)) { c in
                HStack(spacing: 0) {
                    columnFrame(c, sortHeader(c))
                    GearColumnResizeHandle(current: widths.width(c),
                                           set: { widths.set(c, $0) },
                                           reset: { widths.reset() })
                }
            }
        }
        .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textFaint)
        .padding(.vertical, 5)
    }

    private func sortHeader(_ c: GearColumn) -> some View {
        Button {
            if sortKey == c.key { sortDescending.toggle() }
            // Numbers open biggest-first; text opens A-Z. Both are what the column is asked for.
            else { sortKey = c.key; sortDescending = c.kind == .stat }
        } label: {
            HStack(spacing: 2) {
                if c.trailing { Spacer(minLength: 0) }
                Text(c.label).lineLimit(1)
                if sortKey == c.key {
                    Image(systemName: sortDescending ? "chevron.down" : "chevron.up").font(.caption2)
                }
                if !c.trailing { Spacer(minLength: 0) }
            }
            .foregroundStyle(sortKey == c.key ? Theme.gold : Theme.textFaint)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func statText(_ v: Double?, _ key: String) -> String {
        guard let v else { return "" }
        if key == "RATIO" { return String(format: "%.2f", v) }
        if key == "WEIGHT" { return String(format: "%.1f", v) }
        if gearPercentStatKeys.contains(key) { return "\(Int(v))%" }
        return "\(Int(v))"
    }

    /// What a TEXT column sorts on, or nil when the key names a numeric column.
    private func sortText(_ r: ScaledRow, _ key: String, looted: Set<String>) -> String? {
        switch key {
        case "name": return r.row.name
        case "slot": return r.row.slots.joined(separator: " ")
        case "classes": return classText(r.row.classes)
        case "zone": return zoneText(r.row)
        case "owned": return ownedText(r.row, looted: looted)
        // Ascending puts what you already want first; the rest keep their name order.
        case "wish": return wishes.has(r.row.key) ? "0" : ""
        default: return nil
        }
    }

    /// The zones an item drops in, distinct and in the corpus's order.
    private func zoneText(_ r: GearRow) -> String {
        var seen = Set<String>()
        return r.drops.map(\.zone).filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: ", ")
    }

    private func ownedText(_ r: GearRow, looted: Set<String>) -> String {
        let t = store.ownership[r.key]?.cellText ?? ""
        return t.isEmpty && looted.contains(r.key) ? "Looted" : t
    }

    /// `probe` carries the pane's own global x for the FIRST row only: the icon compares its own
    /// global x against it and logs the difference, which is the number that says whether anything
    /// is drawn left of the pane (and so under the sidebar).
    private func row(_ r: ScaledRow, showOwned: Bool, looted: Set<String>,
                     probe: CGFloat? = nil) -> some View {
        HStack(spacing: 0) {
            ForEach(columns(showOwned: showOwned)) { c in
                // The gutter is padding, not a filler view: a `Color` is flexible on both axes and
                // would stretch the row the way it once stretched the header. It is also the row's
                // ONLY gap, so header and row agree column for column.
                columnFrame(c, cell(c, r, looted: looted, probe: c.kind == .name ? probe : nil))
                    .padding(.trailing, GearColumnSet.gutter)
                    // The name CELL reports too, not just the icon inside it: an item with no
                    // artwork drew no probe at all, which is why the log went quiet exactly when
                    // the answer was wanted.
                    .background(cellProbe(c.kind == .name ? probe : nil, item: r.row.name))
            }
        }
        .font(.system(size: 13))
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func cell(_ c: GearColumn, _ r: ScaledRow, looted: Set<String>,
                      probe: CGFloat? = nil) -> some View {
        switch c.kind {
        case .name:
            // THE NAME IS THE PART THAT GIVES WAY. Icon and era chip are fixed size; the name takes
            // whatever is left and truncates. Without that the row's content can exceed the column,
            // and an over-wide HStack is CENTRED, not clipped - which slid the icon off the left of
            // its own cell and sliced it against the edge of the table.
            HStack(spacing: 6) {
                if let img = GameData.shared.itemIcon(r.row.iconId) {
                    Image(nsImage: img).resizable().frame(width: 24, height: 24)
                        .background(iconProbe(probe, item: r.row.name, size: img.size))
                }
                Button { opened = r.row } label: {
                    Text(r.row.name)
                        .foregroundStyle(Color(hex: 0x6fbf7f))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                if r.row.era == .outOfEra { Chip(text: "out of era", color: Theme.orange) }
                else if r.row.era == .unknown { Chip(text: "era?", color: Theme.textFaint) }
            }
            .help(r.row.name)
        case .stat:
            Text(statText(value(r, c.key), c.key)).foregroundStyle(Theme.text).monospacedDigit()
        case .text:
            let text = switch c.key {
            case "slot": r.row.slots.joined(separator: " ")
            case "classes": classText(r.row.classes)
            case "zone": zoneText(r.row)
            default: ownedText(r.row, looted: looted)
            }
            Text(text).foregroundStyle(Theme.textDim).lineLimit(1)
                .help(c.key == "classes" ? r.row.classes.joined(separator: " ") : text)
        case .wish:
            let wished = wishes.has(r.row.key)
            Button {
                if wished { wishes.remove(r.row.key) }
                else { wishes.add(WishEntry(itemKey: r.row.key, name: r.row.name, kind: "gear",
                                            addedAt: nowMs(), source: "user")) }
            } label: {
                Text(wished ? "ON WISH LIST" : "ADD TO WISH LIST")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(wished ? Theme.green : Theme.gold)
                    .lineLimit(1)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(wished ? "Remove from the wish list. It comes off the route with it."
                         : "Add to the wish list, where it joins the route grouped by where it drops.")
        }
    }

    private func classText(_ c: [String]) -> String {
        if c.isEmpty { return "" }
        if c.count >= classAbbrs.count { return "ALL" }
        return c.joined(separator: " ")
    }
}
