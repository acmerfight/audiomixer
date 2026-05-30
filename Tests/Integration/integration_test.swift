import Foundation
import AudioRecorderLib

nonisolated(unsafe) var passed = 0
nonisolated(unsafe) var failed = 0

func check(_ ok: Bool, _ msg: String) {
    if ok { passed += 1; print("  ✓ \(msg)") }
    else { failed += 1; print("  ✗ \(msg)") }
}

print("═══ Integration: Full Pipeline Simulation ═══\n")

// MARK: - Test 1: 3-second simulated recording → valid WAV

do {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).wav")
    defer { try? FileManager.default.removeItem(at: url) }

    let sampleRate: UInt32 = 48000
    let channels: UInt16 = 2
    let seconds = 3
    let totalFrames = Int(sampleRate) * seconds

    // Simulate the full pipeline: RingBuffer → drain → mix → WAV
    let sysRing = RingBuffer(capacity: 48000 * 2 * 5)
    let micRing = RingBuffer(capacity: 48000 * 2 * 5)
    let writer = try WAVWriter(url: url, sampleRate: sampleRate, channels: channels, bitsPerSample: 16)

    // Feed data in 1024-frame chunks (typical ScreenCaptureKit buffer)
    let chunkFrames = 1024
    var framesProduced = 0

    while framesProduced < totalFrames {
        let n = min(chunkFrames, totalFrames - framesProduced)
        let stereoCount = n * Int(channels)

        // System: 440Hz sine
        var sysBuf = [Float](repeating: 0, count: stereoCount)
        for i in 0..<n {
            let t = Float(framesProduced + i) / Float(sampleRate)
            let v = sin(2.0 * .pi * 440.0 * t) * 0.5
            sysBuf[i * 2] = v; sysBuf[i * 2 + 1] = v
        }

        // Mic: 1000Hz sine
        var micBuf = [Float](repeating: 0, count: stereoCount)
        for i in 0..<n {
            let t = Float(framesProduced + i) / Float(sampleRate)
            let v = sin(2.0 * .pi * 1000.0 * t) * 0.3
            micBuf[i * 2] = v; micBuf[i * 2 + 1] = v
        }

        sysRing.write(sysBuf)
        micRing.write(micBuf)
        framesProduced += n

        // Simulate writer thread draining
        let aligned = min(sysRing.availableToRead, micRing.availableToRead)
        if aligned >= Int(sampleRate) * Int(channels) {
            let s = sysRing.read(count: aligned)
            let m = micRing.read(count: aligned)
            let mixed = AudioMixer.mix(system: s, mic: m)
            writer.write(samples: AudioMixer.toInt16(mixed))
        }
    }

    // Final flush
    let sRem = sysRing.read(count: sysRing.availableToRead)
    let mRem = micRing.read(count: micRing.availableToRead)
    if !sRem.isEmpty || !mRem.isEmpty {
        let mixed = AudioMixer.mix(system: sRem, mic: mRem)
        writer.write(samples: AudioMixer.toInt16(mixed))
    }
    writer.finalize()

    // Validate
    let data = try Data(contentsOf: url)
    let expectedBytes = totalFrames * Int(channels) * 2
    check(data.count == 44 + expectedBytes, "File size: \(data.count) = 44 + \(expectedBytes)")

    let riffSize: UInt32 = data[4..<8].withUnsafeBytes { $0.load(as: UInt32.self) }
    check(riffSize == UInt32(data.count - 8), "RIFF size correct")

    let dataSize: UInt32 = data[40..<44].withUnsafeBytes { $0.load(as: UInt32.self) }
    check(dataSize == UInt32(expectedBytes), "Data chunk size correct")

    // Verify non-silence
    var peak: Int16 = 0
    data[44...].withUnsafeBytes { buf in
        for s in buf.bindMemory(to: Int16.self) {
            let a = s < 0 ? -s : s
            if a > peak { peak = a }
        }
    }
    check(peak > 1000, "Audio is not silence (peak: \(peak))")

    let expectedPeak = Int16(0.8 * 32767)
    check(abs(Int(peak) - Int(expectedPeak)) < 600, "Peak ≈ 0.8 (got \(peak), expect ~\(expectedPeak))")

    // afinfo validation
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/afinfo")
    proc.arguments = [url.path]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = pipe
    try proc.run()
    proc.waitUntilExit()
    let info = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    check(proc.terminationStatus == 0, "afinfo validates WAV")
    if proc.terminationStatus == 0 {
        let fmt = info.components(separatedBy: "\n").first { $0.contains("Data format") } ?? ""
        let dur = info.components(separatedBy: "\n").first { $0.contains("estimated duration") } ?? ""
        print("    → \(fmt.trimmingCharacters(in: .whitespaces))")
        print("    → \(dur.trimmingCharacters(in: .whitespaces))")
    }
}

