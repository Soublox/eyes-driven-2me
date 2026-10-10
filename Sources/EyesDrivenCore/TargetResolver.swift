import CoreGraphics
import Foundation

/// Pure window lookup under a gaze point (SPEC 3.7).
public enum TargetResolver {
    /// Resolve `point` to a window.
    ///
    /// - Parameters:
    ///   - windows: windows in front-to-back order (as CGWindowList returns them).
    ///   - displays: active displays in global CG coordinates.
    ///   - excludedPIDs: process ids whose windows are ignored.
    ///   - minSize: minimum width and height (points) to be a candidate.
    ///   - snapDistance: maximum distance (points) to snap to a window when the
    ///     point is not inside any candidate.
    /// - Returns: the front-most candidate containing the point, otherwise the
    ///   nearest candidate on the point's display within `snapDistance`.
    public static func resolve(
        point: CGPoint,
        windows: [WindowInfo],
        displays: [DisplayInfo],
        excludedPIDs: Set<Int32> = [],
        minSize: CGFloat = 120,
        snapDistance: CGFloat = 160
    ) -> WindowInfo? {
        let candidates = windows.filter {
            $0.layer == 0
                && $0.isOnScreen
                && $0.alpha > 0.1
                && $0.frame.width >= minSize
                && $0.frame.height >= minSize
                && !excludedPIDs.contains($0.pid)
        }

        if let hit = candidates.first(where: { $0.frame.contains(point) }) {
            return hit
        }

        guard let display = nearestDisplay(to: point, in: displays) else { return nil }
        let onDisplay = candidates.filter { $0.frame.intersects(display.frame) }
        guard let nearest = onDisplay.min(by: {
            distance(from: point, to: $0.frame) < distance(from: point, to: $1.frame)
        }) else {
            return nil
        }
        return distance(from: point, to: nearest.frame) <= snapDistance ? nearest : nil
    }

    /// Shortest distance from a point to a rectangle (0 when inside).
    public static func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        if rect.contains(point) { return 0 }
        let dx = max(max(rect.minX - point.x, 0), point.x - rect.maxX)
        let dy = max(max(rect.minY - point.y, 0), point.y - rect.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }

    private static func nearestDisplay(to point: CGPoint, in displays: [DisplayInfo]) -> DisplayInfo? {
        displays.min(by: {
            distance(from: point, to: $0.frame) < distance(from: point, to: $1.frame)
        })
    }
}
