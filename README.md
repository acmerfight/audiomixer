# AudioMixer

Record system audio and microphone into a single WAV file on macOS. No virtual audio drivers, no configuration, no third-party dependencies.

## Use Cases

- Record a software installation with voice-over narration
- Capture a video call (both sides) for notes
- Record a tutorial with system sounds + spoken explanation
- Archive any audio playing on your Mac alongside your commentary

## Quick Start

```bash
# Build
swift build -c release

# Record until Ctrl+C
.build/release/AudioRecorder

# Record for 60 seconds
.build/release/AudioRecorder --duration 60
```

Output: `recording_YYYYMMDD_HHMMSS.wav` in the current directory.

## Requirements

- macOS 15.0 (Sequoia) or later
- Xcode Command Line Tools (`xcode-select --install`)

## Permissions

macOS does **not** prompt CLI tools for permissions. You must grant manually:

1. **System Settings → Privacy & Security → Screen & System Audio Recording** → enable your terminal app
2. **System Settings → Privacy & Security → Microphone** → enable your terminal app
3. **Restart your terminal** (quit and reopen — required for permissions to take effect)

If permissions are missing, the tool exits with a clear error message within 3 seconds instead of hanging.

## Features

- **System audio + microphone** mixed into one file — hear both in a single recording
- **Unlimited recording duration** — automatic RF64 upgrade when file exceeds 4GB (EBU Tech 3306)
- **Graceful Ctrl+C** — always produces a valid, playable file even when interrupted
- **Zero setup** — no BlackHole, no virtual audio drivers, no Audio MIDI configuration
- **Headphone-friendly** — no echo/feedback when recording with headphones
- **Automatic sample rate conversion** — handles mic/system rate mismatches transparently

## Output Format

| Property | Value |
|----------|-------|
| Format | WAV (RIFF/WAVE), auto-upgrades to RF64 if >4GB |
| Sample Rate | 48,000 Hz |
| Channels | 2 (Stereo) |
| Bit Depth | 16-bit signed integer (PCM) |
| Max Duration | Unlimited (RF64) |
| Compatibility | macOS (afplay, QuickTime), Windows, Linux, all DAWs |

## How It Works

macOS blocks apps from capturing system audio by default. This tool uses Apple's ScreenCaptureKit (macOS 15+) which provides both system audio and microphone capture in a single API — no virtual audio drivers needed.

```
SCStream (ScreenCaptureKit)
  ├── .audio callback → systemRing (lock-protected)
  ├── .microphone callback → resample → micRing (lock-protected)
  │
  └── Writer Thread
        ├── AlignedDrainer: emit when both sources have data
        ├── AudioMixer: sum + clamp
        └── WAVWriter: PCM → WAV/RF64 → disk
```

1. Captures system audio and microphone via a single `SCStream`
2. Writes PCM samples into ring buffers (real-time safe — no disk I/O in callbacks)
3. A writer thread drains both buffers in lockstep, mixes, and writes to disk
4. On Ctrl+C or `--duration` expiry, flushes remaining audio and finalizes the WAV header

## Technical Details

- **Ring buffers** with `os_unfair_lock` decouple audio callbacks from disk I/O — correct on both x86_64 and ARM64
- **Overflow drops oldest** data, preserving the most recent audio
- **AlignedDrainer** uses min(both sources) strategy — no false drift detection during system silence
- **RF64 (EBU Tech 3306)**: starts as standard WAV with JUNK placeholder; upgrades in-place if file exceeds 4GB
- **Signal handling**: SIGINT/SIGTERM via DispatchSource on serial queue with single-resume guard

## Tests

```bash
swift build

# Integration (22 specs): concurrency, overflow, pipeline, resampling, RF64
.build/debug/AudioRecorderIntegration

# E2E (19 specs): process lifecycle, recording, SIGINT stress, file validation
.build/debug/AudioRecorderE2E
```

## License

MIT
