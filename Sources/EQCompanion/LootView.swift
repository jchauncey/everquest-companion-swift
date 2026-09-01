// The Loot tab: what this character has picked up, over whatever stretch of play the control at the
// top says, and what the app knows about each of it.
//
// TWO STATES, ONE VIEW. `selected == nil` is the ledger — slice bar, toolbar, caption, notable
// pickups and the table. A selection swaps the whole body for `LootDetailView`, which is a takeover
// rather than a sheet for the reason that file's header states.
//
// TWO TABLES, TWO SOURCES, AND THE SPLIT IS DELIBERATE.
//   * GROUPED (the default) is one row per item and is folded HERE, off the `loot` module snapshot,
//     because no served view answers "times looted, top source, how many zones, held estimate" — the
//     Electron renderer folds exactly this, from exactly this snapshot, and the port is faithful
//     (`LootData.swift`).
//   * UNGROUPED is the engine's own `loot.ledger`, paged by window, drawn verbatim. It is a
//     chronological ledger and stays newest-first whatever the Sort control says, which is why that
//     control is not drawn in this mode: an order picker there would either do nothing or lie.
//
// THE AGGREGATION RUNS OFF THE MAIN THREAD. 2.4k rows is not much, but it is folded again on every
// slice change and every count-source flip, and a table this size must never make a keystroke wait.
// It is cached on the module seq, the slice, the count source and the export's instant — the four
// things that can move the answer.
//
// NOTHING HERE HOVERS. The Electron ledger had interactive hover cards on the rows and the pickup
// chips; they opened upward across the toolbar and ate the clicks aimed at the Sort control. The
// rule travelled with the code: chips are state words, and what a popper used to say lives in the
// drill-down, which is where it was always meant to be.
import SwiftUI
import EQCompanionCore

struct LootView: View {
    @Environment(AppModel.self) private var model

    // The four modules this tab reads. `loot` is the ledger, `progression` supplies the slice and
    // both rate denominators, `turnins` says what was handed to an NPC, `outputFiles` says when the
    // inventory export was last written.
    @State private var lootSnap = ModuleSnapshot()
    @State private var progSnap = ModuleSnapshot()
    @State private var turnInSnap = ModuleSnapshot()
    @State private var outputSnap = ModuleSnapshot()

    // The folded inputs, and the version counter every derivation is keyed on.
    @State private var events: [LootEvent] = []
    @State private var prog = LootProgression.empty
    @State private var turnIns: [LootTurnIn] = []
    @State private var inventory = LootInventoryDump()
    @State private var dataVersion = 0
    @State private var agg: LootAggregate?
    @State private var folding = false

    // The slice, and the session split that rides on it.
    @State private var sliceId: LootSliceId = .all
    @State private var marks: [Int64] = []
    @State private var segmentIndex: Int?
    @State private var customRange: LootRange?
    /// The last answer `session.mark.add` gave, and whether it was a yes. A refusal is not an error
    /// — it is the engine saying the fold was not live — so it reads as a note rather than as red.
    @State private var markAck: (text: String, ok: Bool)?

    // The toolbar's own state. Three of these are remembered the way the Electron app remembers
    // them, in the same store keys, because they are preferences rather than a thing you choose
    // while you are looking.
    @State private var query = ""
    @State private var groupByItem = true
    @State private var questOnly = false
    /// Sorted by CLICKING A COLUMN, like every other table in the app. What is stored is the
    /// column and the direction; the old `Sort` dropdown was a second way to say the same thing.
    @State private var sortKey = LootView.storedSortKey
    @State private var sortDescending = UserDefaults.standard.object(forKey: "eq.lootSortDesc") as? Bool ?? true
    @State private var widths = ColumnWidths("eq.loot.columnWidths")
    @State private var showInvOnly = false
    @State private var countSource: LootCountSource = LootView.storedCountSource
    @State private var showTradeskill = UserDefaults.standard.bool(forKey: "eq.loot.showTradeskill")
    @State private var dismissed: Set<String> = []
    @State private var reloadNonce = 0

    // The drill-down, and the flat ledger's window.
    @State private var selected: String?
    @State private var flat = LiveView()
    @State private var flatSelection: String?
    @State private var offset = 0
    private let pageSize = 200

