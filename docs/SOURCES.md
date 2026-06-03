# SuperAudio — Sources Register

> Every external claim cited in our HTML and markdown docs should resolve to an entry here. Built incrementally — when a new claim appears in a doc, the source goes here with the citation ID inline.

The point of this file isn't completeness for its own sake. It's accountability: when a journalist or hostile forum user asks *"where did you get that?"*, we have an answer that isn't *"trust me."*

---

## How citations work

- Each entry has a stable ID: `[S1]`, `[S2]`, etc. — numbered in order added. **IDs never get reused** — if an entry is retired, leave the heading with a `RETIRED` note.
- HTML docs link inline. Recommended pattern:
  ```html
  Claim text<a href="../docs/SOURCES.md#s12" class="cite">[S12]</a>
  ```
- Markdown docs link inline: `Claim text [[S12]](SOURCES.md#s12)`.
- Each entry below uses a consistent shape:

```
### S## — Short title
- URL: https://example.com/…
- Accessed: 2026-MM-DD
- Cite for: which specific claim(s) we make using this source
- Strength: official | press | community consensus | reverse-engineered | speculation
- Caveats: anything that limits how we should use it
```

**Strength categories** —
- **official** — vendor documentation, statute, court filing, regulatory page
- **press** — established journalism (Wired, Verge, Wirecutter, MacStories)
- **community consensus** — multiple independent users in audiophile/maker communities agreeing
- **reverse-engineered** — packet capture or working open-source implementation
- **speculation** — informed but unverified; use sparingly and only when flagged

---

## A — AirPlay protocol (versions, codecs, capabilities)

### S1 — Audio Science Review: "AirPlay 2 is not lossless but AirPlay 1 is"
- URL: https://www.audiosciencereview.com/forum/index.php?threads/airplay-2-is-not-lossless-but-airplay-1-is.52609/
- Accessed: 2026-05-13
- Cite for: Audiophile-community consensus that AP1 carries lossless ALAC at 44.1 kHz / 16-bit, while AP2 transcodes to AAC ~256 kbps before transmission
- Strength: community consensus
- Caveats: No packet capture in thread. Relies on Darko.Audio's analysis attributed to "Brother Thomas's research." Apple has not officially confirmed AP2's codec; absence of denial is suggestive but not proof.

### S2 — Roon Labs Community: AirPlay 1 vs 2 streaming quality
- URL: https://community.roonlabs.com/t/airplay-1-vs-airplay-2-streaming-quality/273219
- Accessed: 2026-05-13
- Cite for: Independent forum confirmation of S1 — Roon users repeating that AP1 = 44.1/16 lossless, AP2 = AAC 256 lossy
- Strength: community consensus
- Caveats: No Roon staff post in thread; corroborates S1 rather than independently sourcing the claim. Two community sources saying the same thing are still one body of evidence.

### S3 — HowToGeek: How to Add AirPlay to Any Speaker
- URL: https://www.howtogeek.com/how-to-add-airplay-to-any-speaker/
- Accessed: 2026-05-13
- Cite for: Current consumer landscape of AirPlay *receivers*; per-speaker adapter prices ($30–$749 range); the workaround taxonomy people use today (bridge devices, AVRs, Pi + shairport-sync, software like Airfoil)
- Strength: press
- Caveats: Receiver-side landscape only. Does not address senders, cross-protocol fan-out, or system audio capture — i.e., the SuperAudio problem space is **not** covered by this article. Useful for prices and product names, not strategy.

### S4 — dev.to: Turn any Bluetooth speaker into an AirPlay speaker with shairport-sync
- URL: https://dev.to/henrylim96/turn-any-bluetooth-speaker-into-an-airplay-speaker-with-shairport-sync-177j
- Accessed: 2026-05-13
- Cite for: Real complexity of the DIY Pi + shairport-sync path — requires `dietpi-software`, `bluetoothctl`, manual `nano` of configs, systemd service setup
- Strength: tutorial (functional how-to, not journalism)
- Caveats: Single-output receiver, no multi-room, no Sonos/Cast, no GUI. Useful for defending why Hub Stick at $59 beats "just use a Pi" for non-Linux households.

---

## B — Sonos

