# Probes

Single-file diagnostic programs that verify environment assumptions before they bite the main project. Each probe is self-contained, compiles with `swiftc`, and runs from Terminal.

These are not part of the SuperAudio SPM workspace. They live alongside it for the same reason a soldering iron lives next to the workbench: handy, distinct, not part of the product.

## Day0Capture

**Question:** does the macOS 14.4+ CoreAudio process tap API (`CATapDescription` + `AudioHardwareCreateProcessTap`) actually work on this machine under Free Apple ID / Personal Team signing, or do we need to fall back to a BlackHole virtual audio device?

**Why this is the first thing to settle:** capturing system audio is the foundation of the whole app. If process tap is blocked, every line of code that assumes it works has to be rewritten. We resolve this on Day 1 — before any SPM scaffolding — to avoid sinking weeks into the wrong assumption.

### Build & run

```bash
swiftc -O probe/Day0Capture.swift -o probe/Day0Capture
./probe/Day0Capture
```

**Run from Apple's Terminal.app, not iTerm.** TCC binds the audio-recording permission to the parent process (the terminal emulator). iTerm has been observed to silently skip the permission prompt; Apple's Terminal reliably prompts. The probe binary itself doesn't appear in System Settings — Terminal does.

On first run, Terminal triggers macOS to prompt: *"Terminal would like to record audio from other applications on your Mac."* Grant it. The prompt only fires once per Terminal grant; subsequent runs use the saved permission.

While the 5-second capture window is open, play some audio (Spotify, YouTube, Safari, or `say "hello world"`). You should see callback logs with non-zero `firstSample` values on stderr.

### Interpreting results

- **Exit 0, ~20+ callbacks, non-zero sample values** → Plan A confirmed. Process tap works under Personal Team signing. Proceed to SPM scaffolding.
- **Exit 2, zero callbacks** → tap reported success but no frames arrived. Most likely cause: no audio was actually playing during the 5-second window. Re-run with audio active. If it still produces zero callbacks, treat as Plan A failure.
- **Exit 1, `AudioHardwareCreateProcessTap failed`** → check System Settings → Privacy & Security → Audio Recording. If Terminal isn't listed or is denied, fix that and re-run. If Terminal is granted but the tap still fails, Plan A is blocked on this machine — install BlackHole and switch to Plan B per CLAUDE.md gotcha #3.
- **Any other error** → log it in DECISIONS.md before deciding. This is the kind of thing we said "STOP and ask" about.

### Why no entitlements file or app bundle?

For an unbundled CLI binary, TCC attributes the audio-recording permission to the parent process, not to the binary. Terminal.app already has `NSAudioCaptureUsageDescription` configured. The probe inherits this transitively. The eventual SuperAudio menu bar app will need its own `.app` bundle with the usage description, an entitlements file (`com.apple.security.device.audio-input`), and a proper signing setup — but the probe does not.
