# AP2 Pairing Runbook — Apple TV 4K first contact

> The M12 gate this runbook exists for: **SRP pair-setup reaches M4 with a verified
> proof against a real HomeKit AP2 receiver.** Everything downstream (pair-verify,
> PTP, RTSP SETUP, RTP audio) keys off this working. Written 2026-07-05, the day
> the Apple TV 4K arrives. See `docs/DECISIONS.md` 2026-06-25 (CryptoKit-native
> pairing) and gotcha context in `Sources/SuperAudioAirPlay2/AP2PairSetup.swift`.

## 0. Apple TV setup (one-time, on the TV)

1. Put the Apple TV on the **same LAN/subnet** as the Mac (wired or the same Wi-Fi
   the speakers use — mDNS doesn't cross subnets without a repeater).
2. **Settings → AirPlay and HomeKit**:
   - **Allow Access: "Everyone"** (or "Anyone on the Same Network") for the first
     test — this is the configuration that accepts **transient** pairing, the mode
     our sender uses for streaming (same as HomePods).
   - Make sure **Require Password is OFF** for run 1.
3. Note the Apple TV's AirPlay name (Settings → General → About, or it'll show in
   our discovery log). Referred to as `<NAME>` below.

## 1. Build + log tail

```sh
./Scripts/build_app.sh
# terminal 2 — watch both the app and AP2 subsystems:
/usr/bin/log stream --predicate 'subsystem BEGINSWITH "com.davidpuerto.SuperAudio"' --level info
```

## 2. Run 1 — transient pairing (the streaming path)

```sh
./SuperAudio.app/Contents/MacOS/SuperAudio --ap2-pair="<NAME>"
```

(Launch the binary directly, not `open`, so stdin/stdout work for run 2.)

Watch for, in order:

| Log line | Meaning |
|---|---|
| `AP2 pair target … waiting for discovery` | flag parsed |
| discovery emits `<NAME>` as airplay2 | `_airplay._tcp` sees the Apple TV |
| `← GET /info RTSP/1.0 200 OK` + `/info keys: …` | transport + capability read work (already proven vs Sonos One SL) |
| `→ M1 (state=1 method=0 flags=10)` | transient M1 sent |
| `← M2 ✓ salt=16B serverB=384B` | **the moment that matters** — a HomeKit receiver is doing SRP with us (the One SL 403'd before this point) |
| `← M4 ✓ — SRP session key established` | **gate passed** — pairing crypto verified end-to-end |

## 3. Interpreting failures

- **`/info` 200 but `/pair-setup` → 403** — the Apple TV is refusing this pairing
  path. Check Allow Access isn't "Only People Sharing This Home"; try run 2 (PIN).
- **M2 comes back with an error TLV** (logged as `receiver error code=N`):
  code 6 = unavailable/busy (another pairing in flight — reboot the Apple TV),
  code 5 = max tries (back off ~10 min), code 2 = try PIN mode.
- **M4 `proof mismatch`** — SRP ran but the password is wrong: the receiver wants
  a PIN, not the transient code. Go to run 2. (This outcome still proves the
  transport + TLV8 + SRP math are right — only the pairing *mode* is off.)
- **Never discovered** — check the Mac's local-network TCC prompt fired and was
  allowed, and both devices are on the same subnet.

## 4. Run 2 — PIN (HomeKit) pairing, if transient is refused

Turn ON Require Password / device verification (or leave settings as they were
when run 1 failed), then:

```sh
./SuperAudio.app/Contents/MacOS/SuperAudio --ap2-pair="<NAME>" --ap2-pin
```

`--ap2-pin` sends `POST /pair-pin-start` (the Apple TV puts a 4-digit PIN on
screen), omits the transient flag from M1, and prompts on the terminal for the
PIN after M2. `--ap2-pin=1234` skips the prompt (for a fixed AirPlay password).
M4 ✓ in this mode verifies SRP against hardware; the M5/M6 long-term key
exchange is a known follow-up, only needed if PIN mode turns out to be required.

## 5. Record the result

Whichever way it lands, capture in `docs/DECISIONS.md` (dated entry):
which mode succeeded, the `/info` `features`/`statusFlags` values from the log
(they encode the supported auth paths — we'll want them for MFi-Sonos triage
later), and any error codes hit along the way. If M4 ✓: next M12 step is
**pair-verify + channel encryption**, then PTP timing.