// MARK: - Test 2: Resampling in pipeline (44.1kHz mic → 48kHz)

print("\n═══ Integration: Mic Resampling 44.1kHz → 48kHz ═══\n")

do {
    // Simulate 10ms of mic audio at 44100Hz mono
    let micFrames = 441
    let micMono = (0..<micFrames).map { Float(sin(2.0 * .pi * 1000.0 * Double($0) / 44100.0)) * 0.3 }

    // Resample to 48kHz
    let resampled = Resampler.resample(micMono, fromRate: 44100, toRate: 48000, channels: 1)
    check(resampled.count == 480, "10ms @ 44.1kHz → 480 samples @ 48kHz (got \(resampled.count))")

    // Convert mono → stereo
    var stereo = [Float](repeating: 0, count: resampled.count * 2)
    for i in 0..<resampled.count {
        stereo[i * 2] = resampled[i]
        stereo[i * 2 + 1] = resampled[i]
    }
    check(stereo.count == 960, "Stereo expansion correct")

    // Verify signal integrity
    let peakAfterResample = resampled.max()!
    check(peakAfterResample > 0.25 && peakAfterResample < 0.35, "Peak preserved after resample (~0.3, got \(peakAfterResample))")
}

// MARK: - Test 3: Drift compensation over 1 hour

print("\n═══ Integration: 1-Hour Drift Simulation ═══\n")

do {
    let detector = DriftDetector(nominalSampleRate: 48000)

    // +50ppm drift over 1 hour: 48000*3600*1.00005 = 172,808,640
    let drift = detector.computeDrift(samplesReceived: 172_808_640, elapsedPTS: 3600.0)
    check(drift == 8640, "1h @ +50ppm = 8640 samples drift (got \(drift))")
    print("    → \(Double(drift) / 48000 * 1000)ms accumulated drift")

    // Verify compensation at per-second granularity
    let perSecondDrift = 8640 / 3600 // ~2 samples/sec
    let oneSecBuffer = [Float](repeating: 0.5, count: 48000)
    let corrected = Resampler.compensateDrift(oneSecBuffer, driftSamples: perSecondDrift, channels: 1)
    check(corrected.count == 48000 - perSecondDrift, "Per-second correction: \(48000) → \(corrected.count)")
    print("    → Correction: \(perSecondDrift) samples/sec = \(Double(perSecondDrift)/48.0)µs/sec (inaudible)")
}

// MARK: - Test 4: RingBuffer under simulated real-time pressure

print("\n═══ Integration: RingBuffer Producer/Consumer ═══\n")

do {
    let ring = RingBuffer(capacity: 48000 * 2 * 2) // 2 seconds
    var totalWritten = 0
    var totalRead = 0

    // Simulate 5 seconds: producer writes 1024 stereo samples at a time,
    // consumer reads 4096 at a time (slower cadence)
    let totalSamples = 48000 * 2 * 5
    let writeChunk = 1024 * 2
    let readChunk = 4096 * 2
    var writePos = 0

    while totalRead < totalSamples {
        // Producer: write as much as fits
        while writePos < totalSamples && ring.availableToWrite >= writeChunk {
            let chunk = [Float](repeating: 0.5, count: min(writeChunk, totalSamples - writePos))
            ring.write(chunk)
            writePos += chunk.count
            totalWritten += chunk.count
        }

        // Consumer: read what's available
        let available = ring.availableToRead
        if available >= readChunk {
            let data = ring.read(count: readChunk)
            totalRead += data.count
        } else if writePos >= totalSamples {
            let data = ring.read(count: available)
            totalRead += data.count
            if data.isEmpty { break }
        }
    }

    check(totalRead == totalSamples, "All \(totalSamples) samples flowed through ring (got \(totalRead))")
}

// MARK: - Results

print("\n" + String(repeating: "═", count: 50))
print("Integration: \(passed) passed, \(failed) failed")
if failed > 0 { print("FAILED"); exit(1) }
else { print("ALL INTEGRATION TESTS PASSED ✓"); exit(0) }
