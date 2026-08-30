// The Raid Targets tab — raid progression and nothing else: the committed 32-target roster, your
// kill record folded onto it, and the weekly loot lockout. Ported from
// `src/renderer/src/features/bosses/BossView.tsx` + `BossSections.tsx`.
//
// TWO READINGS OF ONE ROSTER. OVERALL is everything you have ever killed, with the badge stating
// the highest instance tier. THIS WEEK is the loot-lockout view: of those kills, the ones inside
// the current Pacific reset week, with a five-rung difficulty ladder under each card saying which
// difficulties the week has taken. The clock is `Lockout`'s and there is no second one on this
// surface — the ladder, the badge, the tally and the "Defeated only" switch all read it.
//
// TWO GROUPINGS, ONE GRID. By progression category (Open World → Fear → Hate → Sky) is the
// default: it is what the roster is FOR. By class loadout time-joins each TIER RUN against the
// `combo` module's intervals, so a section header ("you were running these classes") is true of
// every card beneath it — and a stretch the model cannot explain names no loadout at all.
import SwiftUI
import EQCompanionCore

struct RaidTargetsView: View {
    @Environment(AppModel.self) private var model
    @State private var kills = ModuleSnapshot()
    @State private var combo = ModuleSnapshot()
    @State private var selected: String?
    @State private var query = ""
    @State private var defeatedOnly = false
    @State private var byLoadout = false
    @AppStorage("eq.bosses.mode") private var mode = "overall"
    @AppStorage("eq.bossDensity") private var density = "compact"
    /// Recomputed when the view appears and on every kills snapshot — the week is a function of
    /// the clock alone, so it never needs a timer of its own.
    @State private var now = nowMs()

    private var week: LockoutWindow { Lockout.window(now: now) }
    private var isWeek: Bool { mode == "week" }
    private var compact: Bool { density != "comfortable" }
    private var statuses: [TargetStatus] { BossStatus.all(kills.state) }

    var body: some View {
        NeedsEngine {
            let all = statuses
            HSplitView {
                VStack(alignment: .leading, spacing: 12) {
                    toolbar(all)
                    ScrollView { sections(all).padding(.bottom, 12) }
                }
                .padding(12)
                .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(Theme.background)
                if let name = selected, let s = all.first(where: { $0.target.name == name }) {
                    RaidTargetDetail(status: s, week: week, onClose: { selected = nil })
                        .frame(minWidth: 300, idealWidth: 380, maxWidth: 520)
                }
            }
            .task(id: "\(model.moduleSeqs["kills"] ?? 0)|\(model.epoch ?? 0)") {
                now = nowMs()
                await kills.refresh(model, module: "kills")
            }
            .task(id: "\(model.moduleSeqs["combo"] ?? 0)|\(model.epoch ?? 0)") { await combo.refresh(model, module: "combo") }
        }
    }

    // MARK: - Toolbar

    /// The tally counts the WHOLE roster, never the filtered list — it is the denominator the
    /// filter is measured against, so it must not move when a switch is flipped.
    private func tally(_ all: [TargetStatus]) -> String {
        if isWeek {
            let locked = all.filter { !Lockout.tierLocks($0.tiers, week).isEmpty }.count
            return "\(locked) / \(all.count) locked this week · resets in \(Lockout.untilReset(week)) · green rung = cleared"
        }
        let ever = all.filter(\.killed).count
        return "\(ever) / \(all.count) defeated · badge = highest instance tier"
    }

    /// The controls, in the Electron toolbar's order. They wrap to a second line rather than
    /// squeezing the tally off the edge (`ViewThatFits` below) — the tally is the sentence the
    /// whole tab is read for and it must never be the thing that truncates.
    @ViewBuilder
    private var controls: some View {
        SegmentPicker(selection: $mode, options: [("overall", "OVERALL"), ("week", "THIS WEEK")])
        TextField("Search target", text: $query)
            .textFieldStyle(.roundedBorder)
            .frame(width: 160)
        // THE LABEL FOLLOWS THE MODE: the switch filters on what "defeated" means in the view
        // you are standing in, so on the week view it must say so.
        Toggle(isWeek ? "Defeated this week" : "Defeated only", isOn: $defeatedOnly)
            .toggleStyle(.switch).controlSize(.mini).font(.caption).foregroundStyle(Theme.textDim)
        Toggle("By class loadout", isOn: $byLoadout)
            .toggleStyle(.switch).controlSize(.mini).font(.caption).foregroundStyle(Theme.textDim)
        SegmentPicker(selection: $density, options: [("compact", "COMPACT"), ("comfortable", "COMFORTABLE")])
    }

