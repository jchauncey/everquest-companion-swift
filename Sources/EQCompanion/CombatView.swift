// THE COMBAT TAB — the Electron app's Combat surface, natively.
//
// The header is one wrapping row of controls like the Motes and Gear tabs: WHAT AM I LOOKING AT
// (the Fight/Overall scope, then the encounter selector), then HOW AM I LOOKING AT IT
// (Dashboard/Timeline, the direction filter, whose damage).
//
// The body is one mob at a time: a strip of its numbers with your stance (CombatPayout.swift), then
// WHO (the source meter) and WHEN (the DPS curve), then WHAT FIRED (procs), your pet and the loot,
// over a full-width combat log — or the per-event timeline.
//
// EVERY DAMAGE NUMBER IS THE ENGINE'S. The derivations are the DPS curve and a multi-mob pull's
// one-mob view, both folded from the selected encounter's event ring exactly where the Electron
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
    /// The mob chosen on the strip for a pull that was not picked mob-by-mob (the live or last fight).
    @State private var mobChoice: String?
    /// The kills, experience and loot logged around the fight on screen (`combat.rewards`).
    @State private var rewards = FightRewardsLoader()
    /// The pet's casts, damage taken, heals and buffs in the fight on screen (`combat.petLog`).
    @State private var petLog = PetLogLoader()
    /// Your loadout over time (the `combo` module) and which classes can land each of your lanes.
    @State private var combo = ModuleSnapshot()
    @State private var laneClasses = LaneClassesLoader()
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
    /// The selected fight as the engine reports it — the whole pull.
    private var fightSegment: JSONValue { snapshot["selected"] }
    /// What the screen shows: the pull, or ONE of its mobs when it engaged several (`mob`).
    private var segment: JSONValue {
        guard let m = mob else { return fightSegment }
        return mobSegment(fightSegment, timeline: fullDetail, mob: m)
    }
    /// The pull's mobs, largest first, when it engaged more than one.
    private var mobs: [(name: String, total: Double)] {
        let m = pullMobs(fullDetail)
        return m.count > 1 ? m : []
    }
    /// The one mob on screen for a multi-mob pull: the one picked from the list (`fightId#mob`), the
    /// chip chosen, else the biggest. nil for a single-mob fight.
    private var mob: String? {
        guard !mobs.isEmpty else { return nil }
        let want = splitMobSelection(selection).mob ?? mobChoice
        if let w = want, let hit = mobs.first(where: { $0.name.lowercased() == w.lowercased() }) { return hit.name }
        return mobs.first?.name
    }
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
    private var fullDetail: JSONValue {
        if !fullTimeline.isNull { return fullTimeline }
        return digestTimeline(snapshot["digest"], durationSec: fightSegment["durationSec"].double ?? 0) ?? .null
    }
    /// The detail the cards draw: the pull's, or cut down to the mob on screen.
    private var detail: JSONValue { mob.map { mobTimeline(fullDetail, mob: $0) } ?? fullDetail }

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

    /// The fight on screen's first and last instants: the finished fight's row, or the open fight's
    /// own row in the segment list. nil for zone sessions.
    private var fightSpan: (start: Int64, end: Int64)? {
        guard scope == .fight else { return nil }
        guard let r = finishedFight ?? (selection == combatLiveSelection ? opts.head : nil),
              r.startTs > 0 else { return nil }
        return (r.startTs, r.startTs + Int64(r.durationSec * 1000))
    }

    /// What the mob on screen (or the whole fight) paid out; nil until the log has been read.
    private var payout: FightPayout? {
        guard let span = fightSpan, !rewards.raw.isNull else { return nil }
        let names: [String]
        if let m = mob { names = [m] }
        else if let one = pullMobs(fullDetail).first { names = [one.name] }
        else { names = [fightMobName(fightSegment["name"].string ?? "")] }
        return fightPayout(rewards.raw, mobs: names, fightEnd: span.end, coin: mobs.isEmpty)
    }

    /// Your source row in what is on screen.
    private var you: JSONValue? { (segment["entities"].array ?? []).first { $0["kind"].string == "you" } }
    private var yourLanes: [(lane: String, category: String)] { you.map(sourceLanes) ?? [] }

    /// Your abilities' classes, from the loadout you had when the fight started. nil until the
    /// loadout is known (it needs a /who or enough casts).
    private var classes: ClassResolver? {
        let loadout = loadoutClasses(combo.state, at: fightSpan?.start)
        return loadout.isEmpty ? nil : ClassResolver(loadout: loadout, lanes: laneClasses.known)
    }

    private var classShares: [ClassShare] {
        guard scope == .fight, let r = classes else { return [] }
        let pets = (segment["entities"].array ?? []).filter { $0["kind"].string == "pet" }
        return classBreakdown(you: you, pets: pets, resolver: r, durationSec: segment["durationSec"].double ?? 0)
    }

    /// The fight on screen is still open (its window grows).
    private var fightIsOpen: Bool {
        scope == .fight && selection == combatLiveSelection && opts.head?.live == true
    }

    private var petTaskKey: String {
        guard let s = fightSpan, let name = segmentPet(fightSegment)?["name"].string else { return "" }
        return PetLogLoader.key(pet: name, startTs: s.start, endTs: s.end, live: fightIsOpen, now: now)
    }

    /// Your pet's side of the mob (or fight) on screen; nil when you had no pet in it.
    private var pet: PetBreakdown? {
        guard scope == .fight, let p = segmentPet(segment) else { return nil }
        return petBreakdown(p, log: petLog.raw, mob: mob)
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
                poller.selectedId = selection == combatLiveSelection ? nil : splitMobSelection(selection).fight
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
                await unparsed.run(model, selectedId: selection == combatLiveSelection ? nil : splitMobSelection(selection).fight)
            }
            .task(id: "\(finishedFight.map { "\($0.startTs)|\($0.durationSec)" } ?? "")|\(model.epoch ?? 0)") {
                // A finished fight's own lines, once per fight: the engine records its log ring only
                // while following the game live, so an earlier fight's lines come from the file.
                guard let f = finishedFight, f.startTs > 0 else { fightLog.clear(); replay.clear(); return }
                await fightLog.load(model, startTs: f.startTs, durationSec: f.durationSec)
            }
            .task(id: "combo|\(model.moduleSeqs["combo"] ?? 0)|\(model.epoch ?? 0)") {
                await combo.refresh(model, module: "combo")
            }
            .task(id: "\(yourLanes.map { ClassResolver.key($0.lane, $0.category) }.joined(separator: ","))|\(model.epoch ?? 0)") {
                await laneClasses.ensure(model, yourLanes)
            }
            .task(id: "\(petTaskKey)|\(model.epoch ?? 0)") {
                guard let s = fightSpan, let name = segmentPet(fightSegment)?["name"].string else { petLog.clear(); return }
                await petLog.load(model, pet: name, startTs: s.start, endTs: s.end, live: fightIsOpen, now: now)
            }
            .task(id: "\(fightSpan.map { FightRewardsLoader.key(startTs: $0.start, endTs: $0.end, now: now) } ?? "")|\(model.epoch ?? 0)") {
                // What the fight paid out, read from the log past its last swing (loot comes later).
                guard let s = fightSpan else { rewards.clear(); return }
                await rewards.load(model, startTs: s.start, endTs: s.end, now: now)
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

    /// One wrapping row of controls, like the Motes and Gear tabs: WHAT (the scope and the fight)
    /// then HOW (Dashboard/Timeline, the direction, whose damage). The fight's numbers and your
    /// stance live in the stats strip below, not here.
    private var header: some View {
        FlowRow(spacing: 8, lineSpacing: 8) {
            // The scope only decides what the fight selector may LIST, so the two sit together.
            Picker("", selection: Binding(get: { scope }, set: { setScope($0) })) {
                Text("Fight").tag(CombatScope.fight)
                Text("Overall").tag(CombatScope.overall)
            }
            .pickerStyle(.segmented).frame(width: 150)
            FightPicker(opts: opts,
                        scope: scope,
                        selection: selection,
                        now: now,
                        onSelect: { o in picked = o; setSelection(o.value) },
                        loadHistory: loadFightHistory)
            .disabled(hydrating)

            Picker("", selection: Binding(get: { subTab }, set: { v in
                if v == .timeline, noTimeline { return }
                subTab = v
            })) {
                ForEach(SubTab.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).frame(width: 190)
            .help(noTimeline
                  ? "Timeline follows a single fight - it's kept for the live and recent encounters. The zone aggregate and older fights have no event ring."
                  : "")

            if subTab == .dashboard {
                Picker("", selection: Binding(get: { mode }, set: { setMode($0) })) {
                    ForEach(MeterMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).frame(width: 270)
                // Only the two SOURCE dimensions are scoped: the Incoming list is always "what is
                // hitting You", and no roster changes that.
                if mode != .incoming {
                    Chip(text: meterScope == .group && snapshot["roster"]["seen"].bool != true
                            ? "\(meterScope.label) (no roster yet)" : meterScope.label)
                        .help("Whose damage the meters show — Preferences → Combat")
                }
            }
        }
    }

    /// Your stance, invocation and blade coats — as they are NOW, so they ride with the fight on
    /// screen only when that is the current or last one. The display drops the jargon and simply
    /// numbers the slots; the tooltip names them.
    private var modifiers: [StatModifier] {
        guard scope == .fight, selection == combatLiveSelection else { return [] }
        let stance = snapshot["stance"]
        var out: [StatModifier] = []
        if let s = stance["stance"].string { out.append(.init(slot: 1, what: "combat stance", value: s, color: Theme.gold)) }
        if let i = stance["invocation"].string {
            out.append(.init(slot: 2, what: "invocation", value: i, color: Color(hex: 0xa98fe0)))
        }
        let coats = coatNames
        if !coats.isEmpty {
            out.append(.init(slot: 3, what: "blade coats", value: coats.joined(separator: " · "), color: Color(hex: 0xc46fd2)))
        }
        return out
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

    // MARK: - Body

    /// One chip per mob of a multi-mob pull: the screen shows one mob at a time, never the pull.
    @ViewBuilder
    private var mobStrip: some View {
        if !mobs.isEmpty {
            HStack(spacing: 6) {
                Text("Mobs in this pull").font(.caption).foregroundStyle(Theme.textDim)
                ForEach(mobs, id: \.name) { m in
                    let on = m.name == mob
                    Button { chooseMob(m.name) } label: {
                        Text("\(m.name) · \(CFmt.num(m.total))")
                            .font(.caption.weight(on ? .semibold : .regular))
                            .foregroundStyle(on ? Theme.background : Theme.text)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(on ? Theme.gold : Theme.paperRaised))
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// A mob picked from the list is part of the selection (`fightId#mob`); on the live or last fight
    /// it is a choice held beside it.
    private func chooseMob(_ name: String) {
        let (fight, picked) = splitMobSelection(selection)
        if picked != nil { setSelection(mobSelection(fight, name)) } else { mobChoice = name }
    }

    @ViewBuilder
    private var pane: some View {
        if hydrating {
            hydratingPanel
        } else if subTab == .timeline {
            VStack(alignment: .leading, spacing: 8) {
                mobStrip
                ScrollView { CombatTimelinePane(timeline: mob.map { mobTimeline(fullTimeline, mob: $0) } ?? fullTimeline).padding(.bottom, 2) }
                    .frame(maxHeight: .infinity)
            }
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
            VStack(alignment: .leading, spacing: 8) {
                mobStrip
                dashboard
            }
        }
    }

    /// The mob's (or fight's) numbers in a strip, then WHO and WHEN, and WHAT FIRED when it has
    /// something to say. A card with nothing for this selection is left out rather than drawn as a
    /// large empty box: no per-event detail (no ring and no digest) drops the curve; no real procs
    /// drops Procs. Each cell owns its own scroll box, so no panel can dictate the grid's size.
    private var dashboard: some View {
        let hasDetail = !detail.isNull
        let showProcs = procsHaveContent(segment["procs"])
        let meter = CombatMeterCard(seg: segment, timeline: detail, mode: mode,
                                    meterScope: meterScope, roster: snapshot["roster"],
                                    ringless: ringless, classes: classes, drill: $drill)
        return VStack(alignment: .leading, spacing: 8) {
            if let note = detailNote { CombatNote(note) }
            if scope == .fight {
                CombatStatsStrip(seg: segment, payout: payout, classes: classShares, modifiers: modifiers,
                                 inCombat: selection == combatLiveSelection && snapshot["inCombat"].bool == true,
                                 subject: mob ?? fightMobName(fightSegment["name"].string ?? ""))
            }
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
            }
            lowerRow(procs: hasDetail && showProcs)
        }
        .frame(maxHeight: .infinity)
    }

    /// WHAT FIRED, your pet and the loot, side by side and sharing the width. Each is there only
    /// when it has something to show: no pet in the fight and the loot takes the pet's place; the
    /// Overall scope has no corpse, so no loot. Loot alone is a short full-width row.
    @ViewBuilder
    private func lowerRow(procs: Bool) -> some View {
        let loot = scope == .fight && !segment.isNull
        let cards = (procs ? 1 : 0) + (pet != nil ? 1 : 0) + (loot ? 1 : 0)
        if cards > 0 {
            // With a pet, procs and loot are side columns and the pet (the widest card) takes the rest.
            let side: CGFloat? = pet != nil ? 280 : nil
            HStack(alignment: .top, spacing: 10) {
                if procs { CombatProcsCard(seg: segment).frame(maxWidth: side ?? .infinity, maxHeight: .infinity) }
                if let p = pet {
                    CombatPetCard(pet: p, logRead: !petLog.raw.isNull)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if loot { CombatLootCard(payout: payout).frame(maxWidth: side ?? .infinity, maxHeight: .infinity) }
            }
            .frame(height: cards == 1 && loot ? 120 : 190)
        }
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
                                                      ["opts": ["maxSegments": .int(1_000_000), "targets": true]], deadline: 15)
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
