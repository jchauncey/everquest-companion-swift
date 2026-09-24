// The Combat tab's chrome: the card shell, the ranked bar every meter row is drawn as, and the
// four dashboard cells (source meter, procs, damage by mob, combat log) plus the fight picker.
//
// The rows are the Electron app's, word for word: `EntityRow.tsx` decides that a `% hit` badge
// appears only where swings were avoided and a `% crit` only at 1% or more, `MeterRows.tsx` and
// `combatShared.Bar` decide the bar's shape, `CombatDashboard.tsx` the mob rows, `ProcsPanel.tsx`
// the proc rows and `ProcessingLog.tsx` the log lines.

import SwiftUI
import AppKit
import EQCompanionCore

// MARK: - Shell

/// The dashboard's card: `Theme`'s surface with a small-caps title and a free-form trailing slot.
struct CombatCard<Content: View, Trailing: View>: View {
    var title: String
    /// A panel LABEL is small caps; a panel that is titled with a mob's NAME is not — uppercasing
    /// "a wan ghoul knight (214) +3" turns a name into a shout.
    var caps: Bool
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    init(title: String,
         caps: Bool = true,
         @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() },
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.caps = caps
        self.trailing = trailing
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(caps ? title.uppercased() : title)
                    .font(caps ? .caption.weight(.bold) : .callout.weight(.medium))
                    .tracking(caps ? 0.8 : 0)
                    .foregroundStyle(caps ? Theme.textDim : Theme.text).lineLimit(1)
                Spacer(minLength: 6)
                trailing()
            }
            content()
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.paper))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
    }
}

/// A panel's honest empty state — never an error, never furniture.
struct CombatNote: View {
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.caption).foregroundStyle(Theme.textFaint)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// One ranked bar: the fill is the row's share of the list maximum, the name and its badges ride
/// on top, and the right end carries the row's numbers.
struct MeterBarRow: View {
    var rank: Int?
    var color: Color
    var pct: Double
    var name: String
    var tag: String? = nil
    var badges: [(text: String, color: Color)] = []
    var right: String
    var selected: Bool = false
    var bold: Bool = false
    var indent: CGFloat = 0
    var action: (() -> Void)? = nil

    var body: some View {
        let bar = ZStack(alignment: .leading) {
            GeometryReader { g in
                RoundedRectangle(cornerRadius: 3)
                    .fill(color.opacity(0.45))
                    .frame(width: max(0, g.size.width * min(100, max(0, pct)) / 100))
            }
            HStack(spacing: 5) {
                if let r = rank {
                    Text("\(r)").foregroundStyle(Theme.textFaint).frame(width: 16, alignment: .trailing)
                }
                Text(name).fontWeight(bold ? .semibold : .regular).lineLimit(1).foregroundStyle(Theme.text)
                if let t = tag {
                    Text(t).font(.system(size: 9)).foregroundStyle(Theme.textDim)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Capsule().fill(color.opacity(0.2)))
                }
                ForEach(Array(badges.enumerated()), id: \.offset) { _, b in
                    Text(b.text).font(.system(size: 9)).foregroundStyle(b.color).lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(right).font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.text).lineLimit(1)
            }
            .font(.system(size: 11))
            .padding(.horizontal, 5)
        }
        .frame(height: 20)
        .background(RoundedRectangle(cornerRadius: 3).fill(selected ? Theme.gold.opacity(0.12) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(selected ? Theme.gold.opacity(0.5) : Color.clear))
        .padding(.leading, indent)

        if let action {
            Button(action: action) { bar }.buttonStyle(.plain)
        } else {
            bar
        }
    }
}

// MARK: - The meter card

enum MeterMode: String, CaseIterable, Hashable {
    case out, incoming, heal
    var label: String {
        switch self {
        case .out: return "Outgoing"
        case .incoming: return "Incoming"
        case .heal: return "Healing"
        }
    }
}

/// The drill token — ONE subject at a time, so the panel always has exactly one breadcrumb.
enum CombatDrill: Hashable {
    /// a source's flat ability list (the meter drill). `name` is the identity that crosses fights.
    case entity(id: String, name: String)
    /// everything you and your allies landed on ONE mob (driven by the Damage-by-mob card).
    case target(String)
}

/// The dashboard's ANCHOR PANEL — the source meter at level 1 and, when drilled, one subject.
struct CombatMeterCard: View {
    var seg: JSONValue
    var timeline: JSONValue
    var mode: MeterMode
    var meterScope: MeterScope
    var roster: JSONValue
    var ringless: String
    @Binding var drill: CombatDrill?
    @State private var expanded: Set<String> = []

