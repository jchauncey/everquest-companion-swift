// THE item surface — one card for an item everywhere an item can be opened (the map's mob card,
// the Gear table's peek, the Loot drill-down): the wiki upgrade slider with every stat scaled the
// way the item window scales them, then the engine's knowledge record (stats block, quest uses,
// drops) underneath. Two surfaces drawing the same item differently is the bug this file forbids.
import SwiftUI

struct ItemCardView: View {
    var name: String
    /// Drawn as a "‹ Back" leading button when set.
    var onBack: (() -> Void)? = nil
    /// Drawn as a "CLOSE" trailing button when set.
    var onClose: (() -> Void)? = nil

    @State private var index = GearIndex.shared
    @State private var tier = 0
    @State private var fraction = 0
    /// The effect the player clicked in the stats block, shown in place with a way back.
    @State private var spell: String?

    private var state: ItemUpgradeState { ItemUpgradeState(full: tier, fraction: fraction).normalized }

    private var row: GearRow? {
        func exact(_ n: String) -> GearRow? {
            index.rows.first { $0.name.caseInsensitiveCompare(n) == .orderedSame }
        }
        // The article seam again: the slider must open on the same item the record below it shows.
        return exact(name)
            ?? NameArticles.variants(of: name).lazy.compactMap(exact).first
            ?? index.rows.first { $0.name.lowercased().hasPrefix(name.lowercased()) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let spell {
                // The effect's own card, reached from the stats block. Back returns to the item -
                // the same one-level swap the mob card uses for a drop.
                HStack(spacing: 8) {
                    Button { self.spell = nil } label: {
                        HStack(spacing: 3) { Image(systemName: "chevron.left"); Text(name).lineLimit(1) }
                            .font(.caption)
                    }
                    .buttonStyle(.plain).foregroundStyle(Theme.gold)
                    Spacer(minLength: 4)
                    if let onClose { Button("Close") { onClose() }.buttonStyle(OutlineButtonStyle()) }
                }
                KnowledgeCard(domain: "spell", name: spell)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                itemBody
            }
        }
    }

    @ViewBuilder private var itemBody: some View {
        HStack(spacing: 8) {
            if let onBack {
                Button { onBack() } label: {
                    HStack(spacing: 3) { Image(systemName: "chevron.left"); Text("Back") }.font(.caption)
                }
                .buttonStyle(.plain).foregroundStyle(Theme.gold)
            }
            // The artwork, at the size the game's own item window shows it. Looked up by NAME
            // rather than from the gear row, so a card opened for something the gear index does not
            // carry - a quest piece, a tradeskill component - still shows its picture.
            if let img = GameData.shared.item(named: name)?.iconId.flatMap({ GameData.shared.itemIcon($0) }) {
                Image(nsImage: img).resizable().frame(width: 40, height: 40)
                    .accessibilityLabel("\(name) icon")
            }
            Text(name).font(.headline).foregroundStyle(Theme.text).lineLimit(1)
            Spacer(minLength: 4)
            if let onClose { Button("Close") { onClose() }.buttonStyle(OutlineButtonStyle()) }
        }
        if let r = row { sliderSection(r) }
        if let ex = GameData.shared.exaltation(forItem: name) { exaltationSection(ex) }
        KnowledgeCard(domain: "item", name: name)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .environment(\.openSpell) { spell = $0 }
            .onAppear { index.start() }
    }

