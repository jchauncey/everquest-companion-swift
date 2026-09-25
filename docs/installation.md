# Installing EQ Companion

## Requirements

- macOS 14+
- Xcode 16+ / Swift 6 toolchain (`swift --version`) to build it
- EverQuest Legends running under CrossOver, Whisky, or Wine

## Install

Build it and copy it into `/Applications`:

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

### A downloaded release

Released builds are ad-hoc signed rather than notarized, so macOS quarantines a **downloaded** copy
and calls it damaged. Every release's notes carry the one-line `xattr` command that clears it.
Building from source has no such step.

## Point it at EverQuest

In game, type `/log on` — the app has nothing to read until you do.

On launch it looks for an install with `Logs/eqlog_<Character>_<server>.txt`, checking
`EQ_INSTALL_DIR`, every CrossOver bottle, Whisky bottles, `~/.wine`, and a few plain folders. If it
finds nothing it asks. **Preferences (⌘,) → Game** takes a manual path: the install root, its
`Logs` folder, or a single log file.

Characters appear in the toolbar picker. Switching re-attaches the engine and re-hydrates every
panel. The first attach parses the whole log (about 2 s for a 40 MB log after the first run, which
saves a checkpoint); later launches resume from that checkpoint. After an update that changes how
the log is read, the first launch reads the whole log once more.

### Getting more out of the log

- **`/outputfile inventory`** writes your bags and equipment to a file the app reads. The Gear tab's
  *Owned* column and the Character sheet come from the newest one — run it again after you change
  gear.
- **`/who`** (on yourself) tells the app your class loadout and level straight away, instead of
  waiting for enough casts to infer them.

## When something looks empty

Read `~/Library/Application Support/EQCompanion/client.log` first — the app and engine both write
their diagnostics there. `make log` tails it.

Everything the app keeps lives in `~/Library/Application Support/EQCompanion/`: `engine-state/`
(the engine's saved world), `alerts.json`, `soundpacks/`, and `client.log`.
