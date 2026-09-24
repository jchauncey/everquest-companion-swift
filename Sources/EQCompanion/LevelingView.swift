// The Leveling tab: what level you are, what the AA account looks like, how fast both are moving
// over the stretch of log you picked, and what the loadout's best spell is at the level in front
// of you.
//
// Ported from src/renderer/src/features/leveling/LevelingView.tsx and the files its header names.
// The four headline numbers do NOT follow the scope, and that is a decision rather than an
// omission: character level is your level RIGHT NOW, and the three AA figures are a refund-proof
// BALANCE (earned == allocated + unspent), not a flow. The windowed AA reads live one panel down,
// where they are labelled as rates.
import SwiftUI
import EQCompanionCore

// MARK: - The derived state

/// Everything that depends only on the module snapshots. Rebuilt when one of them moves.
private struct LevelingCore {
    var leveling = LevelingSnap.empty
    var prog = LvProgressionColumns.empty
    var stated = LvStatedLevel.empty
    var segments: [LvLevelSegment] = []
    var aaCumulative: [LvAaPoint] = []
    var aa = LvAAAccounting()
    var ledger: [LvAaAbilityRow] = []
    var lo: Int64 = 0
    var hi: Int64 = 0
    var hasBounds = false
    var available: [LvSliceId] = [.all]
    var peak: Int?
    var swaps = 0
    var classes: [String] = []
    var ranks: [String: Int] = [:]

    var bounds: (lo: Int64, hi: Int64)? { hasBounds ? (lo, hi) : nil }
    /// Nothing in either series carries a timestamp — the tab shows its stated empty sentence.
    var nothing: Bool { leveling.levels.isEmpty && leveling.aaGains.isEmpty }

    static let empty = LevelingCore()

    init() {}

    init(leveling levelingJSON: JSONValue, progression progJSON: JSONValue,
         character: JSONValue, combo: JSONValue, ranks ranksJSON: JSONValue) {
        leveling = LevelingSnap(levelingJSON)
        prog = LvProgressionColumns(progJSON)
        segments = LvLevelSeries.segments(leveling.levels)
        peak = LvLevelSeries.peak(leveling.levels)
        swaps = LvLevelSeries.swaps(segments)
        var sum = 0
        aaCumulative = leveling.aaGains.map { g in
            sum += g.amount
            return LvAaPoint(ts: g.ts, y: sum, nowHave: g.nowHave, gain: g.amount)
        }
        aa = LvAAAccounting(gains: leveling.aaGains, spends: leveling.aaSpends)
        ledger = LvAaLedger.rows(leveling.aaSpends)
        stated = LvStatedLevel(character: character, lastDing: leveling.levels.last, lastTs: prog.lastTs)
        let extra = leveling.levels.map(\.ts) + aaCumulative.map(\.ts)
        if let b = prog.bounds(extraTs: extra) { lo = b.lo; hi = b.hi; hasBounds = true }
        available = LvTimeslice.available(prog, bounds: bounds)
        classes = Self.comboClasses(combo)
        ranks = LvSpellLines.snapshot(ranksJSON)
    }

    /// The loadout, from the `combo` module's current interval: every slot that resolved to one
    /// class, plus the candidates of any slot that did not (unless it could still be anything).
    private static func comboClasses(_ combo: JSONValue) -> [String] {
        var out = Set<String>()
        for slot in combo["current"]["slots"].array ?? [] {
            let candidates = (slot["candidates"].array ?? []).compactMap { $0.string }
            if candidates.count == 1 || candidates.count < 16 { out.formUnion(candidates) }
        }
        return out.sorted()
    }
}

/// Everything that depends on the scope in force too — the slice, the drawn window, the stats and
/// the two clipped series. One object, so a control moves everything at once or nothing at all.
private struct LevelingScoped {
    var slice: LvTimeslice
    var window: LvChartWindow
    var scope: LevelingScope
    var pace: LvAaPace?
    var bands: [LvZoneBand]
    var legend: (rows: [LvZoneLegendRow], more: Int)
    var aaVisible: [LvAaPoint]
    var curve: LvLevelCurve

