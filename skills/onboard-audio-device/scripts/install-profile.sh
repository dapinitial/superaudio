#!/bin/bash
# SuperAudio © 2026 David Puerto. Proprietary — see LICENSE.md.
#
# Install a drafted device profile into SuperAudio's user-overlay directory so
# the app picks it up on its next session start.
#
# FILESYSTEM DISCLOSURE: this copies one JSON file into
#   ~/Library/Application Support/SuperAudio/Profiles/
# That directory is exactly what DeviceProfileLoader scans (user overlay wins
# over the app's built-in profiles by `id`). Nothing else is touched. Remove
# the file to undo. The app must be (re)started for the new profile to load —
# ProfileStore loads once at launch.
#
# Usage: install-profile.sh <profile.json>

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: install-profile.sh <profile.json>" >&2
  exit 2
fi

SRC="$1"
if [[ ! -f "$SRC" ]]; then
  echo "error: '$SRC' not found" >&2
  exit 2
fi

DEST_DIR="$HOME/Library/Application Support/SuperAudio/Profiles"
mkdir -p "$DEST_DIR"

BASENAME="$(basename "$SRC")"
DEST="$DEST_DIR/$BASENAME"

if [[ -f "$DEST" ]]; then
  echo "note: overwriting existing overlay profile at:" >&2
  echo "      $DEST" >&2
fi

cp "$SRC" "$DEST"
echo "Installed overlay profile:"
echo "  $DEST"
echo
echo "Restart SuperAudio (or stop/start the session) for it to load."
echo "To undo: rm \"$DEST\""
