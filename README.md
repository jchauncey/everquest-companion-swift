# EQ Companion for macOS

A native macOS companion for **EverQuest Legends**. It reads the log file the game already writes
and turns it into live views: a DPS meter and floating overlay, loot and gear planning, maps, buffs
and timers, leveling, raid targets, the Plane of Sky tracker, and alerts with voice packs.

**It only reads your log.** Nothing is injected, no game file is modified, nothing is automated.
One app process — no child process, no socket, no Electron.

![The Overview tab](docs/overview.jpg)

## Getting started

```sh
git clone https://github.com/jchauncey/everquest-companion-swift.git
cd everquest-companion-swift
make install          # builds a release app and copies it to /Applications
```

Then type `/log on` in game. The app finds your EverQuest install and its logs by itself; if it
cannot, point it there under **Preferences → Game**. The details, and what to do when a panel is
empty, are in [Installing](docs/installation.md).

## Documentation

- [Installing](docs/installation.md) — requirements, install, pointing the app at your logs.
- [The screens](docs/README.md) — what each tab shows and how to read it:
  [Overview](docs/overview.md), [Combat](docs/combat.md), [Leveling](docs/leveling.md),
  [Motes](docs/motes.md), [Gear](docs/gear.md).
- [Building and developing](docs/building.md) — make targets, releases, developer tools, the
  architecture, and how the port is verified against the original engine.

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
