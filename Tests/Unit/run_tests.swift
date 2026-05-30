import Foundation
import AudioRecorderLib

// MARK: - Test Harness

nonisolated(unsafe) var testsPassed = 0
nonisolated(unsafe) var testsFailed = 0

func describe(_ context: String, _ block: () -> Void) {
    print("  \(context)")
    block()
}

func it(_ behavior: String, _ block: () throws -> Void) {
    do {
        try block()
        testsPassed += 1
        print("    ✓ \(behavior)")
    } catch {
        testsFailed += 1
        print("    ✗ \(behavior)")
        print("      Error: \(error)")
    }
}

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ msg: String) { description = msg }
}

func expect<T: Equatable>(_ actual: T, toBe expected: T) throws {
    guard actual == expected else { throw Failure("Expected \(expected), got \(actual)") }
}

func expectClose(_ actual: Float, _ expected: Float, accuracy: Float = 1e-5) throws {
    guard abs(actual - expected) <= accuracy else { throw Failure("Expected ~\(expected), got \(actual)") }
}

func expectClose(_ actual: Int16, _ expected: Int16, accuracy: Int16 = 1) throws {
    guard abs(Int(actual) - Int(expected)) <= Int(accuracy) else { throw Failure("Expected ~\(expected), got \(actual)") }
}

// ═══════════════════════════════════════════════════════════════
// MARK: - WAVWriter Specs
// ═══════════════════════════════════════════════════════════════

print("\nWAVWriter")

describe("header format") {
    it("writes valid 44-byte RIFF/WAVE/fmt/data structure") {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try WAVWriter(url: url, sampleRate: 48000, channels: 2, bitsPerSample: 16)
        writer.finalize()

        let d = try Data(contentsOf: url)
        try expect(d.count, toBe: 44)
        try expect(String(data: d[0..<4], encoding: .ascii)!, toBe: "RIFF")
        try expect(String(data: d[8..<12], encoding: .ascii)!, toBe: "WAVE")
        try expect(String(data: d[12..<16], encoding: .ascii)!, toBe: "fmt ")
        try expect(String(data: d[36..<40], encoding: .ascii)!, toBe: "data")

        let sr: UInt32 = d[24..<28].withUnsafeBytes { $0.load(as: UInt32.self) }
        try expect(sr, toBe: 48000)
        let ch: UInt16 = d[22..<24].withUnsafeBytes { $0.load(as: UInt16.self) }
        try expect(ch, toBe: 2)
        let bps: UInt16 = d[34..<36].withUnsafeBytes { $0.load(as: UInt16.self) }
        try expect(bps, toBe: 16)
    }

    it("updates data chunk size after writing samples") {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try WAVWriter(url: url, sampleRate: 48000, channels: 2, bitsPerSample: 16)
        writer.write(samples: [Int16](repeating: 1000, count: 960))
        writer.finalize()

        let d = try Data(contentsOf: url)
        let dataSize: UInt32 = d[40..<44].withUnsafeBytes { $0.load(as: UInt32.self) }
        try expect(dataSize, toBe: 1920)
    }

    it("sets RIFF size = file size - 8") {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try WAVWriter(url: url, sampleRate: 48000, channels: 2, bitsPerSample: 16)
        writer.write(samples: [Int16](repeating: 0, count: 480))
        writer.finalize()

        let d = try Data(contentsOf: url)
        let riffSize: UInt32 = d[4..<8].withUnsafeBytes { $0.load(as: UInt32.self) }
        try expect(riffSize, toBe: UInt32(d.count - 8))
    }
}

// ═══════════════════════════════════════════════════════════════
// MARK: - AudioMixer Specs
// ═══════════════════════════════════════════════════════════════

print("\nAudioMixer")

describe("mixing") {
    it("sums two equal-length arrays") {
        let r = AudioMixer.mix(system: [0.5, -0.3], mic: [0.1, 0.4])
        try expectClose(r[0], 0.6)
        try expectClose(r[1], 0.1)
    }

    it("clamps result to [-1, 1]") {
        let r = AudioMixer.mix(system: [0.8, -0.9], mic: [0.5, -0.5])
        try expectClose(r[0], 1.0)
        try expectClose(r[1], -1.0)
    }

    it("zero-pads shorter array") {
        let r = AudioMixer.mix(system: [0.5, 0.3, 0.2], mic: [0.1])
        try expect(r.count, toBe: 3)
        try expectClose(r[1], 0.3)
        try expectClose(r[2], 0.2)
    }
}

describe("Float32 → Int16") {
    it("maps full range correctly") {
        let r = AudioMixer.toInt16([1.0, -1.0, 0.0])
        try expect(r[0], toBe: 32767)
        try expect(r[1], toBe: -32767)
        try expect(r[2], toBe: 0)
    }

    it("clamps values beyond [-1, 1]") {
        let r = AudioMixer.toInt16([1.5, -2.0])
        try expect(r[0], toBe: 32767)
        try expect(r[1], toBe: -32767)
    }
}

