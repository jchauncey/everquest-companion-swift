import SwiftUI
import AppKit
import EQCompanionCore

/// The Engine tab: health, performance, budgets, the engine's own stderr, and the client's notes.
struct EngineView: View {
    @Environment(AppModel.self) private var model
    @State private var perf: JSONValue = .null
    @State private var budgets: JSONValue = .null

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                GroupBox("Health") {
                    if let h = model.health {
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                            GridRow { Text("Status").foregroundStyle(.secondary); Text(h.status) }
                            GridRow { Text("Epoch").foregroundStyle(.secondary); Text("\(h.epoch)") }
                            GridRow { Text("Uptime").foregroundStyle(.secondary); Text(Format.clock(ms: h.uptimeMs)) }
                            GridRow { Text("Events").foregroundStyle(.secondary); Text(Format.count(h.events)) }
                            GridRow { Text("Mark").foregroundStyle(.secondary); Text(h.offset.map { Format.bytes($0) } ?? "—") }
                            GridRow { Text("Last event").foregroundStyle(.secondary); Text(h.lastEventTs.map { Format.stamp(ms: $0) } ?? "—") }
                            GridRow { Text("Log modified").foregroundStyle(.secondary); Text(h.logMtimeMs.map { Format.stamp(ms: $0) } ?? "—") }
                        }
                        .font(.callout)
                    } else {
                        Text("No health reading yet.").foregroundStyle(.secondary)
                    }
                }
                GroupBox("Performance") {
                    VStack(alignment: .leading, spacing: 4) {
                        if let ing = perf["ingest"].object {
                            Text("Scan: \(Format.bytes(ing["scanBytes"]?.int64 ?? 0)) in \(ing["scanMs"]?.int ?? 0) ms · spell db \(ing["spellDbMs"]?.int ?? 0) ms")
                        }
                        ForEach(perf["serve"].array ?? [], id: \.self) { s in
                            Text("\(s["source"].string ?? "?"): \(s["frames"].int ?? 0) frames, \(Format.bytes(s["bytes"].int64 ?? 0))")
                                .font(.caption)
                        }
                        ForEach(budgets["budgets"].array ?? [], id: \.self) { b in
                            HStack {
                                Image(systemName: b["verdict"].string == "pass" ? "checkmark.circle" : "xmark.circle")
                                    .foregroundStyle(b["verdict"].string == "pass" ? .green : .red)
                                Text("\(b["label"].string ?? ""): \(b["measured"].string ?? "") (\(b["limit"].string ?? ""))")
                            }.font(.caption)
                        }
                        Button("Refresh") { Task { await load() } }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("Client notes") {
                    ScrollView {
                        Text(model.debugLog.suffix(120).joined(separator: "\n"))
                            .font(.caption.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(height: 160)
                }
            }
            .padding(16)
        }
        .task { await load() }
    }

    private func load() async {
        guard model.client.isReady else { return }
        perf = (try? await model.client.request(Op.perfSnapshot)) ?? .null
        budgets = (try? await model.client.request(Op.perfBudgets)) ?? .null
    }
}
