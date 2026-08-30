import SwiftUI
import EQCompanionCore

enum Tab: String, CaseIterable, Identifiable {
    case overview, combat, mobs, loot, gear, maps, raidTargets, planeOfSky, alerts, leveling, buffs, timers
    case events, knowledge, spells, engine
    var id: String { rawValue }

    /// The Electron nav order, then the Mac-only extras.
    static let primary: [Tab] = [.overview, .combat, .mobs, .loot, .gear, .maps, .raidTargets, .planeOfSky, .alerts, .leveling, .buffs, .timers]
    static let secondary: [Tab] = [.events, .knowledge, .spells, .engine]

    var label: String {
        switch self {
        case .overview: return "Overview"
        case .combat: return "Combat"
        case .mobs: return "Mobs"
        case .loot: return "Loot"
        case .gear: return "Gear"
        case .maps: return "Maps"
        case .raidTargets: return "Raid Targets"
        case .planeOfSky: return "Plane of Sky"
        case .alerts: return "Alerts"
        case .leveling: return "Leveling"
        case .buffs: return "Buffs"
        case .timers: return "Timers"
        case .events: return "Events"
        case .knowledge: return "Knowledge"
        case .spells: return "Spells"
        case .engine: return "Engine"
        }
    }

    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2.fill"
        case .combat: return "chart.bar.fill"
        case .mobs: return "pawprint.fill"
        case .loot: return "shippingbox.fill"
        case .gear: return "figure.stand"
        case .maps: return "map.fill"
        case .raidTargets: return "trophy.fill"
        case .planeOfSky: return "shield.fill"
        case .alerts: return "bell.fill"
        case .leveling: return "chart.line.uptrend.xyaxis"
        case .buffs: return "wand.and.stars"
        case .timers: return "stopwatch.fill"
        case .events: return "list.bullet.rectangle"
        case .knowledge: return "book.fill"
        case .spells: return "sparkles"
        case .engine: return "gearshape.2.fill"
        }
    }

    var badge: String? { self == .gear ? "beta" : nil }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("eq.tab") private var tabRaw: String = Tab.overview.rawValue

    private var tab: Tab { Tab(rawValue: tabRaw) ?? .overview }

    var body: some View {
        // A real split view, so the window title and the toolbar's divider land at the sidebar's
        // edge instead of the title running across it. The column is fixed: the drawer never collapses.
        NavigationSplitView {
            Sidebar(selected: tab) { tabRaw = $0.rawValue }
                // Fixed width (min = ideal = max leaves no drag handle) but still collapsible
                // from the toolbar toggle. The column paints the app's own background, not the
                // split view's vibrant material, so the header is one colour across the window.
                .navigationSplitViewColumnWidth(min: 236, ideal: 236, max: 236)
                .background(Theme.background.ignoresSafeArea())
                .toolbarBackground(Theme.background, for: .windowToolbar)
        } detail: {
            VStack(spacing: 0) {
                EngineBanner()
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Theme.background)
            .toolbarBackground(Theme.background, for: .windowToolbar)
            .navigationTitle("EQ Companion")
            .toolbar {
                // Everything is right-anchored: the character (one per server, so it rarely
                // changes), the HUD number, the log's state, the overlay switch.
                ToolbarItemGroup(placement: .primaryAction) {
                    if let t = PerfHUD.shared.text {
                        // Preferences → Performance: the HUD's one number, only while it is on.
                        Text(t).font(.caption.monospacedDigit()).foregroundStyle(Theme.textDim)
                            .help("This app's share of one processor and its resident memory, once a second")
                    }
                    CharacterPicker()
                    EngineDot().padding(.horizontal, 6)
                    Button {
                        model.overlayVisible.toggle()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: model.overlayVisible ? "rectangle.on.rectangle.fill" : "rectangle.on.rectangle")
                            Text("DPS overlay")
                        }
                    }
                    .help(model.overlayVisible ? "Hide the floating DPS meter (⇧⌘O)" : "Show the floating DPS meter over the game (⇧⌘O)")
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .background(Theme.background)
        .preferredColorScheme(.dark)
        .tint(Theme.gold)
        .onAppear { AppTiming.mark("Interface drawn") }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .overview: OverviewView()
        case .combat: CombatView()
        case .mobs: MobsView()
        case .loot: LootView()
        case .gear: GearView()
        case .maps: MapsView()
        case .raidTargets: RaidTargetsView()
        case .planeOfSky: PlaneOfSkyView()
        case .alerts: AlertsView()
        case .leveling: LevelingView()
        case .buffs: BuffsView()
        case .timers: TimersView()
        case .events: EventsView()
        case .knowledge: KnowledgeView()
        case .spells: SpellsView()
        case .engine: EngineView()
        }
    }
}

