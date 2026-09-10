# EQ Companion for macOS

A native macOS companion for **EverQuest Legends**. It reads the log file the game already writes
and turns it into live views: a DPS meter and floating overlay, loot and gear planning, maps, buffs
and timers, leveling, raid targets, the Plane of Sky tracker, and alerts with voice packs.

**It only reads your log.** Nothing is injected, no game file is modified, nothing is automated.
One app process — no child process, no socket, no Electron.

<!-- Screenshots: drop images in docs/images/ and link them here. -->

## Requirements

- macOS 14+
- Xcode 16+ / Swift 6 toolchain (`swift --version`)
- EverQuest Legends running under CrossOver, Whisky, or Wine

## Install

```sh
git clone https://github.com/jchauncey/everquest-companion-swift.git
cd everquest-companion-swift
make install          # builds a release app and copies it to /Applications
```

Or build without installing:

```sh
make app              # → dist/EQCompanion.app
open dist/EQCompanion.app
```

The app is ad-hoc signed as it is built, so Gatekeeper allows the copy you built on your own
machine. `make run` builds and launches from source for development.

## Point it at EverQuest

In game, type `/log on` — the app has nothing to read until you do.

On launch it looks for an install with `Logs/eqlog_<Character>_<server>.txt`, checking
`EQ_INSTALL_DIR`, every CrossOver bottle, Whisky bottles, `~/.wine`, and a few plain folders. If it
finds nothing it asks. **Preferences (⌘,) → Game** takes a manual path: the install root, its
`Logs` folder, or a single log file.

Characters appear in the toolbar picker. Switching re-attaches the engine and re-hydrates every
panel. The first attach parses the whole log (about 2 s for a 40 MB log after the first run, which
saves a checkpoint); later launches resume from that checkpoint.

If a panel is empty, read `~/Library/Application Support/EQCompanion/client.log` first — the app
and engine both write their diagnostics there. `make log` tails it.

## Make targets

`make help` lists them all. The ones that matter:

| Target | What |
| --- | --- |
| `make install` | Release build → `/Applications/EQCompanion.app` |
| `make app` | Release build → `dist/EQCompanion.app` |
| `make run` | Build and run from source |
| `make build` / `make build-release` | Debug / release build of every target |
| `make test` | The whole suite |
| `make test-app` | Just the SwiftUI app tests (fast, no goldens needed) |
| `make test-engine` | Just the engine suites (the golden oracles) |
| `make test-one FILTER=…` | One test, class, or suite |
| `make verify` | What CI runs: build, then the full suite |
| `make log` | Tail the client log |
| `make clean` | Remove build products |

### Cutting a release

Write the release's notes into `Sources/EQCompanion/Prefs/ReleaseNotes.swift` first — the app shows
them under **Preferences → What's new**, and the GitHub release body is generated from the same
array, so the two cannot drift apart. Then:

```sh
make draft-notes V=0.3.0              # optional: a first pass from the commit log, via claude -p
make tag V=0.3.0                      # bumps VERSION, commits it, annotated tag v0.3.0
git push upstream main --follow-tags
make release                          # builds, zips, publishes, attaches the app
```

`make tag` refuses a version with no notes, a dirty tree, or a tag that already exists; `make
release` refuses until that tag is on GitHub. `make notes` prints what the body will say.

`make draft-notes` writes a draft into that file from the commits since the last release and stops
there: read it and edit it. Re-roll it with `REDRAFT=1`, steering the next pass if the first one
missed the point — what it replaces is kept under `.build/`:

```sh
make draft-notes V=0.3.0 REDRAFT=1 NOTE="shorter, and lead with the overlay"
```

Nothing in `tag` or `release` calls either one — the notes ship inside the build, so they cannot
depend on a CLI or a network, and the log knows what changed while only a person knows which of it
a player would care about. Drafting needs the `claude` CLI; the tool behind all three targets
(`scripts/relnotes`, Go) needs a Go toolchain, and `make tag` will build it for you.