    @ViewBuilder private func sliderSection(_ r: GearRow) -> some View {
        if !r.slots.isEmpty {
            Text(r.slots.joined(separator: " ")).font(.caption).foregroundStyle(Theme.textDim)
        }
        HStack(spacing: 8) {
            Text("Upgrade").font(.caption).foregroundStyle(Theme.textDim)
            Slider(value: Binding(
                get: { Double(tier) },
                set: { v in
                    tier = Int(v.rounded())
                    fraction = min(fraction, max(0, (1 << max(0, min(9, tier))) - 1))
                }), in: 0...Double(GearUpgrade.maxTier), step: 1)
            Text(tier == 0 ? "base" : "+\(tier)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(tier == 0 ? Theme.textDim : Theme.gold)
                .frame(width: 38, alignment: .trailing)
        }
        if tier > 0 && tier < GearUpgrade.maxTier {
            HStack(spacing: 8) {
                Text("Partial").font(.caption).foregroundStyle(Theme.textDim)
                Slider(value: Binding(get: { Double(fraction) }, set: { fraction = Int($0.rounded()) }),
                       in: 0...Double((1 << tier) - 1), step: 1)
                Text("\(fraction)/\(1 << tier)").font(.caption.monospacedDigit()).foregroundStyle(Theme.textDim)
                    .frame(width: 44, alignment: .trailing)
            }
        }
        Text(state.percentLabel).font(.caption)
            .foregroundStyle(tier == 0 && fraction == 0 ? Theme.textFaint : Theme.gold)
        chips(r)
    }

    /// The item's Focus Exaltation, as the item window shows it: the effect it can donate, the
    /// level its bonus decays past, and the family tags. Clicking the effect opens its own card.
    @ViewBuilder private func exaltationSection(_ ex: GameData.Exaltation) -> some View {
        Card("FOCUS EXALTATION") {
            VStack(alignment: .leading, spacing: 6) {
                Button { spell = ex.effect } label: {
                    Text(ex.effect).font(.callout.weight(.semibold)).foregroundStyle(Theme.gold)
                        .underline().lineLimit(1)
                }
                .buttonStyle(.plain)
                FlowLayout(spacing: 6) {
                    ForEach(ex.category, id: \.self) { Chip(text: $0) }
                    if let d = ex.decaysAfter {
                        Chip(text: "decays after \(d)", color: Theme.orange)
                    } else {
                        Chip(text: "no decay", color: Theme.textDim)
                    }
                }
                if let desc = ex.description, !desc.isEmpty {
                    Text(desc).font(.caption).foregroundStyle(Theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Every number the item window would show at this state: the weapon trio and its derived
    /// ratio first, weight, then every other nonzero stat. Chips never wrap their own text.
    private func chips(_ r: GearRow) -> some View {
        let scaled = r.scaled(state)
        var lead: [(String, String)] = []
        if let dmg = scaled["DMG"], dmg != 0 { lead.append(("DMG", "+\(dmg)")) }
        if let dly = scaled["DELAY"], dly != 0 { lead.append(("DELAY", "\(dly)")) }
        if let ratio = damageRatio(scaled) { lead.append(("RATIO", String(format: "%.3f", ratio))) }
        if let b = scaled["DMG_BONUS"], b != 0 { lead.append(("DMG BONUS", "+\(b)")) }
        if let w = r.weight { lead.append(("WT", String(format: "%.1f", GearUpgrade.scaleWeight(w, state)))) }
        let leadKeys: Set<String> = ["DMG", "DELAY", "DMG_BONUS"]
        let rest = scaled
            .filter { $0.value != 0 && !leadKeys.contains($0.key) }
            .sorted { $0.key < $1.key }
            .map { ($0.key.replacingOccurrences(of: "_", with: " "), $0.value > 0 ? "+\($0.value)" : "\($0.value)") }
        // No scroll box: the flow's own wrapped height is the right height, and an item has at
        // most a couple of rows of chips — a fixed-height container was mostly empty space.
        return FlowLayout(spacing: 6) {
            ForEach(Array((lead + rest).enumerated()), id: \.offset) { _, kv in
                HStack(spacing: 4) {
                    Text(kv.0).font(.caption2).foregroundStyle(Theme.textDim)
                    Text(kv.1).font(.caption.monospacedDigit()).foregroundStyle(Theme.text)
                }
                .fixedSize()
                .padding(.horizontal, 7).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 4).fill(Theme.paperRaised))
            }
        }
    }
}
