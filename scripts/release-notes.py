#!/usr/bin/env python3
# Emit one release's notes as Markdown, read from the app's own committed notes
# (Sources/EQCompanion/Prefs/ReleaseNotes.swift).
#
# ONE SOURCE. The app shows these under Preferences -> What's new while offline, and the GitHub
# release body is generated from the same array, so the two can never drift apart. Writing the
# notes is a human job (the voice rules are in that file's header); this only reformats them.
#
# Usage: scripts/release-notes.py <version>          # e.g. 0.3.0
#        scripts/release-notes.py --list             # versions the notes carry
# Exits non-zero when the version has no notes, which is what makes `make tag` refuse to tag a
# release nobody has written notes for.
import re
import sys
import os

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NOTES = os.path.join(HERE, "Sources/EQCompanion/Prefs/ReleaseNotes.swift")

KIND_LABEL = {"new": "New", "fixed": "Fixed", "changed": "Changed"}
KIND_ORDER = ["new", "fixed", "changed"]


def parse():
    """Every release in the file, newest first: [(version, date, [(kind, text)])]."""
    src = open(NOTES, encoding="utf-8").read()
    out = []
    # Each `ReleaseNote(version: "x", date: "y", entries: [ ... ])` block. The entries run to the
    # closing `])`, which the generated file always puts on its own line.
    for m in re.finditer(
        r'ReleaseNote\(version:\s*"([^"]+)",\s*date:\s*"([^"]+)",\s*entries:\s*\[(.*?)\n\s*\]\)',
        src,
        re.S,
    ):
        version, date, body = m.group(1), m.group(2), m.group(3)
        entries = []
        # `ReleaseEntry(.new, "text")` — the text may contain escaped quotes.
        for e in re.finditer(r'ReleaseEntry\(\.(\w+),\s*"((?:[^"\\]|\\.)*)"\s*\)', body):
            text = e.group(2).replace('\\"', '"').replace("\\\\", "\\")
            entries.append((e.group(1), text))
        out.append((version, date, entries))
    return out


def markdown(version):
    for v, date, entries in parse():
        if v != version:
            continue
        lines = [f"_{date}_", ""]
        for kind in KIND_ORDER:
            rows = [t for k, t in entries if k == kind]
            if not rows:
                continue
            lines.append(f"### {KIND_LABEL.get(kind, kind.title())}")
            lines += [f"- {t}" for t in rows]
            lines.append("")
        return "\n".join(lines).rstrip() + "\n"
    return None


def main():
    if len(sys.argv) != 2:
        print(__doc__ or "usage: release-notes.py <version>|--list", file=sys.stderr)
        return 2
    if sys.argv[1] == "--list":
        for v, date, entries in parse():
            print(f"{v}\t{date}\t{len(entries)} entries")
        return 0
    md = markdown(sys.argv[1])
    if md is None:
        have = ", ".join(v for v, _, _ in parse())
        print(
            f"no release notes for {sys.argv[1]} in {os.path.relpath(NOTES, HERE)}\n"
            f"  the file carries: {have}\n"
            f"  add a ReleaseNote for {sys.argv[1]} before tagging it.",
            file=sys.stderr,
        )
        return 1
    sys.stdout.write(md)
    return 0


if __name__ == "__main__":
    sys.exit(main())
