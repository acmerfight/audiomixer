import Foundation

/// Drains two ring buffers in lockstep, ensuring aligned output.
///
/// Strategy (derived from atacan/record's production-verified approach):
///   1. Output = min(systemAvailable, micAvailable) — only emit when both have data
///   2. If one source is more than `maxDriftSeconds` ahead, truncate its excess
///   3. On flush, emit whatever remains (including single-source data)
///
/// This avoids the false-drift-detection problem where system audio silence
/// (ScreenCaptureKit not sending callbacks) would be misinterpreted as clock drift.
public struct AlignedDrainer: Sendable {
    private let sampleRate: Int
    private let channels: Int
    private let maxDriftSamples: Int
    private let minChunkSamples: Int

    public struct DrainResult: Sendable {
        public let system: [Float]
        public let mic: [Float]
    }

    /// - Parameters:
    ///   - sampleRate: Nominal sample rate (e.g. 48000)
    ///   - channels: Channel count (e.g. 2 for stereo)
    ///   - maxDriftSeconds: Maximum allowed difference before truncation (default: 2.0)
    ///   - minChunkFrames: Minimum frames before emitting (default: 1024)
    public init(
        sampleRate: UInt32,
        channels: UInt16,
        maxDriftSeconds: Double = 2.0,
        minChunkFrames: Int = 1024
    ) {
        self.sampleRate = Int(sampleRate)
        self.channels = Int(channels)
        self.maxDriftSamples = Int(Double(sampleRate) * Double(channels) * maxDriftSeconds)
        self.minChunkSamples = minChunkFrames * Int(channels)
    }

    /// Drains aligned samples from both buffers.
    /// Returns empty arrays if not enough data is available (unless flush=true).
    public func drain(system: RingBuffer, mic: RingBuffer, flush: Bool = false) -> DrainResult {
        var sysAvailable = system.availableToRead
        var micAvailable = mic.availableToRead

        // Truncate leading source if drift exceeds threshold
        trimExcessDrift(system: system, mic: mic, sysAvailable: &sysAvailable, micAvailable: &micAvailable)

        let aligned = min(sysAvailable, micAvailable)

        // Check minimum threshold (unless flushing)
        if !flush && aligned < minChunkSamples {
            // On flush with no alignment possible, return unmatched data
            return DrainResult(system: [], mic: [])
        }

        if flush && aligned == 0 {
            // Flush mode: return whatever single source has remaining
            let sysData = sysAvailable > 0 ? system.read(count: sysAvailable) : []
            let micData = micAvailable > 0 ? mic.read(count: micAvailable) : []
            return DrainResult(system: sysData, mic: micData)
        }

        let count = flush ? aligned : min(aligned, sampleRate * channels) // Cap at 1 second per drain
        let sysData = system.read(count: count)
        let micData = mic.read(count: count)
        return DrainResult(system: sysData, mic: micData)
    }

    private func trimExcessDrift(
        system: RingBuffer,
        mic: RingBuffer,
        sysAvailable: inout Int,
        micAvailable: inout Int
    ) {
        // Only truncate when BOTH sources have data.
        // If one source is empty, it means that source is silent (not sending callbacks).
        // Truncating the other would destroy valid data.
        guard sysAvailable > 0 && micAvailable > 0 else { return }

        let diff = sysAvailable - micAvailable

        if diff > maxDriftSamples {
            let excess = diff - maxDriftSamples
            _ = system.read(count: excess)
            sysAvailable -= excess
        } else if -diff > maxDriftSamples {
            let excess = -diff - maxDriftSamples
            _ = mic.read(count: excess)
            micAvailable -= excess
        }
    }
}
