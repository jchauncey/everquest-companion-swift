// THE BUFFS TAB — what the model believes is up right now, and everything its log has ever mined
// about how long a spell line lasts. Ported from `src/renderer/src/features/buffs/BuffsView.tsx`
// and its two split-out halves (ActiveBuffRow.tsx, BuffStats.tsx).
//
// WORLD-MODEL LAW 1 IS THE WHOLE OF THIS PAGE: every number on an active card is either
// message-driven or LABELED as an estimate. An unknown duration says "unknown duration" instead of
// drawing a fake bar; a death bound wears a `≥` instead of reading as a measurement; a permanent
// buff gets a steady bar and the word, never a countdown.
//
// THE HEADER CHIP REPORTS THE MODEL, NOT THE PAGE. `n active` is what the engine believes is up —
// the permanent switch below decides what this page DRAWS, and a header that shrank when you hid a
// section would be reporting a preference as a fact. `n tracked` is the mined count: stats entries
// with at least one cast→fade pair.
//
// PERMANENT BUFFS ARE HIDDEN BY DEFAULT (JOS-215), which is why a missing preference and the
// default are the same fact.
import SwiftUI
import EQCompanionCore

struct BuffsView: View {
    @Environment(AppModel.self) private var model
    @State private var live = LiveView()
    @State private var snap = ModuleSnapshot()
    @State private var table = BuffStatsTable()
    @State private var builtSeq: Int?
    @AppStorage("eq.buffs.showPermanent") private var showPermanent = false
    @MainActor private var allow: BuffAllowStore { BuffAllowStore.shared }