    private func toolbar(_ all: [TargetStatus]) -> some View {
        let text = Text(tally(all)).font(.caption).foregroundStyle(Theme.textDim).fixedSize()
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                controls
                Spacer(minLength: 12)
                text
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 14) { controls; Spacer(minLength: 0) }
                text
            }
        }
    }

    // MARK: - Sections

    private var defeated: (TargetStatus) -> Bool {
        isWeek ? RosterFilter.defeatedThisWeek(week) : RosterFilter.everDefeated
    }

    @ViewBuilder
    private func sections(_ all: [TargetStatus]) -> some View {
        let filtered = RosterFilter.apply(all, query: query, defeatedOnly: defeatedOnly, defeated: defeated)
        VStack(alignment: .leading, spacing: compact ? 14 : 22) {
            if byLoadout {
                loadoutSections(filtered)
            } else {
                ForEach(categories(filtered)) { group in
                    section(header: AnyView(categoryHeader(group)),
                            rows: group.list.map { LoadoutCard(s: $0, whole: $0) })
                }
            }
            if filtered.isEmpty {
                Text("No raid target matches these filters.").font(.callout).foregroundStyle(Theme.textFaint)
            }
        }
    }

    private struct CategoryGroup: Identifiable {
        var name: String
        var list: [TargetStatus]
        var id: String { name }
    }

    /// EQ raid progression order; anything the roster grows that this list does not name sorts last.
    private func categories(_ list: [TargetStatus]) -> [CategoryGroup] {
        var order: [String] = []
        var byCat: [String: [TargetStatus]] = [:]
        for s in list {
            if byCat[s.target.category] == nil { order.append(s.target.category) }
            byCat[s.target.category, default: []].append(s)
        }
        return order.sorted {
            (raidCategoryOrder.firstIndex(of: $0) ?? 98) < (raidCategoryOrder.firstIndex(of: $1) ?? 98)
        }.map { CategoryGroup(name: $0, list: byCat[$0] ?? []) }
    }

    private func categoryHeader(_ group: CategoryGroup) -> some View {
        HStack(spacing: 4) {
            Text(group.name).font(.callout.weight(.semibold)).foregroundStyle(Theme.gold)
            Text("(\(group.list.filter(\.killed).count)/\(group.list.count))")
                .font(.caption).foregroundStyle(Theme.textDim)
        }
    }

    /// Undefeated targets carry no timestamp to join on, so they keep their own trailing section
    /// instead of being silently dropped or attributed to a loadout.
    @ViewBuilder
    private func loadoutSections(_ filtered: [TargetStatus]) -> some View {
        let groups = LoadoutGroups.groups(LoadoutGroups.intervals(combo.state), filtered,
                                          keep: defeatedOnly ? defeated : nil)
        ForEach(groups) { g in
            section(header: AnyView(loadoutHeader(g)), rows: g.rows)
        }
        let undefeated = filtered.filter { !$0.killed || $0.lastTs == 0 }
        if !undefeated.isEmpty {
            section(header: AnyView(HStack(spacing: 4) {
                Text("Not defeated").font(.callout.weight(.semibold)).foregroundStyle(Theme.textDim)
                Text("(\(undefeated.count))").font(.caption).foregroundStyle(Theme.textFaint)
            }), rows: undefeated.map { LoadoutCard(s: $0, whole: $0) })
        }
    }

    private func loadoutHeader(_ g: LoadoutGrouping) -> some View {
        HStack(spacing: 6) {
            if let i = g.interval {
                ForEach(Array(i.slots.enumerated()), id: \.offset) { _, slot in
                    Chip(text: slot.label, color: Theme.blue)
                }
                Chip(text: i.provenanceLabel, color: i.provenance == "inferred" ? Theme.textDim : Theme.green)
                Text(LoadoutGroups.spansText(g.intervals)).font(.caption).foregroundStyle(Theme.textDim)
            } else if g.uncertain {
                // A header may decline to name a loadout: it states the two facts the model has —
                // that the stretch held more than one loadout, and which stretch — and refuses the
                // third. A greyed-out guess is still a guess.
                Text("Mixed loadouts").font(.callout.weight(.semibold)).foregroundStyle(Theme.orange)
                Text(LoadoutGroups.spansText(g.intervals)).font(.caption).foregroundStyle(Theme.textDim)
            } else {
                Text("Loadout not known").font(.callout.weight(.semibold)).foregroundStyle(Theme.textDim)
            }
            Text("(\(g.rows.count))").font(.caption).foregroundStyle(Theme.textFaint)
        }
        .help(g.uncertain ? LoadoutGroups.mixedRule : LoadoutGroups.groupRule)
    }

    private func section(header: AnyView, rows: [LoadoutCard]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            LazyVGrid(columns: [GridItem(.adaptive(minimum: compact ? 116 : 180), spacing: compact ? 8 : 12)],
                      alignment: .leading, spacing: compact ? 8 : 12) {
                ForEach(rows) { row in
                    RaidTargetCard(status: row.s,
                                   compact: compact,
                                   // The LADDER reads the WHOLE target, not this card's slice:
                                   // "which of this boss's difficulties has my week taken" is a
                                   // question about the BOSS, and answering it from a d4-only
                                   // slice would grey out four rungs a d0 card is showing green.
                                   ladder: isWeek ? Lockout.ladder(Lockout.tierLocks(row.whole.tiers, week)) : nil,
                                   lock: isWeek ? Lockout.tierLocks(row.s.tiers, week) : nil,
                                   selected: selected == row.s.target.name)
                    { selected = row.whole.target.name }
                }
            }
        }
    }
}