// ═══════════════════════════════════════════════════════════════
// MARK: - DriftDetector Specs
// ═══════════════════════════════════════════════════════════════

print("\nDriftDetector")

describe("detection") {
    it("reports zero when on-time") {
        let d = DriftDetector(nominalSampleRate: 48000)
        try expect(d.computeDrift(samplesReceived: 480000, elapsedPTS: 10.0), toBe: 0)
    }

    it("reports positive drift when fast") {
        let d = DriftDetector(nominalSampleRate: 48000)
        try expect(d.computeDrift(samplesReceived: 480480, elapsedPTS: 10.0), toBe: 480)
    }

    it("reports negative drift when slow") {
        let d = DriftDetector(nominalSampleRate: 48000)
        try expect(d.computeDrift(samplesReceived: 479520, elapsedPTS: 10.0), toBe: -480)
    }
}

// ═══════════════════════════════════════════════════════════════
// MARK: - Resampler Specs
// ═══════════════════════════════════════════════════════════════

print("\nResampler")

describe("sample rate conversion") {
    it("upsamples 44100→48000 mono correctly") {
        // 441 samples at 44100 = 10ms → should become 480 samples at 48000
        let input = (0..<441).map { Float(sin(2.0 * .pi * 440.0 * Double($0) / 44100.0)) }
        let output = Resampler.resample(input, fromRate: 44100, toRate: 48000, channels: 1)
        try expect(output.count, toBe: 480)
    }

    it("downsamples 96000→48000 correctly") {
        let input = [Float](repeating: 0.5, count: 960) // 10ms at 96kHz
        let output = Resampler.resample(input, fromRate: 96000, toRate: 48000, channels: 1)
        try expect(output.count, toBe: 480)
    }

    it("passes through when rates match") {
        let input: [Float] = [0.1, 0.2, 0.3, 0.4]
        let output = Resampler.resample(input, fromRate: 48000, toRate: 48000, channels: 1)
        try expect(output.count, toBe: 4)
        try expectClose(output[0], 0.1)
        try expectClose(output[3], 0.4)
    }

    it("handles stereo interleaved correctly") {
        // 2 frames of stereo at 48000 → 2 frames at 48000 (no change)
        let input: [Float] = [0.1, 0.2, 0.3, 0.4] // L,R,L,R
        let output = Resampler.resample(input, fromRate: 48000, toRate: 48000, channels: 2)
        try expect(output.count, toBe: 4)
    }
}

describe("drift compensation via resampling") {
    it("stretches by inserting samples when slow") {
        let input = [Float](repeating: 0.5, count: 1000)
        let output = Resampler.compensateDrift(input, driftSamples: -10, channels: 1)
        try expect(output.count, toBe: 1010)
    }

    it("shrinks by removing samples when fast") {
        let input = [Float](repeating: 0.5, count: 1000)
        let output = Resampler.compensateDrift(input, driftSamples: 10, channels: 1)
        try expect(output.count, toBe: 990)
    }

    it("does nothing when drift is zero") {
        let input = [Float](repeating: 0.5, count: 1000)
        let output = Resampler.compensateDrift(input, driftSamples: 0, channels: 1)
        try expect(output.count, toBe: 1000)
    }
}

// ═══════════════════════════════════════════════════════════════
// MARK: - RingBuffer Specs
// ═══════════════════════════════════════════════════════════════

print("\nRingBuffer")

describe("thread-safe SPSC buffer") {
    it("writes and reads back correctly") {
        let rb = RingBuffer(capacity: 1024)
        let data: [Float] = [0.1, 0.2, 0.3, 0.4, 0.5]
        rb.write(data)
        let read = rb.read(count: 5)
        try expect(read.count, toBe: 5)
        try expectClose(read[0], 0.1)
        try expectClose(read[4], 0.5)
    }

    it("returns empty array when nothing available") {
        let rb = RingBuffer(capacity: 1024)
        let read = rb.read(count: 10)
        try expect(read.count, toBe: 0)
    }

    it("reports available count accurately") {
        let rb = RingBuffer(capacity: 1024)
        rb.write([Float](repeating: 0, count: 100))
        try expect(rb.availableToRead, toBe: 100)
        _ = rb.read(count: 30)
        try expect(rb.availableToRead, toBe: 70)
    }

    it("wraps around capacity boundary") {
        let rb = RingBuffer(capacity: 8)
        rb.write([1, 2, 3, 4, 5, 6])
        _ = rb.read(count: 4)
        rb.write([7, 8, 9, 10])
        let read = rb.read(count: 6)
        try expect(read.count, toBe: 6)
        try expectClose(read[0], 5.0)
        try expectClose(read[5], 10.0)
    }
}

