# Building EQ Companion from source

Most people should download a release instead: see [Installing](docs/installation.md). Build from
source to run unreleased changes or to work on the app. Cutting a release is in
[RELEASE.md](RELEASE.md).

## Requirements

- macOS 14+
- Xcode 16+ (Swift 6 toolchain) — check with `swift --version`
- Git, and a network connection for the first build (SwiftPM downloads
  [Sparkle](https://sparkle-project.org), the updater, the app's one outside dependency)

## Build and run

```sh
git clone https://github.com/jchauncey/everquest-companion-swift.git
cd everquest-companion-swift

make install          # release build, copied to /Applications/EQCompanion.app
```

Or keep it out of `/Applications`:

```sh
make app              # release build → dist/EQCompanion.app
open dist/EQCompanion.app

make run              # build and launch straight from source (debug; no app bundle)
```

The first release build takes a few minutes; later ones are incremental. A copy you build is
ad-hoc signed on your own machine, so Gatekeeper opens it without the quarantine step a downloaded
release needs.

### What `make app` produces

`scripts/build-app.sh` compiles the release binary and assembles `dist/EQCompanion.app` around it:

- the binary and every SwiftPM resource bundle (the committed game data and wiki images),
- the icon, built from `Resources/icon.png`,
- `Sparkle.framework` in `Contents/Frameworks`,
- `Info.plist` stamped with the version from `VERSION` and the update key from
  `Resources/sparkle-public-key.txt`,
- an ad-hoc signature, framework first and then the app.

A build made without `Resources/sparkle-public-key.txt` has no updater — Preferences → Updates says
so — and is otherwise identical.

## Make targets

`make help` lists them all. The ones for building and testing:

| Target | What |
| --- | --- |
| `make install` | Release build → `/Applications/EQCompanion.app` |
| `make app` | Release build → `dist/EQCompanion.app` |
| `make app-debug` | The same bundle from a debug build |
| `make run` | Build and run from source |
| `make build` / `make build-release` | Debug / release build of every target |
| `make test` | The whole suite (~5 minutes with goldens present) |
| `make test-app` | Just the SwiftUI app tests (fast, no goldens needed) |
| `make test-engine` | Just the engine suites (the golden oracles) |
| `make test-one FILTER=…` | One test, class, or suite |
| `make verify` | What CI runs: build, then the full suite |
| `make log` | Tail the client log |
| `make clean` | Remove build products |

## Testing and the goldens

This is a Swift port of the [everquest-companion](https://github.com/jmoyers/everquest-companion)
engine, and it is verified against that engine's own recorded output rather than by eye: the parser
is **byte-identical** on all 138 committed fixtures and on a 442k-event real log, every fold module
and the combat engine are **deep-equal**, and all 5,806 recorded op answers match.

Those oracles read `Goldens/` — about 230 MB, git-ignored. `make goldens-unpack` unpacks the
fixtures' goldens from `ci/goldens.tar.xz` (what CI does); `make goldens` re-cuts the whole corpus
from a checkout of the upstream Rust engine (needs `cargo`). **The golden suites skip when
`Goldens/` is absent**, so `make test` is green on a bare checkout while proving much less;
`make goldens-status` says which situation you are in.

Some of what the app shows goes beyond the port — per-fight digests and replays, rewards and pet
detail on the Combat tab, pets inferred from your heals, the updater. Each is marked `NOT A PORT`
at the top of its file, is off in the parity oracles, and changes no golden.

## Developer tools

The tools live in the nested `Tools/` package, so a bare `swift run` still means the app:
`make tools`, then `make events`, `make snapshots`, `make combat`, `make views`, `make bench` —
each takes `ARGS="…"` (e.g. `make events ARGS="--all --kinds loot"`). `make exaltations`
re-scrapes the item exaltation data from the wiki.

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
    Sparkle      the updater (the one outside dependency): reads the release appcast
    EQData       the committed game knowledge (JSON) and wiki images, as a resource bundle
```

State lives in `~/Library/Application Support/EQCompanion/`: `engine-state/` (the engine's
persisted knowledge), `alerts.json`, `soundpacks/`, and `client.log`.

## When a build goes wrong

- **A build seems to hang.** SwiftPM locks `.build`, so a second `swift build` in another terminal
  waits for the first. Run one build at a time.
- **The tools cannot find a type that exists** (`cannot find 'AppUpdater' in scope`, say). The
  `Tools/` package caches the root package's file list and can miss files added since. Delete
  `Tools/.build` and build again.
- **`Sparkle.framework missing`.** The dependency has not been fetched: `swift package resolve`.
