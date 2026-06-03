#!/usr/bin/env bash
# Sync canonical device profiles → SPM resource directory.
#
# Canonical source (eventually a separate public MIT-licensed repo):
#   superaudio-device-profiles/profiles/*.json
#
# SPM resource destination (bundled into SuperAudioCore at build time):
#   Sources/SuperAudioCore/Resources/DeviceProfiles/*.json
#
# Run this whenever profiles change. The build doesn't auto-sync because
# the canonical repo will eventually live elsewhere.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/superaudio-device-profiles/profiles"
DST="$ROOT/Sources/SuperAudioCore/Resources/DeviceProfiles"

if [ ! -d "$SRC" ]; then
  echo "✗ Canonical profile directory missing: $SRC"
  exit 1
fi

mkdir -p "$DST"

# Mirror src → dst. Use rsync if available for cleanest delete-on-missing behavior,
# else fall back to cp + manual prune.
if command -v rsync >/dev/null 2>&1; then
  rsync -a --delete --include='*.json' --exclude='*' "$SRC/" "$DST/"
else
  rm -f "$DST"/*.json
  cp -f "$SRC"/*.json "$DST/"
fi

count=$(find "$DST" -name '*.json' | wc -l | tr -d ' ')
echo "✓ synced $count device profile(s) to $DST"