### S5 — Sonos Community: AirPlay and Play:1
- URL: https://en.community.sonos.com/speakers-229128/airplay-removed-from-play-1-6902460
- Accessed: 2026-05-13
- Cite for: **Play:1 never had AirPlay receive capability** (no hardware chip), per Sonos staff. The official workaround Sonos endorses — *group Play:1 with a newer AirPlay-capable Sonos and inherit the stream* — destroys zone independence. Real-world evidence of the "bridge-pain" we eliminate.
- Strength: official (Sonos staff response from Corry P)
- Caveats: **Does NOT support the claim "Sonos removed AirPlay from Play:1."** The original poster was mistaken; the speaker never had it. If we cite this thread, frame it carefully — the story isn't a removal, it's that *Play:1 owners are permanently stuck with the group-bridge workaround if they want any AirPlay at all.*

---

## C — Competitors (products, pricing, positioning)

(Populate as we cite specific competitor claims. Prices in `website/PRICING.html` and `website/COMPETITIVE_LANDSCAPE.html` are currently public-knowledge MSRPs; verify and cite when challenged.)

### S6 — Airfoil by Rogue Amoeba (product page)
- URL: https://rogueamoeba.com/airfoil/mac/
- Accessed: 2026-05-13 (to verify)
- Cite for: Airfoil for Mac price ($35), feature set (AP1 + AP2 + Sonos + Chromecast + Bluetooth), Mac-only positioning. Our primary software competitor.
- Strength: official (vendor product page)
- Caveats: Pricing may change; re-verify before any direct price comparison ships in marketing.

---

## D — Patents, legal, regulatory

### S7 — Sonos v. Google patent litigation (multi-room audio)
- URL: *to be filled with the specific court docket / press summary we rely on*
- Accessed: not yet verified
- Cite for: The CASE_STUDY.html and COMPETITIVE_LANDSCAPE.html claim that Sonos is the most-litigious player and has won material multi-room sync claims against Google
- Strength: unfilled — currently relying on general knowledge; **upgrade to a real citation before the launch press kit goes out**
- Caveats: **HIGH PRIORITY to fill.** This is one of our most-quoted facts; we cannot let it stand uncited.

### S8 — Apple AirPort Express RSA public key prior art
- URL: shairport-sync source (`https://github.com/mikebrady/shairport-sync`), libraop (`https://github.com/philippe44/libraop`), node-airtunes (`https://github.com/openairplay/node_airtunes`), OwnTone (`https://github.com/owntone/owntone-server`)
- Accessed: 2026-05-13
- Cite for: The 2048-bit RSA public key embedded in our `Sources/SuperAudioAirPlay1/AppleAirPortRSA.swift` is a published numerical constant appearing identically across 4+ open-source RAOP implementations dating to 2008. Not a trade secret; not copyrightable expression.
- Strength: reverse-engineered + open-source precedent
- Caveats: Apple has never enforced against any implementation. Posture is supported by 16+ years of public use without legal action.

---

## E — Technical references (protocols, codecs, encoders)

### S9 — shairport-sync (canonical AirPlay 1 receiver implementation)
- URL: https://github.com/mikebrady/shairport-sync
- Accessed: ongoing
- Cite for: Wire format reference for RAOP. License is GPL-3.0; we do not copy code, only read.
- Strength: reverse-engineered (the canonical reference)
- Caveats: GPL — strict no-copy rule per our license hygiene (DECISIONS.md 2026-05-11).