    private var entities: [JSONValue] { seg["entities"].array ?? [] }

    var body: some View {
        CombatCard(title: seg["name"].string ?? "", caps: false, trailing: { header }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    crumb
                    modeBody(mode)
                    if mode == .out { incomingHeals }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: header

    /// WHAT THE PANEL BELOW IS SHOWING, never the raw segment: the scoped ranked list at level 1,
    /// or the drilled subject with its nested pets. The number carries no label, so it has to be
    /// the one the visible rows add up to.
    private var shownTotals: (total: Double, dps: Double) {
        switch mode {
        case .heal:
            return (seg["healing"]["total"].double ?? 0, seg["healing"]["hps"].double ?? 0)
        case .incoming:
            return (seg["inTotal"].double ?? 0, seg["inDps"].double ?? 0)
        case .out:
            let all = meterSources(entities, combine: true)
            let scoped = scopeSources(all, scope: meterScope, roster: roster)
            let base = scopeTotals(all, scoped, total: seg["outTotal"].double ?? 0, dps: seg["outDps"].double ?? 0)
            if case .entity(let id, let name)? = drill, let subject = resolveSubject(id: id, name: name) {
                let pets = subject["kind"].string == "you" ? entities.filter { $0["kind"].string == "pet" } : []
                let shown = (subject["total"].double ?? 0) + pets.reduce(0) { $0 + ($1["total"].double ?? 0) }
                return panelTotals(shown: shown, total: base.total, dps: base.dps)
            }
            if case .target? = drill, !timeline.isNull, let t = targetName {
                return panelTotals(shown: skillsForTarget(timeline, target: t).total, total: base.total, dps: base.dps)
            }
            return base
        }
    }

    private var header: some View {
        let t = shownTotals
        let heal = mode == .heal
        let color = heal ? CombatColor.heal : (mode == .out ? Theme.gold : CombatColor.enemy)
        return HStack(spacing: 4) {
            if seg["active"].bool == true {
                Circle().fill(Theme.green).frame(width: 6, height: 6)
            }
            // The rate carries its own UNIT WORD, so a healing headline can never read as dps.
            Text(heal ? CFmt.healRate(t.dps) : CFmt.rate(t.dps)).font(.caption).foregroundStyle(color)
            if let act = activeNote { Text(act).font(.system(size: 10)).foregroundStyle(Theme.textDim) }
            Text("· \(CFmt.num(t.total)) · \(CFmt.dur(seg["durationSec"].double ?? 0))")
                .font(.system(size: 10)).foregroundStyle(Theme.textDim)
            if mode == .out, (seg["enemyHealTotal"].double ?? 0) > 0 {
                Text("· +\(CFmt.num(seg["enemyHealTotal"].double ?? 0)) enemy heal")
                    .font(.system(size: 10)).foregroundStyle(Theme.green)
            }
            if let slow = slowNote {
                Text("· \(slow.0)").font(.system(size: 10)).foregroundStyle(slow.1)
            }
            // No copy in the Healing dimension: "copy this view" means THIS view, and the
            // serializer below writes damage tables only.
            if !heal {
                Button { copyView() } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(Theme.textFaint)
                    .help("Copy this breakdown as text")
            }
        }
        .monospacedDigit()
    }

    /// Active-time DPS: only worth printing when the fight actually had idle gaps.
    private var activeNote: String? {
        guard mode == .out else { return nil }
        let active = seg["activeSec"].double ?? 0
        let wall = seg["durationSec"].double ?? 0
        guard active > 0, active < wall else { return nil }
        let scaled = panelTotals(shown: shownTotals.total, total: seg["outTotal"].double ?? 0,
                                 dps: seg["activeDps"].double ?? 0)
        return "(act \(CFmt.rate(scaled.dps)))"
    }

    /// Shown ONLY when a slow-capable coat was actually on at engage — that is what makes
    /// "not landed" a fact about the poison rather than about the loadout.
    private var slowNote: (String, Color)? {
        guard mode == .out, seg["procs"]["slowExpected"].bool == true else { return nil }
        if let ms = seg["procs"]["slowLandMs"].double {
            return ("slow @ \(String(format: "%.1fs", ms / 1000))", Color(hex: 0x57e0a0))
        }
        return ("slow: not landed", Theme.textFaint)
    }

    // MARK: crumb

    private var targetName: String? {
        if case .target(let t) = drill { return t }
        return nil
    }

    private func resolveSubject(id: String, name: String) -> JSONValue? {
        let pool = mode == .incoming ? (seg["incoming"].array ?? []) : entities
        // The id is tried first and always wins; the NAME is the fallback, because half these ids
        // are world instances (one spawn, one summon) and a re-summon renames the same row.
        if let byId = pool.first(where: { $0["id"].string == id }) { return byId }
        if name.isEmpty { return nil }
        return pool.first { $0["name"].string == name }
    }

    @ViewBuilder
    private var crumb: some View {
        if drill != nil {
            HStack(spacing: 6) {
                Button { drill = nil } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left")
                        Text("All")
                    }
                }
                .buttonStyle(.plain).font(.caption).foregroundStyle(Theme.gold)
                Text(crumbLabel).font(.caption).foregroundStyle(Theme.textDim).lineLimit(1)
            }
            .padding(.bottom, 2)
        }
    }

