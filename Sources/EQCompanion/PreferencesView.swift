// Preferences — the upstream PreferencesView: a sidebar of pages, a search box that matches
// sections across every page, and one page's cards on the right. Each page lives in Prefs/<Page>.swift
// and registers itself as a `PrefPage`; this file only arranges them.
import SwiftUI
import AppKit

enum PrefPages {
    /// Sidebar order — the upstream order, minus the Wine-only Graphics page.
    static var all: [PrefPage] {
        [game, appearance, combat, overlays, window, buffs, cursorRing, voice, profiles, updates,
         whatsNew, analytics, performance, feedback, thanks]
    }
}

struct PreferencesView: View {
    @Environment(AppModel.self) private var model
    @State private var selected: String = "game"
    @State private var query: String = ""

    private var pages: [PrefPage] { PrefPages.all }

    /// Sections whose label or keywords contain every word of the query, grouped by page.
    private var matches: [(PrefPage, [PrefSectionInfo])] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        return pages.compactMap { p in
            let hit = p.sections.filter { s in
                let hay = "\(p.label) \(s.label) \(s.keywords)".lowercased()
                return words.allSatisfy { hay.contains($0) }
            }
            return hit.isEmpty ? nil : (p, hit)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            sidebar.frame(width: 210)
            Divider().overlay(Theme.border)
            content
        }
        .background(Theme.background)
        .environment(\.colorScheme, .dark)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Preferences").font(.title2.weight(.bold)).foregroundStyle(Theme.text)
                .padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 12)
            ForEach(pages) { p in
                Button { selected = p.id; query = "" } label: {
                    HStack(spacing: 10) {
                        Image(systemName: p.icon).frame(width: 18).foregroundStyle(Theme.textDim)
                        Text(p.label).foregroundStyle(Theme.text)
                        Spacer()
                    }
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 6).fill(selected == p.id && query.isEmpty ? Theme.gold.opacity(0.12) : Color.clear))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
            }
            Spacer()
            Text("EQ Companion \(AppVersion.current)").font(.caption).foregroundStyle(Theme.textFaint)
                .padding(16)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.textDim)
                TextField("Search preferences…", text: $query).textFieldStyle(.plain).foregroundStyle(Theme.text)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textDim) }.buttonStyle(.plain)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if query.isEmpty {
                        if let p = pages.first(where: { $0.id == selected }) {
                            PrefPageHeading(text: p.label)
                            p.body()
                        }
                    } else if matches.isEmpty {
                        Text("Nothing matches “\(query)”.").foregroundStyle(Theme.textDim)
                    } else {
                        ForEach(matches, id: \.0.id) { (p, hits) in
                            HStack {
                                PrefPageHeading(text: p.label)
                                Text("· \(hits.map(\.label).joined(separator: ", "))").font(.caption).foregroundStyle(Theme.textFaint)
                                Spacer()
                                Button("Open") { selected = p.id; query = "" }.buttonStyle(.plain).foregroundStyle(Theme.gold).font(.caption)
                            }
                            p.body()
                        }
                    }
                }
                .padding(.bottom, 24)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

extension Prefs {
    /// The in-app text-size percent as SwiftUI's type scale: 100% is `.large`, the platform default.
    var dynamicType: DynamicTypeSize {
        switch uiScale {
        case ..<85: return .xSmall
        case ..<95: return .small
        case ..<105: return .large
        case ..<115: return .xLarge
        case ..<125: return .xxLarge
        case ..<140: return .xxxLarge
        default: return .accessibility1
        }
    }
}
