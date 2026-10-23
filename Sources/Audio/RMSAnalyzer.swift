import Foundation

/// Computes per-frame RMS in dBFS for the VU meter.
///
/// Output is clamped to [-60, 0] dBFS. Pure logic, no platform deps.
public actor RMSAnalyzer {
    public init() {}

    public func process(_ samples: [Int16]) -> Float {
        Self.level(samples)
    }

    /// Synchronous form, for callers that can't hop onto the actor (e.g.
    /// the audio tap callback).
    public static func level(_ samples: [Int16]) -> Float {
        guard !samples.isEmpty else { return -60 }
        var sum: Double = 0
        for s in samples {
            let normalized = Double(s) / Double(Int16.max)
            sum += normalized * normalized
        }
        let rms = (sum / Double(samples.count)).squareRoot()
        let dBFS = 20 * log10(max(rms, 1e-6))
        return Float(max(-60, min(0, dBFS)))
    }
}
