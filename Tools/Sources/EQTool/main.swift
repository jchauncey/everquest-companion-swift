// eqtool — the developer's oracle diff. Every subcommand compares this port against a golden the
// Rust engine produced (`Goldens/<fixture>/…`, see scripts/gen-goldens.sh).
//
//   eqtool events <fixture|path> [--kinds a,b] [--tz Zone] [--max N] [--all]
//       Parse the fixture and diff the NDJSON stream line by line. `--kinds` reports only lines
//       whose golden OR ours has one of those kinds. `--all` runs every fixture and prints a table.
//   eqtool snapshots <fixture> [--modules a,b]      (lands with EQFold)
import Foundation
import EQLog
import EQFold
import EQEngine
import EQCompanionCore

// Tools/Sources/EQTool/main.swift → the repo root is four levels up.
let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let goldens = repo.appendingPathComponent("Goldens")
let fixtures = repo.appendingPathComponent("Resources/fixtures")

func usage() -> Never {
    print("""
    usage: eqtool events <fixture> [--kinds a,b] [--tz Zone] [--max N]   diff the parser's NDJSON vs the golden
           eqtool events --all [substring] [--kinds a,b]                every fixture, per-kind table
           eqtool snapshots <fixture> [--modules a,b] [--max N]         fold the GOLDEN events, diff module snapshots
           eqtool snapshots --all [substring] [--modules a,b]           every fixture, per-module table
           eqtool combat <fixture> [--max N]                            diff the combat snapshot + scopes
           eqtool views <fixture> [--sources a,b] [--max N]              cut the golden descriptors, diff the served windows
           eqtool views --all [substring] [--sources a,b]                every fixture, per-source table
    """)
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else { usage() }
args.removeFirst()
var opt: [String: String] = [:]
var positional: [String] = []
var i = 0
while i < args.count {
    let a = args[i]
    if a.hasPrefix("--") {
        let k = String(a.dropFirst(2))
        if k == "all" { opt[k] = "1" } else { opt[k] = i + 1 < args.count ? args[i + 1] : ""; i += 1 }
    } else { positional.append(a) }
    i += 1
}

func fixturePath(_ name: String) -> (log: URL, golden: URL, character: String, tz: String) {
    if name == "_real" {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let log = home.appendingPathComponent("Library/Application Support/CrossOver/Bottles/EverQuest/drive_c/users/Public/Daybreak Game Company/Installed Games/EverQuest Legends/Logs/eqlog_Zoddrick_oggok.txt")
        return (log, goldens.appendingPathComponent("_real"), "Zoddrick", "America/New_York")
    }
    if name.hasPrefix("/") { return (URL(fileURLWithPath: name), goldens.appendingPathComponent(URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent), "Primitive", "America/Los_Angeles") }
    return (fixtures.appendingPathComponent(name + ".log"), goldens.appendingPathComponent(name), "Primitive", "America/Los_Angeles")
}

struct EventsResult { var total = 0; var matched = 0; var firstDiff: (Int, String, String)? = nil; var byKind: [String: (Int, Int)] = [:] }

func kindOf(_ line: String) -> String {
    guard let r = line.range(of: "\"kind\":\"") else { return "?" }
    let rest = line[r.upperBound...]
    return String(rest[..<(rest.firstIndex(of: "\"") ?? rest.endIndex)])
}

func runEvents(_ name: String, kinds: Set<String>?, maxShow: Int, verbose: Bool) -> EventsResult {
    let (log, gdir, character, tzName) = fixturePath(name)
    var res = EventsResult()
    guard let data = try? Data(contentsOf: log) else { print("cannot read \(log.path)"); return res }
    guard let gold = try? String(contentsOf: gdir.appendingPathComponent("events.ndjson"), encoding: .utf8) else { print("no golden at \(gdir.path)"); return res }
    let goldLines = gold.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    let clock = Clock(identifier: opt["tz"] ?? tzName)!
    let parser = Parser(clock: clock, db: SpellDb.shared(), character: character)
    var ours: [String] = []
    ours.reserveCapacity(goldLines.count)
    let t0 = Date()
    Scan.bytes(parser, data) { json, _ in ours.append(json) }
    let ms = Int(Date().timeIntervalSince(t0) * 1000)
    res.total = goldLines.count
    var shown = 0
    for i in 0..<max(goldLines.count, ours.count) {
        let g = i < goldLines.count ? goldLines[i] : "<missing>"
        let o = i < ours.count ? ours[i] : "<missing>"
        let gk = kindOf(g), ok = kindOf(o)
        if let kinds, !kinds.contains(gk), !kinds.contains(ok) { continue }
        var e = res.byKind[gk] ?? (0, 0)
        e.0 += 1
        if g == o { res.matched += 1; e.1 += 1 } else {
            if res.firstDiff == nil { res.firstDiff = (i, g, o) }
            if verbose, shown < maxShow {
                shown += 1
                print("--- line \(i) (seq) kind \(gk) vs \(ok)")
                print("  golden: \(g.prefix(300))")
                print("  ours:   \(o.prefix(300))")
            }
        }
        res.byKind[gk] = e
    }
    if verbose {
        print("\(name): \(res.matched)/\(res.total) identical · parsed \(ours.count) events in \(ms) ms · unparsed stamps \(parser.unparsedStamps)")
        for (k, v) in res.byKind.sorted(by: { $0.value.0 - $0.value.1 > $1.value.0 - $1.value.1 }) where v.0 != v.1 {
            print("  \(k): \(v.1)/\(v.0)")
        }
    }
    return res
}

/// Fold the golden NDJSON for one fixture, exactly as the parity recorder constructs the world:
/// roster seam installed, reset, player name off the filename, construction clock = the last
/// timestamped line, launch anchor on the golden's zone.
func foldGolden(_ name: String) -> (Fold, JSONValue)? {
    let (_, gdir, character, tzName) = fixturePath(name)
    guard let events = try? String(contentsOf: gdir.appendingPathComponent("events.ndjson"), encoding: .utf8),
          let gold = (try? Data(contentsOf: gdir.appendingPathComponent("snapshots.json"))).flatMap({ try? JSONValue.parse($0) }) else {
        print("no golden at \(gdir.path)"); return nil
    }
    let clock = Clock(identifier: opt["tz"] ?? tzName)!
    let db = SpellDb.shared()
    var deps = ClusterDeps()
    deps.knownSpell = Set(db.keys())
    deps.spellClasses = spellClassIndex(db)
    deps.launchMs = Epoch.launchMs(clock)
    deps.constructionNowMs = gold["meta"]["constructionNowMs"].int64 ?? 0
    // The recorder was handed the STAGED filename and published it verbatim as `logPath`.
    let recorded = name == "_real" ? "eqlog_Zoddrick_oggok.real.txt" : "eqlog_\(character)_freeport.\(name).txt"
    deps.character = ["name": .string(character), "server": .string(name == "_real" ? "oggok" : "freeport"),
                      "logPath": .string(gold["meta"]["logPath"].string ?? recorded)]
    deps.selfName = nil
    deps.facts = SpellFacts.project(db)
    let engine = CombatEngine()
    engine.reset()
    engine.setPlayerName(character)
    let fold = Fold(registry: registered(deps), launchMs: deps.launchMs).withCombat(engine)
    let t0 = Date()
    fold.foldNDJSON(events)
    let ms = Int(Date().timeIntervalSince(t0) * 1000)
    if opt["quiet"] == nil { print("\(name): folded \(fold.events) events in \(ms) ms (golden \(gold["meta"]["events"].int ?? 0) in \(gold["meta"]["ms"].int ?? 0) ms)") }
    return (fold, gold)
}

func runSnapshots(_ name: String, modules: Set<String>?, maxShow: Int, verbose: Bool) -> [String: Bool] {
    guard let (fold, gold) = foldGolden(name) else { return [:] }
    var ok: [String: Bool] = [:]
    let ours = fold.registry.snapshots()
    let oursById = Dictionary(uniqueKeysWithValues: (ours["modules"].array ?? []).map { ($0["id"].string ?? "", $0["snapshot"]) })
    for m in gold["modules"].array ?? [] {
        let id = m["id"].string ?? ""
        if let modules, !modules.contains(id) { continue }
        let rep = SnapshotDiff.compare(golden: m["snapshot"], ours: oursById[id] ?? .null, limit: maxShow)
        ok[id] = rep.isEqual
        if verbose {
            print("\(rep.isEqual ? "ok  " : "DIFF") \(id)\(rep.approx.isEmpty ? "" : " (\(rep.approx.count) approx)")")
            for l in rep.mismatches { print("     \(l)") }
        }
    }
    return ok
}

func runCombat(_ name: String, maxShow: Int) -> Bool {
    guard let (fold, gold) = foldGolden(name), let engine = fold.combat else { return false }
    let roster = fold.registry.roster()
    let snap = engine.snapshot(now: fold.lastTs, opts: .full(), roster: roster)
    let rep = SnapshotDiff.compare(golden: gold["combat"], ours: snap, limit: maxShow)
    print("\(rep.isEqual ? "ok  " : "DIFF") combat\(rep.approx.isEmpty ? "" : " (\(rep.approx.count) approx)")")
    for l in rep.mismatches { print("     \(l)") }
    let scopes = JSONValue.array(engine.walkScopes(now: fold.lastTs, roster: roster))
    let rep2 = SnapshotDiff.compare(golden: gold["scopes"], ours: scopes, limit: maxShow)
    print("\(rep2.isEqual ? "ok  " : "DIFF") scopes")
    for l in rep2.mismatches { print("     \(l)") }
    return rep.isEqual && rep2.isEqual
}

/// The engine wave's oracle: cut every golden descriptor through the view registry at
/// `now = fold.lastTs` and diff the window the RUST engine served.
///
/// Three of the eight sources are cut against the recorder's wall clock and cannot be diffed row by
/// row — `buffs.active`, `timers.rows` and `respawn.watches` are checked for their row COUNT and
/// their cell KEY SETS instead, and the report says so. Everything else, errors included, is exact.
let viewsTimeDependent: Set<String> = ["buffs.active", "timers.rows", "respawn.watches"]

/// The one golden entry recorded without its descriptor (`gen-engine-goldens.py` drops it for the
/// bad-sort refusal). Restated here rather than guessed at the call site.
let viewsDescriptorFallback: [String: JSONValue] = [
    "loot.ledger#badsort": ["source": "loot.ledger", "sort": [["nosuch", "asc"]]]
]

func cellKeys(_ rows: [JSONValue]) -> Set<String> {
    var out = Set<String>()
    for r in rows { for k in (r["cells"].object ?? [:]).keys { out.insert(k) } }
    return out
}

func runViews(_ name: String, sources: Set<String>?, maxShow: Int, verbose: Bool) -> [String: Bool] {
    let (_, gdir, _, tzName) = fixturePath(name)
    guard let goldData = try? Data(contentsOf: gdir.appendingPathComponent("views.json")),
          let gold = try? JSONValue.parse(goldData), let entries = gold.object else {
        print("no views golden at \(gdir.path)"); return [:]
    }
    guard let (fold, _) = foldGolden(name) else { return [:] }
    let clock = Clock(identifier: opt["tz"] ?? tzName)!
    let now = fold.lastTs

    // One build per source, cut for every descriptor over it — what the serve loop does. The
    // engine's own door is `FoldSink.sourceRows`, which needs an attach; this reads the same module
    // pull seams off a fold built from the golden events.
    let r = fold.registry
    var built: [String: [SourceRow]] = [
        Views.Loot.ledger.id: r.loot().map { Views.Loot.rows($0, clock) } ?? [],
        Views.Buffs.active.id: r.buffs().map { Views.Buffs.rows($0) } ?? [],
        Views.Respawn.watches.id: r.respawn().map { Views.Respawn.rows($0) } ?? [],
        Views.Kills.recent.id: r.progression().map { Views.Kills.rows($0) } ?? [],
        Views.Progression.recent.id: r.progression().map { Views.Progression.rows($0, clock) } ?? [],
        Views.EventFeed.recent.id: r.eventFeed().map { Views.EventFeed.rows($0) } ?? []
    ]
    if let b = r.buffs(), let t = r.buffTimers() { built[Views.Timers.rowsSource.id] = Views.Timers.rows(b, t) }
    // The meter's rows come off the snapshot's own `selected`, at the cheapest options that produce
    // one — the same call the fold sink makes.
    if let engine = fold.combat {
        let snap = engine.snapshot(now: now, opts: SnapshotOpts(maxSegments: 0), roster: r.roster())
        built[Views.Combat.live.id] = Views.Combat.rows(snap["selected"])
    }

    var ok: [String: Bool] = [:]
    for key in entries.keys.sorted() {
        let entry = entries[key]!
        let source = String(key.split(separator: "#")[0])
        if let sources, !sources.contains(source) { continue }
        let descriptor = entry["descriptor"].isNull ? (viewsDescriptorFallback[key] ?? .null) : entry["descriptor"]
        if descriptor.isNull { print("     \(key): no descriptor in the golden and no fallback"); ok[key] = false; continue }

        var problems: [String] = []
        var note = ""
        do {
            let view = try Views.validate(RawDescriptor(json: descriptor))
            if !entry["error"].isNull {
                problems.append("golden refused (\(entry["error"]["code"].display)) and we served")
            } else {
                let (window, total) = Views.cut(view, built[source] ?? [])
                let ours = window.map { JSONValue.object(["key": .string($0.key), "cells": .object($0.cells)]) }
                let goldRows = entry["rows"].array ?? []
                if viewsTimeDependent.contains(source) {
                    note = " (counts + cell keys only)"
                    if goldRows.count != ours.count { problems.append("golden \(goldRows.count) rows, ours \(ours.count)") }
                    let g = cellKeys(goldRows), o = cellKeys(ours)
                    if !goldRows.isEmpty, !ours.isEmpty, g != o {
                        problems.append("cell keys differ: golden-only \(g.subtracting(o).sorted()), ours-only \(o.subtracting(g).sorted())")
                    }
                } else {
                    if entry["total"].int64 != total { problems.append("total: golden \(entry["total"].display) ours \(total)") }
                    let rep = SnapshotDiff.compare(golden: .array(goldRows), ours: .array(ours), path: "rows", limit: maxShow)
                    problems.append(contentsOf: rep.mismatches)
                }
            }
        } catch let e as ViewError {
            guard !entry["error"].isNull else {
                problems.append("refused \(e.code): \(e.message) — the golden served \(entry["rows"].array?.count ?? 0) rows")
                ok[key] = false
                if verbose { print("DIFF \(key)"); for p in problems { print("     \(p)") } }
                continue
            }
            if entry["error"]["code"].string != e.code {
                problems.append("code: golden \(entry["error"]["code"].display) ours \(e.code)")
            }
            if entry["error"]["message"].string != e.message {
                problems.append("message:\n       golden \(entry["error"]["message"].display)\n       ours   \(e.message)")
            }
        } catch {
            problems.append("\(error)")
        }
        ok[key] = problems.isEmpty
        if verbose {
            print("\(problems.isEmpty ? "ok  " : "DIFF") \(key)\(note)")
            for p in problems.prefix(maxShow) { print("     \(p)") }
        }
    }
    return ok
}

func allFixtures() -> [String] {
    var names = ((try? FileManager.default.contentsOfDirectory(atPath: goldens.path)) ?? []).filter { !$0.hasPrefix("_") && !$0.hasPrefix(".") }.sorted()
    if let only = positional.first { names = names.filter { $0.contains(only) } }
    return names
}

switch cmd {
case "snapshots":
    let modules = opt["modules"].map { Set($0.split(separator: ",").map(String.init)) }
    let maxShow = Int(opt["max"] ?? "8") ?? 8
    if opt["all"] != nil {
        opt["quiet"] = "1"
        var perModule: [String: (Int, Int)] = [:]
        for n in allFixtures() {
            let r = runSnapshots(n, modules: modules, maxShow: 1, verbose: false)
            let bad = r.filter { !$0.value }.map(\.key).sorted()
            print("\(bad.isEmpty ? "ok  " : "DIFF") \(n)" + (bad.isEmpty ? "" : ": " + bad.joined(separator: ",")))
            for (k, v) in r { var e = perModule[k] ?? (0, 0); e.0 += 1; if v { e.1 += 1 }; perModule[k] = e }
        }
        for (k, v) in perModule.sorted(by: { $0.key < $1.key }) { print("  \(k): \(v.1)/\(v.0)\(v.0 == v.1 ? "" : "  <-- \(v.0 - v.1) fixtures diverge")") }
    } else {
        guard let name = positional.first else { usage() }
        _ = runSnapshots(name, modules: modules, maxShow: maxShow, verbose: true)
    }
case "views":
    let vsources = opt["sources"].map { Set($0.split(separator: ",").map(String.init)) }
    let vmax = Int(opt["max"] ?? "8") ?? 8
    if opt["all"] != nil {
        opt["quiet"] = "1"
        var perSource: [String: (Int, Int)] = [:]
        for n in allFixtures() {
            let r = runViews(n, sources: vsources, maxShow: 1, verbose: false)
            let bad = r.filter { !$0.value }.map(\.key).sorted()
            print("\(bad.isEmpty ? "ok  " : "DIFF") \(n)" + (bad.isEmpty ? "" : ": " + bad.joined(separator: ",")))
            for (k, v) in r {
                let src = String(k.split(separator: "#")[0])
                var e = perSource[src] ?? (0, 0); e.0 += 1; if v { e.1 += 1 }; perSource[src] = e
            }
        }
        for (k, v) in perSource.sorted(by: { $0.key < $1.key }) {
            let bar = viewsTimeDependent.contains(k) ? "  (counts + cell keys)" : ""
            print("  \(k): \(v.1)/\(v.0)\(v.0 == v.1 ? "" : "  <-- \(v.0 - v.1) diverge")\(bar)")
        }
    } else {
        guard let name = positional.first else { usage() }
        _ = runViews(name, sources: vsources, maxShow: vmax, verbose: true)
    }
case "combat":
    let maxShow = Int(opt["max"] ?? "12") ?? 12
    if opt["all"] != nil {
        opt["quiet"] = "1"
        var okCount = 0
        let names = allFixtures()
        for n in names { print("== \(n)"); if runCombat(n, maxShow: 1) { okCount += 1 } }
        print("combat: \(okCount)/\(names.count) fixtures identical")
    } else {
        guard let name = positional.first else { usage() }
        _ = runCombat(name, maxShow: maxShow)
    }
case "events":
    let kinds = opt["kinds"].map { Set($0.split(separator: ",").map(String.init)) }
    let maxShow = Int(opt["max"] ?? "5") ?? 5
    if opt["all"] != nil {
        var names = ((try? FileManager.default.contentsOfDirectory(atPath: goldens.path)) ?? []).filter { !$0.hasPrefix("_") && !$0.hasPrefix(".") }.sorted()
        if let only = positional.first { names = names.filter { $0.contains(only) } }
        var totalAll = 0, matchedAll = 0
        var kindTotals: [String: (Int, Int)] = [:]
        for n in names {
            let r = runEvents(n, kinds: kinds, maxShow: 0, verbose: false)
            totalAll += r.total; matchedAll += r.matched
            for (k, v) in r.byKind { var e = kindTotals[k] ?? (0, 0); e.0 += v.0; e.1 += v.1; kindTotals[k] = e }
            let mark = r.matched == r.total ? "ok " : "DIFF"
            print("\(mark) \(n): \(r.matched)/\(r.total)" + (r.firstDiff.map { " first diff at \($0.0)" } ?? ""))
        }
        print("TOTAL \(matchedAll)/\(totalAll)")
        for (k, v) in kindTotals.sorted(by: { $0.key < $1.key }) { print("  \(k): \(v.1)/\(v.0)\(v.0 == v.1 ? "" : "  <-- \(v.0 - v.1) wrong")") }
    } else {
        guard let name = positional.first else { usage() }
        _ = runEvents(name, kinds: kinds, maxShow: maxShow, verbose: true)
    }
default:
    usage()
}
