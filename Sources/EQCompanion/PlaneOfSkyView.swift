// The Plane of Sky tab: 95 class tests, what you hold toward each of them, and the five other
// readings of that one set — what is ready to hand in, who to pull next, what is safe to destroy,
// how far each class is from its unlock, and what you have hidden.
//
// The counts come from three witnesses the store reconciles (`SkyStore`): the looted log, the
// `/outputfile inventory` dump on disk, and the counts you state by hand. Which of them speaks is
// the "Count items from" control, and every pane says which one it used.
import SwiftUI
import EQCompanionCore

struct PlaneOfSkyView: View {
    @Environment(AppModel.self) private var model
    @State private var store = SkyStore()
    @State private var tab: SkyTab = .quests

    enum SkyTab: String, CaseIterable, Identifiable {
        case quests, ready, targets, cleanup, classes, ignored
        var id: String { rawValue }
    }

    var body: some View {
        NeedsEngine {
            VStack(alignment: .leading, spacing: 10) {
                tabs
                pane
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .task(id: taskKey) { await store.refresh(model) }
        }
    }

    /// One key over every input the tab reads: a new character, or any of the three modules moving.
    private var taskKey: String {
        [model.epoch ?? 0,
         model.moduleSeqs["loot"] ?? 0,
         model.moduleSeqs["turnins"] ?? 0,
         model.moduleSeqs["classUnlocks"] ?? 0,
         model.moduleSeqs["outputFiles"] ?? 0].map(String.init).joined(separator: "|")
    }

    private var tabs: some View {
        HStack(spacing: 0) {
            ForEach(SkyTab.allCases) { t in
                Button { tab = t } label: {
                    Text(label(t))
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .foregroundStyle(tab == t ? Theme.gold : Theme.textDim)
                        .background(tab == t ? Theme.gold.opacity(0.12) : Color.clear)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            if store.loading { ProgressView().controlSize(.small) }
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.paperRaised))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border))
    }

    /// A tab's count is the array the pane itself draws — a number that disagreed with the rows
    /// under it would be worse than no number.
    private func label(_ t: SkyTab) -> String {
        switch t {
        case .quests: return "Quests"
        case .ready: return store.ready.isEmpty ? "Ready" : "Ready (\(store.ready.count))"
        case .targets: return store.targets.mobs.isEmpty ? "Targets" : "Targets (\(store.targets.mobs.count))"
        case .cleanup:
            let n = store.cleanupRows.count
            return n == 0 ? "Cleanup" : "Cleanup (\(n))"
        case .classes: return "Classes"
        case .ignored: return store.ignored.isEmpty ? "Ignored" : "Ignored (\(store.ignored.count))"
        }
    }

    @ViewBuilder private var pane: some View {
        switch tab {
        case .quests: SkyQuestsPane(store: store)
        case .ready: SkyReadyPane(store: store)
        case .targets: SkyTargetsPane(store: store)
        case .cleanup: SkyCleanupPane(store: store)
        case .classes: SkyClassesPane(store: store)
        case .ignored: SkyIgnoredPane(store: store)
        }
    }
}
