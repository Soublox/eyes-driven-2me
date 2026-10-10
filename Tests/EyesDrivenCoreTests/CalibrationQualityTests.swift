import CoreGraphics
import Foundation
import Testing
@testable import EyesDrivenCore

/// Deterministic pseudo-random generator (file-private; never touches the clock).
private struct LCG {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(UInt64(1) << 53)
    }
    mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * next() }
}

private func frame(yaw: Double, pitch: Double, target: CGPoint) -> FaceFeatures {
    FaceFeatures(
        timestamp: 0,
        yaw: yaw, pitch: pitch, roll: 0,
        leftIris: CGPoint(x: 0.5 + 0.2 * yaw, y: 0.5 + 0.2 * pitch),
        rightIris: CGPoint(x: 0.5 + 0.2 * yaw, y: 0.5 + 0.2 * pitch),
        leftEyeOpenness: 0.3, rightEyeOpenness: 0.3,
        faceCenter: CGPoint(x: 0.5 + 0.1 * yaw, y: 0.5 + 0.1 * pitch),
        faceSize: 0.3
    )
}

/// `count` noisy samples spread over the 3×3 grid of `display`, all drawn around
/// the given mean head pose (so the display's mean yaw is controlled).
private func samples(
    over display: CGRect,
    meanYaw: Double,
    pitchBase: Double,
    count: Int,
    seed: UInt64
) -> [CalibrationSample] {
    var rng = LCG(seed: seed)
    let grid = CalibrationLayout.points(in: display)
    var out: [CalibrationSample] = []
    for i in 0..<count {
        let target = grid[i % grid.count]
        let yaw = meanYaw + rng.range(-0.02, 0.02)
        let pitch = pitchBase + rng.range(-0.02, 0.02)
        out.append(CalibrationSample(features: frame(yaw: yaw, pitch: pitch, target: target), target: target))
    }
    return out
}

@Suite("Calibration quality")
struct CalibrationQualityTests {

    private var left: DisplayInfo { DisplayInfo(id: 1, frame: CGRect(x: -2000, y: 0, width: 2000, height: 1000)) }
    private var center: DisplayInfo { DisplayInfo(id: 2, frame: CGRect(x: 0, y: 0, width: 2000, height: 1000)) }
    private var right: DisplayInfo { DisplayInfo(id: 3, frame: CGRect(x: 2000, y: 0, width: 2000, height: 1000)) }

    @Test("report indexes displays left-to-right with per-display samples")
    func perDisplayCountsAndOrder() throws {
        // Pass the displays out of order: the report must still number them
        // left-to-right (1 = leftmost).
        let displays = [right, left, center]
        var all: [CalibrationSample] = []
        all += samples(over: left.frame, meanYaw: 0.10, pitchBase: -0.1, count: 45, seed: 1)
        all += samples(over: center.frame, meanYaw: 0.12, pitchBase: 0.0, count: 45, seed: 2)
        all += samples(over: right.frame, meanYaw: 0.60, pitchBase: 0.1, count: 45, seed: 3)

        let model = try GazeModel.fit(samples: all)
        let report = CalibrationQuality.report(model: model, samples: all, displays: displays)

        #expect(report.displays.count == 3)
        #expect(report.displays.map { $0.displayIndex } == [1, 2, 3])
        #expect(report.displays.allSatisfy { $0.sampleCount == 45 })
        #expect(report.crossValidationError == model.crossValidationError)
        // Every mean error is finite and non-negative.
        #expect(report.displays.allSatisfy { $0.meanErrorPoints >= 0 && $0.meanErrorPoints.isFinite })
    }

    @Test("displays with indistinguishable head yaw are flagged")
    func flagsIndistinguishableDisplays() throws {
        let displays = [left, center, right]
        var all: [CalibrationSample] = []
        all += samples(over: left.frame, meanYaw: 0.10, pitchBase: -0.1, count: 45, seed: 4)
        all += samples(over: center.frame, meanYaw: 0.12, pitchBase: 0.0, count: 45, seed: 5) // Δ = 0.02
        all += samples(over: right.frame, meanYaw: 0.60, pitchBase: 0.1, count: 45, seed: 6)  // far away

        let model = try GazeModel.fit(samples: all)
        let report = CalibrationQuality.report(model: model, samples: all, displays: displays)

        #expect(report.indistinguishableDisplays == [1, 2])
    }

    @Test("well-separated displays produce no warning")
    func noWarningWhenSeparated() throws {
        let displays = [left, center, right]
        var all: [CalibrationSample] = []
        all += samples(over: left.frame, meanYaw: -0.40, pitchBase: -0.1, count: 45, seed: 7)
        all += samples(over: center.frame, meanYaw: 0.00, pitchBase: 0.0, count: 45, seed: 8)
        all += samples(over: right.frame, meanYaw: 0.40, pitchBase: 0.1, count: 45, seed: 9)

        let model = try GazeModel.fit(samples: all)
        let report = CalibrationQuality.report(model: model, samples: all, displays: displays)

        #expect(report.indistinguishableDisplays.isEmpty)
    }

    @Test("samples outside every frame go to the nearest display")
    func nearestDisplayAssignment() throws {
        let only = DisplayInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 1000))
        let outside = CGPoint(x: 1000 + 50, y: 500) // 50 pt beyond the right edge
        var all: [CalibrationSample] = []
        for i in 0..<10 {
            let target = CGPoint(x: 100 + Double(i) * 50, y: 500)
            all.append(CalibrationSample(features: frame(yaw: 0.1, pitch: 0.0, target: target), target: target))
        }
        all.append(CalibrationSample(features: frame(yaw: 0.3, pitch: 0.0, target: outside), target: outside))

        let model = try GazeModel.fit(samples: all)
        let report = CalibrationQuality.report(model: model, samples: all, displays: [only])
        #expect(report.displays.count == 1)
        #expect(report.displays[0].sampleCount == all.count)
    }
}
