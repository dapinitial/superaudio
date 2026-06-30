#!/usr/bin/env bash
# SuperAudio © 2026 David Puerto. Proprietary — see LICENSE.md.
#
# Fail if the bundled SPM resource copy of any device profile has drifted from
# the canonical superaudio-device-profiles/profiles/ source. This is the guard
# against gotcha #28: editing a profile without running sync_device_profiles.sh
# silently ships the *stale* resource copy (and the staleness can mask itself if
# the old hint coincidentally still matches). Wired into build_app.sh as a
# pre-step; also becomes the monorepo's CI drift-check once the canonical splits
# into a submodule.
#
# Exit 0 = in sync, 1 = drift (with the exact fix command).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/superaudio-device-profiles/profiles"
DST="$ROOT/Sources/SuperAudioCore/Resources/DeviceProfiles"

drift=0

if [ ! -d "$SRC" ]; then
  echo "✗ canonical profiles missing: $SRC" >&2
  exit 1
fi

for f in "$SRC"/*.json; do
  b="$(basename "$f")"
  if ! diff -q "$f" "$DST/$b" >/dev/null 2>&1; then
    echo "  DRIFT: $b (canonical != bundled resource)"
    drift=1
  fi
done

# Orphans: a bundled resource with no canonical source (a deleted profile that
# was never pruned from the resource dir).
if [ -d "$DST" ]; then
  for f in "$DST"/*.json; do
    [ -e "$f" ] || continue
    b="$(basename "$f")"
    if [ ! -f "$SRC/$b" ]; then
      echo "  ORPHAN: $b in resources has no canonical source"
      drift=1
    fi
  done
fi

if [ "$drift" -ne 0 ]; then
  echo "" >&2
  echo "✗ device-profile drift detected — the build would ship a stale profile." >&2
  echo "  Fix: ./Scripts/sync_device_profiles.sh" >&2
  exit 1
fi

echo "✓ device profiles in sync (canonical == bundled resource)"