Released builds are ad-hoc signed rather than notarized, so macOS quarantines a **downloaded**
copy and calls it damaged; every release body carries the one-line `xattr` fix. Building from
source has no such step, because the signature is made on your own machine.

### Developer tools

Developer tools live in the nested `Tools/` package so a bare `swift run` still means the app:
`make tools`, then `make events`, `make snapshots`, `make combat`, `make views`, `make bench` —
each takes `ARGS="…"` (e.g. `make events ARGS="--all --kinds loot"`). `make goldens` re-cuts the
golden corpus; `make exaltations` re-scrapes the item exaltation data from the wiki.

## Architecture

```
EverQuest (CrossOver bottle) ──appends──► eqlog_<Char>_<server>.txt
                                                │
  EQCompanion (one process)                     ▼
    EQLog        the parser: bytes → canonical events
    EQFold       twenty world-model modules + the combat engine
    EQKnowledge  the committed item / mob / quest corpora and name search
    EQEngine     the World: one fold thread per attach (scan, live tail, 1 Hz tick), the view
                 registry, the ops table, persisted state, and the in-process link
    EQCompanionCore  EngineClient: subscriptions, the epoch law, request correlation
    EQCompanion  the SwiftUI app and the floating overlays
    EQData       the committed game knowledge (JSON) and wiki images, as a resource bundle
```

State lives in `~/Library/Application Support/EQCompanion/`: `engine-state/` (the engine's
persisted knowledge), `alerts.json`, `soundpacks/`, and `client.log`.

## Verification

This is a complete Swift port of the [everquest-companion](https://github.com/jmoyers/everquest-companion)
engine, and it is verified against that engine's own recorded output rather than by eye: the parser
is **byte-identical** on all 138 committed fixtures and on a 442k-event real log, every fold module
and the combat engine are **deep-equal**, and all 5,806 recorded op answers match.

Those oracles read `Goldens/` — about 230 MB, git-ignored, cut from a checkout of the upstream Rust
engine by `make goldens`. **The golden suites skip when it is absent**, so `make test` is green on a
bare checkout while proving much less; `make goldens-status` says which situation you are in, and CI
prints its skip count for the same reason. Only `make verify` with `Goldens/` present proves parity.

## Attribution

**This app is a port.** The engine, the data, the fixtures, the alert seeds and every panel's logic
are a Swift translation of [everquest-companion](https://github.com/jmoyers/everquest-companion) by
**Josh Moyers** (Electron + Rust), from upstream commit `fd5e5bb8` (release 1.14.0, August 2026).
The design, the rules the code states, and most of the sentences in the comments are his. Nothing
here is affiliated with or endorsed by upstream.

**The pictures are not ours.** Item icons and raid-boss portraits come from two volunteer-run
EverQuest wikis and are copied into the app at build time, so drawing them never asks either site
for anything: [wiki.project1999.com](https://wiki.project1999.com/) (raid-boss portraits) and
[eqlwiki.com](https://eqlwiki.com/) (item icons, and the item, spell and quest knowledge behind
them). `Sources/EQData/wiki-images/manifest.json` records the source URL, byte length and SHA-256 of
every file shipped. Neither wiki is affiliated with this app.

**Voice packs.** The default alert voice, installed on demand from the
[openpeon](https://github.com/utensils) registry, is
[utensils/openpeon-alan-rickman-soundpack](https://github.com/utensils/openpeon-alan-rickman-soundpack),
licensed CC-BY-4.0. Packs you install carry their own licenses and attribution in each pack's
manifest; none are part of this repository.

EverQuest is a trademark of Daybreak Game Company LLC. This is a fan-made log reader; it is not
affiliated with Daybreak, and it reads only the log file the game writes for you.

## License

FSL-1.1-MIT (Functional Source License, converting to MIT two years after each version's release) —
see [`LICENSE`](LICENSE). Copyright (c) 2026 Josh Moyers; the Swift port is a derivative work
carried under the same terms. Personal use, non-commercial redistribution and modification are
permitted; a competing commercial product is not, until the change date.
