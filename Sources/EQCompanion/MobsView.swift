// The Mobs tab — the MODULE HOME for creature knowledge, ported from
// `src/renderer/src/features/mobs/MobsView.tsx`.
//
// THE BROWSE SURFACE IS AN OVERVIEW OF WHERE YOU ARE. What you want when you open this tab
// mid-session is the bestiary of the room you are standing in, and then what you were just
// sizing up: the zone roster leads (in a fixed-height scroll box — a growing list never grows
// the page), the con strip sits below it with its own bounded height.
//
// SEARCH is client-side and instant over the whole committed catalog (7,866 rows, name + zones),
// through the same fuzzy scorer the Electron box uses (MobsModel). It replaces the browse
// surfaces while it has text, exactly as it does there.
//
// EVERY NUMBER ON A ROW IS A JOIN, and each has ONE fold behind it:
//   · "79 killed"  — the kills module, re-keyed by `MobKey` (KillRecord.index), so the catalog's
//                    apostrophe spelling and the log's backtick reach the same record.
//   · "28 drops"   — the count of the WIKI drop table, off the committed catalog. It is the
//                    number of things this mob can drop, never a claim about your own loot.
//   · "drops: …"   — the con row's own enrichment (dropsWiki annotated with dropsSeen counts),
//                    which the consider module already carries; no second drops source.
import SwiftUI
import EQCompanionCore

struct MobsView: View {
    @Environment(AppModel.self) private var model
    @State private var kills = ModuleSnapshot()
    @State private var consider = ModuleSnapshot()
    @State private var character = ModuleSnapshot()
    @State private var query = ""
    @State private var selected: String?
    /// Filters over the catalog: a zone ("" = anywhere) and a level window (blank = unbounded).
    @State private var filterZone = ""
    @State private var minLevel = ""
    @State private var maxLevel = ""

    /// The kill index, folded once per snapshot — never per row.
    private var killIndex: [String: KillInfo] { KillRecord.index(KillRecord.parse(kills.state)) }
    private var zone: String? {
        let z = character.state["zone"].string ?? ""
        return z.isEmpty ? nil : z
    }
    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    private var filtering: Bool { !filterZone.isEmpty || Int(minLevel) != nil || Int(maxLevel) != nil }

    /// "1-2 or 1-5", "4-6, ~12", "45" → the span of every number the text states.
    static func levelRange(_ text: String) -> ClosedRange<Int>? {
        var nums: [Int] = []
        var cur = 0, has = false
        for ch in text {
            // `&*`/`&+`, not `*`/`+`: this reads FREE TEXT from the scraped mob catalog, and a run
            // of twenty digits in some page's level field would overflow and trap the whole Mobs
            // list. A wrapped number is nonsense, but the cap below discards it either way, and a
            // nonsense level is a far smaller problem than a crash.
            if let d = ch.wholeNumberValue, d >= 0, d <= 9, cur < 1_000_000 {
                cur = cur &* 10 &+ d
                has = true
            } else if let d = ch.wholeNumberValue, d >= 0, d <= 9 {
                has = true   // still inside a number, just past any level a game could state
            }
            else if has { nums.append(cur); cur = 0; has = false }
        }
        if has { nums.append(cur) }
        guard let lo = nums.min(), let hi = nums.max(), lo > 0 else { return nil }
        return lo...hi
    }

    /// A level filter keeps only rows whose stated span touches the window; a mob with no stated
    /// level cannot satisfy a level filter. The zone filter is the wiki page's own zone list.
    private func passesFilters(_ m: GameData.Mob) -> Bool {
        if !filterZone.isEmpty,
           !m.zones.contains(where: { $0.caseInsensitiveCompare(filterZone) == .orderedSame }) { return false }
        let lo = Int(minLevel), hi = Int(maxLevel)
        if lo != nil || hi != nil {
            guard let r = Self.levelRange(m.level) else { return false }
            if let lo, r.upperBound < lo { return false }
            if let hi, r.lowerBound > hi { return false }
        }
        return true
    }

    /// Every zone the mob catalog names, for the filter menu.
    private var catalogZones: [String] {
        var seen = Set<String>(), out: [String] = []
        for m in GameData.shared.mobs {
            for z in m.zones where seen.insert(z.lowercased()).inserted { out.append(z) }
        }
        return out.sorted()
    }

