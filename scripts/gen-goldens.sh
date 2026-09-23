#!/bin/bash
# Regenerate Goldens/ from the RUST engine — the oracle every Swift port is verified against.
# Needs a checkout of the upstream repo (everquest-companion) with cargo available.
#   scripts/gen-goldens.sh [/path/to/everquest-companion]
# Writes, per fixture: events.ndjson (parser byte-identity), snapshots.json (fold deep-equality),
# views.json + ops.json (engine layer). `_real` covers the owner's live log when present.
#
# Everything is cut into Goldens.new/ and swapped in only when every step succeeded, so an
# interrupted or failing run leaves the previous Goldens/ whole rather than half one engine's and
# half another's. Goldens/UPSTREAM records the upstream commit the set was cut from.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
UP="${1:-$HERE/../everquest-companion}"
CARGO="${CARGO:-$HOME/.cargo/bin/cargo}"; [ -x "$CARGO" ] || CARGO=cargo
(cd "$UP/engine" && "$CARGO" build --release -p parity -p engined)
PARITY="$UP/engine/target/release/parity"; ENGINED="$UP/engine/target/release/engined"

OUT="$HERE/Goldens.new"
STAGE="$(mktemp -d)"
cleanup() { rm -rf "$STAGE"; [ "${DONE:-0}" = 1 ] || rm -rf "$OUT"; }
trap cleanup EXIT
rm -rf "$OUT"; mkdir -p "$OUT" "$STAGE/err"

# One parity run; on failure, name the fixture and show what the engine said.
parity() {
  local name="$1"; shift
  if ! "$PARITY" "$@" 2>>"$STAGE/err/$name.log"; then
    echo "parity failed on $name:" >&2
    tail -20 "$STAGE/err/$name.log" >&2
    exit 1
  fi
}

n=0
for f in "$HERE"/Resources/fixtures/*.log; do
  b="$(basename "$f" .log)"; s="$STAGE/eqlog_Primitive_freeport.$b.txt"; cp "$f" "$s"
  mkdir -p "$OUT/$b"
  parity "$b" "$s" --tz America/Los_Angeles > "$OUT/$b/events.ndjson"
  parity "$b" "$s" --snapshots --tz America/Los_Angeles > "$OUT/$b/snapshots.json"
  n=$((n+1))
done
echo "parser + fold goldens for $n fixtures"
TZ=America/Los_Angeles python3 "$HERE/scripts/gen-engine-goldens.py" "$ENGINED" "$HERE/Resources/fixtures" "$OUT"

REAL="$HOME/Library/Application Support/CrossOver/Bottles/EverQuest/drive_c/users/Public/Daybreak Game Company/Installed Games/EverQuest Legends/Logs/eqlog_Zoddrick_oggok.txt"
if [ -f "$REAL" ]; then
  cp "$REAL" "$STAGE/eqlog_Zoddrick_oggok.real.txt"; mkdir -p "$OUT/_real"
  parity _real "$STAGE/eqlog_Zoddrick_oggok.real.txt" --tz America/New_York > "$OUT/_real/events.ndjson"
  parity _real "$STAGE/eqlog_Zoddrick_oggok.real.txt" --snapshots --tz America/New_York > "$OUT/_real/snapshots.json"
  echo "real-log goldens written (America/New_York)"
else
  echo "no real log at the CrossOver path: this set has no _real" >&2
fi

{
  echo "commit $(git -C "$UP" rev-parse HEAD)"
  if [ -n "$(git -C "$UP" status --porcelain)" ]; then echo "dirty: yes"; else echo "dirty: no"; fi
  echo "cut $(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$OUT/UPSTREAM"

# The swap: the old set goes only once the new one is complete.
if [ -d "$HERE/Goldens" ]; then mv "$HERE/Goldens" "$STAGE/Goldens.old"; fi
mv "$OUT" "$HERE/Goldens"
DONE=1
echo "Goldens/ replaced — upstream $(head -1 "$HERE/Goldens/UPSTREAM")"

# CI's copy of the fixture goldens follows the new set (the Makefile target keeps _real out).
make -C "$HERE" goldens-pack