    init(core: LevelingCore, sliceId: LvSliceId, zoneScope: LvZoneScope, custom: (t0: Int64, t1: Int64)?) {
        let bounds = core.bounds ?? (lo: 0, hi: 0)
        slice = LvTimeslice.resolve(id: sliceId, snap: core.prog, bounds: core.bounds,
                                  scope: zoneScope, custom: custom)
        window = LvChartWindow.forSlice(slice, bounds: bounds)
        scope = LevelingScope.make(snap: core.prog, slice: slice, window: window, bounds: bounds)
        pace = core.leveling.aaGains.isEmpty
            ? nil : LvAaPace(leveling: core.leveling, prog: core.prog, window: scope.stats)
        bands = LvZoneBands.merge(core.prog, window.t0, window.t1)
        legend = LvZoneBands.legend(bands)
        // The anchor point before the window opens comes with the window: at a narrow scale "no
        // gains in this hour" is a real answer, and the plateau is what carries it across.
        let anchor = LvLevelSeries.stepIndex(core.aaCumulative.map(\.ts), window.t0)
        aaVisible = Array(core.aaCumulative[max(0, anchor)...])
        let segVisible = LvLevelSeries.visible(core.segments, from: window.t0)
        curve = LvLevelCurve.build(snap: core.prog, segments: segVisible, t0: window.t0, t1: window.t1)
    }
}

// MARK: - The view

struct LevelingView: View {
    @Environment(AppModel.self) private var model

    @State private var levelingSnap = ModuleSnapshot()
    @State private var progressionSnap = ModuleSnapshot()
    @State private var characterSnap = ModuleSnapshot()
    @State private var comboSnap = ModuleSnapshot()
    @State private var ranksSnap = ModuleSnapshot()

    @State private var core = LevelingCore.empty
    @State private var scoped: LevelingScoped?

    // THE SCOPE. This tab OPENS on `Zone + Session`: the exp surfaces are about the camp you are in
    // right now. The Loot ledger's own opening (`All`) is untouched — the pick is the app's, the
    // opening is the surface's.
    @State private var sliceId: LvSliceId = .zoneSession
    @State private var zoneScope: LvZoneScope = .opening
    @State private var basis: LvRateBasis = .opening
    @State private var customFrom = Date()
    @State private var customTo = Date()
    @State private var customTouched = false

    // The best-spells readout.
    @State private var catalogue: [LvCatalogSpell] = []
    @State private var catalogueLoading = true
    @State private var best = LvBestSpells.empty
    @State private var searchResults: (rows: [LvBestSpellRow], matched: Int, hidden: Int, elsewhere: Int) = ([], 0, 0, 0)
    @State private var viewedLevel: Int?
    @State private var tab: LvBestSpellTab = .dd
    @State private var query = ""
    @State private var simulate = 0.0
    @State private var sorts: [LvBestSpellTab: LvBestSpellSort] = [:]

    private var moduleKey: String {
        let seqs = ["leveling", "progression", "character", "combo", "observedSpellRanks"]
            .map { String(model.moduleSeqs[$0] ?? 0) }
            .joined(separator: "|")
        return "\(seqs)|\(model.epoch ?? 0)"
    }

    private var scopeKey: String {
        "\(moduleKey)|\(sliceId.rawValue)|\(zoneScope.rawValue)|\(Int(customFrom.timeIntervalSince1970))|\(Int(customTo.timeIntervalSince1970))|\(customTouched)"
    }

    private var level: Int { viewedLevel ?? core.stated.level ?? 1 }

    private var spellKey: String {
        "\(catalogue.count)|\(core.classes.joined())|\(core.ranks.count)|\(level)|\(Int(simulate))"
    }

    /// The search re-runs on the sort too: the cap is applied AFTER the sort, so a re-ordered
    /// column can bring a different fifty rows into view.
    private var searchKey: String {
        let s = sorts[tab] ?? LvBestSpellSort(column: tab.rankColumn, desc: true)
        return "\(spellKey)|\(query)|\(tab.rawValue)|\(s.column.rawValue)|\(s.desc)"
    }