    /// Browsing by filter alone (no search text): the catalog rows the filters keep, ordered by
    /// the bottom of their stated level span, capped so a level-only sweep stays a list.
    private var filterBrowse: some View {
        let rows = GameData.shared.mobs.filter(passesFilters)
            .sorted { a, b in
                let la = Self.levelRange(a.level)?.lowerBound ?? Int.max
                let lb = Self.levelRange(b.level)?.lowerBound ?? Int.max
                return la != lb ? la < lb : a.page < b.page
            }
        let shown = Array(rows.prefix(200))
        return Card {
            HStack(spacing: 4) {
                Text("\(rows.count) mob\(rows.count == 1 ? "" : "s") match").font(.caption).foregroundStyle(Theme.textDim)
                if rows.count > shown.count {
                    Text("· first \(shown.count) shown - narrow the level window").font(.caption).foregroundStyle(Theme.textFaint)
                }
            }
            if rows.isEmpty {
                Text("Nothing in the catalog matches these filters.").font(.callout).foregroundStyle(Theme.textFaint)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(shown, id: \.page) { m in
                            MobResultRow(mob: m, kill: KillRecord.killsFor(killIndex, m.name),
                                         selected: selected == m.name) { selected = m.name }
                        }
                    }
                }
                .frame(maxHeight: 520)
            }
        }
    }

    var body: some View {
        NeedsEngine {
            HSplitView {
                browse
                    .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .background(Theme.background)
                if let s = selected {
                    MobDetailPane(name: s, kill: KillRecord.killsFor(killIndex, s), onClose: { selected = nil })
                        .frame(minWidth: 320, idealWidth: 400, maxWidth: 560)
                }
            }
            .task(id: "\(model.moduleSeqs["kills"] ?? 0)|\(model.epoch ?? 0)") { await kills.refresh(model, module: "kills") }
            .task(id: "\(model.moduleSeqs["consider"] ?? 0)|\(model.epoch ?? 0)") { await consider.refresh(model, module: "consider") }
            .task(id: "\(model.moduleSeqs["character"] ?? 0)|\(model.epoch ?? 0)") { await character.refresh(model, module: "character") }
        }
    }

    private var browse: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                TextField("Search mobs…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 420)
                FilterOnePicker(title: "Zone",
                                options: [PickerOption("", "anywhere")]
                                    + catalogZones.map { PickerOption($0) },
                                selection: $filterZone,
                                placeholder: "Find a zone\u{2026}")
                Text("Lvl").font(.caption).foregroundStyle(Theme.textDim)
                TextField("min", text: $minLevel).textFieldStyle(.roundedBorder).frame(width: 46)
                Text("–").font(.caption).foregroundStyle(Theme.textFaint)
                TextField("max", text: $maxLevel).textFieldStyle(.roundedBorder).frame(width: 46)
                if filtering {
                    Button { filterZone = ""; minLevel = ""; maxLevel = "" } label: {
                        Chip(text: "clear", color: Theme.textDim)
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            if searching {
                searchResults
            } else if filtering {
                filterBrowse
            } else {
                if let z = zone { zoneRoster(z) }
                recentlyConsidered
                if zone == nil { noZoneYet }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
    }

    // MARK: - Search

    private var searchResults: some View {
        let hits = MobCatalogIndex.shared.search(query).filter(passesFilters)
        let total = MobCatalogIndex.shared.catalogCount
        return Card {
            if hits.isEmpty {
                Text("No mob in the catalog matches “\(query.trimmingCharacters(in: .whitespaces))”.")
                    .font(.callout).foregroundStyle(Theme.textFaint)
            } else {
                Text("\(hits.count) of \(Format.count(total)) mobs").font(.caption).foregroundStyle(Theme.textDim)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(hits, id: \.page) { m in
                            MobResultRow(mob: m, kill: KillRecord.killsFor(killIndex, m.name),
                                         selected: selected == m.name) { selected = m.name }
                        }
                    }
                }
                .frame(maxHeight: 520)
            }
        }
    }

    // MARK: - In <zone>

    /// The zone name is displayed RAW, exactly as the game printed it — matching your client's
    /// zone line is how you know the app is talking about where you are. The folding that turns
    /// it into catalog rows is `GameData.mobs(inLogZone:)`'s business, not the heading's.
    private func zoneRoster(_ z: String) -> some View {
        let rows = MobZone.roster(z)
        return Card {
            HStack(spacing: 4) {
                Text("In \(z)").font(.callout.weight(.semibold)).foregroundStyle(Theme.gold)
                if !rows.isEmpty {
                    Text("- \(rows.count) in the catalog").font(.caption).foregroundStyle(Theme.textDim)
                }
            }
            if rows.isEmpty {
                // The catalog and the game don't always spell a place the same way. Say so
                // plainly rather than showing an empty box or a guessed roster.
                Text("The catalog lists no mobs for \(z).").font(.callout).foregroundStyle(Theme.textFaint)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows, id: \.page) { m in
                            MobResultRow(mob: m, kill: KillRecord.killsFor(killIndex, m.name),
                                         selected: selected == m.name) { selected = m.name }
                        }
                    }
                }
                .frame(height: 360)
            }
        }
    }

    // MARK: - Recently considered

    /// Renders NOTHING until something has been conned, so a player who never uses `/con` pays
    /// no vertical space for it. Newest first; the module's own order is oldest-first.
    @ViewBuilder
    private var recentlyConsidered: some View {
        let rows = ConsiderRowModel.parse(consider.state).reversed().map { $0 }
        if !rows.isEmpty {
            Card {
                HStack(spacing: 4) {
                    Text("Recently considered").font(.callout.weight(.semibold)).foregroundStyle(Theme.gold)
                    Text("(\(rows.count))").font(.caption).foregroundStyle(Theme.textDim)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { r in
                            ConsiderRowView(row: r, now: nowMs(), selected: selected == r.mob) { selected = r.mob }
                        }
                    }
                }
                .frame(height: 220)
            }
        }
    }

    /// The log hasn't printed a zone line this session, so there is nothing to be an overview OF.
    private var noZoneYet: some View {
        let conned = !(consider.state.array ?? []).isEmpty
        return VStack(spacing: 8) {
            if !conned { Image(systemName: "pawprint").font(.system(size: 40)).foregroundStyle(Theme.textFaint) }
            Text(conned
                 ? "Zone into somewhere and this becomes an overview of what lives there. Until then, search the catalog by name or zone."
                 : "Your zone, cons and kills show up here as you play - a roster of whatever you're standing in. Meanwhile, search \(Format.count(MobCatalogIndex.shared.catalogCount)) creatures by name or zone: levels, zones and full drop tables, all offline.")
                .font(.callout).foregroundStyle(Theme.textDim)
                .multilineTextAlignment(.center).frame(maxWidth: 460)
            Text("Anything you /con in game shows up here too.").font(.caption).foregroundStyle(Theme.textFaint)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }
}

