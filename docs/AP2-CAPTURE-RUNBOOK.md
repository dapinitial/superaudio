# AP2 Packet-Capture Runbook — finding the last 3%

> Goal: capture what **macOS's own AirPlay 2 sender** does when it streams audio
> to the Apple TV ("Living Room", `192.168.1.106`), so we can diff it against our
> sender and find the one thing keeping the Apple TV silent. Written 2026-07-11
> for the 9 PM session. All from the Mac — no iPhone, no port mirroring needed,
> because the Mac captures its *own* traffic to the Apple TV.

## Why this works even though RTSP is encrypted

The RTSP control messages (SETUP, SETRATEANCHORTIME, etc.) ride the pair-verify
cipher and stay opaque. But the stuff most likely to be our bug is **in the
clear**:
- **PTP** (ports 319/320) — who's grandmaster, the clock values, the exact
  Announce/Sync/Follow_Up. Confirms our clock approach.
- **Control-port RTCP** — the `TIME_ANNOUNCE_PTP` (0xD7) packets, **unencrypted**.
  We can compare Apple's exact bytes/values/rate to ours field-by-field.
- **RTP audio** headers (ports, SSRC, sequence, timestamp cadence, packet sizes)
  — even though the payload is encrypted, the framing is visible.
- **Which TCP/UDP connections Apple opens** (event channel, control, an extra
  handshake we're missing, a FairPlay `/fp-setup`, etc.).

That structural diff is exactly what we can't see from source code.

## Step 1 — find the Mac's LAN interface (10 sec)

```sh
route get 192.168.1.106 | awk '/interface:/{print $2}'
```
That prints the interface (likely `en0`). Use it as `<IF>` below.

## Step 2 — start the capture (leave it running)

```sh
sudo tcpdump -i <IF> -s 0 -w /tmp/appletv_real.pcap host 192.168.1.106
```
(`-s 0` = full packets. It'll ask for your password. Leave this terminal running.)

## Step 3 — AirPlay from the Mac to the Apple TV, for real

This is the ground truth — macOS's native AirPlay 2 sender:

1. Open **Music.app**, start playing any song.
2. Click the **AirPlay icon** (or menu bar → Sound → AirPlay) and select
   **"Living Room"** (the Apple TV).
3. **Confirm you hear it out the Playbar** (this is Apple's sender working — it
   should just play). Let it run **~30–45 seconds**.
   - If it asks for an AirPlay code, enter it — that's fine, it still captures.
4. Stop the music, switch AirPlay back to the Mac's own speakers.

## Step 4 — stop the capture

Back in the tcpdump terminal: **Ctrl-C**. You now have `/tmp/appletv_real.pcap`.

## Step 5 — hand it to me

Just tell me it's done. I'll read `/tmp/appletv_real.pcap` and diff Apple's
session against ours:
- Compare the control-port `TIME_ANNOUNCE_PTP` bytes (our #1 suspect).
- Check the PTP master/clock behavior.
- List every connection Apple opens that we don't.
- Check the RTP timing/anchor relationship.

Then we fix the specific gap and test once.

## Optional — capture OUR session too (for a side-by-side)

If you want, after the Apple capture, run the same tcpdump while doing our
`--ap2-play="Living Room"` — then I can diff the two pcaps directly. Not
required; Apple's alone should show the gap.

## Notes
- If `route get` shows a weird interface (VPN/Thunderbolt), disable the VPN so
  traffic goes over Wi-Fi.
- The Apple TV wedges after lots of connects — if AirPlay from Music.app is
  flaky, reboot the Apple TV first (Settings → System → Restart).
- pcap has no secrets worth guarding (LAN audio session), but it's local-only.
