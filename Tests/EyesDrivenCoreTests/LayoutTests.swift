import CoreGraphics
import Testing

@testable import EyesDrivenCore

@Suite("Layout")
struct LayoutTests {

    /// Small deterministic LCG so shuffling can be asserted in tests.
    private struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64

        init(seed: UInt64) {
            state = seed &* 6364136223846793005 &+ 1442695040888963407
        }

        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    @Test("grid points sit at 10/50/90 percent")
    func gridPoints() {
        let points = CalibrationLayout.points(in: CGRect(x: 0, y: 0, width: 1000, height: 800))
        #expect(points.count == 9)
        #expect(points[0] == CGPoint(x: 100, y: 80))
        #expect(points[1] == CGPoint(x: 500, y: 80))
        #expect(points[2] == CGPoint(x: 900, y: 80))
        #expect(points[4] == CGPoint(x: 500, y: 400))
        #expect(points[8] == CGPoint(x: 900, y: 720))
    }

    @Test("grid points on a display with negative x")
    func gridPointsNegativeDisplay() {
        let points = CalibrationLayout.points(in: CGRect(x: -1000, y: 0, width: 1000, height: 800))
        #expect(points[0] == CGPoint(x: -900, y: 80))
        #expect(points[4] == CGPoint(x: -500, y: 400))
        #expect(points[8] == CGPoint(x: -100, y: 720))
    }

    @Test("displays are ordered left to right")
    func displaysLeftToRight() {
        let right = DisplayInfo(id: 2, frame: CGRect(x: 1000, y: 0, width: 1000, height: 800))
        let left = DisplayInfo(id: 1, frame: CGRect(x: -1000, y: 0, width: 1000, height: 800))
        let groups = CalibrationLayout.pointsPerDisplay(displays: [right, left])
        #expect(groups.count == 2)
        #expect(groups[0][0] == CGPoint(x: -900, y: 80))
        #expect(groups[1][0] == CGPoint(x: 1100, y: 80))
    }

    @Test("shuffling preserves membership and per-display grouping")
    func shufflePreservesMembership() {
        let displays = [
            DisplayInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 800)),
            DisplayInfo(id: 2, frame: CGRect(x: 1000, y: 0, width: 1000, height: 800)),
        ]
        var generator = SeededGenerator(seed: 42)
        let targets = CalibrationLayout.shuffledTargets(displays: displays, using: &generator)
        #expect(targets.count == 18)

        // CGPoint is not Hashable on macOS 14, so compare sorted arrays.
        let expected = displays.flatMap { CalibrationLayout.points(in: $0.frame) }
        #expect(sorted(targets) == sorted(expected))

        // The first nine targets belong to the left display, the last nine to
        // the right one (left-to-right order is not shuffled).
        for point in targets.prefix(9) { #expect(point.x <= 1000) }
        for point in targets.suffix(9) { #expect(point.x >= 1000) }
    }

    private func sorted(_ points: [CGPoint]) -> [CGPoint] {
        points.sorted { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
    }

    @Test("CG to AppKit rect on a screen right of the primary")
    func conversionRightOfPrimary() {
        let primaryHeight: CGFloat = 1080
        let screen = CGRect(x: 1920, y: 0, width: 1920, height: 1080)
        let rect = ScreenGeometry.appKitRect(
            fromCG: CGRect(x: 2000, y: 100, width: 400, height: 300),
            screenFrame: screen,
            primaryHeight: primaryHeight
        )
        #expect(rect == CGRect(x: 80, y: 680, width: 400, height: 300))
    }

    @Test("CG to AppKit rect on a screen left of the primary")
    func conversionLeftOfPrimary() {
        let primaryHeight: CGFloat = 1080
        let screen = CGRect(x: -2560, y: 0, width: 2560, height: 1440)
        let rect = ScreenGeometry.appKitRect(
            fromCG: CGRect(x: -2000, y: 0, width: 400, height: 300),
            screenFrame: screen,
            primaryHeight: primaryHeight
        )
        #expect(rect == CGRect(x: 560, y: 780, width: 400, height: 300))
    }

    @Test("CG to AppKit point uses the same formula")
    func conversionPoint() {
        let primaryHeight: CGFloat = 1080
        let screen = CGRect(x: 1920, y: 0, width: 1920, height: 1080)
        let point = ScreenGeometry.appKitPoint(
            fromCG: CGPoint(x: 2000, y: 100),
            screenFrame: screen,
            primaryHeight: primaryHeight
        )
        #expect(point == CGPoint(x: 80, y: 980))
    }
}
