import CoreGraphics
import Foundation

/// Quality of the samples collected on one display (SPEC 4, round 3).
public struct DisplayQuality: Equatable, Sendable {
    /// 1-based index in left-to-right display order (matches "Screen N of M").
    public var displayIndex: Int
    /// Mean Euclidean prediction error (points) of the fitted model on this
    /// display's samples.
    public var meanErrorPoints: Double
    /// Number of samples assigned to this display.
    public var sampleCount: Int
    /// Mean head yaw (radians) of this display's samples.
    public var meanYaw: Double

    public init(displayIndex: Int, meanErrorPoints: Double, sampleCount: Int, meanYaw: Double) {
        self.displayIndex = displayIndex
        self.meanErrorPoints = meanErrorPoints
        self.sampleCount = sampleCount
        self.meanYaw = meanYaw
    }
}

/// Post-fit calibration quality analysis (SPEC 4, round 3).
public struct CalibrationQualityReport: Equatable, Sendable {
    /// Per-display quality, left-to-right.
    public var displays: [DisplayQuality]
    /// Leave-one-target-out cross-validation error (points) of the fitted model.
    public var crossValidationError: Double
    /// 1-based indices of displays whose samples could not be told apart (their
    /// mean head yaw is within `CalibrationQuality.yawSeparabilityThreshold` of
    /// another display's). Sorted ascending.
    public var indistinguishableDisplays: [Int]

    public init(
        displays: [DisplayQuality],
        crossValidationError: Double,
        indistinguishableDisplays: [Int]
    ) {
        self.displays = displays
        self.crossValidationError = crossValidationError
        self.indistinguishableDisplays = indistinguishableDisplays
    }
}

/// Pure per-display quality computations. The text shown to the user lives in
/// the App; this only produces the numbers and the warning flags.
public enum CalibrationQuality {

    /// Mean head-yaw difference (radians) below which two displays are treated as
    /// indistinguishable: the user likely did not turn toward one of them.
    public static let yawSeparabilityThreshold = 0.05

    /// Compute the per-display error, the cross-validation error and the
    /// separability warnings for a fitted model.
    ///
    /// Every sample is assigned to the display whose frame contains its target
    /// point, or to the nearest display otherwise. Displays are indexed 1-based
    /// in left-to-right (`minX`) order so the numbering matches the on-screen
    /// "Screen N of M" progress label.
    public static func report(
        model: GazeModel,
        samples: [CalibrationSample],
        displays: [DisplayInfo]
    ) -> CalibrationQualityReport {
        let sorted = displays.sorted { $0.frame.minX < $1.frame.minX }

        var qualities: [DisplayQuality] = []
        qualities.reserveCapacity(sorted.count)
        for (index, display) in sorted.enumerated() {
            let owned = samples.filter { belongs($0.target, to: display, among: sorted) }
            let meanYaw = owned.isEmpty
                ? 0
                : owned.map { $0.features.yaw }.reduce(0, +) / Double(owned.count)
            qualities.append(DisplayQuality(
                displayIndex: index + 1,
                meanErrorPoints: model.meanError(on: owned),
                sampleCount: owned.count,
                meanYaw: meanYaw
            ))
        }

        var indistinguishable: [Int] = []
        for a in qualities.indices {
            guard qualities[a].sampleCount > 0 else { continue }
            for b in (a + 1)..<qualities.count {
                guard qualities[b].sampleCount > 0 else { continue }
                if abs(qualities[a].meanYaw - qualities[b].meanYaw) < yawSeparabilityThreshold {
                    if !indistinguishable.contains(a + 1) { indistinguishable.append(a + 1) }
                    if !indistinguishable.contains(b + 1) { indistinguishable.append(b + 1) }
                }
            }
        }

        return CalibrationQualityReport(
            displays: qualities,
            crossValidationError: model.crossValidationError,
            indistinguishableDisplays: indistinguishable.sorted()
        )
    }

    /// Whether a target point belongs to `display`: contained by its frame, or
    /// (when outside every frame) closest to it.
    private static func belongs(_ point: CGPoint, to display: DisplayInfo, among all: [DisplayInfo]) -> Bool {
        if display.frame.contains(point) { return true }
        let owner = all.min {
            TargetResolver.distance(from: point, to: $0.frame)
                < TargetResolver.distance(from: point, to: $1.frame)
        }
        return owner?.frame == display.frame
    }
}
