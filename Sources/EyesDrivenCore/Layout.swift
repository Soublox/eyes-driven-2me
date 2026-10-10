import CoreGraphics
import Foundation

/// Pure geometry shared by the calibration UI and the overlay (SPEC 2.1, 4).
///
/// All screen geometry in Core uses CoreGraphics global coordinates: origin at
/// the top-left of the main display, x to the right, y down, units = points.
/// AppKit (`NSScreen`, `NSView`) uses a bottom-left origin, y up. The functions
/// here convert one into the other and lay out the calibration targets.
public enum ScreenGeometry {

    /// Convert a CoreGraphics global point (top-left origin, y down) into the
    /// view coordinates of a screen (bottom-left origin, y up).
    ///
    /// With `primaryHeight = NSScreen.screens[0].frame.height` (SPEC 2.1):
    ///
    ///     viewX = cgPoint.x - screenFrame.minX
    ///     viewY = primaryHeight - cgPoint.y - screenFrame.minY
    ///
    /// x is shared between the two spaces (both originate at the primary
    /// display's left edge); only y flips. `screenFrame` is the screen's AppKit
    /// frame in the global AppKit space.
    public static func appKitPoint(fromCG point: CGPoint, screenFrame: CGRect, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(
            x: point.x - screenFrame.minX,
            y: primaryHeight - point.y - screenFrame.minY
        )
    }

    /// Convert a CoreGraphics global rect (top-left origin, y down) into the
    /// view coordinates of a screen (bottom-left origin, y up).
    ///
    /// The rect is anchored by its CoreGraphics top-left corner; because the y
    /// axis flips, the AppKit origin uses the CoreGraphics `maxY`:
    ///
    ///     viewRect.minX = cgRect.minX - screenFrame.minX
    ///     viewRect.minY = primaryHeight - cgRect.maxY - screenFrame.minY
    ///
    /// Width and height are unchanged. See
    /// `appKitPoint(fromCG:screenFrame:primaryHeight:)` for the shared formula.
    public static func appKitRect(fromCG rect: CGRect, screenFrame: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(
            x: rect.minX - screenFrame.minX,
            y: primaryHeight - rect.maxY - screenFrame.minY,
            width: rect.width,
            height: rect.height
        )
    }
}

/// Calibration target layout: a 3×3 grid per display (SPEC 4).
public enum CalibrationLayout {
    /// Fractions of the display width and height where targets are placed.
    public static let fractions: [CGFloat] = [0.1, 0.5, 0.9]

    /// The nine grid points of one display frame in CoreGraphics global
    /// coordinates, row-major (top row first, left to right within a row).
    public static func points(in displayFrame: CGRect) -> [CGPoint] {
        var points: [CGPoint] = []
        points.reserveCapacity(fractions.count * fractions.count)
        for fy in fractions {
            for fx in fractions {
                points.append(CGPoint(
                    x: displayFrame.minX + displayFrame.width * fx,
                    y: displayFrame.minY + displayFrame.height * fy
                ))
            }
        }
        return points
    }

    /// Grid points grouped per display, for displays sorted left-to-right by
    /// their CoreGraphics `minX` (SPEC 4: displays in left-to-right order).
    public static func pointsPerDisplay(displays: [DisplayInfo]) -> [[CGPoint]] {
        displays
            .sorted { $0.frame.minX < $1.frame.minX }
            .map { points(in: $0.frame) }
    }

    /// Miniature proportional map of the connected displays, laid out inside
    /// `size` (top-left origin, y down, matching CoreGraphics) so the user
    /// recognizes the physical arrangement (SPEC 4, round 3).
    ///
    /// The frames are scaled by a single factor that fits the combined bounding
    /// box into `size` minus `padding` on every side, preserving their relative
    /// positions; the map is centered. Rects are returned in the same order as
    /// `displays`, and `.zero` rects are returned when the bounding box is
    /// degenerate.
    public static func miniMap(
        displays: [DisplayInfo],
        size: CGSize,
        padding: CGFloat = 0
    ) -> [CGRect] {
        guard !displays.isEmpty else { return [] }

        var minX = CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude
        for display in displays {
            minX = min(minX, display.frame.minX)
            minY = min(minY, display.frame.minY)
            maxX = max(maxX, display.frame.maxX)
            maxY = max(maxY, display.frame.maxY)
        }

        let boundsWidth = maxX - minX
        let boundsHeight = maxY - minY
        guard boundsWidth > 0, boundsHeight > 0 else {
            return displays.map { _ in .zero }
        }

        let availableWidth = max(size.width - 2 * padding, 1)
        let availableHeight = max(size.height - 2 * padding, 1)
        let scale = min(availableWidth / boundsWidth, availableHeight / boundsHeight)

        let scaledWidth = boundsWidth * scale
        let scaledHeight = boundsHeight * scale
        let offsetX = padding + (availableWidth - scaledWidth) / 2
        let offsetY = padding + (availableHeight - scaledHeight) / 2

        return displays.map { display in
            CGRect(
                x: offsetX + (display.frame.minX - minX) * scale,
                y: offsetY + (display.frame.minY - minY) * scale,
                width: display.frame.width * scale,
                height: display.frame.height * scale
            )
        }
    }

    /// Calibration targets for every display in left-to-right order, with the
    /// points of each display shuffled independently (order randomized within a
    /// display, SPEC 4). Uses the system random number generator.
    public static func shuffledTargets(displays: [DisplayInfo]) -> [CGPoint] {
        var generator = SystemRandomNumberGenerator()
        return shuffledTargets(displays: displays, using: &generator)
    }

    /// Deterministic variant of `shuffledTargets(displays:)`, for tests.
    public static func shuffledTargets<G: RandomNumberGenerator>(
        displays: [DisplayInfo],
        using generator: inout G
    ) -> [CGPoint] {
        pointsPerDisplay(displays: displays).flatMap { $0.shuffled(using: &generator) }
    }
}
