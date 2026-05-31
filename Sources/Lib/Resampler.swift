import Foundation

/// Audio resampling using linear interpolation.
/// Operates on interleaved Float32 PCM buffers.
public enum Resampler {

    /// Resamples interleaved audio from one sample rate to another.
    /// Returns the resampled buffer. If rates are equal, returns input unchanged.
    public static func resample(
        _ input: [Float],
        fromRate sourceRate: Int,
        toRate targetRate: Int,
        channels: Int
    ) -> [Float] {
        guard sourceRate != targetRate, !input.isEmpty, channels > 0 else { return input }

        let inputFrames = input.count / channels
        let outputFrames = Int((Double(inputFrames) * Double(targetRate) / Double(sourceRate)).rounded())
        guard outputFrames > 0 else { return [] }

        let ratio = Double(inputFrames - 1) / Double(max(outputFrames - 1, 1))
        let output = [Float](unsafeUninitializedCapacity: outputFrames * channels) { buffer, count in
            for frame in 0..<outputFrames {
                let srcPos = Double(frame) * ratio
                let idx = Int(srcPos)
                let frac = Float(srcPos - Double(idx))
                let nextIdx = min(idx + 1, inputFrames - 1)

                for ch in 0..<channels {
                    let a = input[idx * channels + ch]
                    let b = input[nextIdx * channels + ch]
                    buffer[frame * channels + ch] = a + frac * (b - a)
                }
            }
            count = outputFrames * channels
        }
        return output
    }
}
