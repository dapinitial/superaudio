# SuperAudio — Launch Readiness Checklist

> Consolidated, honest gap list between **"works in David's house"** and **"a stranger can pay, download, install, and stream to THEIR speakers."** Compiled 2026-07-09 from the code state, the multi-agent readiness/feasibility/monetization audits, and the AP2 sprint. This is the single place to see everything that stands between here and a paid v1. Complements ROADMAP.md M7/M8 (the milestone framing) with a flat, checkable list. Update as items close.

**Reality anchor:** the hard engineering (capture, AP1, Sonos, and now the full AP2 auth + streaming pipeline) is ~90% done. The gap to *launch* is mostly last-mile productization and the boring-but-mandatory distribution/legal rail — plus one open engineering question (AP2 audible-sound confirmation). Monetization is realistically lifestyle/side-income (~$10k–$40k/yr; see [[superaudio-pricing-and-gtm]] memory + DECISIONS 2026-07-09) — build it because it's wanted, treat revenue as gravy.

---

## Tier 0 — Engineering to a *functional* v1

- [ ] **Confirm AP2 audible sound** (the open one). Pipeline streams RTP correctly; needs a listen test + likely a Music.app→AppleTV packet capture to resolve PTP master/slave, ChaCha nonce padding, and whether RECORD matters. Gotchas #33–#35.
- [ ] **Wire AP2 in as a real sink** once sound is confirmed — a 4th protocol in the menu / Play-All fan-out, integrated with the supervisor + per-sink volume/offset like AP1/Sonos.
- [ ] **Make the `AudioSink`/`SinkRegistry` abstraction real** (currently a facade — every `createSink` throws; the real path is bespoke `AirPlay1Session`/`SonosSession` + a `switch`). AP2 landing as the 4th protocol is the natural forcing function; do the refactor then, or the `$5-addon` seam stays fictional. (Deferrable to v1.x if shipping AP1+Sonos+AP2 hardcoded first.)
- [ ] **Externalize personal-environment hardcodes** into device profiles: the `3025 ms` Sonos auto-align offset (`SessionState`), the `en0`/`en1` interface lock (`RTSPClient` — use `LocalNetwork.primaryLocalIPv4()`), default volume tuned to B&W, "Spacelab" name assumptions. These break for every other user.
- [ ] **30-minute soak test** (the long-owed M3 gate) — all active protocols simultaneously, measure drift + drops.
- [ ] **First-run permissions UX** — a guided flow for the 3 TCC prompts (system-audio capture, mic, local network). Today a user who denies system-audio capture gets a silently dead app with no recovery guidance.
- [ ] **A regression net** — at least a small test target for the pure logic (packetization, profile matching, offset math, RTP/ALAC bit-exactness) before the AudioSink refactor. Zero tests today.

## Tier 1 — Distribution rail (hard blockers; a stranger literally can't run it without these)

- [ ] **Apple Developer Program enrollment** ($99/yr) — multi-day lead time, on the critical path. *(Do this first; unblocks the next three AND gives a stable TCC identity so the audio-capture prompt stops re-firing on rebuilds.)*
- [ ] **Developer ID signing + hardened runtime** — currently ad-hoc signed (`Signature=adhoc`, `TeamIdentifier=not set`). Gatekeeper blocks ad-hoc apps.
- [ ] **Notarization + stapling** (`notarytool`/`stapler`) — mandatory for direct distribution on current macOS. Zero infra today.
- [ ] **Universal binary** — `UNIVERSAL=1 ./Scripts/build_app.sh` exists but the shipped binary is **x86_64-only** (verify arm64 on the M1 Max). Ships broken/Rosetta on the majority Apple-Silicon base.
- [ ] **Distributable artifact** — a signed, notarized DMG (no packaging today).
- [ ] **App icon** — no `.icns` exists at all; `Resources/` is empty; version is `0.0.1`.
- [ ] **Auto-updater** — Sparkle 2 (sign the framework, EdDSA-sign updates, appcast feed). Direct-sale apps need self-update.

## Tier 2 — Monetization plumbing

