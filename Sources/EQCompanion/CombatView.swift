// THE COMBAT TAB — the Electron app's Combat surface, natively.
//
// SUBJECT, then LENS. The header is two ranks that answer two different questions in the order
// you actually ask them: line 1 is WHAT AM I LOOKING AT (the Fight/Overall scope fused to the
// encounter selector, and hard right the selected fight's dps at the size that claims it); line 2
// is HOW AM I LOOKING AT IT (Dashboard/Timeline, the direction filter, whose damage, and hard
// right the purely passive modifier readout).
//
// The body is the 2x2 dashboard — WHO (the source meter), WHEN (the DPS curve), WHAT FIRED
// (procs), WHOM (damage by mob) — over a full-width combat log, or the per-event timeline.
//
// EVERY NUMBER IS THE ENGINE'S. The only two derivations are the DPS curve and the damage-by-mob
// grouping, both folded from the selected encounter's event ring exactly where the Electron
// renderer folds them (CombatData.swift is the port); the meter's own totals are the engine's
// SourceView bars and never touch the ring.

import SwiftUI
import EQCompanionCore

struct CombatView: View {
    @Environment(AppModel.self) private var model
    @State private var poller = CombatPoller()
    @State private var unparsed = UnparsedLog()

    /// Fight vs Overall — an EXPLICIT scope, never an automatic switch. It decides both what the
    /// body shows and what the selector may list (fights only / zone sessions only).
    @State private var scope: CombatScope = .fight
    /// TWO SELECTIONS, ONE PER SCOPE. Flipping the scope shows the other list's own current row
    /// and writes nothing, so an Overall session can never be mistaken for a fight pick.
    @State private var fightSelection = combatLiveSelection
    @State private var zoneSelection = "zone"
    @State private var subTab: SubTab = .dashboard
    @State private var mode: MeterMode = .out
    /// One preference, no per-surface chip (Preferences → Combat → "Whose damage the meters show").
    private var meterScope: MeterScope { MeterScope.preferred }
    @State private var showUnparsed = false
    @State private var drill: CombatDrill?
    /// The row last picked from the fight list: its start and length bound the fight's own log lines.
    @State private var picked: ScopeOption?
    /// A finished fight's own lines, read back from the log file (the engine's `log.window`).
    @State private var fightLog = FightLogLines()
    /// A finished fight's timeline rebuilt from the log, when the engine no longer keeps its ring.
    @State private var replay = FightReplay()
    /// The live poll's window onto the fight list: the head row and the recent fights. The picker
    /// reads the whole history itself, on open (`loadFightHistory`).
    private let maxSegments = 100

    enum SubTab: String, CaseIterable, Hashable {
        case dashboard, timeline
        var label: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    }

    /// What this surface is showing — the scope picks which of the two selections is in force.
    private var selection: String { scope == .fight ? fightSelection : zoneSelection }

    private var snapshot: JSONValue { poller.snapshot }
    private var segment: JSONValue { snapshot["selected"] }
    private var timeline: JSONValue { snapshot["timeline"] }
    /// During the startup replay the engine is folding the whole log, so every snapshot's
    /// "current fight" is an encounter from hours ago. A churning fake-live meter is a lie.
    private var hydrating: Bool { snapshot.isNull || snapshot["hydrating"].bool == true }
    private var opts: ScopeOptions {
        scopeOptions(scope, segments: snapshot["segments"].array ?? [], zoneSessions: snapshot["zoneSessions"].array ?? [])
    }
    /// The timeline is drawn from an encounter's event ring, and a ring only exists for the live
    /// and most recent fights. Offering Timeline for the rest lands on an empty pane, which reads
    /// as a broken view rather than as "this selection has no such data".
    private var noTimeline: Bool { !hydrating && fullTimeline.isNull }
    /// The fight's full timeline: the engine's own ring, or — for a fight the engine no longer keeps
    /// one for — the one rebuilt from its stretch of the log (`combat.replay`). Null when neither.
    private var fullTimeline: JSONValue {
        if !timeline.isNull { return timeline }
        if let f = finishedFight, replay.key == FightReplay.key(f), let tl = replay.timeline { return tl }
        return .null
    }
    /// Why the event-derived panels have nothing to show. Both are quiet notes, never errors.
    private var ringless: String {
        segment["kind"].string == "zone"
            ? "Per-event detail isn't kept for zone sessions - pick a fight to see this."
            : "Per-event detail is no longer kept for this fight."
    }
    private var now: Int64 { poller.now > 0 ? poller.now : nowMs() }