    private var crumbLabel: String {
        switch drill {
        case .entity(let id, let name):
            return resolveSubject(id: id, name: name)?["name"].string ?? name
        case .target(let t): return "damage to \(t)"
        case nil: return ""
        }
    }

    // MARK: bodies

    @ViewBuilder
    private func modeBody(_ mode: MeterMode) -> some View {
        switch mode {
        case .out: outgoingBody
        case .incoming: incomingBody
        case .heal: healingBody
        }
    }

    @ViewBuilder
    private var outgoingBody: some View {
        // A MOB drill replaces the source list entirely — this surface's own level.
        if let t = targetName {
            if timeline.isNull {
                CombatNote(ringless)
            } else {
                targetBody(t)
            }
        } else if case .entity(let id, let name)? = drill, let subject = resolveSubject(id: id, name: name) {
            let pets = subject["kind"].string == "you" ? entities.filter { $0["kind"].string == "pet" } : []
            ForEach(nestedRows(subject, pets: pets)) { row in
                switch row {
                case .skill(let s): skillBar(s)
                case .pet(let p):
                    MeterBarRow(rank: nil, color: CombatColor.pet, pct: p.pct, name: p.name, tag: "pet",
                                right: "\(CFmt.num(p.total)) · \(CFmt.rate(p.dps))") {
                        drill = .entity(id: p.id, name: p.name)
                    }
                }
            }
        } else {
            let rows = scopeSources(meterSources(entities, combine: true), scope: meterScope, roster: roster)
            if rows.isEmpty {
                CombatNote("No damage yet.")
            } else {
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, e in
                    sourceBar(e, rank: i + 1) { drill = .entity(id: e.id, name: e.name) }
                }
            }
        }
    }

    @ViewBuilder
    private var incomingBody: some View {
        let rows = (seg["incoming"].array ?? []).map(meterSource)
        if rows.isEmpty {
            CombatNote("Nothing hit you in this selection.")
        } else {
            // The incoming direction has no drill: the enemy's flat skill list expands INLINE.
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, e in
                sourceBar(e, rank: i + 1) {
                    if expanded.contains(e.id) { expanded.remove(e.id) } else { expanded.insert(e.id) }
                }
                if expanded.contains(e.id) {
                    ForEach(flattenSkills(e.raw)) { s in skillBar(s, indent: 18) }
                }
            }
            defenseLine
        }
    }

    /// The defense rates — on the INCOMING side these six numbers are YOURS.
    @ViewBuilder
    private var defenseLine: some View {
        let d = seg["defense"]
        if (d["swings"].int ?? 0) > 0 {
            let rates = (d["rates"].object ?? [:]).filter { ($0.value.double ?? 0) > 0 }
                .sorted { $0.key < $1.key }
                .map { "\($0.key) \(CFmt.pct1($0.value.double ?? 0))" }
                .joined(separator: " · ")
            Text("\(d["swings"].int ?? 0) swings at you · \(CFmt.pct0(d["avoidedPct"].double ?? 0)) avoided\(rates.isEmpty ? "" : " · \(rates)")")
                .font(.system(size: 10)).foregroundStyle(Theme.textDim).padding(.top, 4)
        }
    }

    @ViewBuilder
    private var healingBody: some View {
        let h = seg["healing"]
        let healers = h["healers"].array ?? []
        if healers.isEmpty {
            CombatNote("No healing in this selection.")
        } else if case .entity(let id, _)? = drill, let healer = healers.first(where: { $0["id"].string == id }) {
            ForEach(Array((healer["spells"].array ?? []).enumerated()), id: \.offset) { _, s in
                MeterBarRow(rank: nil, color: CombatColor.heal, pct: s["pct"].double ?? 0,
                            name: s["name"].string ?? "",
                            tag: s["classification"].string == "restored" ? nil : s["classification"].string,
                            badges: [(spellStat(s), Theme.textDim)],
                            right: laneAmount(s))
            }
        } else {
            ForEach(Array(healers.enumerated()), id: \.offset) { i, healer in
                MeterBarRow(rank: i + 1,
                            color: healer["kind"].string == "pet" ? CombatColor.pet : CombatColor.heal,
                            pct: healer["pct"].double ?? 0,
                            name: healer["name"].string ?? "",
                            badges: [(healerStat(healer), Theme.textDim)],
                            right: healerAmount(healer)) {
                    drill = .entity(id: healer["id"].string ?? "", name: healer["name"].string ?? "")
                }
            }
            if (h["absorbedTotal"].double ?? 0) > 0 || (h["overheal"].double ?? 0) > 0 {
                Text("\(CFmt.num(h["restoredTotal"].double ?? 0)) restored · \(CFmt.num(h["overheal"].double ?? 0)) overheal · \(CFmt.num(h["absorbedTotal"].double ?? 0)) absorbed")
                    .font(.system(size: 10)).foregroundStyle(Theme.textDim).padding(.top, 4)
            }
        }
    }

    /// Everything you and your allies landed on ONE mob — the same flat, category-coloured rows
    /// the entity drill uses. You + pet are combined; the header says so.
    @ViewBuilder
    private func targetBody(_ target: String) -> some View {
        let d = skillsForTarget(timeline, target: target)
        let a = d.estimated ? "~" : ""
        let share = (seg["outTotal"].double ?? 0) > 0 ? d.total / (seg["outTotal"].double ?? 1) * 100 : 0
        VStack(alignment: .leading, spacing: 3) {
            Text("\(a)\(CFmt.num(d.total)) dealt to \(target)")
                .font(.caption.weight(.semibold)).foregroundStyle(CombatColor.enemy)
            Text("\(CFmt.pct0(share)) of this segment's outgoing · \(a)\(d.hits) hits"
                 + (d.crits > 0 ? " · \(a)\(d.crits) crit" : "")
                 + (d.misses > 0 ? " · \(a)\(d.misses) avoided" : "")
                 + (d.resists > 0 ? " · \(a)\(d.resists) resisted" : "")
                 + " · you + pet combined")
                .font(.system(size: 10)).foregroundStyle(Theme.textDim)
            if d.rows.isEmpty {
                CombatNote("Nothing landed on this mob in the selected segment.")
            } else {
                ForEach(d.rows) { s in skillBar(s, approx: d.estimated) }
            }
        }
    }

    @ViewBuilder
    private var incomingHeals: some View {
        if (seg["incomingHealTotal"].double ?? 0) > 0 {
            VStack(alignment: .leading, spacing: 1) {
                Divider().overlay(Theme.border).padding(.vertical, 4)
                Text("Heals received: \(CFmt.num(seg["incomingHealTotal"].double ?? 0))")
                    .font(.system(size: 10).weight(.semibold)).foregroundStyle(Theme.green)
                ForEach(Array((seg["incomingHealers"].array ?? []).prefix(4).enumerated()), id: \.offset) { _, h in
                    Text("\(h["name"].string ?? "") · \(CFmt.num(h["total"].double ?? 0)) (\(h["count"].int ?? 0))")
                        .font(.system(size: 10)).foregroundStyle(Theme.textDim).padding(.leading, 8)
                }
            }
        }
    }

    // MARK: rows

    /// The badges a row carries when its numbers earn them (EntityRow.StatBadges): the hit rate
    /// only where swings were avoided — a 100% row would be furniture — and the resist rate.
    private func sourceBar(_ e: MeterSource, rank: Int, action: @escaping () -> Void) -> some View {
        var badges: [(String, Color)] = []
        if e.ambiguousHits > 0 { badges.append(("~\(e.ambiguousHits)", CombatColor.enemy)) }
        if e.misses > 0 { badges.append(("\(CFmt.pct0(e.hitPct)) hit", Theme.textDim)) }
        if e.resists > 0 { badges.append(("\(CFmt.pct0(e.resistPct)) resist", CombatColor.resist)) }
        let crit = e.critPct >= 1 ? " · \(CFmt.pct0(e.critPct)) crit" : ""
        return MeterBarRow(rank: rank,
                           color: CombatColor.kind(e.kind),
                           pct: e.pct,
                           name: e.name,
                           tag: kindTag(e.kind),
                           badges: badges,
                           right: "\(CFmt.num(e.total)) · \(CFmt.rate(e.dps))\(crit)",
                           bold: e.kind == "you",
                           action: action)
    }

    /// `you` and `enemy` get nothing: the direction filter already said which of the two you are
    /// looking at. The ones that DO need a word are the ones a bare name cannot tell apart.
    private func kindTag(_ k: String) -> String? {
        switch k {
        case "pet": return "pet"
        case "member": return "group"
        case "allyPet": return "ally"
        case "other": return "other"
        default: return nil
        }
    }

    private func skillBar(_ s: SkillRow, indent: CGFloat = 0, approx: Bool = false) -> some View {
        let a = approx ? "~" : ""
        var stats: [String] = []
        if s.hits > 0 { stats.append("\(a)\(s.hits)x") }
        if s.crits > 0 { stats.append("\(a)\(s.crits) crit") }
        if s.misses > 0 { stats.append("\(a)\(s.misses) miss") }
        if s.resists > 0 { stats.append("\(a)\(s.resists) resist") }
        if s.maxHit > 0 { stats.append(s.minHit == s.maxHit ? "\(s.maxHit)" : "\(s.minHit)-\(s.maxHit)") }
        return MeterBarRow(rank: nil,
                           color: CombatColor.category(s.category),
                           pct: s.pct,
                           name: s.children == nil ? s.name : "\(s.name) · \(s.children!.count) skills",
                           tag: nil,
                           badges: [(stats.joined(separator: " · "), Theme.textDim)],
                           right: "\(a)\(CFmt.num(s.total))",
                           indent: indent)
    }

    // MARK: copy

    private func copyView() {
        var lines: [String] = []
        let t = shownTotals
        lines.append("\(seg["name"].string ?? "") · \(CFmt.rate(t.dps)) · \(CFmt.num(t.total)) · \(CFmt.dur(seg["durationSec"].double ?? 0))")
        if let target = targetName, !timeline.isNull {
            for (i, s) in skillsForTarget(timeline, target: target).rows.enumerated() {
                lines.append("\(i + 1). \(s.name)  \(CFmt.num(s.total))  \(CFmt.pct0(s.pct))")
            }
        } else if case .entity(let id, let name)? = drill, let subject = resolveSubject(id: id, name: name) {
            for (i, s) in flattenSkills(subject).enumerated() {
                lines.append("\(i + 1). \(s.name)  \(CFmt.num(s.total))  \(CFmt.pct0(s.pct))")
            }
        } else {
            let rows = mode == .incoming
                ? (seg["incoming"].array ?? []).map(meterSource)
                : scopeSources(meterSources(entities, combine: true), scope: meterScope, roster: roster)
            for (i, e) in rows.enumerated() {
                lines.append("\(i + 1). \(e.name)  \(CFmt.num(e.total))  \(CFmt.rate(e.dps))  \(CFmt.pct0(e.pct))")
            }
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(lines.joined(separator: "\n"), forType: .string)
    }
}

