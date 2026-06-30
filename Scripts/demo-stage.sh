#!/bin/bash
# SuperAudio © 2026 David Puerto. Proprietary — see LICENSE.md.
#
# Demo staging for the M6.5 /onboard-audio-device <90s before/after recording.
#
# The A5 now ships a committed, portable profile (matches via am=A5), so to film
# "onboarding an UNKNOWN speaker" we temporarily suppress its match. We do that
# with a NON-matching OVERLAY profile: the user-overlay dir overrides the bundled
# seed by `id`, so an overlay with id 'bowers-wilkins-a5' and a hint that can't
# match the A5's discovery text ('Spacelab Audio A5') makes the app log
# 'no profile — built-in defaults'. No rebuild needed — overlay + relaunch only,
# so you can stage/re-take without the gotcha-#12 TCC re-prompt.
#
#   before : install the suppression overlay  -> A5 shows 'no profile'
#   reset  : remove any overlay               -> A5 matches via the bundled seed
#
# Between `before` and `reset`, run /onboard-audio-device for real — it overwrites
# the overlay at the same path with a genuine am=A5-keyed draft, and the A5 flips
# to 'matched'. That step is the actual demo; this script only stages around it.
#
# Usage: Scripts/demo-stage.sh before|reset

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/SuperAudio.app"
OVERLAY_DIR="$HOME/Library/Application Support/SuperAudio/Profiles"
OVERLAY="$OVERLAY_DIR/bowers-wilkins-a5.json"

relaunch() {
  pkill -f "SuperAudio.app/Contents/MacOS/SuperAudio" 2>/dev/null || true
  sleep 1
  open "$APP"
  sleep 2
  pgrep -f "SuperAudio.app/Contents/MacOS" | grep -qv "log stream" \
    && echo "  app relaunched (fresh ProfileStore cache)"
}

case "${1:-}" in
  before)
    mkdir -p "$OVERLAY_DIR"
    # Valid profile (so it LOADS and overrides the bundle) but with a hint that
    # cannot substring-match 'Spacelab Audio A5' -> A5 resolves to no profile.
    cat > "$OVERLAY" <<'JSON'
{
  "schemaVersion": 1,
  "id": "bowers-wilkins-a5",
  "displayName": "Bowers & Wilkins A5",
  "manufacturer": "Bowers & Wilkins",
  "model": "A5",
  "firstRelease": 2010,
  "lastFirmware": null,
  "match": {
    "bonjourServiceType": "_raop._tcp",
    "modelHints": ["zzDEMO-unknown-device-zz"],
    "macOUI": []
  },
  "roles": {
    "sink": {
      "protocol": "airplay1",
      "codec": { "format": "alac", "sampleRate": 44100, "bitDepth": 16, "channels": 2, "compressed": true },
      "encryption": { "et": 0, "fallback": "et=1" },
      "audioLatencyMs": 93,
      "volumeScale": { "type": "dB", "min": -30.0, "max": 0.0, "muted": -144.0 },
      "knownFirmware": []
    },
    "control": null
  },
  "verifiedBy": [],
  "verifiedDate": null,
  "contributedDate": "2026-06-29",
  "notes": "DEMO STAGING ONLY — suppression overlay so the A5 reads as unknown for the onboarding recording. Replaced by the real draft when /onboard-audio-device runs. Delete via Scripts/demo-stage.sh reset."
}
JSON
    echo "BEFORE staged: suppression overlay written to:"
    echo "  $OVERLAY"
    relaunch
    echo "Now play the A5 -> it should log: ProfileStore: no profile for sink 'Spacelab Audio' — built-in defaults"
    ;;
  reset)
    if [[ -f "$OVERLAY" ]]; then
      rm -f "$OVERLAY"
      echo "RESET: removed overlay $OVERLAY"
    else
      echo "RESET: no overlay present (already clean)"
    fi
    relaunch
    echo "A5 now matches via the bundled seed (am=A5)."
    ;;
  *)
    echo "usage: $(basename "$0") before|reset" >&2
    exit 2
    ;;
esac
