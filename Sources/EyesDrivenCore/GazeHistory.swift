import CoreGraphics
import Foundation

/// Ring buffer of recent gaze samples, bounded by duration (SPEC 3.4).
///
/// Used to look up "where was the user looking just before the nod started".
public struct GazeHistory {
    /// Maximum age of a retained sample, in seconds.
    public let duration: TimeInterval
    private var samples: [(timestamp: TimeInterval, point: CGPoint)]

    public init(duration: TimeInterval = 3.0) {
        self.duration = duration
        self.samples = []
    }

    /// Append a sample and drop anything older than `timestamp - duration`.
    public mutating func append(_ point: CGPoint, at timestamp: TimeInterval) {
        samples.append((timestamp, point))
        let cutoff = timestamp - duration
        if let firstKept = samples.firstIndex(where: { $0.timestamp >= cutoff }), firstKept > 0 {
            samples.removeFirst(firstKept)
        }
    }

    /// Most recently appended point, if any.
    public var latest: CGPoint? { samples.last?.point }

    /// Number of retained samples.
    public var count: Int { samples.count }

    /// Component-wise median of samples whose timestamp lies in `from...to`.
    /// Returns nil for an empty range or when `from > to`.
    public func median(from: TimeInterval, to: TimeInterval) -> CGPoint? {
        guard from <= to else { return nil }
        let inRange = samples.filter { $0.timestamp >= from && $0.timestamp <= to }
        guard !inRange.isEmpty else { return nil }
        let xs = inRange.map { Double($0.point.x) }
        let ys = inRange.map { Double($0.point.y) }
        return CGPoint(x: GazeHistory.median(xs), y: GazeHistory.median(ys))
    }

    /// Drop all samples.
    public mutating func reset() {
        samples.removeAll()
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let n = sorted.count
        if n == 0 { return 0 }
        if n % 2 == 1 { return sorted[n / 2] }
        return (sorted[n / 2 - 1] + sorted[n / 2]) / 2
    }
}