### S10 — libraop (philippe44)
- URL: https://github.com/philippe44/libraop
- Accessed: ongoing
- Cite for: AirPlay 1 sender architecture and NTP-based sync reference
- Strength: reverse-engineered
- Caveats: Effectively GPLv2 per upstream chevil/raop2_play (libraop issue #36). Read only.

### S11 — Apple Open-Source ALAC encoder
- URL: https://github.com/macosforge/alac
- Accessed: ongoing
- Cite for: Lossless audio encoder we plan to vendor for the M3 RTP audio pipeline. Apache 2.0; permissively licensed; safe to ship.
- Strength: official (Apple)
- Caveats: Hasn't seen a commit in years; we should mirror it locally before M3 starts in case the repo is sunset.

### S12 — Apple Tech Note TN3163 (CoreAudio process tap)
- URL: https://developer.apple.com/documentation/technotes/tn3163-process-audio-tap-api
- Accessed: ongoing
- Cite for: Process tap API reference for `CATapDescription` system audio capture
- Strength: official (Apple)
- Caveats: API was introduced in macOS 14.4; our minimum target.

---

## F — Market data, demographics, pricing context

### S13 — US Census Bureau ACS 2024 median household income
- URL: https://www.census.gov/library/publications/2025/demo/p60-282.html (release: September 2025)
- Accessed: 2026-05-13 (to verify exact URL)
- Cite for: CASE_STUDY.html demographics — US median household income $84,000 (2024 ACS, released Sept 2025). Used to size the addressable audience.
- Strength: official (US Census Bureau)
- Caveats: Update annually when new ACS data drops (typically September). Replace prior $80,610 (2023 ACS) figures across all docs.

---

## G — Historical events anchoring the "Why now" timeline

These dates anchor the lossless-renaissance narrative in CASE_STUDY.html. Each one needs a primary source before press outreach.

### S14 — Apple Music Lossless launch (June 2021)
- URL: https://www.apple.com/newsroom/2021/05/apple-music-announces-amazing-audio-quality-upgrades-with-spatial-audio-and-lossless/ (Apple press release, May 17, 2021; Lossless rolled out in June)
- Accessed: 2026-05-13 (to verify)
- Cite for: The "cruel joke" pivot point in our Why-now timeline — Apple ships lossless audio source but cannot deliver it losslessly over AirPlay 2 to current Apple speakers.
- Strength: official (Apple press release)
- Caveats: Apple's own press release acknowledges Lossless tier; doesn't explicitly say "AirPlay 2 won't carry it losslessly." That gap is established by S1/S2 community sources, not Apple. Cite both together.

### S15 — AirPort Express discontinuation (April 2018)
- URL: https://support.apple.com/en-us/HT204323 (Apple support — "About AirPort base station discontinuation")
- Accessed: 2026-05-13 (to verify exact URL — Apple has reorganized support URLs multiple times)
- Cite for: "Apple discontinued AirPort Express. Last cheap AP1 receiver leaves shelves" — 2018 line in the Why-now timeline.
- Strength: official (Apple)
- Caveats: URL stability is poor; archive a copy via archive.org before launch.

### S16 — Sonos S1 / S2 app split (May 2020)
- URL: https://en.community.sonos.com/announcements-228695/sonos-introducing-s2-6862535 (Sonos community announcement, May 6, 2020)
- Accessed: 2026-05-13 (to verify)
- Cite for: "Sonos splits S1/S2; older models frozen on S1" line in the Why-now timeline. Reinforces the walled-garden / lock-in framing.
- Strength: official (Sonos)
- Caveats: Sonos has subsequently rolled some changes back; verify current state before quoting effects.

### S17 — B&W AirPlay 1 product line EOL
- URL: not yet identified — needs B&W support page or press confirmation
- Accessed: not yet verified
- Cite for: "B&W, Naim, Marantz, etc. EOL their AP1 lines and ship AP2-only successors (2017–2020)" in the Why-now timeline.
- Strength: unfilled
- Caveats: **Currently relying on general industry knowledge. UPGRADE BEFORE PRESS.** Best path: find a press release or support-page archive for each named brand.

### S18 — Apple AirPlay 2 announcement (WWDC 2017 → 2018 rollout)
- URL: https://www.apple.com/newsroom/2017/06/apple-introduces-the-future-of-music-with-homepod/ (WWDC 2017 announcement, includes AirPlay 2 reference)
- Accessed: 2026-05-13 (to verify)
- Cite for: "2018 — Apple launches AirPlay 2" line in the Why-now timeline. AP2 was announced WWDC 2017, shipped publicly 2018 with iOS 11.4.
- Strength: official (Apple press release)
- Caveats: Multiple dates can be cited — announcement vs. ship vs. broad adoption. Use 2018 (ship) as the headline date.

### S19 — eBay price trend for used AirPort Express A1264
- URL: not yet captured — recommend periodic eBay completed-listings screenshot
- Accessed: not yet verified
- Cite for: "eBay prices for AirPort Express A1264 climb" — evidence of the audiophile demand renaissance.
- Strength: unfilled — would need price-history aggregation
- Caveats: **Currently anecdotal.** Lower-priority citation since the narrative still holds without it; if challenged, point to ASR/Roon community threads (S1, S2) as evidence of demand without the price-history claim.

---

## H — Internal wire-format ground truth (our own captures)

### S20 — Music.app → B&W A7 RTSP/RAOP capture (2026-05-14)
- URL: file `/tmp/musicapp-to-a7.pcap` (local, NOT committed). 188,641 bytes, 200 packets.
- Capture command: `sudo tcpdump -i en0 -w /tmp/musicapp-to-a7.pcap 'host 192.168.1.105' -c 200`
- Accessed: 2026-05-14
- Cite for: **Ground truth** for what a working AirPlay 1 audio session looks like on the wire. Specifically establishes (1) Music.app sends compressed ALAC, never verbatim/escape mode — audio packets are 642-1117 bytes variable size; (2) RTP header layout `80 60 <seq> <ts> <ssrc>`; (3) Music.app sends RTCP-style sync packets on the control port (20-byte payload, PT 0xd4); (4) Audio source port is ephemeral (no constraint); control/timing source ports are advertised in SETUP and source-validated by receiver.
- Strength: **reverse-engineered (direct wire capture)** — strongest possible evidence
- Caveats: One capture from one Mac to one B&W A7 model. Worth re-capturing if we encounter other AP1 hardware (e.g., AirPort Express, B&W Zeppelin, older Marantz) to verify behavior generalizes.

### S21 — `probe/PortProbe.swift` UDP source-port-validation discovery
- URL: `probe/PortProbe.swift` in this repo, 2026-05-14
- Cite for: B&W A7 RAOP receiver `connect()`s its control and timing UDP sockets to the source port advertised in SETUP's Transport header. UDP from any other source port → kernel-level ICMP unreachable. Discovered by probing the speaker's ports during a live session from an ephemeral source — got CLOSED on control/timing, open|filtered on audio. Audio port has no source-port constraint.
- Strength: empirical
- Caveats: B&W-firmware-specific (AirTunes/103.2). May not generalize to all RAOP receivers — re-test on other hardware before generalizing the source-port-matching rule.

---

## Audit trail

| Date | Action |
|---|---|
| 2026-05-13 | File created. Seeded with S1–S13 covering AirPlay codec evidence, Sonos AP1 thread, HowToGeek and dev.to articles, Airfoil, patent/RSA prior art, technical references, and Census source. |
| 2026-05-13 | Added S14–S19 anchoring the "Why now — lossless renaissance" timeline in CASE_STUDY.html: Apple Music Lossless launch, AirPort Express EOL, Sonos S1/S2 split, B&W AP1 EOL (unfilled), AirPlay 2 announcement, and AirPort Express eBay price-trend evidence (unfilled). |
| 2026-05-14 | Added S20–S21: internal wire-format ground truth from Music.app pcap (compressed-ALAC requirement) and PortProbe-based discovery (source-port validation). Both cited in DECISIONS.md 2026-05-14 entry. |

---

## What's still uncited (next pass to address)

These claims appear in our docs but don't yet have entries here. **Backfill before any external review or press outreach.**

- WiiM Pro Plus, Sonos Port, Bluesound Node, Audioengine B-FI, iFi Zen Stream, Eve Play, Belkin SoundForm Connect — prices and feature claims in `website/COMPETITIVE_LANDSCAPE.html`
- AirConnect, OwnTone, node-airtunes — feature claims
- Apple Small Business Program 15%/30% rate
- Paddle Merchant of Record fee structure
- FCC / CE / IC certification cost ranges (currently quoted ~$8–14K per SKU)
- HDMI ARC / eARC spec capabilities (2-channel PCM up to 192/24)
- Apple Music Lossless availability (2021 launch)
- macOS 14.4 release date and CoreAudio process tap API introduction date
- "shairport-sync has the Apple RSA key" claim — link to specific source file in shairport-sync repo

Each becomes a new `S##` entry as we touch the relevant doc next.
