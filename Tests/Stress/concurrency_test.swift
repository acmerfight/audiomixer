import Foundation
import AudioRecorderLib

/// Stress tests to verify thread safety and overflow behavior empirically.
/// Not speculation — run it and observe.

nonisolated(unsafe) var passed = 0
nonisolated(unsafe) var failed = 0

func check(_ ok: Bool, _ msg: String) {
    if ok { passed += 1; print("  ✓ \(msg)") }
    else { failed += 1; print("  ✗ \(msg)") }
}

// ═══════════════════════════════════════════════════════════════
// Test 1: RingBuffer concurrent SPSC — producer on one thread,
// consumer on another. Verify no data loss or corruption.
// ═══════════════════════════════════════════════════════════════

print("═══ Concurrency: RingBuffer SPSC stress test ═══\n")

do {
    let iterations = 1_000_000
    let ring = RingBuffer(capacity: 4096)
    var totalWritten = 0
    var totalRead = 0
    var corruptionDetected = false

    let producerDone = DispatchSemaphore(value: 0)
    let consumerDone = DispatchSemaphore(value: 0)

    // Producer: write sequential values so consumer can verify order
    let producerQueue = DispatchQueue(label: "producer", qos: .userInteractive)
    producerQueue.async {
        var value: Float = 0
        var written = 0
        while written < iterations {
            let batchSize = min(64, iterations - written)
            var batch = [Float](repeating: 0, count: batchSize)
            for i in 0..<batchSize {
                batch[i] = value
                value += 1
            }
            ring.write(batch)
            written += batchSize
        }
        totalWritten = written
        producerDone.signal()
    }

    // Consumer: read and verify sequential order
    let consumerQueue = DispatchQueue(label: "consumer", qos: .userInitiated)
    consumerQueue.async {
        var expectedValue: Float = 0
        var read = 0
        var spins = 0

        while read < iterations {
            let data = ring.read(count: 128)
            if data.isEmpty {
                spins += 1
                if spins > 10_000_000 {
                    // Timeout — producer may have finished but we missed data
                    break
                }
                continue
            }
            spins = 0
            for sample in data {
                if sample != expectedValue {
                    corruptionDetected = true
                    break
                }
                expectedValue += 1
            }
            read += data.count
            if corruptionDetected { break }
        }
        totalRead = read
        consumerDone.signal()
    }

    producerDone.wait()
    consumerDone.wait()

    check(!corruptionDetected, "No data corruption in 1M samples across 2 threads")
    check(totalRead == iterations, "All \(iterations) samples transferred (got \(totalRead))")
    if totalRead != iterations {
        print("    Note: \(iterations - totalRead) samples lost (overflow or timing)")
    }
}

// ═══════════════════════════════════════════════════════════════
// Test 2: RingBuffer overflow behavior — verify what happens
// when producer outpaces consumer
// ═══════════════════════════════════════════════════════════════

print("\n═══ Overflow: RingBuffer full behavior ═══\n")

do {
    let ring = RingBuffer(capacity: 100)

    // Write 150 samples into capacity-100 ring (no consumer)
    let first50: [Float] = (0..<50).map { Float($0) }
    let next50: [Float] = (50..<100).map { Float($0) }
    let overflow50: [Float] = (100..<150).map { Float($0) }

    ring.write(first50)
    ring.write(next50)
    // Ring is now full (99 usable slots in power-of-2 or capacity-1 SPSC)
    let availableBeforeOverflow = ring.availableToRead
    ring.write(overflow50)
    let availableAfterOverflow = ring.availableToRead

    print("  Capacity: 100")
    print("  Available before overflow write: \(availableBeforeOverflow)")
    print("  Available after overflow write: \(availableAfterOverflow)")

    // Read whatever is there and check what data we got
    let data = ring.read(count: ring.availableToRead)
    let firstSample = data.first ?? -1
    let lastSample = data.last ?? -1

    print("  Samples read: \(data.count)")
    print("  First sample: \(firstSample) (0 = oldest kept, >0 = oldest dropped)")
    print("  Last sample: \(lastSample)")

    // Determine overflow policy
    if firstSample == 0 {
        check(true, "Overflow policy: NEW data dropped (oldest preserved)")
        print("    → This means: if system is silent 10s, newest mic data is lost")
    } else if lastSample == 149 {
        check(true, "Overflow policy: OLD data dropped (newest preserved)")
        print("    → This means: always have most recent audio (ideal)")
    } else {
        check(false, "Overflow policy: UNKNOWN behavior (first=\(firstSample) last=\(lastSample))")
    }
}

// ═══════════════════════════════════════════════════════════════
// Test 3: Simulate the actual recording scenario —
// system silent for 5 seconds while mic produces data.
// Verify what happens to mic data.
// ═══════════════════════════════════════════════════════════════

