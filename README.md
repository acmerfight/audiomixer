# AudioMixer

A macOS command-line tool that records system audio and microphone input simultaneously into a single WAV file.

Built with Apple's ScreenCaptureKit (macOS 15+). No virtual audio drivers, no third-party dependencies.

## Features

- Records system audio (all app sounds) + microphone into one file
- Lock-free SPSC ring buffer architecture — real-time safe audio callbacks
- Automatic sample rate conversion when mic differs from system
- Overflow-safe: drops oldest buffered audio, never loses recent content
- Aligned draining with 2-second drift tolerance
- Pure Swift, zero dependencies beyond Apple frameworks

## Requirements

- macOS 15.0 (Sequoia) or later
- Xcode Command Line Tools (`xcode-select --install`)
- Permissions: Screen Recording + Microphone (granted to your terminal app)

## Build

```bash
swift build -c release
```

Binary output: `.build/release/AudioRecorder`

## Usage

```bash
# Record until Ctrl+C
.build/release/AudioRecorder

# Record for 30 seconds
.build/release/AudioRecorder --duration 30
```

Output: `recording_YYYYMMDD_HHMMSS.wav` (PCM Int16, 48kHz, Stereo)

## Permissions Setup

macOS does **not** prompt CLI tools for permissions. You must grant manually:

1. **System Settings → Privacy & Security → Screen & System Audio Recording** → enable your terminal app
2. **System Settings → Privacy & Security → Microphone** → enable your terminal app
3. **Restart your terminal** (quit and reopen — required for permissions to take effect)

If permissions are missing, the tool exits with a clear error message within 3 seconds instead of hanging.

## Architecture

```
SCStream (ScreenCaptureKit)
  ├── .audio callback → systemRing (lock-free SPSC)
  ├── .microphone callback → resample → micRing (lock-free SPSC)
  │
  └── Writer Thread (50ms poll)
        ├── AlignedDrainer: min(sys, mic) + 2s drift truncation
        ├── AudioMixer: clamp(sys + mic)
        └── WAVWriter: PCM Int16 → disk
```

Key design decisions:
- **Ring buffers** decouple real-time audio callbacks from disk I/O (FileHandle.write can block)
- **Overflow drops oldest** data, preserving the most recent audio
- **AlignedDrainer** uses min(both sources) strategy — no false drift detection during system silence
- **Linear interpolation** resampling — sufficient for 44.1↔48kHz conversion in speech/system audio

## Tests

```bash
swift build

# Integration tests — concurrency, overflow, pipeline, resampling (15 specs)
.build/debug/AudioRecorderIntegration

# E2E tests — process lifecycle, recording, SIGINT, file validation (18 specs)
.build/debug/AudioRecorderE2E
```

## How It Works

macOS does not expose system audio output to third-party apps by default. ScreenCaptureKit (macOS 15+) provides `captureMicrophone` alongside `capturesAudio` on a single `SCStream`, delivering both as separate `CMSampleBuffer` callbacks.

This tool:
1. Configures an `SCStream` with minimal video (2x2px) and audio capture enabled
2. Receives system audio and microphone PCM in real-time callbacks
3. Writes samples into lock-free ring buffers (no allocations, no locks on audio thread)
4. A writer thread drains both buffers in lockstep, mixes, and writes WAV to disk

## License

MIT
