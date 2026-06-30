#!/bin/bash
# SuperAudio © 2026 David Puerto. Proprietary — see LICENSE.md.
#
# Submit a drafted profile as a PR to the public superaudio-device-profiles repo.
#
# EXTERNAL-SERVICE DISCLOSURE: this pushes a branch to GitHub and opens a public
# pull request via the `gh` CLI. The profile content becomes public. Run only
# after the user has reviewed the drafted JSON and explicitly confirmed.
#
# The public repo is LIVE (dapinitial/superaudio-device-profiles). PR submission
# is a deliberate opt-in so the Skill never surprise-pushes: it refuses unless
#   SUPERAUDIO_ENABLE_PR=1
# is set after the user reviews the drafted JSON and confirms. The target repo
# defaults to the live repo; override with SUPERAUDIO_PROFILES_REPO if needed.
#
# Usage: open-pr.sh <profile.json>

set -euo pipefail

REPO="${SUPERAUDIO_PROFILES_REPO:-dapinitial/superaudio-device-profiles}"
ENABLED="${SUPERAUDIO_ENABLE_PR:-0}"

if [[ "$ENABLED" != "1" ]]; then
  cat >&2 <<EOF
PR submission is a deliberate opt-in.

Your profile is installed locally and working. To open a PUBLIC pull request
against $REPO — the profile content becomes public — confirm with the user, then:
  export SUPERAUDIO_ENABLE_PR=1
and re-run. (Override the target with SUPERAUDIO_PROFILES_REPO if needed.)
EOF
  exit 3
fi

if [[ $# -lt 1 ]]; then
  echo "usage: open-pr.sh <profile.json>" >&2
  exit 2
fi
SRC="$1"
[[ -f "$SRC" ]] || { echo "error: '$SRC' not found" >&2; exit 2; }

command -v gh >/dev/null || { echo "error: gh CLI not found" >&2; exit 2; }
gh auth status >/dev/null 2>&1 || { echo "error: 'gh' not authenticated — run 'gh auth login'" >&2; exit 2; }

ID="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['id'])" "$SRC")"
BRANCH="add-profile-$ID"
TMP="$(mktemp -d)"

echo "Cloning $REPO..."
gh repo clone "$REPO" "$TMP/repo" -- --depth 1 >/dev/null
cd "$TMP/repo"
git checkout -b "$BRANCH"
cp "$SRC" "profiles/$ID.json"
git add "profiles/$ID.json"
git commit -m "Add device profile: $ID" >/dev/null
git push -u origin "$BRANCH"

gh pr create \
  --title "Add device profile: $ID" \
  --body "Drafted via the SuperAudio \`/onboard-audio-device\` Claude Skill. Probed on real hardware; \`verifiedBy\`/\`verifiedDate\` reflect what was actually tested. Please review the match hints and codec/encryption fields." \
  --repo "$REPO"

echo "PR opened against $REPO for profile '$ID'."