print("\n═══ Scenario: System silent 5s, mic active ═══\n")

do {
    // Same ring size as CaptureEngine: 48000 * 2 * 10 = 960000 (10 seconds stereo)
    let micRing = RingBuffer(capacity: 48000 * 2 * 10)
    let sysRing = RingBuffer(capacity: 48000 * 2 * 10)

    // Simulate: mic produces 5 seconds of data, system produces nothing
    let fiveSecondsStereo = 48000 * 2 * 5 // 480000 samples
    let micData = [Float](repeating: 0.5, count: fiveSecondsStereo)
    micRing.write(micData)

    let micAvailable = micRing.availableToRead
    let sysAvailable = sysRing.availableToRead

    print("  After 5s silence: mic has \(micAvailable) samples, sys has \(sysAvailable)")
    check(micAvailable == fiveSecondsStereo, "Mic data preserved during system silence (\(micAvailable)/\(fiveSecondsStereo))")
    check(sysAvailable == 0, "System ring empty as expected")

    // Now simulate: system starts producing again (1 second)
    let oneSecondStereo = 48000 * 2
    sysRing.write([Float](repeating: 0.3, count: oneSecondStereo))

    // Use AlignedDrainer
    let drainer = AlignedDrainer(sampleRate: 48000, channels: 2, minChunkFrames: 0)
    let result = drainer.drain(system: sysRing, mic: micRing)

    print("  After system resumes: drained sys=\(result.system.count) mic=\(result.mic.count)")
    check(result.system.count == result.mic.count, "Output is aligned")
    check(result.system.count == oneSecondStereo, "Output = 1 second (limited by system)")

    // After drain: AlignedDrainer truncates mic excess beyond 2s threshold before draining.
    // mic had 5s, sys had 1s → diff=4s > 2s → mic truncated to sys+2s = 3s → drain 1s → mic remains 2s
    let micRemaining = micRing.availableToRead
    let sysRemaining = sysRing.availableToRead
    print("  Mic remaining: \(micRemaining) (\(Double(micRemaining)/(48000*2))s), sys remaining: \(sysRemaining)")
    let maxDiff = 48000 * 2 * 2  // 2 seconds threshold
    check(micRemaining - sysRemaining <= maxDiff, "Mic-sys gap ≤ 2s after drain (gap=\(micRemaining - sysRemaining))")
}

// ═══════════════════════════════════════════════════════════════
// Test 4: Simulate 10s system silence (exceeds ring buffer) —
// What happens when mic fills the ring?
// ═══════════════════════════════════════════════════════════════

print("\n═══ Scenario: System silent >10s (ring overflow) ═══\n")

do {
    let capacity = 48000 * 2 * 10 // 10 seconds
    let micRing = RingBuffer(capacity: capacity)
    let sysRing = RingBuffer(capacity: capacity)

    // Simulate: mic produces 12 seconds (exceeds 10s ring capacity)
    let twelveSec = 48000 * 2 * 12
    // Write in 1-second chunks to be realistic
    for sec in 0..<12 {
        let chunk = [Float](repeating: Float(sec), count: 48000 * 2)
        micRing.write(chunk)
    }

    let micAvailable = micRing.availableToRead
    print("  After 12s mic into 10s ring: available = \(micAvailable)")
    print("  Ring capacity: \(capacity)")

    // Read and check: which data survived?
    let surviving = micRing.read(count: micAvailable)
    let firstSurvivingSec = surviving.first ?? -1
    let lastSurvivingSec = surviving.last ?? -1
    print("  First surviving sample value: \(firstSurvivingSec) (expected: 0 if old kept, 2+ if old dropped)")
    print("  Last surviving sample value: \(lastSurvivingSec)")

    if firstSurvivingSec == 0 {
        print("  → CONCLUSION: Overflow drops NEW data. Oldest 10s kept, newest 2s LOST.")
        print("  → RISK: In your scenario, if system silent >10s, most recent mic audio is lost.")
        check(false, "Overflow policy is suboptimal for recording (drops newest)")
    } else {
        print("  → CONCLUSION: Overflow drops OLD data. Newest audio preserved.")
        check(true, "Overflow policy is optimal for recording (keeps newest)")
    }
}

// ═══════════════════════════════════════════════════════════════
// Results
// ═══════════════════════════════════════════════════════════════

print("\n" + String(repeating: "═", count: 50))
print("Concurrency/Overflow: \(passed) passed, \(failed) failed")
if failed > 0 { print("ISSUES FOUND — SEE ABOVE"); exit(1) }
else { print("ALL PASSED ✓"); exit(0) }
