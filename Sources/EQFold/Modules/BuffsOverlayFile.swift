// `<userData>/message-overlay.json` — the user's register, read and written verbatim. The pure
// half; the engine owns the directory and the disk.
//
// The format is inherited, not negotiated: the app writes this file too, and a user who turns the
// engine off must not lose what their logs have taught this install.
//
//   {"version":2,"updatedAt":"<ISO8601>","sources":[{"key":…,"messages":[…]}]}
//
// It is a register, not a snapshot. Counts are stored per source, keyed by the character whose log
// produced them, so re-folding a log replaces that log's bucket instead of adding to it. No verdict
// is stored: a stored verdict is a second opinion waiting to disagree with the derived one.
//
// The committed baseline is filed under its own key and deliberately not written back — it is
// re-seeded from the bundle every launch. It is filtered on the way in and on the way out.
//
// Three separate ordering claims: `sources` in insertion order and not sorted (the resist ledger
// does sort its sources; the difference is inherited from two app writers), `messages` by codepoint
// on `text`, and `spells` by codepoint on `spell`.
//
// `updatedAt` is the log's clock, never a wall clock, so a re-fold of unchanged bytes writes an
// unchanged file — which is what lets the write be coalesced at all.
// (fold/src/overlay_file.rs)
import Foundation
import EQLog
import EQCompanionCore

/// `overlayPersistence.ts OVERLAY_REGISTER_VERSION`. Anything else reads as empty, including every
/// v1 file in the field, whose counts carry the inflation v2 fixes.
public let overlayRegisterVersion: Int64 = 2

/// The persisted file: the register plus its schema version, in the app's key order.
public struct OverlayRegisterFile {
    public var version: Int64
    public var updatedAt: String
    public var sources: [OverlaySourceCounts]

    /// The bytes, in the app's field order.
    public func serializedString() -> String {
        var out = "{\"version\":" + String(version) + ",\"updatedAt\":"
        JS.writeJSONString(&out, updatedAt)
        out.append(",\"sources\":[")
        for (i, source) in sources.enumerated() {
            if i > 0 { out.append(",") }
            out.append("{\"key\":")
            JS.writeJSONString(&out, source.key)
            out.append(",\"messages\":[")
            for (j, m) in source.messages.enumerated() {
                if j > 0 { out.append(",") }
                out.append("{\"text\":")
                JS.writeJSONString(&out, m.text)
                out.append(",\"role\":")
                JS.writeJSONString(&out, m.role)
                out.append(",\"spells\":[")
                for (k, s) in m.spells.enumerated() {
                    if k > 0 { out.append(",") }
                    out.append("{\"spell\":")
                    JS.writeJSONString(&out, s.spell)
                    out.append(",\"count\":" + String(s.count) + "}")
                }
                out.append("]}")
            }
            out.append("]}")
        }
        out.append("]}")
        return out
    }

    public var json: JSONValue {
        [
            "version": .int(version),
            "updatedAt": .string(updatedAt),
            "sources": .array(sources.map { s in
                ["key": .string(s.key),
                 "messages": .array(s.messages.map { m in
                     ["text": .string(m.text), "role": .string(m.role),
                      "spells": .array(m.spells.map { ["spell": .string($0.spell), "count": .int($0.count)] })]
                 })]
            }),
        ]
    }
}

public enum OverlayFile {
    /// One read rule with no tiers: every failure — missing, unparseable, stale-version, wrong
    /// shape — answers with no sources. Then the committed baseline's bucket and any source whose
    /// `messages` is not an array are filtered out.
    ///
    /// No salvage and no quarantine, unlike the resist ledger: the overlay is a nicety rather than
    /// required state, and the active character's log re-mines itself on the next fold.
    public static func readRegister(_ text: String) -> [OverlaySourceCounts] {
        guard let doc = try? JSONValue.parse(text) else { return [] }
        if doc["version"].int64 != overlayRegisterVersion { return [] }
        guard let raw = doc["sources"].array else { return [] }
        return raw.compactMap { entry -> OverlaySourceCounts? in
            guard entry["key"].string != overlayBaselineSource else { return nil }
            guard entry["messages"].array != nil, let key = entry["key"].string else { return nil }
            let messages: [OverlayMessageCounts] = (entry["messages"].array ?? []).compactMap { m in
                guard let t = m["text"].string, let r = m["role"].string,
                      let sp = m["spells"].array else { return nil }
                let spells: [OverlaySpellCount] = sp.compactMap {
                    guard let s = $0["spell"].string, let c = $0["count"].int64 else { return nil }
                    return OverlaySpellCount(spell: s, count: c)
                }
                return OverlayMessageCounts(text: t, role: r, spells: spells)
            }
            return OverlaySourceCounts(key: key, messages: messages)
        }
    }

    /// The write rule: the version, the register's own `updatedAt`, and every bucket except the
    /// committed baseline's, in the register's own order.
    public static func registerFileOf(_ register: OverlayRegister) -> OverlayRegisterFile {
        OverlayRegisterFile(version: overlayRegisterVersion,
                            updatedAt: register.updatedAt,
                            sources: register.sources.filter { $0.key != overlayBaselineSource })
    }

    /// One persisted bucket as the miner's `merge` wants it: the source key, and the counts filed
    /// under it. The key travels with the counts, because merging two origins under one key would
    /// leave `beginSource` able to replace only both or neither.
    public static func seeds(_ sources: [OverlaySourceCounts]) -> [(String, [OverlaySeedMessage])] {
        sources.map { source in
            (source.key, source.messages.map {
                OverlaySeedMessage(text: $0.text, role: overlayRoleOf($0.role),
                                   spells: $0.spells.map { ($0.spell, $0.count) })
            })
        }
    }

    /// The engine's seam shape: each bucket's counts as the `SeedMessage` JSON the registry hands
    /// back through `Registry.seedPersisted`.
    public static func seedsOf(_ sources: [OverlaySourceCounts]) -> [(String, [SeedMessage])] {
        sources.map { source in
            (source.key, source.messages.map { m in
                JSONValue.object([
                    "text": .string(m.text),
                    "role": .string(m.role),
                    "spells": .array(m.spells.map { ["spell": .string($0.spell), "count": .int($0.count)] }),
                ])
            })
        }
    }

    /// The other half of that seam: the JSON the registry carried, back in the miner's shape.
    public static func seedMessages(_ counts: [SeedMessage]) -> [OverlaySeedMessage] {
        counts.map { m in
            OverlaySeedMessage(
                text: m["text"].string ?? "",
                role: overlayRoleOf(m["role"].string ?? ""),
                spells: (m["spells"].array ?? []).map { ($0["spell"].string ?? "", $0["count"].int64 ?? 0) })
        }
    }
}
