import Foundation

/// Pure-function audio mixing utilities.
public enum AudioMixer {

    /// Sums two Float32 PCM streams sample-by-sample, clamped to [-1.0, 1.0].
    /// Shorter array is implicitly zero-padded.
    public static func mix(system: [Float], mic: [Float]) -> [Float] {
        let count = max(system.count, mic.count)
        let output = [Float](unsafeUninitializedCapacity: count) { buffer, initializedCount in
            for i in 0..<count {
                let s = i < system.count ? system[i] : 0
                let m = i < mic.count ? mic[i] : 0
                buffer[i] = clamp(s + m)
            }
            initializedCount = count
        }
        return output
    }

    /// Converts Float32 [-1.0, 1.0] to Int16 [-32767, 32767] with clamping.
    public static func toInt16(_ samples: [Float]) -> [Int16] {
        samples.map { Int16(clamp($0) * 32767.0) }
    }

    @inline(__always)
    private static func clamp(_ v: Float) -> Float {
        min(1.0, max(-1.0, v))
    }
}
