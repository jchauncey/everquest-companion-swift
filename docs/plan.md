# What's left — pick-up list

State: the whole engine and app are Swift (no Rust at build or run time), verified against the Rust
engine's goldens (parser byte-identical on 138 fixtures + a real log; all 20 fold modules and the
combat engine deep-equal; 5,806 op answers identical); `make app` produces a self-contained
`dist/EQCompanion.app`; Preferences has all fifteen pages. Items are in rough priority order.

## 1. Visual QA pass
The tabs and overlays have been used against a live game and their worst layout bugs fixed (gear
and loot tables, map pane, dropdown pickers, the overlay lock). What has NOT happened is a
systematic pass: open every tab and every Preferences page in turn and fix what looks wrong.
- Overlays: meter, toasts, banner and con card are `NSPanel`s. Check auto-hide (default ON — the
  meter only shows while the game runs), "Move it", opacity.
- Cursor ring over the CrossOver window; the menu-bar item; the HUD text in the title bar.

## 2. Fold performance
- `eqbench <log> --fold` times parser + fold together. On the real log as of 2026-09-23 (92 MB,
  1.14M events, release): 29.7 s → 11.3 s after the typed payload keeping Strings, the rank-tail
  regex replaced by a byte check, the buffs hygiene sweep's quiet-until cache, parse-without-JSON
  for the fold, the pthread bridge cache and the landing-shape memo. Parse alone is ~5.5 s of it.
- What the profile shows next (`sample` on `eqbench --fold`): the combat engine (~25%, spread over
  classify/route/ingestDamage), `Parser.classify`'s regex cascade, Resist, and `reapOrphanedOpen`
  (runs every event). The roster rebuild and `JSMap.remove` measured at ~1% and were left alone.

## 3. Preferences — honest gaps the workers reported
- Overlay meter still draws its own inline alert line; with the alert banner on, both show the
  same alert. Decide which wins (upstream: the banner).
- Toasts instantiate a private `SkyStore`; share `PlaneOfSkyView`'s once one exists app-wide.
- Cursor ring shows whenever the game is frontmost; upstream also parks it when the cursor is
  hidden or the window bounds are unknown. If it freezes while EQ grabs the pointer, add a
  display-linked `NSEvent.mouseLocation` poll.
- Import: UI prefs (favorites, class filter, count source) land on the next launch because their
  stores read at construction. Alert dedupe uses a behaviour fingerprint, not upstream's
  `alertBehaviorKey` bytes. The missing-sound-pack notice on import is not ported.
- Resist evidence switch left out — nothing in the app shows a resist estimate yet. Port the
  resist estimator / mob resist card first, then the switch.
- Banner/con-card duration lists are narrower than upstream's (2/4/6/8/10 vs 2/3/4/6/8/10/15;
  con card 2/3/5/8/12 vs 3…60 + "until I close it").
- Voice: only macOS voices; upstream's Kokoro natural-voice engine has no macOS implementation.
- Updates: no release feed. The repo is now public — add "check for updates" against its releases
  API (no auto-install; reveal the download).
- `Prefs.overlayIndependent` per-overlay values exist for ids meter/toast/banner/conCard only.

## 4. Upstream features not carried (see README "Not (yet) here")
- Wiki fetch on `knowledgeMiss` (the app currently shows the miss and stops).
- `/outputfile achievements` inference; the `rebaseline` inventory count source.
- Chart drag/hover interactions on the combat and leveling charts.
- `app:` alert triggers (bossDefeat / questComplete) — never fire in either engine.
- Telemetry / feedback upload — deliberately not.

## 5. Engineering hygiene
- `Tests/EQCompanionTests` has no UI snapshot tests; consider a few `ImageRenderer` checks for
  the overlay views (the cursor-ring test already does one pixel check).
- `scripts/gen-goldens.sh` needs the upstream checkout at `../everquest-companion`; it now records
  the upstream commit in `Goldens/UPSTREAM` (the current set predates that: `fd5e5bb8`) and
  refreshes `ci/goldens.tar.xz`. It still calls `gen-engine-goldens.py`; that and
  `gen-exaltations.py` should be ported to Go beside `scripts/relnotes` (no Python here).
- The `_real` goldens are the owner's own log — never commit them (`Goldens/` is ignored, and
  `make goldens-pack` refuses an archive with `_real` in it).
- Distribution: the bundle is ad-hoc signed and arm64-only while `LSMinimumSystemVersion` 14
  admits Intel Macs. Either build universal or say "Apple silicon only". For anyone else's Mac:
  Developer ID signing, hardened runtime + notarization, and a DMG target in `build-app.sh`.
- `AppModel` still carries the pre-Prefs overlay keys (`eq.overlay.visible/locked/scope`); fold
  them into `Prefs` when touching the overlay next.
- The banner, con card and toasts repeat the same panel/timer/hover/apply scaffolding; one
  `TimedStrip` in OverlayHost would stop fixes to one drifting from the others.
- Strict concurrency is off everywhere; EQCompanionCore and EQFold have no `@unchecked Sendable`
  and would be the cheap first targets.

## 6. Nice to have
- A "What's new" badge on the nav when `ReleaseNotes` is newer than `seenReleaseNotesVersion`.
- Startup timeline: add "· N log events replayed" (pass `health.events` at the replay mark).
- Search-preferences: jump to the matched card, not just the page.
