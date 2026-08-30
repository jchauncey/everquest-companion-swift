#!/bin/bash
# Regenerate Goldens/ from the RUST engine — the oracle every Swift port is verified against.
# Needs a checkout of the upstream repo (everquest-companion) with cargo available.
#   scripts/gen-goldens.sh [/path/to/everquest-companion]
# Writes, per fixture: events.ndjson (parser byte-identity), snapshots.json (fold deep-equality),
# views.json + ops.json (engine layer). `_real` covers the owner's live log when present.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
UP="${1:-$HERE/../everquest-companion}"
CARGO="${CARGO:-$HOME/.cargo/bin/cargo}"; [ -x "$CARGO" ] || CARGO=cargo
(cd "$UP/engine" && "$CARGO" build --release -p parity -p engined)
PARITY="$UP/engine/target/release/parity"; ENGINED="$UP/engine/target/release/engined"
STAGE="$(mktemp -d)"
n=0
for f in "$HERE"/Resources/fixtures/*.log; do
  b="$(basename "$f" .log)"; s="$STAGE/eqlog_Primitive_freeport.$b.txt"; cp "$f" "$s"
  mkdir -p "$HERE/Goldens/$b"
  "$PARITY" "$s" --tz America/Los_Angeles > "$HERE/Goldens/$b/events.ndjson" 2>/dev/null
  "$PARITY" "$s" --snapshots --tz America/Los_Angeles > "$HERE/Goldens/$b/snapshots.json" 2>/dev/null
  n=$((n+1))
done
echo "parser + fold goldens for $n fixtures"
TZ=America/Los_Angeles python3 "$HERE/scripts/gen-engine-goldens.py" "$ENGINED" "$HERE/Resources/fixtures" "$HERE/Goldens"
REAL="$HOME/Library/Application Support/CrossOver/Bottles/EverQuest/drive_c/users/Public/Daybreak Game Company/Installed Games/EverQuest Legends/Logs/eqlog_Zoddrick_oggok.txt"
if [ -f "$REAL" ]; then
  cp "$REAL" "$STAGE/eqlog_Zoddrick_oggok.real.txt"; mkdir -p "$HERE/Goldens/_real"
  "$PARITY" "$STAGE/eqlog_Zoddrick_oggok.real.txt" --tz America/New_York > "$HERE/Goldens/_real/events.ndjson"
  "$PARITY" "$STAGE/eqlog_Zoddrick_oggok.real.txt" --snapshots --tz America/New_York > "$HERE/Goldens/_real/snapshots.json"
  echo "real-log goldens written (America/New_York)"
fi
rm -r "$STAGE"
