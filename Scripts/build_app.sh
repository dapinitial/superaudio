#!/bin/bash
# SuperAudio © 2026 David Puerto. Proprietary — see LICENSE.md.
#
# Wraps the SPM-built SuperAudioApp executable in a proper macOS .app bundle
# so the menu bar item renders correctly and process-tap entitlements apply.
# SPM doesn't natively produce .app bundles; this script is the bridge.
#
# Usage:
#   ./Scripts/build_app.sh                # debug build → SuperAudio.app at repo root
#   CONFIG=release ./Scripts/build_app.sh # release build
#
# After build, launch with:  open SuperAudio.app

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIG="${CONFIG:-debug}"
APP="SuperAudio.app"
BIN_NAME="SuperAudio"
BUNDLE_ID="com.davidpuerto.SuperAudio"

echo "==> Checking device-profile sync (gotcha #28)"
"$ROOT/Scripts/check_profile_drift.sh"

echo "==> Building $BIN_NAME ($CONFIG)"
swift build -c "$CONFIG"

BIN_DIR="$(swift build --show-bin-path -c "$CONFIG")"
BIN_PATH="$BIN_DIR/$BIN_NAME"

if [ ! -f "$BIN_PATH" ]; then
    echo "Error: $BIN_PATH not found after build" >&2
    exit 1
fi

echo "==> Assembling $APP from $BIN_PATH"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp "$BIN_PATH" "$APP/Contents/MacOS/$BIN_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Optional but good practice — touch the bundle so LaunchServices re-reads it
touch "$APP"

echo "==> Ad-hoc signing with entitlements"
codesign --sign - \
    --force \
    --timestamp=none \
    --entitlements Resources/SuperAudio.entitlements \
    --identifier "$BUNDLE_ID" \
    "$APP"

echo ""
echo "Built $APP — launch with:"
echo "    open $APP"
echo ""
echo "Tail logs with:"
echo "    /usr/bin/log stream --predicate 'subsystem == \"$BUNDLE_ID\"' --level info"
