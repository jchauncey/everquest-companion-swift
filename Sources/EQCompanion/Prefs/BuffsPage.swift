// Preferences → Buffs — "Track other casters", ported from BuffTrustSetting.tsx and the
// normalizer it shares with the engine (src/shared/buffTrust.ts).
//
// ONE LIST OF NAMES. The buff and debuff bars only ever show spells a CAST LINE anchors, and the
// only cast lines that are yours say "You begin casting". A player who duos with the same
// enchanter every night wants that enchanter's mez timers on their debuff window; the honest way
// to give it to them is to let them NAME the person, because the game's landing sentences name
// nobody.
//
// STATE, NEVER PROCESS: this is a list you edit, not a scan you run. There is deliberately no
// "add everyone in my group" button and no suggestion from the roster — a group changes without
// the user choosing it, and this preference is a choice. The caption says what the empty state
// means rather than leaving it to be inferred, because "why do I not see their buffs" is the
// question this control exists to answer.
//
// THE LIST IS PUSHED, NOT POLLED. The engine's buffs module holds the allowlist as a `define`
// (`buffTrust.define`), so every edit re-sends the whole list, and `AppModel.pushBuffTrust()`
// re-sends it after an attach — a fold that came up without it would anchor nobody's casts but
// yours and quietly drop the bars the user asked for.
import SwiftUI
import EQCompanionCore

extension PrefPages {
    static let buffs = PrefPage(id: "buffs", label: "Buffs", icon: "person.2", sections: [
        PrefSectionInfo(id: "buff-trust", label: "Track other casters",
                        keywords: "buff buffs debuff debuffs timer timers bar bars mez mesmerize charm slow snare root overlay other caster casters group party friend enchanter cleric shaman missing not showing hidden allow allowlist trust duration durations")
    ]) { AnyView(BuffsPage()) }
}

/// How many external casters a user may allowlist. A preference, not a roster import.
let maxExternalCasters = 16

/// The longest name we will store. EQ character names are short; this only bounds abuse.
let maxCasterNameChars = 32

/// The ONE normalizer, run by the reader and by every edit alike — the port of
/// `normalizeBuffTrustPrefs`. Anything it cannot read is dropped rather than raised: a
/// hand-edited defaults file must not be able to stop the app folding buffs.
enum BuffTrust {
    /// A caster name folded to its comparison key: names are dirty, canonicalize at the boundary,
    /// display raw.
    static func key(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// A name is storable when it is a BARE name: non-empty, short, and free of the characters a
    /// log line uses as structure. Not a guess at EQ's naming rules — a refusal to store something
    /// that could never match a cast line anyway.
    static func storable(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t.count > maxCasterNameChars { return nil }
        if t.rangeOfCharacter(from: CharacterSet(charactersIn: "[]'\"\n\r\t")) != nil { return nil }
        let k = key(t)
        if k == "self" || k == "you" { return nil }
        return t
    }

    /// The list as it is persisted: display spellings, in the order the user added them, deduped
    /// case-insensitively and capped.
    static func normalize(_ list: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for entry in list {
            guard let name = storable(entry) else { continue }
            let k = key(name)
            if seen.contains(k) { continue }
            seen.insert(k)
            out.append(name)
            if out.count >= maxExternalCasters { break }
        }
        return out
    }

    /// Add a name, preserving order and refusing duplicates.
    static func adding(_ list: [String], _ name: String) -> [String] {
        normalize(list + [name])
    }

    /// Remove a name, case-insensitively.
    static func removing(_ list: [String], _ name: String) -> [String] {
        let k = key(name)
        return list.filter { key($0) != k }
    }
}

extension AppModel {
    /// Push the trusted-caster allowlist to the engine. Called after every edit and — by the
    /// integrator — after each attach, because the module holds it as a define and a fresh fold
    /// starts out trusting nobody but you.
    func pushBuffTrust() async {
        guard client.isReady else { return }
        let externals = BuffTrust.normalize(Prefs.shared.trustedCasters)
        do {
            _ = try await client.request(Op.buffTrustDefine,
                                         ["trust": ["externals": .array(externals.map { .string($0) })]])
        } catch {
            note("buffTrust.define failed: \(error)")
        }
    }
}

struct BuffsPage: View {
    @Environment(AppModel.self) private var model
    @Bindable private var prefs = Prefs.shared
    @State private var draft = ""

    private var full: Bool { prefs.trustedCasters.count >= maxExternalCasters }
    private var canAdd: Bool { !full && BuffTrust.storable(draft) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PrefCard("Track other casters") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Show buffs and debuffs cast by these people, as well as your own")
                        .foregroundStyle(Theme.text)

                    HStack(alignment: .bottom, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Character name").font(.caption).foregroundStyle(Theme.textDim)
                            TextField("", text: $draft)
                                .textFieldStyle(.plain)
                                .foregroundStyle(Theme.text)
                                .disabled(full)
                                .frame(width: 200)
                                .padding(.horizontal, 8).padding(.vertical, 6)
                                .background(RoundedRectangle(cornerRadius: 6).stroke(Theme.border))
                                .onSubmit(add)
                                .onChange(of: draft) { _, v in
                                    if v.count > maxCasterNameChars { draft = String(v.prefix(maxCasterNameChars)) }
                                }
                        }
                        PrefButton(title: "Add", action: add).disabled(!canAdd).opacity(canAdd ? 1 : 0.4)
                    }

                    if !prefs.trustedCasters.isEmpty {
                        TrustedCasterChips(names: prefs.trustedCasters, onRemove: remove)
                    }

                    PrefCaption(prefs.trustedCasters.isEmpty
                        ? "Empty, so the bars show only spells you cast. A landing message names no caster, so without a name here there is no way to tell your work from a stranger`s in a crowded zone."
                        : "Their casts appear on the same bars as yours. Learned durations stay separate: their spell timers come from their gear and abilities, not yours.")

                    if full {
                        PrefCaption("That is all \(maxExternalCasters) names this list holds. Remove one to add another.")
                    }
                }
            }
        }
    }

    private func add() {
        guard let name = BuffTrust.storable(draft), !full else { return }
        prefs.trustedCasters = BuffTrust.adding(prefs.trustedCasters, name)
        draft = ""
        push()
    }

    private func remove(_ name: String) {
        prefs.trustedCasters = BuffTrust.removing(prefs.trustedCasters, name)
        push()
    }

    private func push() {
        Task { await model.pushBuffTrust() }
    }
}

/// The names as removable chips, wrapping onto as many rows as they need.
private struct TrustedCasterChips: View {
    let names: [String]
    let onRemove: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(names, id: \.self) { name in
                HStack(spacing: 4) {
                    Text(name).font(.caption).foregroundStyle(Theme.text).lineLimit(1)
                    Button { onRemove(name) } label: {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textDim)
                    .help("Stop showing \(name)’s buffs and debuffs")
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .overlay(Capsule().stroke(Theme.border))
            }
        }
    }
}