    var body: some View {
        NeedsEngine {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    heroes
                    paceTiles
                    HStack(alignment: .top, spacing: 12) {
                        spellsPanel.frame(maxWidth: .infinity, alignment: .top)
                        if !core.ledger.isEmpty {
                            LvAaLedgerPanel(rows: core.ledger, allocated: core.aa.allocated)
                                .frame(maxWidth: .infinity, alignment: .top)
                        }
                    }
                    progress
                }
                .padding(14)
            }
            .background(Theme.background)
            .task(id: moduleKey) { await refreshModules() }
            .task(id: scopeKey) { rescope() }
            .task { await loadCatalogue() }
            .task(id: spellKey) { rebuildSpells() }
            .task(id: searchKey) { runSearch() }
        }
    }

    // MARK: - Loading

    private func refreshModules() async {
        await levelingSnap.refresh(model, module: "leveling")
        await progressionSnap.refresh(model, module: "progression")
        await characterSnap.refresh(model, module: "character")
        await comboSnap.refresh(model, module: "combo")
        await ranksSnap.refresh(model, module: "observedSpellRanks")
        core = LevelingCore(leveling: levelingSnap.state, progression: progressionSnap.state,
                            character: characterSnap.state, combo: comboSnap.state, ranks: ranksSnap.state)
        // A slice this record cannot define falls back to the whole log, exactly as the app-wide
        // pick does — the tab never shows a window the log cannot draw.
        if !core.available.contains(sliceId) { sliceId = .all }
        if !customTouched, let b = core.bounds {
            customFrom = Date(timeIntervalSince1970: Double(b.lo) / 1000)
            customTo = Date(timeIntervalSince1970: Double(b.hi) / 1000)
        }
        rescope()
        rebuildSpells()
    }

    private func rescope() {
        guard core.hasBounds else { scoped = nil; return }
        let custom = customTouched
            ? (t0: Int64(customFrom.timeIntervalSince1970 * 1000), t1: Int64(customTo.timeIntervalSince1970 * 1000))
            : nil
        scoped = LevelingScoped(core: core, sliceId: sliceId, zoneScope: zoneScope, custom: custom)
    }

    /// ~1 MB of committed spell pages, parsed once, off the main thread.
    private func loadCatalogue() async {
        guard catalogue.isEmpty else { return }
        let root = GameData.shared.roots.data
        catalogue = await LvSpellCatalogueStore.shared.spells(dataRoot: root)
        catalogueLoading = false
        rebuildSpells()
    }

    private func rebuildSpells() {
        guard !catalogue.isEmpty else { return }
        best = LvBestSpellsReadout.build(spells: catalogue, classes: core.classes, level: level,
                                       observed: core.ranks, simulate: Int(simulate), sorts: sorts)
    }

    private func runSearch() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, !catalogue.isEmpty else { searchResults = ([], 0, 0, 0); return }
        searchResults = LvBestSpellsReadout.search(
            spells: catalogue, query: q, classes: core.classes, level: level, tab: tab,
            sort: sorts[tab] ?? LvBestSpellSort(column: tab.rankColumn, desc: true),
            observed: core.ranks, simulate: Int(simulate))
    }

    // MARK: - The four headline numbers

    private var heroes: some View {
        HStack(alignment: .top, spacing: 12) {
            BigStat(value: core.stated.level.map(String.init) ?? LevelingFormat.none,
                    label: "Character level",
                    sub: levelSub,
                    color: Theme.gold,
                    icon: "medal")
                .help(core.stated.title)
            BigStat(value: core.aa.earned > 0 ? LevelingFormat.grouped(core.aa.earned) : LevelingFormat.none,
                    label: "AA points earned", sub: "spent + unspent", color: Theme.blue, icon: "sparkles")
            BigStat(value: core.aa.allocated > 0 ? LevelingFormat.grouped(core.aa.allocated) : LevelingFormat.none,
                    label: "AA points spent",
                    sub: "\(core.aa.boughtCount) ranks allocated",
                    color: Color(hex: 0xb07fd0), icon: "sparkles")
            BigStat(value: core.leveling.aaGains.isEmpty ? LevelingFormat.none : LevelingFormat.grouped(core.aa.unspent),
                    label: "AA unspent", sub: "last reported balance", color: Theme.green, icon: "bolt.fill")
        }
    }

    /// The `/who` cue rides the CAPTION, not the label — the label is the card's one-line name.
    private var levelSub: String {
        let cue = core.stated.cue.isEmpty ? "" : "\(core.stated.cue) · "
        let n = core.leveling.levels.count
        guard n > 0 else { return cue + "no level-ups in log" }
        var out = "\(n) level-ups logged"
        if core.swaps > 0, let peak = core.peak {
            out += " · peak \(peak) · \(core.swaps) class \(LevelingFormat.plural(core.swaps, "swap"))"
        }
        return cue + out
    }

    // MARK: - The panels

    /// AA pace for the window the time-range bar below has chosen, in the same tiles as the
    /// headline row. Each says which window it is, because the bar that sets it sits at the bottom.
    @ViewBuilder
    private var paceTiles: some View {
        if let s = scoped, let pace = s.pace {
            HStack(alignment: .top, spacing: 12) {
                ForEach(pace.tiles(basis)) { t in paceTile(t, scope: s.scope.label) }
            }
            .help("\(s.scope.label) - \(pace.caption(basis)). \(basis.title)")
        }
    }

    private var spellsPanel: some View {
        LvBestSpellsPanel(best: best, ranks: core.ranks, level: level, loading: catalogueLoading,
                          tab: $tab, query: $query, simulate: $simulate, sorts: $sorts,
                          search: searchResults,
                          onLevel: { viewedLevel = max(1, min(60, $0)) })
    }

    /// The time-range bar and the two charts it drives, across the whole width.
    @ViewBuilder
    private var progress: some View {
        if core.nothing || scoped == nil {
            Card {
                Text(core.hasBounds
                     ? "No level-ups or AA gains found in this character's log yet. They'll appear here live as you play."
                     : "Reading the log…")
                    .font(.callout).foregroundStyle(Theme.textDim)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if let s = scoped {
            VStack(alignment: .leading, spacing: 12) {
                scopeBar(s)
                if s.aaVisible.count >= 1, core.aaCumulative.count >= 2 { aaCard(s) }
                if core.leveling.levels.count >= 2 { levelCard(s) }
            }
        }
    }

    private func paceTile(_ t: LvAaPaceTile, scope: String) -> some View {
        let color: Color = {
            switch t.id {
            case .rate: return Theme.blue
            case .points: return Color(hex: 0xb07fd0)
            case .eta: return Theme.green
            case .potion: return Theme.gold
            }
        }()
        return BigStat(value: t.unit.isEmpty ? t.value : "\(t.value) \(t.unit)", label: t.label,
                       sub: t.inferred ? "\(scope) · inferred" : scope, color: color)
            .help(t.title)
    }

    /// WHICH STRETCH, WHICH TIERS OF IT, AND PER HOUR OF WHAT — one row of controls, one line that
    /// describes them. The middle control is drawn exactly while the slice carries a zone: a
    /// membership is meaningless on a slice with no camp in it.
    private func scopeBar(_ s: LevelingScoped) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                SegmentPicker(selection: $sliceId, options: core.available.map { ($0, $0.label) })
                if s.slice.zoneKey != nil {
                    SegmentPicker(selection: $zoneScope, options: LvZoneScope.allCases.map { ($0, $0.label) })
                        .help(zoneScope.title)
                }
                SegmentPicker(selection: $basis, options: LvRateBasis.allCases.map { ($0, $0.rawValue) })
                    .help(basis.buttonTitle)
                Spacer(minLength: 0)
            }
            if sliceId == .custom {
                HStack(spacing: 8) {
                    DatePicker("From", selection: $customFrom).labelsHidden()
                    DatePicker("To", selection: $customTo).labelsHidden()
                }
                .font(.caption)
                .controlSize(.small)
                .onChange(of: customFrom) { customTouched = true }
                .onChange(of: customTo) { customTouched = true }
            }
            Text("\(s.slice.windowCaption) · rates per hour of \(basis.rawValue) time")
                .font(.caption2).foregroundStyle(Theme.textFaint).lineLimit(1)
                .help(basis.title)
        }
    }

    private func aaCard(_ s: LevelingScoped) -> some View {
        Card("AA GAINED OVER TIME") {
            VStack(alignment: .leading, spacing: 6) {
                Text("cumulative gain lines - the final value can run ahead of the \(LevelingFormat.grouped(core.aa.earned)) earned headline")
                    .font(.caption2).foregroundStyle(Theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
                LvAaAreaChart(points: s.aaVisible, bands: s.bands, t0: s.window.t0, t1: s.window.t1)
            }
        }
    }

    private func levelCard(_ s: LevelingScoped) -> some View {
        Card("LEVEL OVER TIME") {
            VStack(alignment: .leading, spacing: 6) {
                (Text("the curve is your last level-up plus every percentage the game has stated since; a ")
                 + Text("shaded span").foregroundColor(lvSwapColor)
                 + Text(" is experience the log did not state")
                 + Text(core.swaps > 0
                        ? ", and a dashed break is a class swap - the level is re-reported for the new loadout, not lost"
                        : ""))
                    .font(.caption2).foregroundStyle(Theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
                LvLevelStepChart(curve: s.curve, bands: s.bands, t0: s.window.t0, t1: s.window.t1)
                LvZoneLegendStrip(rows: s.legend.rows, more: s.legend.more)
            }
        }
    }
}
