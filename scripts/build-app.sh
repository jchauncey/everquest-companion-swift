#!/bin/bash
# Build EQCompanion.app: the Swift app (release) with its data bundle, the icon, and an ad-hoc
# signature so Gatekeeper on THIS machine lets it run. Self-contained: no Rust, no child process.
# Usage: scripts/build-app.sh [--debug]
#
# Output: dist/EQCompanion.app
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG=release
for arg in "$@"; do
  case "$arg" in
    --debug) CONFIG=debug ;;
    *) echo "unknown argument: $arg (usage: scripts/build-app.sh [--debug])" >&2; exit 2 ;;
  esac
done

echo "==> swift build -c $CONFIG"
(cd "$HERE" && swift build -c "$CONFIG" --product EQCompanion)
BIN="$HERE/.build/$CONFIG/EQCompanion"
[ -x "$BIN" ] || { echo "swift binary missing at $BIN" >&2; exit 1; }

[ -s "$HERE/VERSION" ] || { echo "VERSION is missing or empty — refusing to stamp a guess" >&2; exit 1; }
VERSION="$(cat "$HERE/VERSION")"
DIST="$HERE/dist"
APP="$DIST/EQCompanion.app"
echo "==> assembling $APP (version $VERSION)"
mkdir -p "$DIST"
if [ -d "$APP" ]; then rm -r "$APP"; fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/EQCompanion"

# The committed game knowledge and wiki images travel as SwiftPM resource bundles: every target's,
# so a target that gains resources is packaged rather than crashing at `Bundle.module`.
shopt -s nullglob
BUNDLES=("$HERE/.build/$CONFIG"/EQCompanion_*.bundle)
shopt -u nullglob
[ ${#BUNDLES[@]} -gt 0 ] || { echo "no resource bundles in .build/$CONFIG" >&2; exit 1; }
for b in "${BUNDLES[@]}"; do cp -R "$b" "$APP/Contents/Resources/"; done

# Icon: the repo's 256px PNG, scaled into an .icns.
ICONSET="$DIST/AppIcon.iconset"
if [ -d "$ICONSET" ]; then rm -r "$ICONSET"; fi
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size "$HERE/Resources/icon.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
done
sips -z 64 64 "$HERE/Resources/icon.png" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
cp "$ICONSET/icon_32x32.png"   "$ICONSET/icon_16x16@2x.png"
cp "$ICONSET/icon_256x256.png" "$ICONSET/icon_128x128@2x.png"
cp "$ICONSET/icon_512x512.png" "$ICONSET/icon_256x256@2x.png"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -r "$ICONSET"

sed -e "s/__VERSION__/$VERSION/g" "$HERE/Resources/Info.plist" > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> codesign (ad hoc)"
codesign --force --sign - --entitlements "$HERE/Resources/EQCompanion.entitlements" "$APP"
codesign --verify --deep --strict "$APP" && echo "signature ok"

echo "==> done: $APP"
echo "    open \"$APP\""