    /// What the curve and mob cards draw from: the event ring when there is one, else the engine's
    /// digest of it (a fight whose ring was dropped), read as a timeline. Null when neither exists.
    private var detail: JSONValue {
        if !fullTimeline.isNull { return fullTimeline }
        return digestTimeline(snapshot["digest"], durationSec: segment["durationSec"].double ?? 0) ?? .null
    }

    /// The finished fight on screen, with its start and length — the head row between pulls, or the
    /// row picked from the list. nil for the open fight and for zone sessions: those read the
    /// engine's live log.
    private var finishedFight: ScopeOption? {
        guard scope == .fight else { return nil }
        if selection == combatLiveSelection {
            guard let h = opts.head, !h.live else { return nil }
            return h
        }
        if let p = picked, p.value == selection { return p }
        return opts.rest.first { $0.value == selection }
    }

    var body: some View {
        NeedsEngine {
            VStack(spacing: 10) {
                header
                pane
                CombatLogCard(lines: logLines, showUnparsed: $showUnparsed, note: logNote).frame(height: 210)
            }
            .padding(12)
            .background(Theme.background)
            .task(id: "\(selection)|\(maxSegments)|\(model.epoch ?? 0)") {
                // The sentinel is sent as *no* selectedId, so the engine re-resolves it every
                // tick (open fight → that fight; none open → the most recent finalized one).
                poller.selectedId = selection == combatLiveSelection ? nil : selection
                poller.maxSegments = maxSegments
                // ALWAYS on for this tab: the DPS curve and the damage-by-mob grouping both come
                // from the ring, so the payload is needed for every ring-backed selection and not
                // just while the Timeline pane is up. The engine caps a serialized timeline at 2k
                // events and a ring-less selection returns null for free.
                poller.timeline = true
                // And the digest for a fight whose event ring the engine has dropped, so the curve and
                // damage-by-mob still draw for it.
                poller.digest = true
                await poller.run(model)
            }
            .task(id: "\(showUnparsed)|\(selection)|\(model.epoch ?? 0)") {
                // `showUnparsed` is an engine-side filter (it runs BEFORE the ring is sliced), so
                // it cannot be answered client-side. The shared poller carries no such option, so
                // the toggle runs its own thin poll and only while it is on.
                guard showUnparsed else { unparsed.lines = []; return }
                await unparsed.run(model, selectedId: selection == combatLiveSelection ? nil : selection)
            }
            .task(id: "\(finishedFight.map { "\($0.startTs)|\($0.durationSec)" } ?? "")|\(model.epoch ?? 0)") {
                // A finished fight's own lines, once per fight: the engine records its log ring only
                // while following the game live, so an earlier fight's lines come from the file.
                guard let f = finishedFight, f.startTs > 0 else { fightLog.clear(); replay.clear(); return }
                await fightLog.load(model, startTs: f.startTs, durationSec: f.durationSec)
            }
            .task(id: "\(finishedFight.map(FightReplay.key) ?? "")|\(timeline.isNull)|\(model.epoch ?? 0)") {
                // Only for a fight the engine has no ring for: rebuild its timeline from the log.
                guard let f = finishedFight, f.startTs > 0, timeline.isNull, !hydrating else { return }
                await replay.load(model, f)
            }
            .onChange(of: noTimeline) { _, gone in
                if gone, subTab == .timeline { subTab = .dashboard }
            }
        }
    }

    private var logLines: [JSONValue] {
        if showUnparsed { return unparsed.lines }
        if finishedFight != nil { return fightLog.lines }
        return snapshot["recent"].array ?? []
    }

    /// Where an older fight's detail came from, said once above the cards.
    private var detailNote: String? {
        guard segment["kind"].string != "zone", timeline.isNull else { return nil }
        if !fullTimeline.isNull { return "This fight's detail was rebuilt from the log file." }
        if replay.loading { return "Rebuilding this fight's detail from the log…" }
        if !detail.isNull { return "Showing this fight's summary: its full detail couldn't be rebuilt from the log." }
        return "No per-event detail is kept for this fight, so its curve and damage-by-mob can't be drawn."
    }