// MARK: - Rows

/// ONE catalog row — the row IS the catalog entry: level, zones and drop count, all local, plus
/// the one kill join. Used by both the search results and the zone roster.
private struct MobResultRow: View {
    var mob: GameData.Mob
    var kill: KillInfo?
    var selected: Bool
    var onOpen: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(mob.name).font(.callout.weight(.semibold)).foregroundStyle(Theme.text).fixedSize()
            if !mob.level.isEmpty {
                Text("Lvl \(mob.level)").font(.caption).foregroundStyle(Theme.textDim).fixedSize()
            }
            Text(mob.zones.joined(separator: ", ")).font(.caption).foregroundStyle(Theme.textDim).lineLimit(1)
            Spacer(minLength: 8)
            if let k = kill, k.count > 0 {
                Text("\(k.count) killed").font(.caption).foregroundStyle(Theme.green).fixedSize()
            }
            // The drop COUNT, not the drops: the card lists them out. Absent when the page had
            // no loot section at all — an honest 0 is a different claim and this row can't make it.
            if !mob.drops.isEmpty {
                Chip(text: "\(mob.drops.count) drop\(mob.drops.count == 1 ? "" : "s")")
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 4).fill(selected ? Theme.gold.opacity(0.12) : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
    }
}

/// One considered mob: name, LEVEL, and when you conned it.
///
/// The con's DIFFICULTY verdict is ephemeral — it is a statement about the gap between your level
/// and the mob's ON THE DAY YOU CONNED IT — so it is not rendered; the durable facts the con line
/// carried are the name and the level. The faction rung survives only as hover text.
private struct ConsiderRowView: View {
    var row: ConsiderRowModel
    var now: Int64
    var selected: Bool
    var onOpen: () -> Void

