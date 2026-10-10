import Foundation

/// Tuning parameters for `NodDetector` (SPEC 3.5).
public struct NodDetectorConfig: Sendable, Equatable {
    /// Minimum downward excursion (radians) relative to the baseline.
    public var minAmplitude: Double
    /// Minimum duration of a nod (seconds).
    public var minDuration: TimeInterval
    /// Maximum duration; longer excursions are treated as "just looked down".
    public var maxDuration: TimeInterval
    /// Fraction of the peak at which the head counts as returned to baseline.
    public var returnRatio: Double
    /// Minimum time between accepted nods (seconds).
    public var cooldown: TimeInterval
    /// Time constant of the idle baseline EMA (seconds).
    public var baselineTimeConstant: TimeInterval

    public init(
        minAmplitude: Double = 0.10,
        minDuration: TimeInterval = 0.12,
        maxDuration: TimeInterval = 0.80,
        returnRatio: Double = 0.35,
        cooldown: TimeInterval = 1.0,
        baselineTimeConstant: TimeInterval = 0.6
    ) {
        self.minAmplitude = minAmplitude
        self.minDuration = minDuration
        self.maxDuration = maxDuration
        self.returnRatio = returnRatio
        self.cooldown = cooldown
        self.baselineTimeConstant = baselineTimeConstant
    }

    /// Map a nod sensitivity in `0...1` to a config: sensitivity `0` requires a
    /// large amplitude (0.16 rad) and sensitivity `1` a small one (0.05 rad),
    /// interpolated linearly.
    public static func config(forSensitivity sensitivity: Double) -> NodDetectorConfig {
        let s = min(max(sensitivity, 0), 1)
        let amplitude = 0.16 - 0.11 * s
        return NodDetectorConfig(minAmplitude: amplitude)
    }
}

/// Detects one quick nod: the head pitches "down" by at least `minAmplitude`
/// and returns close to the baseline within `minDuration...maxDuration`
/// (SPEC 3.5). Single movement — no double nod required.
public final class NodDetector {
    /// Tuning parameters.
    public var config: NodDetectorConfig
    /// Sign of the "down" pitch direction (`+1` or `-1`). Defaults to `-1`.
    public var downSign: Int

    private var baseline: Double?
    private var lastTimestamp: TimeInterval?
    private var pendingStart: TimeInterval?
    private var activeStart: TimeInterval?
    private var peak: Double = 0
    private var monitoring = false
    private var cooldownUntil: TimeInterval = -.infinity

    public init(config: NodDetectorConfig = NodDetectorConfig(), downSign: Int = -1) {
        self.config = config
        self.downSign = downSign
    }

    /// Forget all state; the next sample re-seeds the baseline.
    public func reset() {
        baseline = nil
        lastTimestamp = nil
        pendingStart = nil
        activeStart = nil
        peak = 0
        monitoring = false
        cooldownUntil = -.infinity
    }

    /// Feed one pitch sample. Returns a `NodEvent` on the frame the return to
    /// baseline completes, otherwise nil.
    public func process(pitch: Double, timestamp: TimeInterval) -> NodEvent? {
        guard let b = baseline else {
            baseline = pitch
            lastTimestamp = timestamp
            return nil
        }

        let pastCooldown = timestamp >= cooldownUntil
        let excursion = Double(downSign) * (pitch - b)

        if monitoring {
            if excursion > peak { peak = excursion }
            let duration = timestamp - (activeStart ?? timestamp)

            if excursion <= config.returnRatio * peak {
                let started = activeStart ?? timestamp
                monitoring = false
                activeStart = nil
                pendingStart = nil
                peak = 0
                baseline = pitch
                lastTimestamp = timestamp
                if duration >= config.minDuration {
                    cooldownUntil = timestamp + config.cooldown
                    return NodEvent(startTimestamp: started, endTimestamp: timestamp)
                }
                return nil
            }

            if duration > config.maxDuration {
                // User just looked down; abandon and re-seed the baseline.
                monitoring = false
                activeStart = nil
                pendingStart = nil
                peak = 0
                baseline = pitch
                lastTimestamp = timestamp
                return nil
            }

            lastTimestamp = timestamp
            return nil
        }

        // Idle: track a pending downward excursion and keep the baseline fresh.
        if excursion > 0.25 * config.minAmplitude {
            if pendingStart == nil { pendingStart = timestamp }
        } else {
            pendingStart = nil
        }

        if pastCooldown, excursion >= config.minAmplitude {
            monitoring = true
            peak = excursion
            activeStart = pendingStart ?? timestamp
            lastTimestamp = timestamp
            return nil
        }

        if pendingStart == nil {
            let previous = lastTimestamp ?? timestamp
            let dt = max(timestamp - previous, 0)
            let alpha = dt > 0 ? 1.0 - exp(-dt / config.baselineTimeConstant) : 0
            baseline = b + alpha * (pitch - b)
        }
        lastTimestamp = timestamp
        return nil
    }
}
