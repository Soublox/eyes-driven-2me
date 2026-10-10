import CoreGraphics
import Foundation

/// Removes contaminated frames from a calibration session (SPEC 4, round 3).
///
/// Real calibrations sometimes contain frames recorded while the user was still
/// looking at the previous display: a step change in head yaw/pitch lands in the
/// middle of a target's samples. Fitting on those frames drags the model and the
/// reported error. For each target this keeps only the frames whose yaw and
/// pitch stay close to that target's median:
///
///     threshold = max(madMultiplier * madToSigma * MAD, minimumDeviation)
///
/// where `MAD` is the median absolute deviation of the group and
/// `madToSigma = 1.4826` makes `1.4826 * MAD` a robust Gaussian sigma estimate.
/// The `minimumDeviation` floor (`0.05 rad`) keeps a very clean target from being
/// over-filtered when its MAD is near zero.
///
/// The function is pure and deterministic: samples are grouped by their target
/// point and their original order is preserved.
public enum CalibrationCleaner {

    /// Multiplier applied to the robust sigma (`madToSigma * MAD`).
    public static let madMultiplier = 3.0

    /// Consistency factor that turns a median absolute deviation into a
    /// Gaussian sigma estimate.
    public static let madToSigma = 1.4826

    /// Absolute floor (radians) for the rejection threshold.
    public static let minimumDeviation = 0.05

    /// Return the samples with per-target outliers removed.
    ///
    /// A frame is dropped when its yaw *or* pitch deviates from its target's
    /// median by more than the target's threshold. Targets too small to estimate
    /// a spread are left untouched (their threshold collapses to
    /// `minimumDeviation`, so only genuinely extreme frames are dropped).
    public static func clean(_ samples: [CalibrationSample]) -> [CalibrationSample] {
        guard !samples.isEmpty else { return [] }

        // Group sample indices by target point, preserving first-seen order.
        var targetPoints: [CGPoint] = []
        var groups: [[Int]] = []
        for (index, sample) in samples.enumerated() {
            if let group = targetPoints.firstIndex(of: sample.target) {
                groups[group].append(index)
            } else {
                targetPoints.append(sample.target)
                groups.append([index])
            }
        }

        var keep = [Bool](repeating: false, count: samples.count)
        for group in groups {
            let yaws = group.map { samples[$0].features.yaw }
            let pitches = group.map { samples[$0].features.pitch }

            let medianYaw = median(yaws)
            let medianPitch = median(pitches)
            let madYaw = median(yaws.map { abs($0 - medianYaw) })
            let madPitch = median(pitches.map { abs($0 - medianPitch) })

            let thresholdYaw = max(madMultiplier * madToSigma * madYaw, minimumDeviation)
            let thresholdPitch = max(madMultiplier * madToSigma * madPitch, minimumDeviation)

            for index in group {
                let features = samples[index].features
                if abs(features.yaw - medianYaw) <= thresholdYaw,
                   abs(features.pitch - medianPitch) <= thresholdPitch {
                    keep[index] = true
                }
            }
        }

        return samples.enumerated().compactMap { keep[$0.offset] ? $0.element : nil }
    }

    /// Median of a non-empty series (mean of the two central values for an even
    /// count). Returns `0` for an empty input.
    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }
}