// MARK: - Procs

/// A glanceable list of what procced in the selected segment: name · PPM · count, ranked by
/// count. Every number is folded on ingest by the engine, never derived from the event ring — so
/// this card carries no `~ N of M events` chip. The only `~` in it marks a lane whose NAME the
/// game left ambiguous.
struct CombatProcsCard: View {
    var seg: JSONValue

    var body: some View {
        let procs = seg["procs"]
        let rows = procListRows(procs)
        // Only a coat's poison damage is a proc ledger; a caster's poison-typed spells are not.
        let poison = procsShowPoison(procs) ? (procs["poisonDamage"].array ?? []) : []
        return CombatCard(title: "Procs", trailing: {
            if !rows.isEmpty {
                Text(procSummaryHeader(procs)).font(.caption).foregroundStyle(Theme.textDim).monospacedDigit()
            }
        }) {
            if rows.isEmpty && poison.isEmpty {
                CombatNote("No procs in this selection.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(rows) { r in
                            HStack(spacing: 6) {
                                RoundedRectangle(cornerRadius: 2).fill(CombatColor.origin(r.origin))
                                    .frame(width: 6, height: 6)
                                Text(r.ambiguous ? "~ \(r.name)" : r.name).lineLimit(1)
                                Spacer(minLength: 4)
                                Text(r.ppm).foregroundStyle(Theme.textDim)
                                    .frame(width: 62, alignment: .trailing)
                                Text("×\(r.count)").frame(width: 44, alignment: .trailing)
                            }
                            .font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.text)
                        }
                        // The poison DAMAGE lanes are a second ledger: what the coats actually
                        // dealt, which the proc counts above deliberately do not carry.
                        if !poison.isEmpty {
                            Divider().overlay(Theme.border).padding(.vertical, 4)
                            Text("POISON DAMAGE · \(CFmt.num(procs["poisonDamageTotal"].double ?? 0))")
                                .font(.system(size: 9).weight(.bold)).tracking(0.6)
                                .foregroundStyle(Theme.textFaint)
                            ForEach(Array(poison.enumerated()), id: \.offset) { _, p in
                                HStack(spacing: 6) {
                                    RoundedRectangle(cornerRadius: 2).fill(CombatColor.origin("poison"))
                                        .frame(width: 6, height: 6)
                                    Text(p["name"].string ?? "").lineLimit(1)
                                    Spacer(minLength: 4)
                                    Text(CFmt.num(p["total"].double ?? 0)).foregroundStyle(Theme.textDim)
                                        .frame(width: 62, alignment: .trailing)
                                    Text("×\(p["count"].int ?? 0)").frame(width: 44, alignment: .trailing)
                                }
                                .font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.text)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

// MARK: - Damage by mob

/// Outgoing damage grouped by defender. Clicking a row drives the MAIN panel down to the flat
/// skill breakdown of everything you and your pet landed on that mob.
struct CombatMobCard: View {
    /// how many rows the card mounts; the rest are a count, not a scroll marathon.
    private static let cap = 10
    var seg: JSONValue
    var timeline: JSONValue
    var ringless: String
    /// nil in the Healing dimension: there is no level-2 mob body for a click to open, so the
    /// rows are read-only rather than an affordance that leads nowhere.
    var setDrill: ((CombatDrill?) -> Void)?
    var drill: CombatDrill?

    var body: some View {
        let mobs: MobBreakdown? = timeline.isNull ? nil : groupByTarget(timeline)
        let rows = Array((mobs?.rows ?? []).prefix(Self.cap))
        let a = (mobs?.estimated ?? false) ? "~" : ""
        let selected: String? = { if case .target(let t)? = drill { return t }; return nil }()
        return CombatCard(title: "Damage by mob", trailing: {
            if let m = mobs, !m.rows.isEmpty {
                Text("\(m.rows.count) mob\(m.rows.count == 1 ? "" : "s") · \(a)\(CFmt.num(m.total))")
                    .font(.caption).foregroundStyle(Theme.textDim).monospacedDigit()
            }
        }) {
            if let m = mobs {
                if rows.isEmpty {
                    CombatNote("Nothing landed on anything yet.")
                } else {
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                                MeterBarRow(rank: i + 1,
                                            color: CombatColor.enemy,
                                            pct: r.pct,
                                            name: r.target,
                                            badges: r.resists > 0 ? [("\(a)\(r.resists) resist", CombatColor.resist)] : [],
                                            right: "\(a)\(CFmt.num(r.total)) · \(CFmt.pct0(r.share))",
                                            selected: selected == r.target,
                                            action: setDrill.map { set in
                                                {
                                                    let next: CombatDrill? = selected == r.target ? nil : .target(r.target)
                                                    set(next)
                                                }
                                            })
                            }
                            if m.rows.count > rows.count {
                                Text("+\(m.rows.count - rows.count) more")
                                    .font(.system(size: 10)).foregroundStyle(Theme.textFaint)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
            } else {
                CombatNote(ringless)
            }
        }
    }
}

// MARK: - Combat log

/// The classification-ring readout. Append-only, bounded by the engine's own ring, and it follows
/// the tail only for a reader who is already at the bottom.
struct CombatLogCard: View {
    var lines: [JSONValue]
    @Binding var showUnparsed: Bool
    /// Where the lines came from, when not the engine's live ring (a finished fight's own lines,
    /// read back from the log file). nil for the live log.
    var note: String? = nil

    var body: some View {
        CombatCard(title: "Combat log", trailing: {
            if let note { Text(note).font(.caption).foregroundStyle(Theme.textFaint) }
            Toggle(isOn: $showUnparsed) { Text("show unparsed").font(.caption) }
                .toggleStyle(.switch).controlSize(.mini).foregroundStyle(Theme.textDim)
        }) {
            if lines.isEmpty {
                CombatNote(note == nil ? "Waiting for combat…"
                           : note == "reading the log…" ? "Reading this fight's lines from the log…"
                           : "No fight lines in the log for this fight.")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                                HStack(alignment: .top, spacing: 8) {
                                    Text(CFmt.clock(l["ts"].int64 ?? 0))
                                        .foregroundStyle(Theme.textFaint)
                                    Text(l["cat"].string ?? "")
                                        .foregroundStyle(Theme.textDim)
                                        .frame(width: 62, alignment: .leading)
                                    Text(l["text"].string ?? "")
                                        .foregroundStyle(CombatColor.logRole(l["role"].string ?? ""))
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 0)
                                }
                                .font(.system(size: 11, design: .monospaced))
                                .id(i)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: lines.count) { _, n in
                        if n > 0 { proxy.scrollTo(n - 1, anchor: .bottom) }
                    }
                }
            }
        }
    }
}

// MARK: - Fight picker

/// The encounter selector. Exactly ONE scope's rows are ever listed — the fight scope shows no
/// zone sessions and vice versa — and the list is frozen at open time so a fight finalizing
/// mid-pull cannot move the row under the pointer.
///
/// In the fight scope, opening it reads EVERY fight the engine holds (`loadHistory`: one request,
/// not the live poll) and shows those inside a chosen window — last 24h (the default), 3d, 7d or
/// 30d — grouped by day under pinned headings. Typing filters that list as you type:
/// case-insensitive, anywhere in the mob's name or the zone, with `*` for "anything between".
struct FightPicker: View {
    var opts: ScopeOptions
    var scope: CombatScope
    var selection: String
    var now: Int64
    /// The picked row itself: its id selects it, and its start and length let the view read the
    /// fight's own lines from the log.
    var onSelect: (ScopeOption) -> Void
    /// Every fight, for the history. nil when it could not be read: the live list stands in.
    var loadHistory: () async -> ScopeOptions? = { nil }

    @State private var open = false
    @State private var frozen: ScopeOptions?
    @State private var frozenNow: Int64 = 0
    @State private var query = ""
    /// The row the arrow keys are on; Return picks it. Follows the query and the range.
    @State private var highlighted = 0
    /// The whole fight history, read when the picker opens; kept so a fight picked from it still
    /// labels the closed trigger.
    @State private var history: ScopeOptions?
    @State private var loadingHistory = false
    @AppStorage("eq.combat.fightRange") private var rangeRaw = FightRange.day.rawValue

    private var range: FightRange { FightRange(rawValue: rangeRaw) ?? .day }
    private var at: Int64 { frozenNow == 0 ? now : frozenNow }
    private var filtering: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    /// The option the CLOSED trigger states. The live list wins whenever it holds the selection,
    /// so the head row keeps re-labelling itself live/last and its age keeps ticking.
    private var trigger: ScopeOption? {
        if opts.head?.value == selection { return opts.head }
        if let listed = opts.rest.first(where: { $0.value == selection }) { return listed }
        if let old = history?.rest.first(where: { $0.value == selection }) { return old }
        return opts.head
    }

    var body: some View {
        Button {
            frozen = opts
            frozenNow = now
            open = true
            if scope == .fight { Task { await readHistory() } }
        } label: {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(trigger?.label ?? (scope == .fight ? "No fights yet" : "No zone sessions yet"))
                        .font(.callout).foregroundStyle(Theme.text).lineLimit(1)
                    if let t = trigger {
                        Text(rowTiming(t, now))
                            .font(.system(size: 10)).foregroundStyle(Theme.textFaint).lineLimit(1)
                    }
                }
                Image(systemName: "chevron.down").font(.system(size: 9)).foregroundStyle(Theme.textDim)
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open, arrowEdge: .bottom) { list }
    }

    private func rowTiming(_ o: ScopeOption, _ at: Int64) -> String {
        // The running zone session has no end yet, so it has no duration to disambiguate by.
        o.live && scope == .overall ? "live" : CFmt.timing(startTs: o.startTs, durationSec: o.durationSec, now: at)
    }

    /// The head row (live or last fight), shown while it matches what was typed.
    private var head: ScopeOption? {
        guard let h = (frozen ?? opts).head, fightMatches(h, query) else { return nil }
        return h
    }

    /// The fights inside the window that match, by day. Until the history lands, the frozen live
    /// window stands in, so the list is never empty while it loads.
    private var days: [FightDay] {
        fightDays(fightRows((frozen ?? opts).rest, range: range, query: query, now: at), now: at)
    }

    /// Every row the open list shows, in the order drawn — the arrow keys walk this.
    private var listRows: [ScopeOption] {
        if scope == .overall { return ((frozen ?? opts).head.map { [$0] } ?? []) + (frozen ?? opts).rest }
        return (head.map { [$0] } ?? []) + days.flatMap(\.rows)
    }

    private var list: some View {
        let rows = listRows
        let grouped = scope == .fight ? days : []
        let headRow = scope == .fight ? head : (frozen ?? opts).head
        return VStack(alignment: .leading, spacing: 6) {
            if scope == .fight {
                TextField("Filter by mob or zone - gloom, gloom*maid…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onSubmit { pickHighlighted() }
                    .onChange(of: query) { _, _ in highlighted = 0 }
                SegmentPicker(selection: Binding(get: { range }, set: { rangeRaw = $0.rawValue; highlighted = 0 }),
                              options: FightRange.allCases.map { ($0, $0.label) })
            }
            if rows.isEmpty {
                CombatNote(emptyText)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        if let h = headRow {
                            row(h, head: true, keyed: highlighted == 0).id(h.value)
                            Divider().overlay(Theme.border)
                        }
                        if scope == .fight {
                            if loadingHistory, history == nil {
                                Text("Reading every fight…").font(.caption).foregroundStyle(Theme.textFaint)
                                    .padding(.vertical, 4)
                            }
                            ForEach(sectionOffsets(grouped, first: headRow == nil ? 0 : 1), id: \.day.key) { s in
                                Section {
                                    ForEach(Array(s.day.rows.enumerated()), id: \.element.value) { j, o in
                                        row(o, head: false, keyed: highlighted == s.offset + j).id(o.value)
                                    }
                                } header: {
                                    dayHeader(s.day)
                                }
                            }
                        } else {
                            ForEach(Array((frozen ?? opts).rest.enumerated()), id: \.offset) { i, o in
                                row(o, head: false, keyed: highlighted == i + (headRow == nil ? 0 : 1))
                                    .id(o.value)
                            }
                        }
                    }
                }
                .frame(height: 380)
                // Rows are identified by their fight, never by their place in the list: a filter moves
                // fights into places other fights held, and a lazy list keyed by place keeps the old rows.
                .onChange(of: highlighted) { _, i in
                    let rows = listRows
                    if rows.indices.contains(i) { proxy.scrollTo(rows[i].value) }
                }
            }
        }
        .padding(10)
        .frame(width: 480)
        // The zone-session list has no search field, so the keys land on the popover itself.
        .focusable(scope != .fight)
        .focusEffectDisabled()
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.return) { pickHighlighted(); return .handled }
    }

    /// Each day with the flat index of its first row, so a row's id is its place in `listRows`.
    private func sectionOffsets(_ days: [FightDay], first: Int) -> [(day: FightDay, offset: Int)] {
        var out: [(day: FightDay, offset: Int)] = []
        var at = first
        for d in days { out.append((day: d, offset: at)); at += d.rows.count }
        return out
    }

    private func dayHeader(_ d: FightDay) -> some View {
        HStack(spacing: 6) {
            Text(d.label).font(.caption.weight(.semibold)).foregroundStyle(Theme.text)
            Text("\(d.rows.count) \(d.rows.count == 1 ? "fight" : "fights")").font(.caption2).foregroundStyle(Theme.textFaint)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.paper)
    }

    /// The whole history, once per open. The list swaps from the live window to it when it lands.
    private func readHistory() async {
        loadingHistory = true
        defer { loadingHistory = false }
        guard let all = await loadHistory() else { return }
        history = all
        if open { frozen = all }
    }

    private func move(_ d: Int) {
        let n = listRows.count
        guard n > 0 else { return }
        highlighted = min(max(0, highlighted + d), n - 1)
    }

    private func pickHighlighted() {
        let rows = listRows
        guard rows.indices.contains(highlighted) else { return }
        onSelect(rows[highlighted])
        open = false
    }

    private var emptyText: String {
        if scope == .overall { return "No zone sessions yet" }
        let q = query.trimmingCharacters(in: .whitespaces)
        if loadingHistory, history == nil { return "Reading every fight…" }
        if q.isEmpty { return "No fights in the \(range.label.lowercased()) - try a longer range." }
        return "No fights in the \(range.label.lowercased()) match “\(q)”" + (range == .month ? "." : " - try a longer range.")
    }

    private func row(_ o: ScopeOption, head: Bool, keyed: Bool = false) -> some View {
        Button {
            onSelect(o)
            open = false
        } label: {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(o.label).font(.callout).foregroundStyle(Theme.text).lineLimit(1)
                        if o.live { Text("live").font(.system(size: 9)).foregroundStyle(Theme.green) }
                        if let z = o.zone, !z.isEmpty {
                            Text(z).font(.system(size: 9)).foregroundStyle(Theme.textFaint).lineLimit(1)
                        }
                    }
                    Text(rowTiming(o, at))
                        .font(.system(size: 10)).foregroundStyle(Theme.textFaint)
                }
                Spacer(minLength: 6)
                Text(CFmt.rate(o.dps)).font(.caption).monospacedDigit()
                    .foregroundStyle(o.value == selection ? Theme.gold : Theme.textDim)
            }
            .padding(.vertical, 4).padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 4)
                .fill(keyed ? Theme.gold.opacity(0.22)
                      : o.value == selection ? Theme.gold.opacity(0.12) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.bottom, head ? 2 : 0)
    }
}
