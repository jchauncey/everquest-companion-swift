import SwiftUI
import EQCompanionCore

/// The event feed (`eventFeed.recent`), the alerts that fired, and the last `/con` card.
struct EventsView: View {
    @Environment(AppModel.self) private var model
    @State private var feed = LiveView()

    var body: some View {
        NeedsEngine {
            HSplitView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Event feed").font(.headline).padding(10)
                    List(feed.rows) { r in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(r["kind"].display).font(.caption).padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                                Text(r["title"].display)
                                Spacer()
                                Text(Format.stamp(ms: r.at)).font(.caption).foregroundStyle(.secondary)
                            }
                            if let d = r["detail"].string { Text(d).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    .listStyle(.inset)
                    if feed.rows.isEmpty, !feed.loading {
                        Text("Nothing in the feed yet — quest turn-ins, boss kills and other notable moments land here.")
                            .font(.caption).foregroundStyle(.secondary).padding(10)
                    }
                }
                .frame(minWidth: 380, maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Alerts fired").font(.headline).padding(10)
                    List(model.fires) { f in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(f.rule).fontWeight(.semibold)
                                Spacer()
                                Text(Format.time(ms: f.at)).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(f.message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            if let s = f.spell { Text(s).font(.caption2).foregroundStyle(.blue) }
                        }
                    }
                    .listStyle(.inset)
                    if let c = model.lastConCard {
                        Divider()
                        ConCardView(card: c).padding(10)
                    }
                }
                .frame(minWidth: 320, idealWidth: 380, maxWidth: 520)
            }
            .task(id: model.epoch) { feed.bind(model.client, ViewDescriptor(source: "eventFeed.recent", window: (0, 200))) }
            .onDisappear { feed.close() }
        }
    }
}

/// One live `/con` as the engine finished it: the five resist chips, numbers not sentences.
struct ConCardView: View {
    var card: JSONValue

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Last /con: \(card["name"].display)").font(.headline)
                if let l = card["level"].int { Text("level \(l)").foregroundStyle(.secondary) }
                if card["rare"].bool == true { Text("rare").foregroundStyle(.orange) }
                Spacer()
                Text(Format.time(ms: card["at"].int64 ?? 0)).font(.caption).foregroundStyle(.secondary)
            }
            if card["spellData"].bool == false {
                Text("spells_us.txt could not be read, so no resist benchmarks.").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                ForEach(card["chips"].array ?? [], id: \.self) { chip in
                    VStack(spacing: 1) {
                        Text(chip["axis"].display).font(.caption2).foregroundStyle(.secondary)
                        if let fit = chip["fit"].object, let r = fit["R"]?.double {
                            Text("R \(Int(max(0, r).rounded()))").font(.caption.weight(.semibold)).monospacedDigit()
                            Text("\(Int(max(0, fit["lo"]?.double ?? 0).rounded()))–\(Int(max(0, fit["hi"]?.double ?? 0).rounded()))").font(.caption2).foregroundStyle(.secondary)
                        } else {
                            Text(chip["tag"].string ?? "no data").font(.caption)
                        }
                        Text("n=\(chip["n"].int ?? 0)").font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                }
            }
        }
    }
}
