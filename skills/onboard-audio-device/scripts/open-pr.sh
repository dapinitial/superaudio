#!/bin/bash
# SuperAudio © 2026 David Puerto. Proprietary — see LICENSE.md.
#
# Submit a drafted profile as a PR to the public superaudio-device-profiles repo.
#
# EXTERNAL-SERVICE DISCLOSURE: this pushes a branch to GitHub and opens a public
# pull request via the `gh` CLI. The profile content becomes public. Run only
# after the user has reviewed the drafted JSON and explicitly confirmed.
#
# ALPHA STATUS: the public repo is not split out of the monorepo yet (M5.5
# "public repo go-live" is unchecked). This script refuses to run unless
#   SUPERAUDIO_PROFILES_REPO  is set to the public repo (owner/name), and
#   SUPERAUDIO_ENABLE_PR=1     is set as an explicit opt-in.
# Until then, the onboarding flow stops after install-profile.sh — the profile
# works locally; sharing waits for go-live.
#
# Usage: open-pr.sh <profile.json>

set -euo pipefail

REPO="${SUPERAUDIO_PROFILES_REPO:-}"
ENABLED="${SUPERAUDIO_ENABLE_PR:-0}"

if [[ "$ENABLED" != "1" || -z "$REPO" ]]; then
  cat >&2 <<'EOF'
PR submission is disabled in the alpha.

The public superaudio-device-profiles repo has not gone live yet, so there is
nowhere to send the PR. Your profile is already installed locally and working.

When the repo is public, enable this step with:
  export SUPERAUDIO_PROFILES_REPO="dapinitial/superaudio-device-profiles"
  export SUPERAUDIO_ENABLE_PR=1
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