// ═══════════════════════════════════════════════════════════════
// MARK: - AlignedDrainer Specs
// ═══════════════════════════════════════════════════════════════

print("\nAlignedDrainer")

describe("aligned draining") {
    it("outputs min(system, mic) samples when both have data") {
        let sys = RingBuffer(capacity: 4096)
        let mic = RingBuffer(capacity: 4096)
        sys.write([Float](repeating: 0.3, count: 1000))
        mic.write([Float](repeating: 0.2, count: 600))

        let drainer = AlignedDrainer(sampleRate: 48000, channels: 2, minChunkFrames: 0)
        let result = drainer.drain(system: sys, mic: mic)

        try expect(result.system.count, toBe: 600)
        try expect(result.mic.count, toBe: 600)
    }

    it("returns empty when neither has enough data for threshold") {
        let sys = RingBuffer(capacity: 4096)
        let mic = RingBuffer(capacity: 4096)
        sys.write([Float](repeating: 0.1, count: 100))
        mic.write([Float](repeating: 0.1, count: 100))

        let drainer = AlignedDrainer(sampleRate: 48000, channels: 2, minChunkFrames: 1024)
        let result = drainer.drain(system: sys, mic: mic)

        try expect(result.system.count, toBe: 0)
        try expect(result.mic.count, toBe: 0)
    }

    it("returns all data when flush is true regardless of threshold") {
        let sys = RingBuffer(capacity: 4096)
        let mic = RingBuffer(capacity: 4096)
        sys.write([Float](repeating: 0.1, count: 100))
        mic.write([Float](repeating: 0.1, count: 50))

        let drainer = AlignedDrainer(sampleRate: 48000, channels: 2, minChunkFrames: 1024)
        let result = drainer.drain(system: sys, mic: mic, flush: true)

        try expect(result.system.count, toBe: 50)
        try expect(result.mic.count, toBe: 50)
    }

    it("truncates leading source when drift exceeds 2 seconds") {
        let sys = RingBuffer(capacity: 48000 * 2 * 5)
        let mic = RingBuffer(capacity: 48000 * 2 * 5)

        // System has 3 seconds of data, mic has 0.5 seconds
        // Difference = 2.5 seconds > 2 second threshold
        let sysCount = 48000 * 2 * 3
        let micCount = 48000 * 2 / 2
        sys.write([Float](repeating: 0.5, count: sysCount))
        mic.write([Float](repeating: 0.3, count: micCount))

        let drainer = AlignedDrainer(sampleRate: 48000, channels: 2, minChunkFrames: 0)
        let result = drainer.drain(system: sys, mic: mic)

        // After truncation: system should have been trimmed so that
        // system - mic <= 2 seconds (192000 samples)
        // Then output = min(trimmed system, mic) = mic count
        try expect(result.mic.count, toBe: micCount)
        // System remainder after drain should be <= 2 seconds
        try expect(sys.availableToRead <= 48000 * 2 * 2, toBe: true)
    }

    it("does not truncate when system is silent (mic ahead is normal)") {
        let sys = RingBuffer(capacity: 4096)
        let mic = RingBuffer(capacity: 48000 * 2 * 5)

        // Only mic has data (system is silent — no callbacks)
        mic.write([Float](repeating: 0.3, count: 48000 * 2 * 3))

        let drainer = AlignedDrainer(sampleRate: 48000, channels: 2, minChunkFrames: 1024)
        let result = drainer.drain(system: sys, mic: mic)

        // Cannot output anything — system has no data
        try expect(result.system.count, toBe: 0)
        // Mic should NOT be truncated (it's waiting for system to catch up)
        try expect(mic.availableToRead, toBe: 48000 * 2 * 3)
    }

    it("flushes remaining mic data when system is empty and flush=true") {
        let sys = RingBuffer(capacity: 4096)
        let mic = RingBuffer(capacity: 4096)
        mic.write([Float](repeating: 0.4, count: 200))

        let drainer = AlignedDrainer(sampleRate: 48000, channels: 2, minChunkFrames: 0)
        let result = drainer.drain(system: sys, mic: mic, flush: true)

        // On flush, output whatever is available (pad shorter with zeros)
        try expect(result.mic.count, toBe: 200)
        try expect(result.system.count, toBe: 0)
    }
}

// ═══════════════════════════════════════════════════════════════
// Results
// ═══════════════════════════════════════════════════════════════

print("\n" + String(repeating: "─", count: 50))
print("Results: \(testsPassed) passed, \(testsFailed) failed")
if testsFailed > 0 {
    exit(1)
} else {
    print("ALL TESTS PASSED ✓")
    exit(0)
}
