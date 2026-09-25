# Building and developing

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

## Cutting a release

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

`make release` publishes as whichever account `gh` is logged in as — unless `PERSONAL_GITHUB_TOKEN`
is exported, in which case that token is handed to `gh` for the release calls alone, ahead of any
`GITHUB_TOKEN` in the shell (useful when the shell's token belongs to another org).

Nothing in `tag` or `release` calls either one — the notes ship inside the build, so they cannot
depend on a CLI or a network, and the log knows what changed while only a person knows which of it
a player would care about. Drafting needs the `claude` CLI; the tool behind all three targets
(`scripts/relnotes`, Go) needs a Go toolchain, and `make tag` will build it for you.

Released builds are ad-hoc signed rather than notarized, so macOS quarantines a **downloaded**
copy and calls it damaged; every release body carries the one-line `xattr` fix. Building from
source has no such step, because the signature is made on your own machine.

## Developer tools

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

Some of what the app shows goes beyond the port — per-fight digests and replays, rewards and pet
detail on the Combat tab, pets inferred from your heals. Each is marked `NOT A PORT` at the top of
its file, is off in the parity oracles, and changes no golden.
