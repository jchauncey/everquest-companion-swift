// Preferences → Performance (upstream PerfSetting.tsx).
//
// TWO THINGS, deliberately on one page because they answer one question: what this app is costing
// the machine the game is running on.
//
//   THE PRIORITY SWITCH — the one control here that changes how the app BEHAVES rather than what
//   it shows, which is why it sits above the HUD. It moves the fold thread's scheduling class.
//
//   THE HUD SWITCH — off by default. Nothing about it runs while it is off.
//
//   LAST STARTUP — read-only, recorded on every launch whether the HUD was on or not.
//
// STATE, NEVER PROCESS: the captions say what the setting does and what the numbers mean. Nothing
// here explains samplers or scheduling classes — the user asked to see how the app is behaving,
// not how it looks at itself.
import SwiftUI
import EQCompanionCore
// SCOPED: `EQEngine` exports a `View` of its own (the serve path's), and a whole-module import of
// it makes every `some View` in this file ambiguous.
import enum EQEngine.FoldPriority

extension PrefPages {
    static let performance = PrefPage(id: "performance", label: "Performance", icon: "gauge.with.needle", sections: [
        PrefSectionInfo(id: "game-priority", label: "Game priority",
                        keywords: "priority cpu processor yield game foreground below normal lag stutter freeze hitch fps performance smooth background scheduling"),
        PrefSectionInfo(id: "perf-hud", label: "Performance HUD",
                        keywords: "performance perf cpu memory ram hud meter monitor lag stutter freeze slow jank fps startup boot launch profile speed diagnostics"),
        PrefSectionInfo(id: "engine-perf", label: "Engine",
                        keywords: "engine fold ingest scan serve budget latency rate verdict diagnostics")
    ]) { AnyView(PerformancePage()) }
}

/// The one place the "yield" setting reaches the engine. The engine's own default is to compete on
/// equal terms; this is what makes the stored preference true of the running process.
enum GamePriority {
    static func apply(yield: Bool) { FoldPriority.qos = yield ? .utility : .userInitiated }
    static func applyFromPrefs() { apply(yield: Prefs.shared.yieldCPU) }
}