    var body: some View {
        NeedsEngine {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    activeSection
                    BuffsDurationsSection(table: table)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.background)
            .task(id: model.epoch) {
                live.bind(model.client, ViewDescriptor(source: "buffs.active", window: (0, 200)))
            }
            .task(id: "\(model.moduleSeqs["buffs"] ?? 0)|\(model.epoch ?? 0)") {
                await snap.refresh(model, module: "buffs")
            }
            // THE TABLE IS BUILT ONCE PER MODULE SEQ, off the main actor. The `buffs` snapshot is
            // the largest this app fetches (the overlay audit carries thousands of messages), so
            // the rebuild is keyed on the seq the engine stamped and skipped when it has not moved.
            .task(id: "\(snap.seq ?? -1)|\(snap.state.isNull ? 0 : 1)") { await rebuild() }
            .onDisappear { live.close() }
        }
    }

    private func rebuild() async {
        guard !snap.state.isNull else { return }
        if let s = snap.seq, s == builtSeq { return }
        let stats = snap.state["stats"]
        let built = await Task.detached(priority: .userInitiated) { BuffStatsBuilder.build(stats: stats) }.value
        table = built
        builtSeq = snap.seq
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "wand.and.stars").foregroundStyle(Theme.gold)
            Text("Buffs").font(.title2.weight(.semibold))
            Chip(text: "\(live.total) active · \(table.tracked) tracked")
            WindowStatus(live: live)
            Spacer()
            // THE MODE, AT THE TOP OF THE TAB — what every checkbox below it means. Off is the
            // shipped answer and off is invisible: no boxes anywhere.
            Toggle("Only track buffs and debuffs I check", isOn: Binding(
                get: { allow.optIn },
                set: { allow.setOptIn($0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .font(.caption)
            .foregroundStyle(Theme.textDim)
        }
    }

    // MARK: - Active

    /// Self buffs first, then one group per bound entity, most-recently-refreshed entity first.
    private var groups: [RowGroup] {
        let shown = showPermanent ? live.rows : live.rows.filter { $0["permanent"].bool != true }
        var byKey: [String: [Row]] = [:]
        var order: [String] = []
        for r in shown {
            let k = BuffFormat.groupKey(isSelf: r["self"].bool == true, target: r["target"].string)
            if byKey[k] == nil { order.append(k) }
            byKey[k, default: []].append(r)
        }
        func recency(_ rows: [Row]) -> Int64 { rows.map { $0["startedTs"].int64 ?? 0 }.max() ?? 0 }
        return order
            .map { RowGroup(id: $0, rows: (byKey[$0] ?? []).sorted { ($0["startedTs"].int64 ?? 0) < ($1["startedTs"].int64 ?? 0) }) }
            .sorted { a, b in
                if a.id == "self" { return true }
                if b.id == "self" { return false }
                return recency(a.rows) > recency(b.rows)
            }
    }

    private var permanentCount: Int { live.rows.filter { $0["permanent"].bool == true }.count }

    private var activeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Active").font(.headline)
                // The chip is absent when there is nothing to reveal, and its label carries the
                // COUNT — the whole answer for a reader who only wanted to know whether any are up.
                if permanentCount > 0 {
                    Button { showPermanent.toggle() } label: {
                        Chip(text: "\(permanentCount) permanent",
                             color: showPermanent ? Theme.orange : Theme.textDim,
                             filled: showPermanent)
                    }
                    .buttonStyle(.plain)
                    .help(showPermanent
                          ? "Showing buffs that never expire. Click to hide them."
                          : "Buffs that never expire are hidden. Click to show them.")
                }
            }
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let now = Int64(ctx.date.timeIntervalSince1970 * 1000)
                let gs = groups
                if gs.isEmpty {
                    Text("No active buffs.").font(.callout).foregroundStyle(Theme.textDim)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(gs) { g in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 6) {
                                    Text(BuffFormat.groupLabel(g.id)).font(.caption.weight(.semibold))
                                    Chip(text: "\(g.rows.count)")
                                }
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 10)], alignment: .leading, spacing: 10) {
                                    ForEach(g.rows) { r in ActiveBuffCard(row: r, now: now) }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

/// ONE LIVE BUFF, as a card: what it is, how long it has been up, and how much longer it is
/// estimated to last. The countdown carries the whole of law 1 for this feature.
struct ActiveBuffCard: View {
    var row: Row
    var now: Int64

    private var cls: String { row["cls"].string ?? "buff" }
    private var elapsed: Double { max(0, Double(now - (row["startedTs"].int64 ?? now))) }
    private var estimate: Double? {
        guard let e = row["estimatedMs"].double, e > 0 else { return nil }
        return e
    }

    /// Overdue: run past the estimated window. For a mined estimate that needs n≥2 past p75; for a
    /// STATED one (the database, or a death bound) being past the number itself is enough, because
    /// expiry is message-driven and the model is waiting for a line.
    private var overdue: Bool {
        let source = row["durationSource"].string
        let stated = source == "db" || source == "deathBound"
        if BuffFormat.isOverdue(elapsedMs: elapsed, p75: row["p75"].double, n: row["n"].int ?? 0) { return true }
        return stated && estimate != nil && elapsed > (estimate ?? 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            titleRow
            bar
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.paper))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
        .overlay(alignment: .leading) { Rectangle().fill(BuffFormat.classAccent(cls)).frame(width: 3) }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            BuffAllowCheck(spell: row["spell"].display)
            Text(row["spell"].display).font(.callout.weight(.semibold)).lineLimit(1)
            // The rank the cast line spelled, beside the name and never inside it: `spell` is the
            // identity the model speaks, the numeral is a fact about this instance.
            if let rank = BuffFormat.rowRankLabel(name: row["spell"].display, castName: row["castName"].string) {
                Text(rank).font(.caption).foregroundStyle(Theme.textDim)
            }
            if row["ambiguous"].bool == true { Text("~").foregroundStyle(Theme.orange) }
            if row["messageDriven"].bool == true {
                Chip(text: "message", color: Theme.green).help("Confirmed by a chat message")
            }
            Spacer(minLength: 4)
            Text("\(BuffFormat.duration(elapsed)) elapsed").font(.caption).foregroundStyle(Theme.textDim).monospacedDigit()
        }
    }

    @ViewBuilder
    private var bar: some View {
        if row["permanent"].bool == true {
            // A buff that never fades: a full, steady bar and the word. The caption says WHICH kind
            // of permanent, because the model answers that (`permanentSource`) and guessing at it
            // told rogues their poison coat was an illusion AA.
            ProgressView(value: 1).tint(Theme.gold)
            Text(row["permanentSource"].string == "illusion-aa" ? "permanent · illusion AA" : "permanent")
                .font(.caption).foregroundStyle(Theme.orange)
        } else if let est = estimate {
            estimateBar(est)
        } else {
            // No estimate at all: an indeterminate bar that says so rather than faking a countdown.
            ProgressView().progressViewStyle(.linear).opacity(0.5)
            Text("unknown duration").font(.caption).foregroundStyle(Theme.textFaint)
        }
    }

    @ViewBuilder
    private func estimateBar(_ est: Double) -> some View {
        let remaining = max(0, est - elapsed)
        let frac = BuffFormat.remainingFraction(elapsedMs: elapsed, estimatedMs: est)
        let source = row["durationSource"].string
        let prefix = BuffFormat.estimatePrefix(source)
        let spread: Double? = {
            guard let a = row["p25"].double, let b = row["p75"].double else { return nil }
            return (b - a) / 2
        }()
        ProgressView(value: frac).tint(overdue || frac < 0.2 ? Theme.orange : Theme.blue)
        HStack(spacing: 6) {
            Text(overdue
                 ? "past estimate"
                 : "\(prefix.isEmpty ? "~" : prefix)\(BuffFormat.duration(remaining)) left"
                 + ((spread.map { $0 > 1000 } ?? false) ? " (± \(BuffFormat.duration(spread)))" : ""))
                .font(.caption)
                .foregroundStyle(overdue ? Theme.orange : Theme.textDim)
                .monospacedDigit()
            Spacer(minLength: 0)
            if let source {
                Text(BuffFormat.sourceChip(source))
                    .font(.system(size: 9))
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .overlay(Capsule().stroke(Theme.textFaint))
                    .foregroundStyle(Theme.textDim)
                    .help(BuffFormat.estimatorSourceTitle(source))
            }
            Text("n=\(row["n"].int ?? 0)").font(.caption).foregroundStyle(Theme.textFaint)
        }
    }
}
