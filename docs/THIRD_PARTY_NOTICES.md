# Third-Party Notices

SuperAudio uses, will use, or has read the following third-party software. This file is maintained from day one — add an entry every time a dependency lands. Reference-only projects are listed separately so the boundary between "used in our code" and "read to understand the protocol" stays explicit.

---

## In-binary dependencies

(None yet. Each entry below is provisional — confirmed when the dependency actually lands in `Package.swift` or vendored sources.)

### Apple ALAC Encoder *(provisional, Phase 1)*

- **Source:** https://github.com/macosforge/alac
- **License:** Apache License 2.0
- **Use:** Encoding PCM audio to ALAC for AirPlay 1 RTP packets in `SuperAudioAirPlay1`.
- **Attribution:** Copyright © 2011 Apple Inc. All rights reserved.

### AudioCap *(reference; may adapt code with attribution)*

- **Source:** https://github.com/insidegui/AudioCap
- **Author:** Guilherme Rambo (@insidegui)
- **License:** MIT
- **Use:** Process tap (`CATapDescription`) integration in `SuperAudioCore` capture layer. We adapt patterns from this project with attribution; we do not vendor the code wholesale.
- **Attribution:** Copyright © Guilherme Rambo. Licensed under MIT.

### SoCo SOAP envelope strings *(reference; lift verbatim)*

- **Source:** https://github.com/SoCo/SoCo
- **License:** MIT
- **Use:** UPnP/SOAP envelope text used in `SuperAudioSonos` for `SetAVTransportURI`, `Play`, `GetTransportInfo`, etc. SOAP envelopes are effectively API definitions; we lift them verbatim.
- **Attribution:** Copyright © SoCo contributors. Licensed under MIT.

### BlackHole *(only if Plan B capture path is needed)*

- **Source:** https://github.com/ExistentialAudio/BlackHole
- **License:** GPL-3.0 (the driver itself; we do not link to or distribute its source)
- **Use:** If the Day 0 capture probe shows process tap is blocked under Personal Team signing, BlackHole is installed by the user as a virtual audio device. We capture from BlackHole as a normal input — no linking, no source dependency, just a runtime requirement. GPL boundary is therefore not crossed.

---

## Reference-only (NOT in our binary, NOT copied)

These projects were read to understand wire formats and protocol behavior. **No code from these projects is copied into SuperAudio.** Reading is fair use; the wire formats themselves are facts and cannot be copyrighted.

### shairport-sync

- **Source:** https://github.com/mikebrady/shairport-sync
- **License:** GPL-3.0
- **Use:** Reference for AirPlay 1 (RAOP) wire format — RTSP handshake, SDP body, RTP packet structure, AES-128 session-key handshake with the well-known Apple RSA public key.

### libraop (philippe44)

- **Source:** https://github.com/philippe44/libraop
- **License:** Effectively GPLv2 (per upstream `chevil/raop2_play`; confirmed in libraop issue #36)
- **Use:** Reference for AirPlay 1 sender architecture and NTP-based multi-device sync.

### OwnTone (forked-daapd)

- **Source:** https://github.com/owntone/owntone-server
- **License:** GPL-2.0
- **Use:** Reference for AirPlay 1 sender (`outputs/raop.c`) in a working multi-room context.

### Snapcast

- **Source:** https://github.com/badaix/snapcast
- **License:** GPL-3.0
- **Use:** Reference for multi-room sync algorithm (`time_provider.cpp`).

### node-airtunes

- **Source:** https://github.com/openairplay/node_airtunes
- **License:** BSD-2-Clause
- **Use:** Reference for AirPlay 1 sender behavior in a high-level (JS) implementation. Cleaner protocol description than shairport-sync in some respects.

---

## Public-domain facts used in our code

### Apple AirPort Express RSA public key (2048-bit)

- **Used in:** `Sources/SuperAudioAirPlay1/AppleAirPortRSA.swift`
- **What it is:** The 2048-bit RSA public key originally embedded in Apple's AirPort Express firmware (~2008) to wrap AES session keys for RAOP `et=1` audio sessions. Required for interoperability with every AirTunes-derived AirPlay 1 receiver.
- **Why it's here verbatim:** cryptographic public keys are numeric values, not copyrighted expression. The same modulus appears byte-for-byte in:
  - https://github.com/owntone/owntone-server (`src/outputs/raop.c`)
  - https://github.com/philippe44/libraop (`src/raop_client.c`)
  - https://github.com/openairplay/node_airtunes
  - https://github.com/mikebrady/shairport-sync (as the receiver-side key it decrypts against)
- **No code copied** from any of those projects — only the key value, which is a published fact.

---

## License hygiene rules

Repeated from CLAUDE.md so this file stands on its own:

- SuperAudio's own code is intended to be MIT-licensable. No GPL code is copied into the binary.
- "Reading" GPL projects to learn protocols is fine. "Copying" code is not.
- Every dependency in the in-binary list above must have a permissive license (MIT, BSD, Apache, ISC) or be explicitly carved out as a runtime-only dependency (like BlackHole).
- This file is updated in the same commit that adds the dependency to `Package.swift` or vendored sources.