    private static let dropsShown = 3

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(row.mob).font(.callout.weight(.semibold)).foregroundStyle(Theme.text).fixedSize()
                .help("\(ConsiderFaction.text(row.faction)) - click to open its page")
            if let l = row.level {
                Text("Lvl \(l)").font(.caption).foregroundStyle(Theme.textDim).fixedSize()
            }
            if row.rare { Chip(text: "rare", color: Theme.orange) }
            if !row.quests.isEmpty {
                Chip(text: row.quests.count == 1 ? "quest" : "\(row.quests.count) quests", color: Theme.green)
                    .help(row.quests.joined(separator: " · "))
            }
            dropsLine
            Spacer(minLength: 8)
            Text("\(row.cons > 1 ? "×\(row.cons) · " : "")conned \(MobFormat.age(row.ts, now: now))")
                .font(.caption).foregroundStyle(Theme.textFaint).fixedSize()
                .help(Format.stamp(ms: row.ts))
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 4).fill(selected ? Theme.gold.opacity(0.12) : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
    }

    /// `drops: a ×3, b, c +17`. Renders nothing when nothing is known — never "no drops".
    @ViewBuilder
    private var dropsLine: some View {
        let shown = Array(row.drops.all.prefix(Self.dropsShown))
        if !shown.isEmpty {
            let rest = row.drops.all.count - shown.count
            (shown.enumerated().reduce(Text("drops: ").foregroundColor(Theme.textDim)) { acc, pair in
                let (i, item) = pair
                var t = acc
                if i > 0 { t = t + Text(", ").foregroundColor(Theme.textDim) }
                t = t + Text(item).foregroundColor(Theme.text)
                // Corroboration rides ON the definitive row, never in place of it.
                if let mine = row.drops.countByKey[item.lowercased()] {
                    t = t + Text(" ×\(mine)").foregroundColor(Theme.green)
                }
                return t
            } + Text(rest > 0 ? " +\(rest)" : "").foregroundColor(Theme.textDim))
                .font(.caption).lineLimit(1)
        }
    }
}

// MARK: - The detail pane

/// The mob card the engine serves, over the committed catalog's own drop table and whatever the
/// kills module has recorded. One mob, one surface — the same card every other tab opens.
private struct MobDetailPane: View {
    var name: String
    var kill: KillInfo?
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(name).font(.headline).foregroundStyle(Theme.text).lineLimit(1)
                Spacer()
                // Jumps to the Maps tab, opens the mob's zone and puts the camera on its pin.
                if let m = GameData.shared.mob(named: name), !m.zones.isEmpty {
                    Button("Show on map") { MapJump.shared.show(mob: name, zonesLongNames: m.zones) }
                        .buttonStyle(OutlineButtonStyle())
                }
                Button("Close", action: onClose).buttonStyle(OutlineButtonStyle())
            }
            .padding(10)
            // The summary cards are bounded and the engine's card takes the rest: no nested
            // unbounded scrollers, and a 28-item drop table cannot push the card off the pane.
            VStack(alignment: .leading, spacing: 12) {
                if let k = kill, k.count > 0 { killCard(k) }
                dropsCard
            }
            .padding(.horizontal, 10)
            KnowledgeCard(domain: "mob", name: name)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.background)
    }

    private func killCard(_ k: KillInfo) -> some View {
        Card("YOUR KILLS") {
            HStack(spacing: 12) {
                Stat(label: "Killed", value: Format.count(k.count))
                Stat(label: "Credited", value: Format.count(k.credited))
                Stat(label: "Best tier", value: RaidTier.style(k.bestTier).label)
            }
            Text("First \(Format.stamp(ms: k.firstTs)) · Last \(Format.stamp(ms: k.lastTs))")
                .font(.caption).foregroundStyle(Theme.textDim)
        }
    }

    /// The WIKI drop table off the committed catalog — the definitive statement of what this
    /// thing can drop. A mob the catalog does not carry says so rather than showing an empty list.
    @ViewBuilder
    private var dropsCard: some View {
        if let m = GameData.shared.mob(named: name) {
            Card("DROPS (WIKI)") {
                if m.drops.isEmpty {
                    Text("The page lists no loot for \(m.name).").font(.callout).foregroundStyle(Theme.textFaint)
                } else {
                    Text("\(m.drops.count) item\(m.drops.count == 1 ? "" : "s")").font(.caption).foregroundStyle(Theme.textDim)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(m.drops, id: \.self) { d in
                                Text(d).font(.callout).foregroundStyle(Theme.text)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(maxHeight: 200)
                }
            }
        }
    }
}
