import SwiftUI
import Charts
import EQCompanionCore

/// The landing tab: zone strip, then Damage / Leveling / Target cards, the DPS curve, and the
/// recent drops and kills feeds — the Electron Overview, card for card.
struct OverviewView: View {
    @Environment(AppModel.self) private var model
    @State private var character = ModuleSnapshot()
    @State private var progression = ModuleSnapshot()
    @State private var loot = ModuleSnapshot()
    @State private var poller = CombatPoller()
    @State private var kills = LiveView()
    @State private var leveling = OverviewLevelingState()
    @State private var drops: [DropRow] = []
    @State private var openTab: (Tab) -> Void = { _ in }
    @AppStorage("eq.tab") private var tabRaw: String = Tab.overview.rawValue

    var body: some View {
        NeedsEngine {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    zoneStrip
                    HStack(alignment: .top, spacing: 14) {
                        damageCard.frame(maxWidth: .infinity)
                        levelingCard.frame(maxWidth: .infinity)
                        targetCard.frame(maxWidth: .infinity)
                    }
                    dpsCurveCard
                    HStack(alignment: .top, spacing: 14) {
                        dropsCard.frame(maxWidth: .infinity)
                        killsCard.frame(maxWidth: .infinity)
                    }
                }
                .padding(16)
            }
            .background(Theme.background)
            .task(id: "\(model.moduleSeqs["character"] ?? 0)|\(model.epoch ?? 0)") { await character.refresh(model, module: "character") }
            .task(id: "\(model.moduleSeqs["progression"] ?? 0)|\(model.epoch ?? 0)") {
                await progression.refresh(model, module: "progression")
                let snap = OverviewProgression(progression.state)
                let who = character.state["level"]
                let stated: (Int, Int64, String)? = who["level"].int.map { ($0, who["ts"].int64 ?? 0, who["source"].string ?? "ding") }
                leveling = overviewLeveling(snap, statedLevel: stated)
            }
            .task(id: "\(model.moduleSeqs["loot"] ?? 0)|\(model.epoch ?? 0)") {
                await loot.refresh(model, module: "loot")
                drops = buildDropRows(loot.state)
            }
            .task(id: model.epoch) { kills.bind(model.client, ViewDescriptor(source: "kills.recent", window: (0, 25))) }
            .onDisappear { kills.close() }
            .task { poller.maxSegments = 5; poller.timeline = true; await poller.run(model) }
        }
    }

    // MARK: - Zone strip

    private var zoneStrip: some View {
        HStack(spacing: 8) {
            Image(systemName: "mappin.and.ellipse").foregroundStyle(Theme.textDim)
            Text(character.state["zone"].string ?? "Zone unknown").font(.headline)
            Text("\(model.attached?.name ?? "") · \(model.attached?.server ?? "")").foregroundStyle(Theme.textDim)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.paper))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
    }

    private func link(_ text: String, _ tab: Tab) -> AnyView {
        AnyView(Button { tabRaw = tab.rawValue } label: {
            HStack(spacing: 4) { Text(text.uppercased()); Image(systemName: "arrow.up.forward.square") }
                .font(.caption.weight(.semibold)).foregroundStyle(Theme.gold)
        }.buttonStyle(.plain))
    }

    // MARK: - Damage

    private var segment: JSONValue { poller.snapshot["selected"] }

    private var damageCard: some View {
        Card("Damage", trailing: link("Open in Combat", .combat)) {
            let s = segment
            if s.isNull {
                Text(poller.snapshot["hydrating"].bool == true ? "Catching up on the log…" : "No fight recorded yet.").foregroundStyle(Theme.textDim)
                    .frame(minHeight: 120)
            } else {
                let live = poller.snapshot["inCombat"].bool == true && s["active"].bool == true
                Text("\(live ? "Live fight" : "Last fight") - \(s["name"].string ?? "")").font(.callout).foregroundStyle(Theme.textDim).lineLimit(1)
                Text(Format.rate(s["outDps"].double ?? 0)).font(.system(size: 34, weight: .semibold)).foregroundStyle(Theme.gold)
                Text("\(Format.compact(s["outTotal"].double ?? 0)) total · \(clock(s["durationSec"].double ?? 0)) · \(Format.rate(s["activeDps"].double ?? 0)) active")
                    .font(.caption).foregroundStyle(Theme.textDim)
                MeterBars(segment: s).padding(.top, 4)
            }
        }
    }

    private func clock(_ sec: Double) -> String {
        let t = Int(sec.rounded())
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    // MARK: - Leveling

    private var levelingCard: some View {
        Card("Leveling", trailing: link("Open Leveling", .leveling)) {
            if leveling.empty {
                Text("Nothing folded yet.").foregroundStyle(Theme.textDim)
            } else {
                Text("Last hour").font(.caption).foregroundStyle(Theme.textDim)
                // Fixed-width tiles that wrap: a narrow window moves a tile down rather than
                // squeezing its number and clipping its label.
                FlowLayout(spacing: 8) {
                    ForEach(leveling.tiles) { t in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline, spacing: 3) {
                                Text(t.value).font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.gold).monospacedDigit()
                                    .lineLimit(1).fixedSize()
                                if !t.unit.isEmpty { Text(t.unit).font(.caption2).foregroundStyle(Theme.textDim).fixedSize() }
                            }
                            Text(t.label).font(.caption2).foregroundStyle(Theme.textDim).lineLimit(1)
                        }
                        .padding(8)
                        .frame(width: 132, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.paperRaised))
                        .help(t.title)
                    }
                }
                spark
                Text("\(leveling.killRate) · \(leveling.activity)\(leveling.offline.map { " · \($0)" } ?? "")").font(.caption).foregroundStyle(Theme.textDim)
                if let aa = leveling.aaLine { Text(aa).font(.caption).foregroundStyle(Theme.textDim) }
                if let z = leveling.zoneLine { Text(z).font(.caption).foregroundStyle(Theme.textDim).lineLimit(1) }
                if let h = leveling.history {
                    Text(h + (leveling.verdict.map { " · \($0)" } ?? "")).font(.caption).foregroundStyle(Theme.textDim).lineLimit(1)
                }
                if leveling.atCap { Chip(text: "at cap", color: Theme.orange) }
            }
        }
    }

    private var spark: some View {
        let peak = max(leveling.sparkPeak, 0.0001)
        return HStack(alignment: .bottom, spacing: 2) {
            ForEach(leveling.spark) { b in
                RoundedRectangle(cornerRadius: 1)
                    .fill(b.zone.isEmpty ? Color.gray : sparkColor(b.zone))
                    .frame(height: max(2, 36 * b.value / peak))
                    .frame(maxWidth: .infinity)
                    .help("\(Format.time(ms: b.t0)) · \(b.zone.isEmpty ? "zone unknown" : b.zone) · \(String(format: "%.2f", b.value)) levels")
            }
        }
        .frame(height: 36)
    }

    private static let zonePalette: [Color] = [Theme.green, Theme.purple, Theme.blue, Theme.orange, Theme.gold, Color(hex: 0xd97fb0), Color(hex: 0x7fd6c2), Color(hex: 0xc0c0c0)]

    private func sparkColor(_ zone: String) -> Color { Self.zonePalette[overviewZoneColorIndex(zone)] }

    // MARK: - Target

    private var targetCard: some View {
        Card("Target") {
            if let t = poller.snapshot["currentTarget"].object, let name = t["name"]?.string {
                Text(name).font(.headline)
                if let o = t["others"]?.int, o > 0 { Text("+\(o) other\(o == 1 ? "" : "s") engaged").font(.caption).foregroundStyle(Theme.textDim) }
                if let m = GameData.shared.mob(named: name) {
                    Text("Level \(m.level) · \(m.zones.joined(separator: ", "))").font(.caption).foregroundStyle(Theme.textDim)
                    if !m.drops.isEmpty {
                        Text("Drops: " + m.drops.prefix(6).joined(separator: ", ") + (m.drops.count > 6 ? " +\(m.drops.count - 6)" : ""))
                            .font(.caption).foregroundStyle(Theme.textDim)
                    }
                } else {
                    Text("Not in the catalog.").font(.caption).foregroundStyle(Theme.textDim)
                }
                Button("Open in Mobs") { tabRaw = Tab.mobs.rawValue }.buttonStyle(OutlineButtonStyle())
            } else {
                Text("Nothing engaged - the mob you swing at appears here as soon as a hit lands.")
                    .foregroundStyle(Theme.textDim).frame(minHeight: 120, alignment: .top)
            }
        }
    }

    // MARK: - DPS curve

    private struct CurvePoint: Identifiable {
        var id: Int
        var t: Double
        var dps: Double
        var series: String
    }

    private func curve(_ tl: JSONValue) -> ([CurvePoint], Double) {
        let events = tl["events"].array ?? []
        let duration = max(1000.0, tl["durationMs"].double ?? 1000)
        let bucketMs = max(1000.0, (duration / 60).rounded())
        let n = Int((duration / bucketMs).rounded(.up)) + 1
        var youPet = [Double](repeating: 0, count: n), pet = [Double](repeating: 0, count: n), incoming = [Double](repeating: 0, count: n)
        for e in events {
            let b = dpsBucketIndex(t: e["t"].double ?? 0, bucketMs: bucketMs, count: n)
            let amt = e["amount"].double ?? 0
            switch e["kind"].string {
            case "you": youPet[b] += amt
            case "pet": youPet[b] += amt; pet[b] += amt
            case "enemy": incoming[b] += amt
            default: break
            }
        }
        // 5 s rolling: the sum over the buckets covering the last five seconds, divided by 5.
        let win = max(1, Int((5000 / bucketMs).rounded()))
        var out: [CurvePoint] = []
        var peak = 0.0
        var id = 0
        for (name, arr) in [("you + pet", youPet), ("pet", pet), ("incoming", incoming)] {
            for i in 0..<n {
                let lo = max(0, i - win + 1)
                let sum = arr[lo...i].reduce(0, +)
                let dps = sum / (Double(i - lo + 1) * bucketMs / 1000)
                if name == "you + pet" { peak = max(peak, dps) }
                out.append(CurvePoint(id: id, t: Double(i) * bucketMs / 1000, dps: dps, series: name))
                id += 1
            }
        }
        return (out, peak)
    }

    private var dpsCurveCard: some View {
        let tl = poller.snapshot["timeline"]
        let (points, peak) = tl.isNull ? ([], 0) : curve(tl)
        return Card("DPS over time", trailing: AnyView(Text(peak > 0 ? "\(Int(peak.rounded())) dps peak" : "").font(.caption).foregroundStyle(Theme.gold))) {
            if points.isEmpty {
                Text("The curve draws from the selected fight's timeline.").foregroundStyle(Theme.textDim).frame(height: 120)
            } else {
                Chart(points) { p in
                    if p.series == "you + pet" {
                        AreaMark(x: .value("t", p.t), y: .value("dps", p.dps)).foregroundStyle(Theme.gold.opacity(0.18))
                    }
                    LineMark(x: .value("t", p.t), y: .value("dps", p.dps), series: .value("s", p.series))
                        .foregroundStyle(by: .value("s", p.series))
                        .lineStyle(StrokeStyle(lineWidth: p.series == "you + pet" ? 2 : 1))
                }
                .chartForegroundStyleScale(["you + pet": Theme.gold, "pet": Theme.blue, "incoming": Theme.red])
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) { v in AxisValueLabel { if let s = v.as(Double.self) { Text(clock(s)) } } } }
                .chartLegend(position: .bottom)
                .frame(height: 180)
                Text("5s rolling").font(.caption2).foregroundStyle(Theme.textFaint)
            }
        }
    }

    // MARK: - Recent drops

    struct DropRow: Identifiable {
        var id: String
        var ts: Int64
        var item: String
        var source: String
        var zone: String
        var count: Int?
        var highlighted: Bool
        var iconId: Int?
    }

    private func buildDropRows(_ state: JSONValue) -> [DropRow] {
        let history = state.array ?? []
        let skyKeys = Set(GameData.shared.skyQuests.flatMap { q in (q["items"].array ?? []).compactMap { $0["name"].string.map(GameData.nameKey) } })
        var rows: [DropRow] = []
        var i = history.count - 1
        while i >= 0, rows.count < 25 {
            let e = history[i]
            i -= 1
            if e["disposition"].string == "destroyed" { continue }
            let name = e["item"].string ?? ""
            let known = GameData.shared.item(named: name)
            let key = GameData.nameKey(name.replacingOccurrences(of: #" \+\d+$"#, with: "", options: .regularExpression))
            let posky = skyKeys.contains(key)
            let flags = (known?.stats["flags"].array ?? []).compactMap(\.string).map { $0.lowercased() }
            let notable = posky || flags.contains("lore item") || (known?.raw["quest"].bool == true) || !(known?.raw["questUses"].array ?? []).isEmpty
            rows.append(DropRow(id: "\(e["ts"].int64 ?? 0)|\(key)|\(i)", ts: e["ts"].int64 ?? 0, item: name,
                                source: e["source"].string ?? "", zone: e["zone"].string ?? "", count: e["count"].int,
                                highlighted: notable, iconId: known?.iconId))
        }
        return rows
    }

    private var dropsCard: some View {
        Card("Recent drops", trailing: link("All loot", .loot)) {
            if drops.isEmpty { Text("Nothing looted yet.").foregroundStyle(Theme.textDim) }
            ForEach(drops) { d in
                HStack(spacing: 8) {
                    Group {
                        if let img = GameData.shared.itemIcon(d.iconId) { Image(nsImage: img).resizable().interpolation(.none) }
                        else { RoundedRectangle(cornerRadius: 3).fill(Theme.paperRaised) }
                    }.frame(width: 18, height: 18)
                    Text((d.count.map { $0 > 1 ? "\($0)× " : "" } ?? "") + d.item)
                        .fontWeight(d.highlighted ? .bold : .regular)
                        .foregroundStyle(d.highlighted ? Theme.gold : Theme.text)
                        .lineLimit(1)
                    Spacer()
                    Text(d.source).foregroundStyle(Theme.textDim).lineLimit(1)
                    Text("· \(d.zone)").foregroundStyle(Theme.textDim).lineLimit(1)
                    Text(Format.time(ms: d.ts)).foregroundStyle(Theme.textFaint).monospacedDigit()
                }
                .font(.callout)
                .padding(.vertical, 1)
                .background(d.highlighted ? Theme.gold.opacity(0.06) : Color.clear)
            }
        }
    }

    // MARK: - Recent kills

    private var killsCard: some View {
        Card("Recent kills", trailing: link("Leveling", .leveling)) {
            if kills.rows.isEmpty, !kills.loading { Text("No kills yet.").foregroundStyle(Theme.textDim) }
            ForEach(kills.rows) { r in
                HStack(spacing: 8) {
                    Text(r["name"].display).lineLimit(1)
                    if r["pet"].bool == true { Chip(text: "pet") }
                    Spacer()
                    Text(r["zone"].display).foregroundStyle(Theme.textDim).lineLimit(1)
                    if r["expStated"].bool == true, let p = r["expPct"].double {
                        Text(String(format: "+%.2f%%", p)).foregroundStyle(Theme.green).monospacedDigit()
                    } else if r["expLine"].bool == true {
                        Text("xp").foregroundStyle(Theme.green)
                    }
                    Text(Format.time(ms: r.at)).foregroundStyle(Theme.textFaint).monospacedDigit()
                }
                .font(.callout)
            }
        }
    }
}
