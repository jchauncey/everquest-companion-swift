# Cutting a release

A release is a GitHub release carrying two files: the app, zipped, and `appcast.xml`, the signed
feed that installed copies read to update themselves. The notes are written once, in the app's own
source, and appear in three places — the app's **Preferences → What's new**, the GitHub release
page, and Sparkle's update window.

Building from source is in [BUILD.md](BUILD.md).

## What you need

- A clone with push access to `jchauncey/everquest-companion-swift` (the remote named `upstream`)
- The [GitHub CLI](https://cli.github.com), logged in: `gh auth status`
- A Go toolchain — `make` builds the notes tool (`scripts/relnotes`) with it
- Optional: the `claude` CLI, for `make draft-notes`
- **The update-signing key** in your login Keychain (below)

## Once per release machine: the update-signing key

Every build embeds the public half of an EdDSA key (`Resources/sparkle-public-key.txt`, committed),
and an installed copy accepts an update only if it was signed with the matching private half.

```sh
make sparkle-key
```

creates the pair — or, if your Keychain already holds one, reads it — and writes the public half to
`Resources/sparkle-public-key.txt`. Commit that file if it changed.

**Back up the private key** as soon as it exists, somewhere safe and outside the repository:

```sh
.build/artifacts/sparkle/Sparkle/bin/generate_keys -x ~/sparkle-private-key
```

If it is lost, no installed copy can ever accept another update. To release from a second machine,
import the backup there instead of making a new key:

```sh
.build/artifacts/sparkle/Sparkle/bin/generate_keys -f ~/sparkle-private-key
```

## The release

### 1. Write the notes

Add the release's entry to `Sources/EQCompanion/Prefs/ReleaseNotes.swift` — the voice rules are at
the top of that file. For a first draft from the commits since the last release:

```sh
make draft-notes V=1.2.0
```

It writes the draft into that file and stops: read it and edit it. Re-roll it with `REDRAFT=1`,
steering the next pass if the first one missed the point (what it replaces is kept under `.build/`):

```sh
make draft-notes V=1.2.0 REDRAFT=1 NOTE="shorter, and lead with the overlay"
```

`make notes` prints what the release body will say. Commit the notes.

### 2. Check it

```sh
make verify          # build and the full suite; with Goldens/ present it proves parity
```

CI runs the same thing on every push, but only a local run covers the real log.

### 3. Tag

```sh
make tag V=1.2.0
git push upstream main --follow-tags
```

`make tag` writes `VERSION`, commits it as "Release 1.2.0", and makes the annotated tag `v1.2.0`
with the notes as its message. It refuses a version with no notes, a dirty tree, or a tag that
already exists.

### 4. Publish

```sh
make release
```

This:

1. checks the tag is on GitHub, that `HEAD` is the tag, and that the tree is clean — the zip is
   built from the working tree, so it has to *be* the tag;
2. refuses if there is no update key;
3. builds the app (`make app`) and zips it to `dist/EQCompanion-1.2.0.zip`;
4. runs `make appcast`: Sparkle's `generate_appcast` signs the zip with the key in your Keychain
   and writes `dist/appcast.xml`, with the notes embedded (macOS may ask to allow Keychain access);
5. creates the GitHub release `v1.2.0` with both files attached, and the notes plus the
   quarantine-fix note (`scripts/release-install-note.md`) as its body.

Installed copies read `releases/latest/download/appcast.xml`, so once the release is published they
see the update on their next check.

If `gh` answers 403, the token it used cannot write this repository — common when the shell's
`GITHUB_TOKEN` belongs to another org. Export `PERSONAL_GITHUB_TOKEN` (a token for the account that
owns the repo) and run `make release` again; it is handed to `gh` for the release calls alone.

## After publishing

- **Check the update arrives.** On a copy of the previous release, choose **EQ Companion → Check
  for Updates…**: it should offer the new version with its notes, install it, and relaunch.
- **A downloaded copy is quarantined.** Releases are ad-hoc signed, not notarized, so a copy
  downloaded from the release page is called "damaged" until the `xattr` line in the release notes
  clears it. An update the app installs itself should not be quarantined — confirm that with the
  check above on the first release that updates an earlier one.

## Numbering

`MAJOR.MINOR.PATCH`. Sparkle compares versions, so every release must be higher than the last —
`make tag` refuses to reuse a tag, but it will not stop a lower number.
