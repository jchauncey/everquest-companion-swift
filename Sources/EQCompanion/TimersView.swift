// THE TIMERS TAB — respawn clocks started by death messages, and the buff/debuff bars the overlay
// draws. Ported from `src/renderer/src/features/timers/TimersView.tsx`.
//
// Two columns, and the second one is why the feature is usable on the first kill of a fresh install
// rather than after a configuration session:
//
//   LEFT   the live clocks, then the buff timers.
//   RIGHT  what you just killed. Every mob whose death this fold has seen recently, each with a
//          one-click Watch. Clicking it does not merely arm the FUTURE — the module already holds
//          the death, so the clock starts from the kill you already made.
//
// NOTHING IS CLOCKED UNTIL YOU SAY SO. Recently killed is the ONLY way a row appears on the left,
// which makes the two columns one flow rather than a list and its settings.
//
// AND THE PAGE IS SCOPED TO ONE ZONE. The scope switch defaults to the zone the fold is in and the
// whole page obeys it — clocks AND recently-killed — because "what can I do about this right now"
// is a question about where you are standing. The counts on the switch say how much is hiding
// either way, so the default never silently swallows anything.
//
// AND THE PAGE RE-ORDERS AGAINST ITS OWN CLOCK. The order is a function of NOW — soonest due, a
// sighting ageing out of UP, a countdown passing into stale — while the view publishes an order
// only when the FOLD changes, which on an idle log is never. So the rows are sorted here, per tick,
// by the same rule both surfaces read (`Respawn.ordered`).
import SwiftUI
import EQCompanionCore

struct TimersView: View {
    @Environment(AppModel.self) private var model
    @State private var watches = LiveView()
    @State private var timers = LiveView()
    @State private var respawn = ModuleSnapshot()
    @State private var scope = "zone"
    @State private var surface = "buffs"
    @State private var query = ""

    var body: some View {
        NeedsEngine {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    scopeSwitch
                    HStack(alignment: .top, spacing: 20) {
                        VStack(alignment: .leading, spacing: 18) {
                            runningSection
                            buffTimersSection
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        recentSection.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.background)
            .task(id: model.epoch) { watches.bind(model.client, ViewDescriptor(source: "respawn.watches", window: (0, 100))) }
            .task(id: "\(model.epoch ?? 0)|\(surface)") {
                timers.bind(model.client, ViewDescriptor(source: "timers.rows", filter: ["surface": .string(surface)], window: (0, 200)))
            }
            .task(id: "\(model.moduleSeqs["respawn"] ?? 0)|\(model.epoch ?? 0)") { await respawn.refresh(model, module: "respawn") }
            .onDisappear { watches.close(); timers.close() }
        }
    }

    // MARK: - Scope

    /// The zone name as the switch and the empty states say it. The fold has no zone before the log
    /// states one, and "this zone" is then a claim it cannot make.
    private var zoneName: String {
        let z = respawn.state["zone"].string ?? ""
        return z.isEmpty ? "Unknown zone" : z
    }

    private var zone: String { respawn.state["zone"].string ?? "" }

    private var allClocks: [RespawnClock] { watches.rows.map(RespawnClock.init(row:)) }
    private var hereClocks: [RespawnClock] {
        allClocks.filter { Respawn.zoneKey($0.zone) == Respawn.zoneKey(zone) }
    }

    @MainActor private var allCandidates: [RespawnCandidate] {
        (respawn.state["recent"].array ?? []).map { v in
            RespawnCandidate(v, wikiFallback: WikiRespawns.text(for: v["display"].string ?? v["key"].display))
        }
    }

    @MainActor private var hereCandidates: [RespawnCandidate] {
        allCandidates.filter { Respawn.zoneKey($0.zone) == Respawn.zoneKey(zone) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "stopwatch.fill").foregroundStyle(Theme.gold)
            Text("Timers").font(.title2.weight(.semibold))
            if !zone.isEmpty { Chip(text: zone) }
            WindowStatus(live: watches)
            Spacer()
        }
    }

    private var scopeSwitch: some View {
        SegmentPicker(selection: $scope, options: [
            ("zone", "\(zoneName.uppercased()) (\(hereClocks.count))"),
            ("all", "ALL ZONES (\(allClocks.count))")
        ])
    }

    // MARK: - Running

