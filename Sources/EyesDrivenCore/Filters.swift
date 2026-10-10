import CoreGraphics
import Foundation

/// Scalar One Euro filter (Casiez, Roussel & Vogel, CHI 2012), SPEC 3.3.
///
/// Driven by timestamps in seconds. The first sample passes through unchanged.
public final class OneEuroFilter {
    /// Baseline cutoff frequency (Hz) applied when there is no motion.
    public let minCutoff: Double
    /// Speed coefficient: higher reacts faster to quick movements.
    public let beta: Double
    /// Cutoff frequency (Hz) of the derivative low-pass.
    public let dCutoff: Double

    private var xPrev: Double?
    private var dxPrev: Double = 0
    private var tPrev: TimeInterval?

    public init(minCutoff: Double = 1.0, beta: Double = 0.007, dCutoff: Double = 1.0) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.dCutoff = dCutoff
    }

    /// Filter one sample taken at `timestamp` (seconds, monotonically increasing).
    public func filter(_ x: Double, at timestamp: TimeInterval) -> Double {
        guard let xp = xPrev, let tp = tPrev else {
            xPrev = x
            tPrev = timestamp
            dxPrev = 0
            return x
        }
        let dt = timestamp - tp
        guard dt > 0 else { return xp }

        let aD = OneEuroFilter.alpha(dt: dt, cutoff: dCutoff)
        let dx = (x - xp) / dt
        let dxHat = aD * dx + (1 - aD) * dxPrev

        let cutoff = minCutoff + beta * abs(dxHat)
        let a = OneEuroFilter.alpha(dt: dt, cutoff: cutoff)
        let xHat = a * x + (1 - a) * xp

        xPrev = xHat
        dxPrev = dxHat
        tPrev = timestamp
        return xHat
    }

    /// Clear all state; the next sample passes through.
    public func reset() {
        xPrev = nil
        dxPrev = 0
        tPrev = nil
    }

    private static func alpha(dt: Double, cutoff: Double) -> Double {
        let tau = 1.0 / (2.0 * Double.pi * cutoff)
        return 1.0 / (1.0 + tau / dt)
    }
}

/// Two `OneEuroFilter`s, one per axis (SPEC 3.3).
public final class PointFilter {
    private let fx: OneEuroFilter
    private let fy: OneEuroFilter

    public init(minCutoff: Double = 1.0, beta: Double = 0.007, dCutoff: Double = 1.0) {
        fx = OneEuroFilter(minCutoff: minCutoff, beta: beta, dCutoff: dCutoff)
        fy = OneEuroFilter(minCutoff: minCutoff, beta: beta, dCutoff: dCutoff)
    }

    /// Filter a point taken at `timestamp`.
    public func filter(_ point: CGPoint, at timestamp: TimeInterval) -> CGPoint {
        CGPoint(
            x: fx.filter(Double(point.x), at: timestamp),
            y: fy.filter(Double(point.y), at: timestamp)
        )
    }

    /// Clear both axis filters.
    public func reset() {
        fx.reset()
        fy.reset()
    }
}
