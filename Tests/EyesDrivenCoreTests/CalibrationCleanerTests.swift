import CoreGraphics
import Foundation
import Testing
@testable import EyesDrivenCore

/// Deterministic pseudo-random generator so tests never depend on the clock.
private struct LCG {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(UInt64(1) << 53)
    }
    mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * next() }
}

private func sample(yaw: Double, pitch: Double, target: CGPoint) -> CalibrationSample {
    CalibrationSample(
        features: FaceFeatures(
            timestamp: 0,
            yaw: yaw, pitch: pitch, roll: 0,
            leftIris: CGPoint(x: 0.5, y: 0.5),
            rightIris: CGPoint(x: 0.5, y: 0.5),
            leftEyeOpenness: 0.3, rightEyeOpenness: 0.3,
            faceCenter: CGPoint(x: 0.5, y: 0.5),
            faceSize: 0.3
        ),
        target: target
    )
}

@Suite("Calibration cleaner")
struct CalibrationCleanerTests {

    @Test("injected yaw outliers are removed")
    func removesYawOutliers() {
        let target = CGPoint(x: 100, y: 100)
        var samples: [CalibrationSample] = []
        for i in 0..<20 {
            samples.append(sample(yaw: 0.10 + Double(i) * 0.001, pitch: 0.05, target: target))
        }
        // Two frames still looking at the previous display.
        samples.insert(sample(yaw: 0.60, pitch: 0.05, target: target), at: 5)
        samples.append(sample(yaw: -0.50, pitch: 0.05, target: target))

        let cleaned = CalibrationCleaner.clean(samples)
        #expect(cleaned.count == 20)
        #expect(cleaned.allSatisfy { abs($0.features.yaw - 0.10) < 0.05 })
    }

    @Test("injected pitch outliers are removed")
    func removesPitchOutliers() {
        let target = CGPoint(x: 200, y: 200)
        var samples: [CalibrationSample] = []
        for _ in 0..<15 {
            samples.append(sample(yaw: 0.2, pitch: -0.05, target: target))
        }
        samples.append(sample(yaw: 0.2, pitch: 0.9, target: target))
        samples.insert(sample(yaw: 0.2, pitch: -0.8, target: target), at: 3)

        let cleaned = CalibrationCleaner.clean(samples)
        #expect(cleaned.count == 15)
        #expect(cleaned.allSatisfy { abs($0.features.pitch + 0.05) < 0.05 })
    }

    @Test("clean frames are kept in order")
    func keepsCleanFrames() {
        let target = CGPoint(x: 300, y: 300)
        var rng = LCG(seed: 0xC1EA_4)
        var samples: [CalibrationSample] = []
        for _ in 0..<25 {
            // Noise well inside the 0.05 rad floor.
            samples.append(sample(
                yaw: 0.15 + rng.range(-0.02, 0.02),
                pitch: -0.10 + rng.range(-0.02, 0.02),
                target: target
            ))
        }

        let cleaned = CalibrationCleaner.clean(samples)
        #expect(cleaned == samples)
    }

    @Test("small-noise targets are untouched")
    func smallNoiseTargetsUntouched() {
        let a = CGPoint(x: 100, y: 100)
        let b = CGPoint(x: 900, y: 800)
        var rng = LCG(seed: 0x5011)
        var samples: [CalibrationSample] = []
        for _ in 0..<12 { samples.append(sample(yaw: 0.4 + rng.range(-0.04, 0.04), pitch: 0.1, target: a)) }
        for _ in 0..<12 { samples.append(sample(yaw: -0.2 + rng.range(-0.04, 0.04), pitch: -0.3, target: b)) }

        let cleaned = CalibrationCleaner.clean(samples)
        #expect(cleaned.count == samples.count)
    }

    @Test("outliers in one target do not drop another target's frames")
    func perTargetIndependence() {
        let a = CGPoint(x: 100, y: 100)
        let b = CGPoint(x: 900, y: 800)
        var samples: [CalibrationSample] = []
        for i in 0..<12 { samples.append(sample(yaw: 0.10 + Double(i) * 0.001, pitch: 0.05, target: a)) }
        samples.append(sample(yaw: 0.9, pitch: 0.05, target: a)) // outlier only in target a
        for i in 0..<12 { samples.append(sample(yaw: 0.30 + Double(i) * 0.001, pitch: 0.20, target: b)) }

        let cleaned = CalibrationCleaner.clean(samples)
        #expect(cleaned.filter { $0.target == a }.count == 12)
        #expect(cleaned.filter { $0.target == b }.count == 12)
    }
}