    private var logNote: String? {
        guard !showUnparsed, finishedFight != nil else { return nil }
        if fightLog.loading { return "reading the log…" }
        return fightLog.truncated ? "from the log file · first \(fightLog.lines.count) lines" : "from the log file"
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 6) {
            subjectLine
            lensLine
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.paper))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
    }

    /// LINE 1 — SUBJECT. The scope toggle is fused tight against the encounter selector as ONE
    /// unit, because scope is not a peer of anything: it only decides what that selector may LIST.
    private var subjectLine: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                SegmentPicker(selection: Binding(get: { scope }, set: { setScope($0) }),
                              options: [(CombatScope.fight, "Fight"), (.overall, "Overall")])
                FightPicker(opts: opts,
                            scope: scope,
                            selection: selection,
                            now: now,
                            onSelect: { o in picked = o; setSelection(o.value) },
                            loadHistory: loadFightHistory)
                .disabled(hydrating)
            }
            .padding(.horizontal, 4).padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border))
            .frame(maxWidth: 560)

            Spacer(minLength: 8)
            headlineStat
        }
    }

    /// The subject line's payoff: outgoing dps is what this tab is for, so it gets the size and
    /// the accent; total and duration ride along dim, as the context that makes the rate mean
    /// something.
    @ViewBuilder
    private var headlineStat: some View {
        if !segment.isNull {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(CFmt.rate(segment["outDps"].double ?? 0))
                    .font(.system(size: 17.5, weight: .bold)).foregroundStyle(Theme.gold).monospacedDigit()
                Text("\(CFmt.num(segment["outTotal"].double ?? 0)) · \(CFmt.dur(segment["durationSec"].double ?? 0))")
                    .font(.caption).foregroundStyle(Theme.textFaint).monospacedDigit()
            }
            .lineLimit(1)
        }
    }

    /// LINE 2 — LENS, left to right in decreasing consequence: the view switch (the tab's own
    /// navigation), the direction filter, whose damage, then right-aligned the purely passive
    /// readout — modifier slots and the in-combat dot, which are STATE and not controls.
    private var lensLine: some View {
        HStack(spacing: 8) {
            SegmentPicker(selection: Binding(get: { subTab }, set: { v in
                if v == .timeline, noTimeline { return }
                subTab = v
            }), options: SubTab.allCases.map { ($0, $0.label) })
            .help(noTimeline
                  ? "Timeline follows a single fight - it's kept for the live and recent encounters. The zone aggregate and older fights have no event ring."
                  : "")

            if subTab == .dashboard {
                Divider().frame(height: 14).overlay(Theme.border)
                SegmentPicker(selection: Binding(get: { mode }, set: { setMode($0) }),
                              options: MeterMode.allCases.map { ($0, $0.label) })
                // Only the two SOURCE dimensions are scoped: the Incoming list is always "what is
                // hitting You", and no roster changes that.
                if mode != .incoming {
                    Text(meterScope.label).font(.system(size: 10)).foregroundStyle(Theme.textFaint)
                        .help("Whose damage the meters show — Preferences → Combat")
                    if meterScope == .group, snapshot["roster"]["seen"].bool != true {
                        Text("(no roster yet)").font(.system(size: 10)).foregroundStyle(Theme.textFaint)
                    }
                }
            }

            Spacer(minLength: 8)
            passiveStatus
        }
    }

    /// Stance, invocation and the blade coats. The DISPLAY drops the jargon — the categories read
    /// as strange next to a value like "Berserker" — and simply numbers the two slots.
    @ViewBuilder
    private var passiveStatus: some View {
        let stance = snapshot["stance"]
        let coats = coatNames
        HStack(spacing: 6) {
            if let s = stance["stance"].string { modifierSlot(1, s, Theme.gold) }
            if let i = stance["invocation"].string { modifierSlot(2, i, Color(hex: 0xa98fe0)) }
            if !coats.isEmpty { modifierSlot(3, coats.joined(separator: " · "), Color(hex: 0xc46fd2)) }
            if snapshot["inCombat"].bool == true {
                HStack(spacing: 4) {
                    Circle().fill(Theme.green).frame(width: 7, height: 7)
                    Text("in combat").font(.caption).foregroundStyle(Theme.textDim)
                }
            }
        }
        .lineLimit(1)
    }

    /// Utility first, then the venom stack — the order the pill truncates from the right in.
    private var coatNames: [String] {
        let coat = snapshot["poison"]["coat"]
        var slots: [JSONValue] = []
        if !coat["utility"].isNull { slots.append(coat["utility"]) }
        slots.append(contentsOf: coat["combat"].array ?? [])
        return slots.compactMap { $0["poison"].string }.map { p in
            p == "unknown" ? "unknown" : p.replacingOccurrences(of: " Poison", with: "").replacingOccurrences(of: " Venom", with: "")
        }
    }

    private func modifierSlot(_ n: Int, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 2) {
            Text("\(n):").font(.system(size: 10)).foregroundStyle(Theme.textFaint)
            Text(value.prefix(1).uppercased() + value.dropFirst())
                .font(.caption.weight(.semibold)).foregroundStyle(color).lineLimit(1)
        }
        .padding(.horizontal, 5).padding(.vertical, 1)
        .background(Capsule().fill(Color.white.opacity(0.04)))
        .help("Modifier \(n) - \(n == 1 ? "combat stance" : n == 2 ? "invocation" : "blade coats"): \(value)")
    }

    // MARK: - Body

    @ViewBuilder
    private var pane: some View {
        if hydrating {
            hydratingPanel
        } else if subTab == .timeline {
            ScrollView { CombatTimelinePane(timeline: fullTimeline).padding(.bottom, 2) }
                .frame(maxHeight: .infinity)
        } else if segment.isNull {
            // A Fight scope with nothing in it stays empty on purpose — it does NOT borrow the
            // zone aggregate to look busy; Overall is one click away and says so.
            CombatCard(title: scope == .fight ? "No fights yet" : "No zone session yet") {
                CombatNote(scope == .fight
                          ? "Engage something and it'll appear here live. Switch to Overall for this zone's totals."
                          : "It starts with your first damage in a zone.")
            }
            .frame(maxHeight: .infinity)
        } else {
            dashboard
        }
    }

    /// WHO, WHEN, WHAT FIRED, WHOM — and only the ones with something to say. A card with nothing
    /// for this selection is left out rather than drawn as a large empty box: no per-event detail
    /// (no ring and no digest) drops the curve and mob cards; no real procs drops Procs. Each cell
    /// owns its own scroll box, so no panel can dictate the grid's size.
    private var dashboard: some View {
        let hasDetail = !detail.isNull
        let showProcs = procsHaveContent(segment["procs"])
        let meter = CombatMeterCard(seg: segment, timeline: detail, mode: mode,
                                    meterScope: meterScope, roster: snapshot["roster"],
                                    ringless: ringless, drill: $drill)
        return VStack(alignment: .leading, spacing: 6) {
            if let note = detailNote { CombatNote(note) }
            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    meter
                    if hasDetail {
                        DpsOverTimeCard(timeline: detail,
                                        live: isLiveSelection(opts.head, selection),
                                        noRing: ringless)
                    } else if showProcs {
                        CombatProcsCard(seg: segment)
                    }
                }
                if hasDetail {
                    GridRow {
                        if showProcs { CombatProcsCard(seg: segment) }
                        // The mob card's level-2 body renders inside the meter panel — so in the Healing
                        // dimension its rows are read-only rather than a click that opens nothing.
                        CombatMobCard(seg: segment, timeline: detail, ringless: ringless,
                                      setDrill: mode == .heal ? nil : { drill = $0 },
                                      drill: drill)
                            .gridCellColumns(showProcs ? 1 : 2)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var hydratingPanel: some View {
        CombatCard(title: "Reading log") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Folding your log's history — the meter is live the moment the tail is reached.")
                        .font(.caption).foregroundStyle(Theme.textDim)
                }
                ForEach(0..<5, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 3).fill(Theme.paperRaised.opacity(1 - Double(i) * 0.15))
                        .frame(height: 20)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Navigation

    /// Switching scope shows the OTHER scope's own current row — it writes nothing.
    private func setScope(_ s: CombatScope) {
        scope = s
        if s == .fight, fightSelection.isEmpty { fightSelection = defaultSelection(.fight) }
        if s == .overall, zoneSelection.isEmpty { zoneSelection = defaultSelection(.overall) }
    }

    /// Picking another fight KEEPS the drill: the subject is resolved against the new segment, and
    /// a segment without it shows level 1 while the token waits for one that has it.
    private func setSelection(_ v: String) {
        if scope == .fight { fightSelection = v } else { zoneSelection = v }
    }

    /// …and the one navigation that makes a drill meaningless: the three directions are three
    /// different lists of subjects, so a token carried sideways means nothing where it lands.
    private func setMode(_ m: MeterMode) {
        drill = nil
        mode = m
    }

    /// Every fight the engine holds, for the picker's by-day history: one request when the picker
    /// opens, apart from the once-a-second poll (about 2,800 fights and a few ms on a month-old log).
    private func loadFightHistory() async -> ScopeOptions? {
        guard let r = try? await model.client.request(Op.combatSnapshot,
                                                      ["opts": ["maxSegments": .int(1_000_000)]], deadline: 15)
        else { return nil }
        return fightScopeOptions(r["snapshot"]["segments"].array ?? [])
    }

}

/// The combat log's UNPARSED half. `showUnparsed` is filtered engine-side before the ring is
/// sliced, so the lines simply are not in the shared poller's snapshot — this asks for them, and
/// only while the toggle is on.
@MainActor
@Observable
final class UnparsedLog {
    var lines: [JSONValue] = []

    func run(_ model: AppModel, selectedId: String?) async {
        while !Task.isCancelled {
            if model.client.isReady {
                var opts: [String: JSONValue] = ["showUnparsed": .bool(true), "maxSegments": .int(1)]
                if let s = selectedId { opts["selectedId"] = .string(s) }
                if let r = try? await model.client.request(Op.combatSnapshot, ["opts": .object(opts)], deadline: 10) {
                    lines = r["snapshot"]["recent"].array ?? []
                }
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }
}

/// A finished fight's own lines, read back from the log file through `log.window`: the engine's
/// log ring is only written while it follows the game live, so a fight from before this launch
/// has nothing in memory. Read once per fight; the window pads a second either side.
@MainActor
@Observable
final class FightLogLines {
    var lines: [JSONValue] = []
    var truncated = false
    var loading = false
    private var key = ""

    func clear() { key = ""; lines = []; truncated = false; loading = false }

    func load(_ model: AppModel, startTs: Int64, durationSec: Double) async {
        let k = "\(startTs)|\(durationSec)"
        guard k != key else { return }
        key = k
        lines = []
        truncated = false
        loading = true
        defer { loading = false }
        let to = startTs + Int64(durationSec * 1000) + 1000
        guard let r = try? await model.client.request(Op.logWindow,
                                                      ["from": .int(startTs - 1000), "to": .int(to), "limit": .int(3000)],
                                                      deadline: 15),
              key == k else { return }
        lines = r["lines"].array ?? []
        truncated = r["truncated"].bool ?? false
    }
}

/// A finished fight's full timeline rebuilt from the log (`combat.replay`): the engine keeps the
/// event ring only for its last 60 fights, and this folds the older fight's stretch of the log again
/// (with a few minutes' lead-in for context) to get it back. One request per fight, remembered.
@MainActor
@Observable
final class FightReplay {
    var timeline: JSONValue?
    var loading = false
    private(set) var key = ""

    static func key(_ f: ScopeOption) -> String { "\(f.startTs)|\(f.durationSec)" }

    func clear() { key = ""; timeline = nil; loading = false }

    func load(_ model: AppModel, _ f: ScopeOption) async {
        let k = Self.key(f)
        guard k != key else { return }
        key = k
        timeline = nil
        loading = true
        defer { loading = false }
        let to = f.startTs + Int64(f.durationSec * 1000)
        guard let r = try? await model.client.request(Op.combatReplay,
                                                      ["from": .int(f.startTs), "to": .int(to)], deadline: 30),
              key == k else { return }
        let tl = r["timeline"]
        timeline = tl.isNull ? nil : tl
    }
}
