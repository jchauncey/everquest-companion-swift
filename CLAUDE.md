# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A native, self-contained macOS companion for EverQuest Legends: one SwiftPM app that reads the
game's log file and folds it into live views. It is a **complete Swift port** of
jmoyers/everquest-companion (Electron + Rust engine), carried under the same FSL-1.1-MIT license.
The upstream checkout is expected at `../everquest-companion`; its `AGENTS.md`, Rust crates
(`engine/crates/{eqlog,fold,knowledge,engined}`) and `protocol/schema/*.json` are the reference
for everything here. Port faithfully — the upstream comments state rules, and the goldens check them.

## Commands

`make help` lists every target; the Makefile is a thin wrapper over exactly the commands below, so
what CI runs and what you run are the same lines. `make verify` is the CI entry point.

CI (`.circleci/config.yml`) builds both packages and runs the suite on every push. It CANNOT prove
parity: `Goldens/` and the owner's EverQuest install do not exist on a CI box, so those suites
`XCTSkip` there. The run prints the skip count and reasons so a green build never reads as more
than it is — only a local `make verify` with `Goldens/` present proves byte-identity.

```sh
swift build                                   # debug build of every target
swift run                                     # the app (the only executable in the root package)
swift test                                    # ~730 tests, ~5 min (the golden oracles dominate)
swift test --filter EQFoldTests.GoldenSnapshotsTests     # one class
swift test --filter 'EQLogTests.GoldenEventsTests/testAllFixtures'   # one test
scripts/build-app.sh [--debug]                # release build → dist/EQCompanion.app (ad-hoc signed)

# Developer tools live in the nested package Tools/ so a bare `swift run` means the app:
swift run --package-path Tools eqtool events <fixture>|--all [--kinds a,b] [--tz Zone] [--max N]
swift run --package-path Tools eqtool snapshots <fixture>|--all [--modules loot,kills]
swift run --package-path Tools eqtool combat <fixture>|--all
swift run --package-path Tools eqtool views <fixture>|--all [--sources]
swift run --package-path Tools eqbench <log> [--tz Zone] [--golden path]   # parser timing + byte diff

scripts/gen-goldens.sh [../everquest-companion]   # re-cut Goldens/ from the RUST engine (needs cargo)
```

Requires Xcode 16+ / Swift 6 toolchain, macOS 14+. Every target is Swift language mode 5.
A `swift build` while another SwiftPM instance holds `.build` waits — don't run parallel builds.

## Verification is the law here

`Goldens/` (git-ignored, ~230 MB) holds what the **Rust engine** produced for the 138 fixtures in
`Resources/fixtures/` and for `_real` (the owner's own log, never committed):

| golden | Swift bar | checked by |
|---|---|---|
| `events.ndjson` | **byte identity**, every line | `eqtool events`, `EQLogTests` |
| `snapshots.json` (20 modules + combat + scopes) | deep equality (key order free; `undefined` = absent key; ints == integral doubles; array order matters; `seq` must match) | `eqtool snapshots/combat`, `EQFoldTests` |
| `views.json`, `ops.json` | deep equality for time-independent view sources and every op answer | `eqtool views`, `EQEngineTests` |

Golden tests `XCTSkip` when `Goldens/` is absent, so a green run without goldens proves little.
Fixtures are all character `Primitive@freeport`, zone `America/Los_Angeles`; the real log is
`Zoddrick@oggok`, `America/New_York`. The parity oracle needs staged names of the form
`eqlog_<Name>_<server>.<slice>.txt` — the log path is a fold input (the `character` module).
The three wall-clock views (`buffs.active`, `timers.rows`, `respawn.watches`) can't be byte-diffed
against recordings; they are checked structurally.

**JS-semantics fidelity** is why the goldens match and must be preserved: `JS.*` in `EQLog/JSStr.swift`
(ECMA whitespace, `JSON.stringify` escaping, JS number spelling), `Clock` (V8 legacy date parsing
with DST rules), `JSMap` (insertion order), stable sorts and byte-wise string ordering emulated
where Rust used them. `Re` (`EQLog/Re.swift`) feeds Rust-dialect patterns to ICU — paste upstream
patterns verbatim; it translates `\u{…}`, `(?-u:\b)`, `$`→`\z`, and bare `.`→`[^\n]`.

## Architecture

```
EverQuest (CrossOver bottle) ──appends──► Logs/eqlog_<Char>_<server>.txt
                                                │
  EQCompanion (one process)                     ▼
    EQData        committed JSON corpora + wiki images, as a resource bundle (EQData.text("items.json"))
    EQLog         parser: bytes → canonical NDJSON events (port of the eqlog crate); SpellDb; Tail
    EQFold        20 EqModule world-model modules + Combat/* engine (port of fold); Registry wires them
    EQKnowledge   item/mob/quest corpora + name search (KnowledgeCorpus.shared())
    EQEngine      World: one fold thread per attach (scan → live tail → 1 Hz tick), generation/epoch law,
                  Views/* registry (validate/cut/diff, reset-then-diffs), Ops table, StateDir persistence,
                  LocalEngine = the in-process EngineLink (no socket, no child process)
    EQCompanionCore  JSONValue, Protocol.swift (EngineMessage, Op.* names), EngineClient (subscriptions,
                  request correlation, the epoch law: epoch bump → drop every window, re-query)
    EQCompanion   SwiftUI app: RootView tabs, AppModel (boot/attach/health), Prefs/ (Preferences pages),
                  OverlayHost + Overlay*.swift (NSPanels), AlertPlayer, GamePresence, CursorRing, MenuBarItem
```

Rules that cross files:
- **The app never munges domain data.** Views read `view.subscribe` rows / `combat.snapshot` /
  `knowledge.*` results in the upstream protocol shape verbatim (`Protocol.swift`, schema `$defs`).
  Filtering that upstream did in the renderer (meter scope, pet nesting) lives in `CombatData.swift`.
- **World is single-writer.** Fold state is touched only on the fold thread; readers ask through
  `World` (patience-bounded). `World.attach` bumps generation + epoch in one critical section;
  `World.shutdown()` retires the fold so `StateDir` flushes on quit.
- **Fold inputs are per generation**: alert defs, buff trust, combo corrections and respawn
  defines must be re-pushed after every attach (`AppModel.attachSelected` → `pushAlerts`,
  `pushBuffTrust`, `pushComboCorrections`).
- **Settings**: every preference is a property on `Prefs.shared` (`Prefs/Prefs.swift`, UserDefaults
  `prefs.<page>.<name>`); pages are `PrefPage`s registered in `PrefPages.all`, built from the
  `PrefControls.swift` vocabulary. Engine diagnostics and client notes both go to
  `~/Library/Application Support/EQCompanion/client.log` — read it first when a panel is empty;
  screen capture is unavailable in the agent environment, so verify by log and test.
- Sound packs download from the openpeon registry into Application Support; nothing else touches
  the network. There is no telemetry and no updater — don't add controls that pretend otherwise.

## Working in parallel

Large ports here were done as waves of workers on disjoint files (see `docs/plan.md` for what is
left). Each worker owns named files, verifies with `eqtool` and its own new test file, and
reports the shared-file changes it needs rather than making them; the integrator applies them
and re-runs the oracles. Keep to that: one owner per file per wave.
