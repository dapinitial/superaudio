---
name: onboard-audio-device
description: Onboard an unrecognized audio device into SuperAudio by probing it, drafting a SuperAudio device-profile JSON, validating it against the schema, and installing it locally (optionally opening a PR to the public profiles repo). Use when the user says "onboard this speaker", "SuperAudio doesn't recognize my speaker", "add a device profile", "/onboard-audio-device", or wants an unknown AirPlay speaker to show up tuned in SuperAudio.
---

# Onboard an audio device into SuperAudio

You walk an unknown audio device from "not tuned in SuperAudio" to "drafted,
validated, installed device profile that the app loads on next start" — and,
once the public repo is live, an open PR sharing it with the community.

A **device profile** is one MIT-licensed JSON file (pure data, no code) that
tells SuperAudio how to talk to one device model: protocol, codec params,
encryption, latency, volume scale, and plain-English firmware quirks. The app's
`ProfileStore` matches a discovered device to a profile and reads tuned behavior
from it instead of compile-time defaults. The schema lives at
`superaudio-device-profiles/schema.json`; existing profiles in
`superaudio-device-profiles/profiles/` are your templates.

## Alpha scope (read this first)

This alpha handles **AirPlay 1 (`_raop._tcp`) sink-role** devices — the path
SuperAudio actually consumes today (AP1 volume scale is wired; codec/latency
slices are landing). Do **not** attempt packet capture (`tcpdump`/`tshark`),
soundbar control-role profiles, or non-AirPlay-1 protocols in this alpha — AP1
receivers are all AirPort-Express-derived, so everything you need (match hints,
volume scale, encryption type) is knowable from discovery alone, no pcap.

If the user's device is a soundbar, a Sonos, a Chromecast, or an AirPlay 2-only
speaker, say so plainly and stop — those paths are future scope.

## Privacy & disclosure rules (non-negotiable)

Before each phase that touches the network, filesystem, or an external service,
**state in one sentence what is about to happen and wait for the user to
proceed.** Never run `tcpdump`. When drafting, **anonymize aggressively**: never
copy the owner's chosen speaker name, MAC address, hostname, or Apple-ID device
name into the profile. Match on the *model*, not the *instance*. All discovery
is LAN-only; nothing leaves the machine until the explicit PR step, which the
user must confirm.

## Phases

### 1. Probe (network — disclose first)

Run the bundled probe. It uses `dns-sd` to list and resolve `_raop._tcp`
receivers — passive LAN discovery, nothing sent to the speakers:

```
python3 scripts/probe-raop.py
```

It prints JSON: `serviceName`, `mac`, `displayName`, `host`, `port`,
`likelyKind`, and the `txt` record. Show the user the devices found. The device
they want to onboard is the one not yet appearing tuned in SuperAudio.

`likelyKind` is a heuristic that steers you to the right target: `_raop._tcp` is
also advertised by Macs and by AirPlay-2 devices (Sonos, HomePods), neither of
which this alpha onboards. Only pursue a device classified `airplay1-receiver`.
If the user points at one marked `computer` or `airplay2-likely`, say why it's
out of scope and stop.

> **Match contract — the key detail.** SuperAudio's `ProfileStore` matches a
> profile's `match.modelHints` (case-insensitive substring) against the device's
> `displayName` **plus** its model-bearing TXT keys (`am`, `model`). The
> `displayName` is the owner's pet name ("Spacelab Audio") — personal and
> non-portable. **`txt.am` is the stable model identifier** (e.g. `A5`). Always
> prefer `am` for `modelHints` so the profile resolves on *anyone's* speaker,
> not just this owner's. If `am` is missing, fall back to a stable substring of
> the model — never the owner's pet name.

### 2. Identify

From the `txt.am` value, manufacturer hints, and `host`, web-search the make and
model. Confirm it's an AirPlay-1 receiver. Determine: manufacturer, model name,
first-release year if findable, and any documented encryption requirement
(some firmware needs `et=1`; default is `et=0` with `et=1` fallback).

### 3. Draft

Copy `templates/airplay1-receiver.json` and fill it in:

- `id`: `<manufacturer-slug>-<model-slug>`, lowercase, hyphenated (the filename).
- `displayName`, `manufacturer`, `model`: the real product names (not the pet name).
- `match.modelHints`: **the `txt.am` value** and/or a stable model substring.
  Verify your chosen hint is a substring of `displayName + " " + txt.am` (that
  is exactly what the app matches against — see the contract above).
  **Never use a hint derived from the speaker's user-given name.** The Bonjour
  name is 100% owner-chosen and brand-agnostic, so a name-hint is worse than
  useless — it can *false-match* a different device the owner named similarly
  (a non-B&W speaker named "…A5…" would wrongly inherit the A5 profile). Hints
  must be **manufacturer-set model identifiers** (the `am` value), never names.
- `match.macOUI`: only if you can confirm the MAC's OUI belongs to this
  manufacturer (tiebreaker, optional); otherwise leave `[]`.
- `roles.sink.encryption.et`: `0` unless identification shows the device needs
  `1`. Keep the `fallback`.
- `roles.sink.volumeScale`: AirTunes dB scale (`-30`..`0`, muted `-144`) unless
  you have evidence of a different scale.
- `quirks`: anything you actually observed or found documented. Plain English.
- `verifiedBy` / `verifiedDate`: list the user **only if** the device played
  correctly on their hardware in phase 5; otherwise `[]` / `null` and note
  "seeded from references" in `notes`.
- `contributedDate`: today's date (ask or use the system date).

Write the draft to a temp path, e.g. `/tmp/<id>.json`.

### 4. Validate

```
python3 scripts/validate-profile.py /tmp/<id>.json
```

Fix every reported error and re-run until it prints `PASS`. A profile that
passes here loads in the app and passes the repo's CI.

### 5. Install locally (filesystem — disclose first)

```
bash scripts/install-profile.sh /tmp/<id>.json
```

This copies the profile into `~/Library/Application Support/SuperAudio/Profiles/`
(the user-overlay directory the app scans; overlay wins over built-ins by `id`).
Then tell the user to **restart SuperAudio / restart the session** — `ProfileStore`
loads once at launch, so the new profile is picked up on next start, not live.

### 6. Verify

Have the user start a session to the device in SuperAudio and confirm: it now
appears matched (the app logs `ProfileStore: matched '<id>'`), volume tracks the
profile scale, and audio plays. If anything's off, return to phase 3, adjust,
re-validate, re-install. Update `verifiedBy`/`verifiedDate` honestly based on
what actually worked.

### 7. Share via PR (external — disclose + confirm; alpha-gated)

```
bash scripts/open-pr.sh /tmp/<id>.json
```

The public repo is **live** (`dapinitial/superaudio-device-profiles`). This step
is a deliberate opt-in so the Skill never surprise-pushes: it refuses unless the
user has reviewed the drafted JSON and set `SUPERAUDIO_ENABLE_PR=1`. Always
confirm explicitly before pushing, and only after the profile content has been
anonymized. The PR is validated by the repo's CI (`scripts/validate.py` against
`schema.json`) before a maintainer reviews it.

## Done

Report concisely: the device identified, the profile `id` installed, whether it
verified on hardware, and the exact path it was written to (so the user can undo
with `rm`). If the PR step was gated off, say so and why.