/// The Electron app's nav drawer: icon rows, a `beta` chip, Preferences and the version footer.
struct Sidebar: View {
    @Environment(AppModel.self) private var model
    var selected: Tab
    var onSelect: (Tab) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Tab.primary) { row($0) }
                    Divider().overlay(Theme.border).padding(.vertical, 8)
                    ForEach(Tab.secondary) { row($0) }
                }
                .padding(.top, 8)
            }
            Spacer(minLength: 0)
            Divider().overlay(Theme.border)
            SettingsLink {
                HStack(spacing: 14) {
                    Image(systemName: "gearshape.fill").frame(width: 22)
                    Text("Preferences")
                    Spacer()
                }
                .font(.system(size: 15))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 18).padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            HStack {
                Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev") · \(model.launchPhase == .live ? "engine live" : "engine \(String(describing: model.launchPhase))")")
                    .font(.caption2).foregroundStyle(Theme.textFaint)
                Spacer()
            }
            .padding(.horizontal, 18).padding(.bottom, 10)
        }
        .background(Theme.background)
    }

    private func row(_ t: Tab) -> some View {
        Button { onSelect(t) } label: {
            HStack(spacing: 14) {
                Image(systemName: t.icon).frame(width: 22).foregroundStyle(selected == t ? Theme.gold : Theme.text)
                Text(t.label).foregroundStyle(Theme.text)
                Spacer()
                if let b = t.badge { Chip(text: b) }
            }
            .font(.system(size: 15))
            .padding(.horizontal, 18).padding(.vertical, 11)
            .background(selected == t ? Theme.gold.opacity(0.12) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct CharacterPicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            if model.characters.isEmpty {
                Text("No character logs found")
            }
            ForEach(model.characters) { c in
                Button {
                    model.select(c)
                } label: {
                    if c.logPath == model.selectedLogPath { Label(c.label, systemImage: "checkmark") } else { Text(c.label) }
                }
            }
            Divider()
            Button("Refresh") { Task { await model.refreshCharacters(); await model.attachSelected() } }
            SettingsLink { Text("Preferences…") }
        } label: {
            Label(model.attached?.label ?? model.characters.first(where: { $0.logPath == model.selectedLogPath })?.label ?? "Character",
                  systemImage: "person.crop.circle")
        }
    }
}

struct EngineDot: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
        .help(help)
    }

    private var color: Color {
        switch model.launchPhase {
        case .live: return .green
        case .folding: return .yellow
        case .starting: return .gray
        case .absent, .failed: return .red
        }
    }

    /// What the dot says: the state of the LOG READER, in the player's words.
    private var text: String {
        switch model.launchPhase {
        case .live: return model.health?.status == "live" ? "Log live" : "Log ready"
        case .folding: return "Catching up"
        case .starting: return "Starting"
        case .absent: return "No log"
        case .failed: return "Reader failed"
        }
    }

    private var help: String {
        let lead: String
        switch model.launchPhase {
        case .live: lead = "Live: the log is being followed as the game writes it - every panel updates as lines land."
        case .folding: lead = "Catching up: reading the log's history before going live."
        case .starting: lead = "Starting the log reader."
        case .absent: lead = "No character log is attached - pick one, or point Preferences → Game at your EverQuest folder."
        case .failed: lead = "The log reader failed to start - see the card in the window, or client.log."
        }
        if let h = model.health {
            return lead + " \(Format.count(h.events)) events read, up \(Format.clock(ms: h.uptimeMs))."
        }
        return lead
    }
}

/// The catch-up bar and the failure card — the two states that draw. `starting` and `live` are
/// silent on purpose.
struct EngineBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.launchPhase {
        case .folding:
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Reading \(model.attached?.label ?? "the log")…").font(.callout.weight(.semibold))
                    Spacer()
                    if let p = model.progress {
                        Text("\(Int(p.pct))% · \(Format.bytes(p.offset)) of \(Format.bytes(max(p.offset, p.logSize))) · \(Format.count(p.events)) events")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        if let eta = model.foldRing.etaText { Text(eta).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                ProgressView(value: min(100, max(0, model.progress?.pct ?? 0)), total: 100)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.bar)
        case .absent, .failed:
            if let f = model.fault {
                FailureCard(fault: f)
            }
        case .starting:
            HStack { ProgressView().controlSize(.small); Text("Starting the data engine…").font(.callout) ; Spacer() }
                .padding(.horizontal, 14).padding(.vertical, 6).background(.bar)
        case .live:
            EmptyView()
        }
    }
}

struct FailureCard: View {
    @Environment(AppModel.self) private var model
    var fault: EngineFault
    @State private var showPaths = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(headline, systemImage: "exclamationmark.triangle.fill").font(.headline).foregroundStyle(.red)
            Text(body_).font(.callout)
            Text("Until it starts, EQ Companion cannot read your log at all — every panel will stay empty. Your log file and your settings are untouched.")
                .font(.caption).foregroundStyle(.secondary)
            if let d = fault.detail, !d.isEmpty { Text(d).font(.caption.monospaced()).foregroundStyle(.secondary) }
            HStack {
                Button("Retry") { model.retryEngine() }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    private var headline: String {
        switch fault.kind {
        case .startFailed: return "EQ Companion could not start its data engine"
        case .unhealthy: return "The data engine stopped responding"
        }
    }

    private var body_: String {
        switch fault.kind {
        case .startFailed: return "The engine that reads your log could not be built in this process."
        case .unhealthy: return "The engine stopped answering the app's health checks. Retry rebuilds it from your log."
        }
    }
}

/// A view that needs the engine live: shows the honest empty state until it is.
struct NeedsEngine<Content: View>: View {
    @Environment(AppModel.self) private var model
    @ViewBuilder var content: () -> Content

    var body: some View {
        if model.connection == .ready, model.attached != nil {
            content()
        } else {
            ContentUnavailableView {
                Label(model.characters.isEmpty && model.connection == .ready ? "No character logs" : "Waiting for the engine",
                      systemImage: model.characters.isEmpty && model.connection == .ready ? "doc.text.magnifyingglass" : "hourglass")
            } description: {
                if model.characters.isEmpty, model.connection == .ready {
                    Text("No `eqlog_<Character>_<server>.txt` under \(model.install?.logsDir.path ?? "the install folder"). In EverQuest type `/log on`, or point Preferences at your EverQuest Legends folder.")
                } else {
                    Text("The data engine is starting and will read your log the moment it is up.")
                }
            } actions: {
                SettingsLink { Text("Preferences…") }
            }
        }
    }
}