struct PerformancePage: View {
    @Environment(AppModel.self) private var model
    @Bindable private var prefs = Prefs.shared
    @State private var perf: JSONValue = .null
    @State private var budgets: JSONValue = .null
    @State private var asked = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            priorityCard
            hudCard
            engineCard
        }
        .onAppear {
            GamePriority.applyFromPrefs()
            PerfHUD.shared.applyFromPrefs()
        }
    }

    // MARK: - Game priority

    private var priorityCard: some View {
        PrefCard("Game priority") {
            PrefToggle(label: "Yield CPU to the game (below-normal priority)",
                       isOn: $prefs.yieldCPU,
                       captionOn: "EverQuest gets the processor first whenever this app and the game want it at the same moment.",
                       captionOff: "Off. This app and EverQuest compete for the processor on equal terms.")
            .onChange(of: prefs.yieldCPU) { _, on in GamePriority.apply(yield: on) }
        }
    }

    // MARK: - Performance HUD, and the launch it recorded

    private var hudCard: some View {
        PrefCard("Performance HUD") {
            PrefToggle(label: "Show CPU and memory in the title bar",
                       isOn: $prefs.perfHUD,
                       // The upstream caption promises a click-through breakdown BY PROCESS. This
                       // app is one process with the engine folding on a thread inside it, so
                       // there is no process list to break down and nothing to click.
                       captionOn: "A live reading sits in the title bar - this app's share of one processor, and the memory it is holding, taken once a second. It is one process here, so the number is the whole of it.",
                       captionOff: "Off. Nothing is measured and nothing is shown. Turn it on if the app ever feels like it is stuttering - a low reading here while the app feels slow says the machine is loaded, not this app.")
            .onChange(of: prefs.perfHUD) { _, on in PerfHUD.shared.setEnabled(on) }
            startup
        }
    }

    @ViewBuilder
    private var startup: some View {
        if let p = AppTiming.profile(), !p.marks.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                (Text("Last startup: ") + Text(StartupFormat.ms(p.totalMs)).bold())
                    .foregroundStyle(Theme.text)
                VStack(spacing: 4) {
                    ForEach(p.timings) { t in
                        PhaseBar(label: t.phase, ms: t.durationMs,
                                 share: t.durationMs / max(1, p.totalMs))
                    }
                }
                PrefCaption("Launched \(StartupFormat.dateTime(p.startedAt))"
                            + " · version \(p.version)"
                            + (p.complete ? "" : " · this launch is still starting up"))
            }
            .padding(.top, 4)
        } else {
            PrefCaption("No startup breakdown recorded yet.")
        }
    }

    // MARK: - The engine's own numbers

    private var engineCard: some View {
        PrefCard("Engine") {
            VStack(alignment: .leading, spacing: 8) {
                if !asked {
                    PrefCaption("Not read yet.")
                } else if perf.isNull && budgets.isNull {
                    PrefCaption("The engine did not answer. It may still be starting up.")
                } else {
                    engineRows
                }
                PrefButton(title: "Refresh", icon: "arrow.clockwise") { Task { await load() } }
                // Asked when the page opens and when this button is pressed, and at no other
                // moment: a performance surface that costs a round trip a second while nobody is
                // looking at it is the bug it exists to find.
                PrefCaption("Read when this page opens and when you press refresh - never on a timer.")
            }
        }
        .task {
            guard !asked else { return }
            await load()
        }
    }

    @ViewBuilder
    private var engineRows: some View {
        if let status = perf["status"].string {
            EngineRow(label: "Status", value: status + " · epoch \(perf["epoch"].int ?? 0)")
        }
        if let ing = perf["ingest"].object {
            if let ms = ing["spellDbMs"]?.int {
                EngineRow(label: "Spell catalog", value: "\(ms) ms")
            }
            if let ms = ing["scanMs"]?.int {
                EngineRow(label: "History scan",
                          value: "\(Format.bytes(ing["scanBytes"]?.int64 ?? 0)) in \(StartupFormat.ms(Double(ms)))")
            } else {
                EngineRow(label: "History scan", value: "still running")
            }
        }
        EngineRow(label: "Events folded", value: Format.count(perf["events"].int ?? 0))
        ForEach(perf["serve"].array ?? [], id: \.self) { s in
            EngineRow(label: s["source"].string ?? "?",
                      value: "\(Format.count(s["frames"].int ?? 0)) frames · \(Format.bytes(s["payloadWeight"].int64 ?? 0))"
                             + (s["foldToFrameUsMax"].int.map { " · worst \($0) µs" } ?? ""))
        }
        ForEach(budgets["budgets"].array ?? [], id: \.self) { b in
            BudgetRow(budget: b)
        }
    }

    private func load() async {
        asked = true
        guard model.client.isReady else { perf = .null; budgets = .null; return }
        perf = (try? await model.client.request(Op.perfSnapshot)) ?? .null
        budgets = (try? await model.client.request(Op.perfBudgets)) ?? .null
    }
}

/// One phase's row: its name, a bar proportional to its share of the launch, and its duration.
private struct PhaseBar: View {
    let label: String
    let ms: Double
    let share: Double

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.caption).foregroundStyle(Theme.textDim)
                .frame(width: 190, alignment: .leading)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.06))
                    RoundedRectangle(cornerRadius: 4).fill(Theme.gold)
                        .frame(width: max(g.size.width * min(max(share, 0), 1), share > 0 ? 2 : 0))
                }
            }
            .frame(height: 8)
            Text(StartupFormat.ms(ms)).font(.caption.monospacedDigit()).foregroundStyle(Theme.text)
                .frame(width: 64, alignment: .trailing)
        }
    }
}

/// A label and a measurement, in the engine card's one shape.
private struct EngineRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.caption).foregroundStyle(Theme.textDim)
            Spacer()
            Text(value).font(.caption.monospacedDigit()).foregroundStyle(Theme.text)
        }
    }
}

/// One budget: what it allows, what it measured, and the engine's own verdict. The limit is drawn
/// beside the measurement because a performance goal is self-measured and never promised — a
/// reader judges for himself instead of trusting a colour.
private struct BudgetRow: View {
    let budget: JSONValue

    var body: some View {
        let verdict = budget["verdict"].string ?? "unmeasured"
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: verdict == "pass" ? "checkmark.circle"
                                : verdict == "fail" ? "xmark.circle" : "circle.dashed")
                    .foregroundStyle(verdict == "pass" ? Theme.green
                                     : verdict == "fail" ? Theme.red : Theme.textDim)
                Text(budget["label"].string ?? "").font(.caption).foregroundStyle(Theme.text)
                Spacer()
                Text(budget["measured"].string ?? "not measured yet")
                    .font(.caption.monospacedDigit()).foregroundStyle(Theme.text)
                Text("(\(budget["limit"].string ?? ""))").font(.caption).foregroundStyle(Theme.textDim)
            }
            if let note = budget["note"].string, !note.isEmpty { PrefCaption(note) }
        }
    }
}
