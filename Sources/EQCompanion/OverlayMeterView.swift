import SwiftUI
import EQCompanionCore

/// The overlay's content: a compact header and the meter's bars, polled from `combat.snapshot` at
/// 1 Hz so the scope (fight / overall zone) is the engine's own selection.
///
/// ITS SIZE AND ITS TRANSPARENCY ARE PREFERENCES (Appearance → Overlays), read here on every draw,
/// so a press in that card moves this window while you are watching it.
struct OverlayMeterView: View {
    @Environment(AppModel.self) private var model
    @State private var poller = CombatPoller()

    private var scale: Double { OverlayLook.textScale(OverlayID.meter) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4 * scale) {
            header
            if let banner = activeBanner {
                Text(banner)
                    .font(.system(size: 12 * scale, weight: .bold))
                    .foregroundStyle(.yellow)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
            }
            MeterBars(segment: segment, compact: true, scale: scale, roster: poller.snapshot["roster"])
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
        }
        .frame(width: 340 * scale)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(Color.black.opacity(OverlayLook.backgroundAlpha(OverlayID.meter))))
        .task(id: "\(model.overlayScope)|\(model.overlayVisible)") {
            guard model.overlayVisible else { return }
            poller.selectedId = model.overlayScope == "overall" ? "zone" : nil
            poller.maxSegments = 5
            await poller.run(model)
        }
    }

    private var segment: JSONValue { poller.snapshot["selected"] }

    private var header: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11 * scale, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
            Spacer()
            Picker("", selection: Bindable(model).overlayScope) {
                Text("Fight").tag("fight")
                Text("Overall").tag("overall")
            }
            .pickerStyle(.segmented)
            .controlSize(.mini)
            .frame(width: 110)
            .labelsHidden()
            Button { model.overlayLocked.toggle() } label: {
                Image(systemName: model.overlayLocked ? "lock.fill" : "lock.open")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.8))
            .help("Lock: clicks pass through to the game. To unlock, bring EQ Companion forward and click this again (or press ⇧⌘L).")
            Button { model.overlayVisible = false } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.8))
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
    }

    private var title: String {
        let s = segment
        if s.isNull { return poller.snapshot["hydrating"].bool == true ? "Catching up…" : "No fight yet" }
        let name = s["name"].string ?? ""
        let dps = Format.rate(s["outDps"].double ?? 0)
        let dur = Format.seconds(s["durationSec"].double ?? 0)
        let live = s["active"].bool == true ? "● " : ""
        return "\(live)\(name) — \(dps) · \(dur)"
    }

    private var activeBanner: String? {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        for f in model.fires.prefix(5) {
            guard let d = model.alerts.def(named: f.rule), d.showOnScreen else { continue }
            let fireWall = f.at
            if now - fireWall < 8000 || now - fireWall > 10 * 365 * 86400 * 1000 {
                return d.bannerText.isEmpty ? f.rule : d.bannerText
            }
        }
        return nil
    }
}

/// The ranked bars both meters draw: name, tag, badges, total and dps, filled by `pct`.
struct MeterBars: View {
    var segment: JSONValue
    var compact = false
    var incoming = false
    /// The overlay's text size, 1 in the app's own windows. Every size below is multiplied by it.
    var scale: Double = 1
    /// The fight's roster, for the Group scope; `.null` degrades to Everyone.
    var roster: JSONValue = .null

    /// The rows every damage meter ranks: the engine's, with the pet-nesting and scope preferences
    /// applied (Preferences → Combat). The Incoming list is always "what is hitting You" — unscoped.
    private var entities: [MeterSource] {
        let raw = segment[incoming ? "incoming" : "entities"].array ?? []
        if incoming { return raw.map(meterSource) }
        return scopeSources(meterSources(raw, combine: true), scope: MeterScope.preferred, roster: roster)
    }

    var body: some View {
        VStack(spacing: compact ? 2 : 4) {
            if entities.isEmpty {
                Text(segment.isNull ? "" : "No damage yet")
                    .font(.system(size: (compact ? 11 : 12) * scale))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(Array(entities.enumerated()), id: \.offset) { i, e in
                bar(rank: i + 1, e)
            }
        }
    }

    private func bar(rank: Int, _ e: MeterSource) -> some View {
        let pct = max(0, min(100, e.pct))
        let kind = e.kind
        return ZStack(alignment: .leading) {
            GeometryReader { g in
                RoundedRectangle(cornerRadius: 3)
                    .fill(kindColor(kind).opacity(0.55))
                    .frame(width: g.size.width * pct / 100)
            }
            HStack(spacing: 6) {
                Text("\(rank)").foregroundStyle(.secondary).frame(width: 18 * scale, alignment: .trailing)
                Text(e.name)
                    .fontWeight(kind == "you" ? .bold : .regular)
                    .lineLimit(1)
                if let tag = kindTag(kind) {
                    Text(tag).font(.system(size: (compact ? 9 : 10) * scale)).foregroundStyle(.secondary)
                }
                if e.ambiguousHits > 0 {
                    Text("~\(e.ambiguousHits)").font(.system(size: 9 * scale)).foregroundStyle(.orange)
                }
                Spacer(minLength: 4)
                if e.critPct >= 1 {
                    Text("\(Int(e.critPct.rounded()))% crit").font(.system(size: 9 * scale)).foregroundStyle(.secondary)
                }
                if e.misses > 0 {
                    Text("\(Int(e.hitPct.rounded()))% hit").font(.system(size: 9 * scale)).foregroundStyle(.secondary)
                }
                Text(Format.compact(e.total)).monospacedDigit()
                Text(Format.rate(e.dps)).monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.system(size: (compact ? 11 : 12) * scale))
            .padding(.horizontal, 4)
        }
        .frame(height: (compact ? 18 : 22) * scale)
        .foregroundStyle(compact ? Color.white : Color.primary)
    }

    static func color(for kind: String) -> Color {
        switch kind {
        case "you": return .green
        case "pet": return .teal
        case "member": return .blue
        case "allyPet": return .cyan
        case "enemy": return .red
        default: return .gray
        }
    }

    private func kindColor(_ k: String) -> Color { Self.color(for: k) }

    private func kindTag(_ k: String) -> String? {
        switch k {
        case "pet": return "pet"
        case "member": return "group"
        case "allyPet": return "ally pet"
        case "other": return "other"
        default: return nil
        }
    }
}
