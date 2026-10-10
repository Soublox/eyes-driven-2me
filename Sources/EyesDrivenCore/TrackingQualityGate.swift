import Foundation

/// Tuning parameters for `TrackingQualityGate` (SPEC 3.10).
public struct TrackingQualityGateConfig: Sendable, Equatable {
    /// Minimum acceptable `FaceFeatures.landmarksConfidence`.
    public var minLandmarksConfidence: Double
    /// Minimum acceptable `FaceFeatures.captureQuality` (nil never fails).
    public var minCaptureQuality: Double
    /// Maximum acceptable `FaceFeatures.handOverlap`.
    public var maxHandOverlap: Double
    /// Maximum yaw/pitch change (radians) between consecutive frames, scaled by dt.
    public var maxYawPitchJump: Double
    /// Seconds of consecutive clean frames required before tracking is trusted again.
    public var recoverySeconds: TimeInterval

    public init(
        minLandmarksConfidence: Double = 0.5,
        minCaptureQuality: Double = 0.25,
        maxHandOverlap: Double = 0.15,
        maxYawPitchJump: Double = 0.25,
        recoverySeconds: TimeInterval = 0.5
    ) {
        self.minLandmarksConfidence = minLandmarksConfidence
        self.minCaptureQuality = minCaptureQuality
        self.maxHandOverlap = maxHandOverlap
        self.maxYawPitchJump = maxYawPitchJump
        self.recoverySeconds = recoverySeconds
    }
}

/// The verdict of `TrackingQualityGate` for one frame (SPEC 3.10).
public struct TrackingQuality: Sendable, Equatable {
    /// Why the gate considers tracking unreliable.
    public enum Reason: String, Sendable, Equatable, Hashable, CaseIterable {
        /// `landmarksConfidence` below the configured minimum.
        case lowLandmarkConfidence
        /// `captureQuality` below the configured minimum.
        case lowCaptureQuality
        /// `handOverlap` above the configured maximum (a hand on the face).
        case handOnFace
        /// yaw/pitch jumped more than the dt-scaled maximum since the last frame.
        case poseJump
        /// Signals are clean, but the recovery window has not elapsed yet.
        case recovering
    }

    /// Whether the frame may be used for focusing / nodding / calibration.
    public var isReliable: Bool
    /// The reasons the frame is unreliable (empty when `isReliable`).
    public var reasons: Set<Reason>

    public init(isReliable: Bool, reasons: Set<Reason>) {
        self.isReliable = isReliable
        self.reasons = reasons
    }
}

/// Pure hysteresis gate over the per-frame tracking-quality signals
/// (SPEC 3.10).
///
/// A hand on the face occludes landmarks: pose and iris jump, which looks like
/// a new gaze target (dwell fires) and like a nod. The gate marks a frame
/// unreliable **immediately** when any signal fails, and trusted again only
/// after `recoverySeconds` of consecutive clean frames, so brief glitches do
/// not flap the paused/running state.
public struct TrackingQualityGate {
    /// Tuning parameters.
    public var config: TrackingQualityGateConfig

    /// Maximum gap (seconds) between frames for which a pose jump is meaningful.
    private static let maximumJumpGap: TimeInterval = 0.2

    private var reliable = true
    /// Timestamp of the first clean frame of the current recovery window.
    private var recoveryStart: TimeInterval?
    private var lastTimestamp: TimeInterval?
    private var lastYaw: Double = 0
    private var lastPitch: Double = 0

    public init(config: TrackingQualityGateConfig = TrackingQualityGateConfig()) {
        self.config = config
    }

    /// Forget all state; tracking is trusted again from the next frame.
    public mutating func reset() {
        reliable = true
        recoveryStart = nil
        lastTimestamp = nil
        lastYaw = 0
        lastPitch = 0
    }

    /// Evaluate one frame and advance the hysteresis state.
    public mutating func process(_ features: FaceFeatures) -> TrackingQuality {
        let failing = failingReasons(features)

        // Always carry the pose forward, so a jump is measured against the most
        // recent frame even while unreliable (and after a long gap).
        lastTimestamp = features.timestamp
        lastYaw = features.yaw
        lastPitch = features.pitch

        if !failing.isEmpty {
            // Any failing signal makes tracking unreliable immediately and
            // restarts the recovery window.
            reliable = false
            recoveryStart = nil
            return TrackingQuality(isReliable: false, reasons: failing)
        }

        if reliable {
            return TrackingQuality(isReliable: true, reasons: [])
        }

        // Signals are clean: count up the recovery window.
        if recoveryStart == nil {
            recoveryStart = features.timestamp
        }
        if let start = recoveryStart, features.timestamp - start >= config.recoverySeconds {
            reliable = true
            recoveryStart = nil
            return TrackingQuality(isReliable: true, reasons: [])
        }
        return TrackingQuality(isReliable: false, reasons: [.recovering])
    }

    // MARK: - Signals

    private func failingReasons(_ features: FaceFeatures) -> Set<TrackingQuality.Reason> {
        var reasons: Set<TrackingQuality.Reason> = []
        if features.landmarksConfidence < config.minLandmarksConfidence {
            reasons.insert(.lowLandmarkConfidence)
        }
        if let quality = features.captureQuality, quality < config.minCaptureQuality {
            reasons.insert(.lowCaptureQuality)
        }
        if features.handOverlap > config.maxHandOverlap {
            reasons.insert(.handOnFace)
        }
        if hasPoseJump(features) {
            reasons.insert(.poseJump)
        }
        return reasons
    }

    /// A pose jump is a yaw or pitch change between consecutive frames larger
    /// than `maxYawPitchJump`, scaled by the frame gap relative to 1/30 s (so a
    /// fast frame is held to a proportionally tighter limit and a slow one is
    /// forgiven). Gaps longer than 0.2 s are ignored: a large change across a
    /// pause is not a glitch.
    private func hasPoseJump(_ features: FaceFeatures) -> Bool {
        guard let last = lastTimestamp else { return false }
        let dt = features.timestamp - last
        guard dt > 0, dt <= Self.maximumJumpGap else { return false }
        let allowed = config.maxYawPitchJump * dt / (1.0 / 30.0)
        let jump = max(abs(features.yaw - lastYaw), abs(features.pitch - lastPitch))
        return jump > allowed
    }
}
