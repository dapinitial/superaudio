# superaudio-device-profiles

Community-contributed JSON profiles describing how to talk to audio devices — speakers, soundbars, AVRs, smart-TV-as-source — across protocols. Consumed by [SuperAudio](https://github.com/dapinitial/superaudio) and openly licensed so anyone (commercial or open-source) can use them.

**MIT licensed. Pure data. No executable code.** Profiles describe protocol parameters, codec quirks, timing tolerances, volume scales, and known-firmware-gotchas. They don't run code. A hostile profile cannot pwn your user.

This is the substrate for SuperAudio's M6.5 Claude Skill — an AI-assisted onboarding flow that probes an unknown device, drafts a profile, and opens a PR back to this repo. The community curates; SuperAudio (and any other consumer) reads.

---

## Status — 2026-05-18

**v1 schema · 4 seed profiles · pre-launch.** This repo lives inside the SuperAudio monorepo for now; it'll split out as a standalone public repo (`github.com/dapinitial/superaudio-device-profiles`) when SuperAudio M5.5 ships.

| Profile | Status | Source |
|---|---|---|
| Bowers & Wilkins A5 | ✅ Verified on hardware | David Puerto, 2026-05-14 |
| Bowers & Wilkins A7 | ✅ Verified on hardware | David Puerto, 2026-05-14 |
| Sonos Playbar (gen 1) | ✅ Verified on hardware | David Puerto, 2026-05-15 |
| Apple AirPort Express (gen 1) | 🟡 Seeded from public reverse-engineering (shairport-sync, libraop) | David Puerto, 2026-05-18 — not verified on hardware |

---

## How profiles work

Each profile is one JSON file describing one device model. A profile has up to **two roles**:

- **Sink role**: how to send audio TO this device. Protocol family (AirPlay 1 / Sonos / AirPlay 2 / Chromecast / ...), codec parameters, handshake quirks, timing tolerances, volume scale, known-firmware-gotchas.
- **Control role**: how to subscribe to events FROM this device (volume changes, power events, source switches). Used when a device acts as the "audio brain" of a room — typically a soundbar paired with our Audio Bridge — and the rest of the mesh needs to follow its state.

Most devices have only the sink role. Sonos Playbar has both. A generic IR-only soundbar would have only the control role (paired with an Audio Bridge that does the audio capture).

See [`schema.json`](./schema.json) for the full field definition.

---

## Adding a new device

1. **Find a similar profile in [`profiles/`](./profiles/)** as a template. Copy + rename.
2. **Fill in what you know.** Required: `id`, `displayName`, `manufacturer`, `model`, at least one role.
3. **Document gotchas in plain English** in the `quirks` array — they're the most valuable part for downstream consumers.
4. **Mark `verifiedBy` honestly.** If you measured the behavior on your own hardware, list yourself. If you derived from public references (shairport-sync, libraop, node-sonos-ts), list those instead and set `verifiedDate: null`.
5. **Open a PR.** A GitHub Action validates JSON against [`schema.json`](./schema.json) and CODEOWNERS routes by protocol family for review.

If you don't want to hand-author, the [SuperAudio app](https://github.com/dapinitial/superaudio) will eventually include a Claude Skill that probes your device interactively and drafts the profile for you. See M6.5 in the [SuperAudio roadmap](https://github.com/dapinitial/superaudio/blob/main/docs/ROADMAP.md).

---

## Schema versioning

`schemaVersion: 1` is the current spec. Future versions will be **non-breaking additive** — new optional fields only. Profiles never need to upgrade in lockstep with the spec; old consumers ignore fields they don't understand.

Major bumps (rare) would change semantics of existing fields; we'd ship a migration script alongside.

---

## Why a separate repo (eventually)

Three reasons SuperAudio splits this out:

1. **License separation.** SuperAudio app stays commercial; profiles stay MIT. Other multi-room projects (Snapcast, OwnTone, shairport-sync derivatives) can reuse our data without buying us.
2. **PR velocity.** Profile contributions don't need to wait on app releases. A community fix lands in hours, not weeks.
3. **Schema as a coordination point.** Other consumers can adopt the schema; we'd be the largest user but not the only one. Tailscale-style: open substrate, paid UX.

For now, the directory lives inside the SuperAudio monorepo so the substrate ships in lockstep with the app's loader. Split happens at M5.5 ship.

---

## License

[MIT](./LICENSE). Profiles are pure data and don't carry independent copyright on the device behavior they describe (interop facts aren't copyrightable). Wrapper code in this repo (schema, validators, examples) is MIT to remove any ambiguity for downstream users.