    private var runningSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Running").font(.headline)
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let now = Int64(ctx.date.timeIntervalSince1970 * 1000)
                let rows = Respawn.ordered(scope == "zone" ? hereClocks : allClocks, now: now)
                if rows.isEmpty {
                    Text(runningEmptyText).font(.callout).foregroundStyle(Theme.textDim)
                } else {
                    VStack(spacing: 6) {
                        ForEach(rows) { c in
                            RespawnClockRow(clock: c, now: now) { setWatch(key: $0.key, display: $0.display, on: false) }
                        }
                    }
                }
            }
        }
    }

    /// A clock the scope is hiding is STATED, never silently dropped.
    private var runningEmptyText: String {
        let elsewhere = scope == "zone" ? allClocks.count - hereClocks.count : 0
        if elsewhere > 0 { return "No clocks in \(zoneName). \(elsewhere) running in other zones." }
        return "No clocks running. Watch a mob from Recently killed."
    }

    // MARK: - Recently killed

    @MainActor private var shownCandidates: [RespawnCandidate] {
        let pool = scope == "zone" ? hereCandidates : allCandidates
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        if needle.isEmpty { return pool }
        return pool.filter { $0.matches(needle) }
    }

    @MainActor private var recentSection: some View {
        let pool = scope == "zone" ? hereCandidates : allCandidates
        let shown = shownCandidates
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Recently killed").font(.headline)
                if shown.count != pool.count {
                    Text("\(shown.count) of \(pool.count)").font(.caption).foregroundStyle(Theme.textDim)
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.textFaint).font(.caption)
                TextField("Search name, zone or wiki", text: $query).textFieldStyle(.plain)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.paperRaised))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border))
            if shown.isEmpty {
                Text(recentEmptyText).font(.callout).foregroundStyle(Theme.textDim)
            } else {
                VStack(spacing: 0) {
                    ForEach(shown) { c in
                        RespawnCandidateRow(candidate: c) { setWatch(key: $0.key, display: $0.display, on: true) }
                            onUnwatch: { setWatch(key: $0.key, display: $0.display, on: false) }
                        if c.id != shown.last?.id { Divider().overlay(Theme.border) }
                    }
                }
            }
        }
    }

    /// A search that matched nothing is a different state from an empty log, and saying so is what
    /// keeps a typo from reading as "this dungeon killed nothing".
    @MainActor private var recentEmptyText: String {
        let typed = query.trimmingCharacters(in: .whitespaces)
        if !typed.isEmpty { return "No kills match \"\(typed)\"." }
        if scope == "zone", !allCandidates.isEmpty {
            return "Nothing has died in \(zoneName) yet. \(allCandidates.count) elsewhere."
        }
        return "Nothing has died yet in this log."
    }

    // MARK: - Buff timers

    /// The overlay's own rows, on the page. The allow-list filters them here exactly as it filters
    /// the floating windows in the Electron app — it is a display filter and reaches no model.
    @MainActor private var buffTimersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Buff timers").font(.headline)
                SegmentPicker(selection: $surface, options: [("buffs", "BUFFS"), ("debuffs", "DEBUFFS")])
                Spacer()
                WindowStatus(live: timers)
            }
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let now = Int64(ctx.date.timeIntervalSince1970 * 1000)
                let rows = allowedTimerRows
                if rows.isEmpty {
                    Text(timersEmptyText).font(.callout).foregroundStyle(Theme.textDim)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(timerGroups(rows)) { g in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(g.id == "self" ? "You" : g.id).font(.caption.weight(.semibold)).foregroundStyle(Theme.textDim)
                                ForEach(g.rows) { r in TimerBar(row: r, now: now) }
                            }
                        }
                    }
                }
            }
        }
    }

    @MainActor private var allowedTimerRows: [Row] {
        let allow = BuffAllowStore.shared
        guard allow.optIn else { return timers.rows }
        return timers.rows.filter { allow.allowed(BuffFormat.timerNameKey($0["name"].display)) }
    }

    @MainActor private var timersEmptyText: String {
        if timers.rows.isEmpty { return "No \(surface) timers running." }
        return "Every \(surface) timer is unchecked. Tick a spell in Buffs → Durations to draw it here."
    }

    private func timerGroups(_ rows: [Row]) -> [RowGroup] {
        var byKey: [String: [Row]] = [:]
        for r in rows { byKey[r["group"].display, default: []].append(r) }
        return byKey.keys
            .sorted { a, b in a == "self" ? true : (b == "self" ? false : a < b) }
            .map { RowGroup(id: $0, rows: (byKey[$0] ?? []).sorted { ($0["order"].int ?? 0) < ($1["order"].int ?? 0) }) }
    }

    // MARK: - Writing the watch list

    /// A define is a full-set REPLACE: the whole watch list is pushed on every change, with this
    /// one entry added or taken out and nothing else disturbed.
    ///
    /// The list is edited in `Prefs`, synchronously, rather than rebuilt from the last module
    /// snapshot: a snapshot is stale between two quick clicks and empty during catch-up, and a
    /// replace built from either drops watches. The snapshot is read only once, to adopt a list
    /// that predates `Prefs` holding one.
    private func setWatch(key: String, display: String, on: Bool) {
        var list = RespawnWatches.stored() ?? (respawn.state["prefs"]["watches"].array ?? [])
        list.removeAll { $0["key"].string == key }
        if on { list.append(["key": .string(key), "display": .string(display)]) }
        RespawnWatches.store(list)
        Task {
            await model.pushRespawnWatches()
            await respawn.refresh(model, module: "respawn")
        }
    }
}