// MARK: - The card

private struct RaidTargetCard: View {
    var status: TargetStatus
    var compact: Bool
    /// Present ⇒ THIS WEEK view: the five rungs, derived from the WHOLE target.
    var ladder: [Lockout.Rung]?
    /// Present ⇒ THIS WEEK view: the difficulties THIS card's kills are locked at (empty = open).
    var lock: [TierLock]?
    var selected: Bool
    var onOpen: () -> Void

    /// What the corner pill says, and whether the card reads as "you have this one". Without a
    /// `lock` this is the OVERALL roster: the pill is the highest tier ever, and an undefeated
    /// target greys out under a neutral scrim. WITH a lock the same slot reports what this WEEK
    /// has taken — an empty lock array is "open", which is not "never killed".
    private var pill: (on: Bool, label: String, style: TierStyle) {
        guard let lock else {
            let style = RaidTier.style(status.bestTier)
            return (status.killed,
                    status.killed ? "defeated ×\(status.count) · \(RaidTier.badge(status.bestTier))" : "not defeated",
                    style)
        }
        guard let top = lock.last else { return (false, "open", RaidTier.style(status.bestTier)) }
        return (true, RaidTier.badge(top.tier), RaidTier.style(top.tier))
    }

    var body: some View {
        let p = pill
        let height: CGFloat = compact ? 70 : 120
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                portrait(height: height, dim: !p.on)
                Text(p.label)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(p.on ? p.style.fg : .white)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Capsule().fill(p.on ? p.style.bg : Color.black.opacity(0.65)))
                    .padding(4)
            }
            .overlay(alignment: .topLeading) {
                if p.on {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(p.style.fg)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(p.style.bg))
                        .padding(4)
                }
            }
            caption
        }
        .background(Theme.paper)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Theme.gold : (p.on ? p.style.bg : Theme.border), lineWidth: 2))
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .help("\(status.target.name) - drops, quests, your kills")
    }

    @ViewBuilder
    private func portrait(height: CGFloat, dim: Bool) -> some View {
        if let url = status.target.image, let img = GameData.shared.image(url: url) {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(height: height)
                .frame(maxWidth: .infinity)
                .clipped()
                .grayscale(dim ? 1 : 0)
                .brightness(dim ? -0.28 : 0)
        } else {
            // No portrait in the manifest: the initials tile, exactly as the web card falls back.
            Text(status.target.initials)
                .font(.system(size: height > 90 ? 26 : 18, weight: .bold))
                .foregroundStyle(Theme.textFaint)
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .background(Theme.paperRaised)
        }
    }

    @ViewBuilder
    private var caption: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(status.target.name)
                .font(compact ? .caption.weight(.semibold) : .callout.weight(.semibold))
                .foregroundStyle(status.killed ? Theme.text : Theme.textDim)
                .lineLimit(1)
                .help(status.target.name)
            if !compact, !status.target.zone.isEmpty {
                Text(status.target.zone).font(.caption).foregroundStyle(Theme.textDim).lineLimit(1)
            }
            // The five difficulties, every week, whether or not any of them is taken — and the
            // last thing on the card: the rungs carry the whole per-tier story, so nothing is
            // written underneath them.
            if let ladder {
                HStack(spacing: 3) {
                    ForEach(ladder) { rung in
                        let style = RaidTier.style(rung.tier)
                        Text(RaidTier.badge(rung.tier))
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(rung.cleared ? style.fg : Theme.textFaint)
                            .padding(.horizontal, 3).padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 3).fill(rung.cleared ? style.bg : Color.clear))
                            .overlay(RoundedRectangle(cornerRadius: 3).stroke(rung.cleared ? .clear : Theme.border))
                            .help(rung.cleared ? Format.date(ms: rung.ts) : "")
                    }
                }
            } else if status.killed {
                Text("\(Format.date(ms: status.lastTs != 0 ? status.lastTs : status.firstTs))\(compact ? "" : " · \(status.count) kill\(status.count == 1 ? "" : "s")")")
                    .font(.caption).foregroundStyle(Theme.textDim).lineLimit(1)
                    .help("First \(Format.stamp(ms: status.firstTs)) · Last \(Format.stamp(ms: status.lastTs))")
            } else if !compact {
                Text("not defeated").font(.caption).foregroundStyle(Theme.textFaint)
            }
        }
        .padding(compact ? 6 : 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - The detail pane

/// A raid target IS a mob, so it opens the same knowledge card everything else does — with the
/// kill history the roster already computed above it.
private struct RaidTargetDetail: View {
    var status: TargetStatus
    var week: LockoutWindow
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(status.target.name).font(.headline).foregroundStyle(Theme.text).lineLimit(1)
                Spacer()
                Button("Close", action: onClose).buttonStyle(OutlineButtonStyle())
            }
            .padding(10)
            VStack(alignment: .leading, spacing: 12) {
                Card("KILL HISTORY") {
                    if status.killed {
                        HStack(spacing: 12) {
                            Stat(label: "Kills", value: Format.count(status.count))
                            Stat(label: "Credited", value: Format.count(status.credited))
                            Stat(label: "Best", value: RaidTier.badge(status.bestTier))
                        }
                        Text("First \(Format.stamp(ms: status.firstTs)) · Last \(Format.stamp(ms: status.lastTs))")
                            .font(.caption).foregroundStyle(Theme.textDim)
                        ForEach(KillRecord.runs(status.tiers).reversed()) { r in
                            HStack(spacing: 8) {
                                Text(RaidTier.style(r.tier).long).font(.caption).foregroundStyle(Theme.text)
                                    .frame(width: 120, alignment: .leading)
                                Text("\(r.run.count) kill\(r.run.count == 1 ? "" : "s") · \(r.run.credited) credited")
                                    .font(.caption).foregroundStyle(Theme.textDim)
                                Spacer(minLength: 0)
                                Text(Format.stamp(ms: r.run.lastTs)).font(.caption).foregroundStyle(Theme.textFaint)
                            }
                        }
                        let locks = Lockout.tierLocks(status.tiers, week)
                        Text(locks.isEmpty
                             ? "Open this week at every difficulty."
                             : "Locked this week at \(locks.map { RaidTier.badge($0.tier) }.joined(separator: ", ")). Resets in \(Lockout.untilReset(week)).")
                            .font(.caption).foregroundStyle(locks.isEmpty ? Theme.textDim : Theme.green)
                    } else {
                        // Never a "0 kills" claim: the record simply has nothing to say.
                        Text("No kill of this target is on the record. Its `match` names are \(status.target.match.joined(separator: ", ")).")
                            .font(.callout).foregroundStyle(Theme.textFaint)
                    }
                }
                if !status.target.zone.isEmpty {
                    Text(status.target.zone).font(.caption).foregroundStyle(Theme.textDim)
                }
            }
            .padding(.horizontal, 10)
            KnowledgeCard(domain: "mob", name: status.target.name)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.background)
    }
}
