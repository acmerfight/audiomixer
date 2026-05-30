import Foundation

/// Stateless drift calculator. Given the number of samples received and the elapsed
/// presentation time, computes the drift in samples relative to the nominal rate.
public struct DriftDetector: Sendable {
    private let nominalRate: Double

    public init(nominalSampleRate: UInt32) {
        self.nominalRate = Double(nominalSampleRate)
    }

    /// Returns drift in samples. Positive = too many samples (device fast).
    /// Negative = too few samples (device slow).
    public func computeDrift(samplesReceived: Int, elapsedPTS: Double) -> Int {
        let expected = Int(elapsedPTS * nominalRate)
        return samplesReceived - expected
    }
}