/// The respawn watch list's home: `Prefs.respawnWatchesJSON`, pushed as `respawn.define`.
enum RespawnWatches {
    static func stored() -> [JSONValue]? {
        guard let text = Prefs.shared.respawnWatchesJSON, let v = try? JSONValue.parse(text) else { return nil }
        return v.array
    }

    static func store(_ list: [JSONValue]) {
        Prefs.shared.respawnWatchesJSON = JSONValue.array(list).serializedString()
    }
}

extension AppModel {
    /// Push the stored watch list. Called after every edit and after each attach; a list this
    /// install has never stored is not pushed, so the checkpoint's copy stands.
    func pushRespawnWatches() async {
        guard client.isReady, let list = RespawnWatches.stored() else { return }
        do {
            _ = try await client.request(Op.respawnDefine, ["prefs": ["watches": .array(list)]])
        } catch {
            note("respawn.define failed: \(error)")
        }
    }
}

/// One buff/debuff bar — the row the overlay draws, on the page. `mode` is the engine's own answer
/// about what this timer IS: a countdown, a count-up, or something that never expires.
struct TimerBar: View {
    var row: Row
    var now: Int64

    var body: some View {
        let started = row["startedTs"].int64 ?? 0
        let duration = row["durationMs"].int64
        let mode = row["mode"].string ?? "countup"
        let left = Double(started + (duration ?? 0) - now)
        HStack(spacing: 8) {
            Circle().fill(BuffFormat.classAccent(row["kind"].string ?? "buff")).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(row["name"].display).font(.callout)
                    // The engine already decided whether this row has a rank to print
                    // (`row_rank_label`), so the cell is read rather than re-derived here.
                    if let rank = row["rank"].string {
                        Text(rank).font(.caption).foregroundStyle(Theme.textDim)
                    }
                    if row["ambiguous"].bool == true { Text("~").foregroundStyle(Theme.orange) }
                    // A debuff's target is INFERRED (a cast line carries none), so it is labeled
                    // rather than stated.
                    if let t = row["target"].string, row["group"].string != "self" {
                        Text(row["inferredTarget"].bool == true ? "on \(t) (inferred)" : "on \(t)")
                            .font(.caption).foregroundStyle(Theme.textDim)
                    }
                    if let c = row["count"].int, c > 1 { Text("×\(c)").font(.caption).foregroundStyle(Theme.textDim) }
                }
                if mode == "countdown", let d = duration, d > 0 {
                    ProgressView(value: min(1, max(0, left / Double(d)))).tint(left < 30_000 ? Theme.orange : Theme.blue)
                }
            }
            Spacer(minLength: 6)
            Text(reading(mode: mode, started: started, left: left))
                .font(.callout).monospacedDigit()
                .foregroundStyle(mode == "countdown" && left < 30_000 ? Theme.orange : Theme.text)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.paper))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border))
    }

    private func reading(mode: String, started: Int64, left: Double) -> String {
        switch mode {
        case "countdown": return left > 0 ? BuffFormat.duration(left) : "ending"
        case "permanent": return "∞"
        default: return "up \(BuffFormat.duration(max(0, Double(now - started))))"
        }
    }
}