    /// Times looted stays the default: the grouped table's headline question is "what do I keep
    /// picking up".
    /// The stored column, migrated from the retired `Sort` dropdown so an existing preference
    /// keeps meaning what it meant.
    private static var storedSortKey: String {
        if let k = UserDefaults.standard.string(forKey: "eq.lootSortKey") { return k }
        switch UserDefaults.standard.string(forKey: "eq.lootSort") ?? "" {
        case "recent": return "last"
        case "name": return "item"
        case "zones": return "zones"
        default: return "count"
        }
    }

    /// `both` and not `inventory`: a dump covers only what was OPEN when it was written, so making
    /// it the sole witness would hide banked items from anyone whose bank window was shut.
    private static var storedCountSource: LootCountSource {
        LootCountSource(rawValue: UserDefaults.standard.string(forKey: "eq.countSource") ?? "") ?? .both
    }

    // MARK: - The slice

    private var bounds: (lo: Int64, hi: Int64)? { prog.bounds }
    private var available: [LootSliceId] { LootTimeslice.available(prog, bounds) }
    private var segments: [LootSessionSegment] { LootSessions.segments(marks) }

    private var slice: LootSlice {
        let id = LootTimeslice.resolveId(sliceId, prog, bounds)
        let caption = segments.first { $0.n == segmentIndex }?.caption
        return LootTimeslice.resolve(snap: prog, bounds: bounds, id: id,
                                     custom: customRange,
                                     customCaption: id == .custom ? caption : nil)
    }

    var body: some View {
        NeedsEngine {
            Group {
                if let item = selected {
                    LootDetailView(item: item,
                                   events: agg?.sliced ?? [],
                                   slice: slice,
                                   estimate: estimate(for: item),
                                   consumed: agg?.consumed[LootName.countKey(item)] ?? 0,
                                   onBack: closeDetail)
                } else {
                    ledger
                }
            }
            .background(Theme.background)
            .task(id: "\(model.moduleSeqs["loot"] ?? 0)|\(model.epoch ?? 0)") { await loadLoot() }
            .task(id: "\(model.moduleSeqs["progression"] ?? 0)|\(model.epoch ?? 0)") { await loadProgression() }
            .task(id: "\(model.moduleSeqs["turnins"] ?? 0)|\(model.epoch ?? 0)") { await loadTurnIns() }
            .task(id: "\(model.moduleSeqs["outputFiles"] ?? 0)|\(model.epoch ?? 0)|\(reloadNonce)") { await loadInventory() }
            .task(id: "\(dataVersion)|\(slice.key)|\(countSource.rawValue)") { await fold() }
            .onDisappear { flat.close() }
        }
    }

    private var ledger: some View {
        VStack(spacing: 0) {
            sliceBar
            toolbar
            summary
            notableStrip
            // The table takes the SAME left edge as the chrome above it. Every other row in this
            // stack pads itself; the table is the one that ran flush against the sidebar, which is
            // what put the item icons hard against the menu.
            Group { if groupByItem { groupedTable } else { flatTable } }
                .padding(.horizontal, DataTableMetrics.tabInset)
            footer
        }
    }

    // MARK: - Row 1: which stretch of play