- [ ] **Real `LicenseManager`** — currently `return true` for everything. Local key validation, no phone-home (LAN-only stance).
- [ ] **Checkout + license-key issuance** — **Lemon Squeezy** favored (merchant-of-record handles global VAT, native license-key API, ~1hr onboarding; Paddle is enterprise-slow). Single price, NO addon IAPs (decided). Early-bird $12 → list $19.99 → ~$14.99 coupon.
- [ ] **In-app license entry / status UI** — enter key, see status, restore.

## Tier 3 — Legal / trust / support (easy to forget, all mandatory for direct sale)

- [ ] **Product name / trademark check** — is "SuperAudio" safe + distinctive? (Watch: Sony/Philips "Super Audio CD"/SACD.) Research in progress 2026-07-09; resolve before print/marketing spend.
- [ ] **Privacy policy + Terms of Service** — required by Lemon Squeezy/Paddle and for trust. LAN-only/no-telemetry is a selling point; say it plainly.
- [ ] **Refund policy** — set expectations for a v1 with fragile pillars (see monetization audit).
- [ ] **Support channel** — a real support inbox (help@ / hello@) and/or a small Discord. Network-audio-sync tickets are the worst in software; budget for them.
- [ ] **Crash reporting decision** — a privacy-respecting choice (local-only? opt-in?) that doesn't violate the no-telemetry stance but still surfaces crashes.
- [ ] **THIRD_PARTY_NOTICES.md up to date** — add any new deps; the AP2 work stayed fresh-Swift (BigInt MIT only), keep it clean.
- [ ] **AirConnect stays OUT** — confirmed GPL/libraop; would poison the proprietary binary. (License-clean onboarding help = an iOS remote/setup companion, not a wrapper.)

## Tier 4 — Go-to-market (don't skip the beta)

- [ ] **Stranger beta (10–20 testers)** — *the* answer to "does it work in someone else's house." Recruit from the live high-intent threads: r/sonos (~300k, still salty from the 2024 app disaster), Sonos Community, MacRumors. Their hardware diversity also seeds the device-profile flywheel (only 4 profiles today, all David's — not yet a flywheel).
- [ ] **Flip the marketing site off `noindex`** at launch (spacelabforever.com is built, honest — 9.2/10 audit — and pre-launch-gated; funnel + email loop operational).
- [ ] **Launch positioning:** *"keeps your whole house in sync when Sonos updates break everything else."* Channels: Show HN, the AlternativeTo Airfoil page (no strong entrant), answering the broken-Airfoil threads, MacStories/9to5Mac pitches. The Claude Skill onboarding is a press-worthy hook.
- [ ] **Honest scope language** — "perfect AP1 + AP2 sync"; legacy-Sonos-via-coordinator + by-ear-slider caveats in the FAQ, not buried.

## Parked (explicitly NOT v1)

- Hub Stick / Optical Hub / Hub Pro hardware ($59/$79/$249) — a second company on paper; needs a $3–5K patent freedom-to-operate search. Ignore until the Mac app has paying users.
- Setapp — conflicts with the addon model / paid components; revisit post-launch as a second channel.
- iOS remote/setup companion — legitimate, license-clean, brand-strengthening, but a nicety not a launch blocker.
- App Store — never (sandbox incompatible with system-audio capture; Airfoil's model).

## Watch-items (ongoing risk, not a task)

- **Sonos S2 UPnP sunset** — Sonos is phasing down local UPnP on S2 firmware toward an authenticated local API. Legacy S1 targets (Playbar gen 1) are frozen-firmware and immune; plan the S2 migration eventually.
- **CoreAudio process-tap fragility** — the "zombie silence" / all-zero-buffer bug fights the OS each macOS release (already mitigated; gotcha #26). A permanent solo-maintainer tax.
- **AP2 sender is reverse-engineered** — Apple can rotate the crypto/protocol in any OS/firmware update. Precedent (Airfoil 20+ yrs, pyatv, shairport) protects the practice; keep it fresh-Swift and expect occasional break/fix.