    private var sliceBar: some View {
        HStack(spacing: 10) {
            SegmentPicker(selection: Binding(get: { LootTimeslice.resolveId(sliceId, prog, bounds) },
                                             set: { pick($0) }),
                          options: available.map { ($0, $0.label) })
            // "Start a new session now": one click ends the stretch you were farming and opens a new
            // one from that instant, with the old one still in the picker beside it. What it produces
            // is an ordinary custom range, so nothing downstream has to know this button exists.
            Button("New session") { newSession() }
                .buttonStyle(OutlineButtonStyle())
                .disabled(model.connection != .ready)
            if segments.count > 1 {
                Picker("", selection: Binding(get: { segmentIndex ?? 0 }, set: { pickSegment($0) })) {
                    Text("—").tag(0)
                    ForEach(segments) { s in Text(s.label).tag(s.n) }
                }
                .labelsHidden()
                .frame(maxWidth: 160)
            }
            Text("\(LootFmt.edge(slice.range.t0)) → \(LootFmt.edge(slice.range.t1))")
                .font(.caption).foregroundStyle(Theme.textDim).monospacedDigit()
            if let z = slice.zoneCaption {
                Text("· \(z)").font(.caption).foregroundStyle(Theme.textDim).lineLimit(1)
            }
            if let ack = markAck {
                Text(ack.text).font(.caption).foregroundStyle(ack.ok ? Theme.green : Theme.orange).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DataTableMetrics.tabInset).padding(.top, 10).padding(.bottom, 6)
    }

    // MARK: - Row 2: the filters

    private var toolbar: some View {
        HStack(spacing: 12) {
            // IT SEARCHES WHAT YOU OWN, NOT ONLY WHAT YOU LOOTED — the label says "looted" because
            // that is what the table under it is, but a query also reaches the items only the
            // inventory export knows about.
            TextField("Search looted item", text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(width: 210)
            Toggle("Group by item", isOn: $groupByItem).toggleStyle(.switch).font(.caption)
            Toggle("Only Plane of Sky items", isOn: $questOnly).toggleStyle(.switch).font(.caption)
            if groupByItem, let n = agg?.invOnly.count, n > 0 {
                // The inventory-only tail is kept OUT of the default browse so the table stays a loot
                // table — the chip says how many are hiding. A SEARCH always reaches it anyway: typing
                // a name asks whether the app knows this item at all.
                Button { showInvOnly.toggle() } label: {
                    Chip(text: "+\(Format.count(n)) in inventory only", color: Theme.gold, filled: showInvOnly)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
            Picker("Count from", selection: $countSource) {
                ForEach(LootCountSource.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .frame(width: 260)
            .onChange(of: countSource) { _, v in UserDefaults.standard.set(v.rawValue, forKey: "eq.countSource") }
            Button { reloadNonce += 1 } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.gold)
                .help("Re-read the inventory export")
        }
        .font(.caption)
        .padding(.horizontal, DataTableMetrics.tabInset).padding(.vertical, 6)
    }

    // MARK: - The caption

    private var summary: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(summaryLine).font(.caption).foregroundStyle(Theme.textDim)
            if let a = agg, let line = LootFmt.rateLine(a) {
                Text(line).font(.caption).foregroundStyle(Theme.textDim)
            }
            if folding, agg == nil {
                Text("Folding the ledger…").font(.caption).foregroundStyle(Theme.textFaint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DataTableMetrics.tabInset).padding(.bottom, 6)
    }

    private var summaryLine: String {
        let a = agg
        var s = "\(Format.count(a?.events ?? 0)) loot events"
        // The total is stated beside the sliced count because "what did I gain in totality vs this
        // session" is the literal question the control was asked for. Omitted under `All`, where the
        // two are equal.
        if slice.id != .all { s += " in \(slice.caption) of \(Format.count(a?.total ?? 0)) all time" }
        s += " · \(Format.count(uniqueCount)) unique items · click a row for mob/zone/drop-rate breakdown · "
        s += inventory.generatedAt > 0
            ? "inventory export \(LootFmt.exportStamp(inventory.generatedAt))"
            : "no inventory export loaded — run /outputfile inventory in game"
        return s
    }

    // MARK: - Notable pickups

    private var pickups: (shown: [LootPickup], hiddenTradeskill: Int) {
        LootKnowledge.shared.pickups(agg?.sliced ?? [], dismissed: dismissed, showTradeskill: showTradeskill)
    }

    @ViewBuilder
    private var notableStrip: some View {
        let p = pickups
        if !p.shown.isEmpty || p.hiddenTradeskill > 0 {
            HStack(spacing: 8) {
                Image(systemName: "book").font(.caption).foregroundStyle(Theme.purple)
                Text("Notable pickups").font(.caption).foregroundStyle(Theme.textDim)
                ForEach(p.shown.prefix(8)) { pick in
                    HStack(spacing: 3) {
                        Button { open(pick.item) } label: {
                            Text(pick.label).font(.caption).lineLimit(1)
                                .foregroundStyle(LootChipColor.of(pick.facts.sky ? "sky" : "quest"))
                        }
                        .buttonStyle(.plain)
                        Button { dismissed.insert(pick.countKey) } label: {
                            Image(systemName: "xmark").font(.system(size: 8))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.textFaint)
                    }
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .overlay(Capsule().stroke(Theme.border))
                }
                Spacer(minLength: 0)
                // The toggle says how many are behind it rather than pretending the pickups did not
                // happen. Components are hidden by default: a grinding session loots hundreds of
                // spider legs, and a strip full of ingredients drowns the one coin that starts a quest.
                Toggle("show tradeskill\(p.hiddenTradeskill > 0 ? " (\(p.hiddenTradeskill))" : "")",
                       isOn: $showTradeskill)
                    .toggleStyle(.switch).font(.caption).foregroundStyle(Theme.textDim)
                    .onChange(of: showTradeskill) { _, v in
                        UserDefaults.standard.set(v, forKey: "eq.loot.showTradeskill")
                    }
            }
            .padding(.horizontal, DataTableMetrics.tabInset).padding(.vertical, 6)
            .background(Theme.paper)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
        }
    }

    // MARK: - The grouped table

    /// The grouped rows the table draws: the slice's own groups under the current filters and order,
    /// plus the opt-in inventory-only tail.
    private var groupRows: [LootGroupRow] {
        guard let a = agg else { return [] }
        var rows = filter(a.groups)
        rows.sort { LootColumnSort.compare($0, $1, key: sortKey, descending: sortDescending) }
        let tail = filter(a.invOnly)
        return (showInvOnly || !trimmedQuery.isEmpty) ? rows + tail : rows
    }

    /// The unique-item count the caption states — the grouped rows the filters admit, WITHOUT the
    /// inventory-only tail, which is not loot.
    private var uniqueCount: Int { agg.map { filter($0.groups).count } ?? 0 }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces).lowercased() }

    private func filter(_ rows: [LootGroupRow]) -> [LootGroupRow] {
        var out = rows
        if questOnly {
            let sky = LootKnowledge.shared.skyKeys
            out = out.filter { sky.contains($0.countKey) }
        }
        let q = trimmedQuery
        if !q.isEmpty { out = out.filter { $0.item.lowercased().contains(q) } }
        return out
    }

    /// The loot table's columns. Same shape, same widths vocabulary and same interactions as the
    /// Gear tab's — because it is the same table: see `DataTableView`.
    private var groupColumns: [DataColumn] {
        [
            DataColumn(key: "item", label: "Item", width: 300),
            DataColumn(key: "count", label: "Times looted", width: 92, trailing: true),
            DataColumn(key: "estimate", label: "In inventory (est.)", width: 118, trailing: true),
            // Top source takes the leftover: it is the column most often cut short, and unlike the
            // item name it was never the one crowding the table.
            DataColumn(key: "source", label: "Top source", width: 180, flexible: true),
            DataColumn(key: "zones", label: "Zones", width: 60, trailing: true),
            DataColumn(key: "last", label: "Last looted", width: 150, trailing: true),
        ]
    }

    private var groupedTable: some View {
        DataTableView(
            columns: groupColumns,
            rows: groupRows,
            widths: widths,
            sortKey: Binding(get: { sortKey },
                             set: { sortKey = $0; UserDefaults.standard.set($0, forKey: "eq.lootSortKey") }),
            sortDescending: Binding(get: { sortDescending },
                                    set: { sortDescending = $0; UserDefaults.standard.set($0, forKey: "eq.lootSortDesc") }),
            emptyText: trimmedQuery.isEmpty
                ? "No loot in this slice. Widen the range above, or turn off the filters."
                : "Nothing looted or held matches \u{201C}\(query)\u{201D}.",
            overflowNote: { "\(Format.count($0)) more - narrow the filters to see them." },
            cell: { c, r in groupCell(c, r) },
            onRowTap: { open($0.item) })
    }

    /// One cell. The contents are the loot tab's business; the layout is the table's.
    @ViewBuilder
    private func groupCell(_ c: DataColumn, _ r: LootGroupRow) -> some View {
        switch c.key {
        case "item":
            // The SAME cell the Gear table draws: an item looks like itself on either tab.
            ItemNameCell(
                name: r.item,
                chips: LootKnowledge.shared.facts(r.item).chips.map { ItemChip(text: $0.0, color: LootChipColor.of($0.1)) }
                    + (r.disposition.map { [ItemChip(text: $0, color: LootChipColor.of($0))] } ?? [])
                    + (r.invOnly ? [ItemChip(text: "export only", color: Theme.textFaint)] : []),
                dimmed: r.invOnly,
                onOpen: { open(r.item) })
        case "count":
            Text(r.invOnly ? LootFmt.none : Format.count(r.count)).monospacedDigit()
        case "estimate":
            // An ESTIMATE, never a fact: the log cannot see bank deposits, trades or vendor sales
            // that happen off-camera, so it renders as a `~` chip like every other inferred value.
            if r.estimate > 0 { Chip(text: "~\(r.estimate)", color: Theme.textDim) }
            else { Text(LootFmt.none).foregroundStyle(Theme.textFaint) }
        case "source":
            Text(r.topSource ?? LootFmt.none).foregroundStyle(Theme.textDim).lineLimit(1)
        case "zones":
            Text(r.zoneCount > 0 ? String(r.zoneCount) : LootFmt.none)
                .monospacedDigit().foregroundStyle(Theme.textDim)
        default:
            Text(r.invOnly ? LootFmt.none : Format.stamp(ms: r.last))
                .foregroundStyle(Theme.textDim).monospacedDigit()
        }
    }

    // MARK: - The flat ledger

    /// THE SLICE REACHES THE SERVED LEDGER THROUGH THE ROW'S OWN IDENTITY, not by re-reading its
    /// cells. `loot.ledger` keys a row `loot:<n>`, where n is its position in the module's
    /// append-only array — which is the very array `module.snapshot` serializes, so the key indexes
    /// straight into the events folded here. Nothing is parsed back out of a rendered cell (the
    /// instant is served as `Aug 19, 04:21 PM`, a string, and turning that back into a moment is
    /// exactly the munging the served layer exists to prevent).
    ///
    /// A row appended AFTER this snapshot has an index past the end and is admitted rather than
    /// dropped: an append-only ledger cannot re-number, so an index that exists in both names one
    /// row, and one that does not yet exist here is newer than the window this page was cut from.
    private func flatEvent(_ key: String) -> LootEvent? {
        guard key.hasPrefix("loot:"), let i = Int(key.dropFirst(5)), i >= 0, i < events.count else { return nil }
        return events[i]
    }

    /// The engine's own `loot.ledger` rows, drawn verbatim — the instant, the item, the mob, the
    /// zone. The slice and the search narrow what this PAGE shows; they cannot narrow the PAGING,
    /// because a served source filters on equality and has no range term. The footer says so rather
    /// than letting the counts imply otherwise.
    private var shownFlat: [Row] {
        let q = trimmedQuery
        return flat.rows.filter { r in
            if let e = flatEvent(r.key), !LootTimeslice.admits(slice, ts: e.ts, zone: e.zone) { return false }
            if q.isEmpty { return true }
            return ["item", "from", "zone", "disposition"].contains { r[$0].display.lowercased().contains(q) }
        }
    }

    private var flatTable: some View {
        Table(shownFlat, selection: $flatSelection) {
            TableColumn("When") { Text($0["at"].display).monospacedDigit().foregroundStyle(Theme.textDim) }
                .width(min: 120, ideal: 140)
            TableColumn("Item") { r in
                HStack(spacing: 4) {
                    if let c = r["count"].int, c > 1 { Text("\(c) ×").foregroundStyle(Theme.textDim) }
                    Text(r["item"].display)
                    if let d = r["disposition"].string { Chip(text: d, color: LootChipColor.of(d)) }
                }
            }
            TableColumn("From") { Text($0["from"].display).foregroundStyle(Theme.textDim).lineLimit(1) }
            TableColumn("Zone") { Text($0["zone"].display).foregroundStyle(Theme.textDim).lineLimit(1) }
            TableColumn("Created") { Text($0["created"].display).foregroundStyle(Theme.textDim).lineLimit(1) }
                .width(min: 90, ideal: 140)
        }
        .task(id: "\(offset)|\(model.epoch ?? 0)") {
            flat.bind(model.client, ViewDescriptor(source: "loot.ledger", window: (offset, pageSize)))
        }
        .onChange(of: flatSelection) { _, v in
            if let k = v, let row = flat.rows.first(where: { $0.key == k }) { open(row["item"].display) }
        }
    }

    // MARK: - The footer

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 8) {
            if groupByItem {
                Text(groupedNote).font(.caption).foregroundStyle(Theme.textDim)
            } else {
                Button { offset = max(0, offset - pageSize) } label: { Image(systemName: "chevron.left") }
                    .disabled(offset == 0)
                Text("\(flat.total == 0 ? 0 : offset + 1)–\(min(offset + pageSize, flat.total)) of \(Format.count(flat.total))")
                    .font(.caption).monospacedDigit()
                Button { offset += pageSize } label: { Image(systemName: "chevron.right") }
                    .disabled(offset + pageSize >= flat.total)
                Text(flatNote).font(.caption).foregroundStyle(Theme.textDim)
            }
            Spacer(minLength: 0)
            // Only the served ledger has a window to be loading or failing — the grouped table is
            // folded here and says what it is doing in its own caption.
            if !groupByItem { WindowStatus(live: flat) }
        }
        .padding(.horizontal, DataTableMetrics.tabInset).padding(.vertical, 6)
    }

    private var groupedNote: String {
        if events.isEmpty {
            return "No loot parsed yet. Every \u{201C}--You have looted …--\u{201D} line shows up here in real "
                + "time, and the whole history is read from your log on launch. Check /log on if it stays empty."
        }
        if bounds == nil {
            // The slice and BOTH rate denominators are read off the `progression` snapshot, so
            // without it there is no stretch of play to measure over — and saying "no loot" would
            // blame the ledger for a module that has not landed.
            return "Waiting for the progression snapshot — the slice and both rate denominators are read from it."
        }
        if agg?.events == 0 {
            return "No loot in \(slice.caption). Widen the slice to see the rest of this character's history."
        }
        return "One row per item, over the acquisitions only — a destroy names no mob and is bag "
            + "history, so it is in the flat ledger and not in these counts."
    }

    private var flatNote: String {
        slice.id == .all
            ? "Newest first, the engine's own ledger."
            : "Newest first. The slice and the search narrow THIS PAGE; the paging is over the whole ledger."
    }

    // MARK: - Loading

    private func loadLoot() async {
        await lootSnap.refresh(model, module: "loot")
        let state = lootSnap.state
        events = await Task.detached(priority: .userInitiated) { LootEvent.parse(state) }.value
        dataVersion += 1
    }

    private func loadProgression() async {
        await progSnap.refresh(model, module: "progression")
        let state = progSnap.state
        prog = await Task.detached(priority: .userInitiated) { LootProgression.parse(state) }.value
        dataVersion += 1
    }

    private func loadTurnIns() async {
        await turnInSnap.refresh(model, module: "turnins")
        turnIns = LootTurnIn.parse(turnInSnap.state)
        dataVersion += 1
    }

    /// Read the newest `/outputfile inventory` dump off disk. The `outputFiles` module says WHEN the
    /// game last wrote one; the file itself is the only thing that says what it holds, so this
    /// re-reads whenever that instant moves (and whenever the reader presses refresh).
    private func loadInventory() async {
        await outputSnap.refresh(model, module: "outputFiles")
        guard let root = model.install?.root, let who = model.attached else {
            inventory = LootInventoryDump()
            dataVersion += 1
            return
        }
        let name = who.name, server = who.server
        inventory = await Task.detached(priority: .userInitiated) {
            LootInventory.load(root: root, character: name, server: server)
        }.value
        dataVersion += 1
    }

    /// The fold, off the main thread and cached on everything that can move it.
    private func fold() async {
        guard !events.isEmpty || !inventory.isEmpty else {
            agg = LootAggregate()
            return
        }
        folding = true
        let input = LootAggregate.Input(events: events, prog: prog, slice: slice,
                                        inventory: inventory, turnIns: turnIns, countSource: countSource)
        agg = await Task.detached(priority: .userInitiated) { LootAggregate.build(input) }.value
        folding = false
    }

    // MARK: - Acts

    private func pick(_ id: LootSliceId) {
        sliceId = id
        if id != .custom { segmentIndex = nil }
        markAck = nil
    }

    private func pickSegment(_ n: Int) {
        guard let seg = segments.first(where: { $0.n == n }) else {
            segmentIndex = nil
            return
        }
        customRange = seg.range
        segmentIndex = seg.n
        sliceId = .custom
    }

    /// Close what is running at the wall clock and open a fresh segment from there — the reset in one
    /// click. THE ENGINE STAMPS ITS OWN HALF: the mark is handed to `session.mark.add` so the combat
    /// records split on the same instant, and a REFUSAL means NEITHER HALF — a mark the engine never
    /// took would be a boundary only this window has.
    private func newSession() {
        let at = nowMs()
        markAck = ("Marking…", true)
        Task {
            do {
                let r = try await model.client.request(Op.sessionMarkAdd, ["at": .int(at)])
                if r["accepted"].bool == true {
                    marks = LootSessions.add(marks, at: at)
                    if let cur = segments.last { pickSegment(cur.n) }
                    markAck = ("New session from \(Format.time(ms: at))", true)
                } else {
                    markAck = ("Not marked — the engine is \(r["status"].display), not live.", false)
                }
            } catch {
                markAck = ("Not marked — \(error)", false)
            }
        }
    }

    private func open(_ item: String) {
        guard !item.isEmpty else { return }
        selected = item
    }

    private func closeDetail() {
        selected = nil
        flatSelection = nil
    }

    /// What the count source vouches for on one item, read back off the folded rows so the pane and
    /// the table can never disagree.
    private func estimate(for item: String) -> Int {
        let key = LootName.countKey(item)
        guard let a = agg else { return 0 }
        if let row = a.groups.first(where: { $0.countKey == key }) { return row.estimate }
        return a.invOnly.first { $0.countKey == key }?.estimate ?? 0
    }
}
