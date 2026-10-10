import CoreGraphics
import Foundation
import Testing
@testable import EyesDrivenCore

// MARK: - Helpers

/// Deterministic pseudo-random generator so tests never depend on the clock.
private struct LCG {
    var state: UInt64
    init(seed: UInt64 = 0x1234_5678_9abc_def0) { state = seed }
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(UInt64(1) << 53)
    }
    mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * next() }
}

private func features(_ v: [Double]) -> FaceFeatures {
    FaceFeatures(
        timestamp: 0,
        yaw: v[0], pitch: v[1], roll: 0,
        leftIris: CGPoint(x: v[2], y: v[3]),
        rightIris: CGPoint(x: v[2], y: v[3]),
        leftEyeOpenness: 0.3, rightEyeOpenness: 0.3,
        faceCenter: CGPoint(x: v[4], y: v[5]),
        faceSize: v[6]
    )
}

/// Ground truth: a degree-2 map from base features to a target on a
/// three-display row spanning x in roughly [-3840, 5568].
private func trueTarget(_ v: [Double]) -> CGPoint {
    let yaw = v[0], pitch = v[1], ix = v[2] - 0.5, iy = v[3] - 0.5
    let x = 864 + 9408 * yaw
        + 400 * ix + 1500 * yaw * yaw + 800 * yaw * ix + 600 * ix * ix
    let y = 1080 + 3000 * pitch
        + 300 * iy + 1200 * pitch * pitch + 700 * pitch * iy + 400 * iy * iy
    return CGPoint(x: x, y: y)
}

private func makeSamples(count: Int, seed: UInt64) -> [CalibrationSample] {
    var rng = LCG(seed: seed)
    var samples: [CalibrationSample] = []
    for _ in 0..<count {
        let v = [
            rng.range(-0.5, 0.5),   // yaw
            rng.range(-0.35, 0.35), // pitch
            rng.range(0.3, 0.7),    // irisX
            rng.range(0.3, 0.7),    // irisY
            rng.range(0.45, 0.55),  // faceCenterX
            rng.range(0.45, 0.55),  // faceCenterY
            rng.range(0.2, 0.4),    // faceSize
        ]
        samples.append(CalibrationSample(features: features(v), target: trueTarget(v)))
    }
    return samples
}

// MARK: - Tests

@Test func degreeTwoModelRecoversLinearAndQuadraticGroundTruth() throws {
    let samples = makeSamples(count: 80, seed: 1)
    let model = try GazeModel.fit(samples: samples)

    // Held-out points must be predicted within 5 pt.
    var rng = LCG(seed: 99)
    var worst = 0.0
    for _ in 0..<25 {
        let v = [
            rng.range(-0.5, 0.5), rng.range(-0.35, 0.35),
            rng.range(0.3, 0.7), rng.range(0.3, 0.7),
            rng.range(0.45, 0.55), rng.range(0.45, 0.55), rng.range(0.2, 0.4),
        ]
        let expected = trueTarget(v)
        let predicted = model.predict(features(v))
        let error = hypot(Double(predicted.x - expected.x), Double(predicted.y - expected.y))
        worst = max(worst, error)
    }
    #expect(worst < 5.0)
    #expect(model.meanError(on: samples) < 5.0)
}

@Test func fitThrowsWithFewerThanFiveSamples() {
    let samples = makeSamples(count: 4, seed: 2)
    #expect(throws: CalibrationError.notEnoughSamples) {
        _ = try GazeModel.fit(samples: samples)
    }
}

@Test func codableRoundTripPredictsIdentically() throws {
    let samples = makeSamples(count: 40, seed: 3)
    let model = try GazeModel.fit(samples: samples)

    let data = try JSONEncoder().encode(model)
    let decoded = try JSONDecoder().decode(GazeModel.self, from: data)

    for sample in makeSamples(count: 10, seed: 4) {
        let a = model.predict(sample.features)
        let b = decoded.predict(sample.features)
        #expect(abs(a.x - b.x) < 1e-6)
        #expect(abs(a.y - b.y) < 1e-6)
    }
    #expect(decoded.pitchDownSign == model.pitchDownSign)
}

@Test func pitchDownSignPositiveWhenPitchGrowsWithTargetY() throws {
    // pitch increases as the target y grows (user looks lower).
    var samples: [CalibrationSample] = []
    for i in 0..<10 {
        let pitch = -0.3 + Double(i) * 0.06
        let v = [0.1, pitch, 0.5, 0.5, 0.5, 0.5, 0.3]
        samples.append(CalibrationSample(
            features: features(v),
            target: CGPoint(x: 100 + Double(i) * 10, y: Double(i) * 200)
        ))
    }
    let model = try GazeModel.fit(samples: samples)
    #expect(model.pitchDownSign == 1)
}

@Test func pitchDownSignNegativeWhenPitchShrinksWithTargetY() throws {
    var samples: [CalibrationSample] = []
    for i in 0..<10 {
        let pitch = 0.3 - Double(i) * 0.06
        let v = [0.1, pitch, 0.5, 0.5, 0.5, 0.5, 0.3]
        samples.append(CalibrationSample(
            features: features(v),
            target: CGPoint(x: 100 + Double(i) * 10, y: Double(i) * 200)
        ))
    }
    let model = try GazeModel.fit(samples: samples)
    #expect(model.pitchDownSign == -1)
}

@Test func profileCodableRoundTrip() throws {
    let samples = makeSamples(count: 20, seed: 5)
    let model = try GazeModel.fit(samples: samples)
    let displays = [
        DisplayInfo(id: 2, frame: CGRect(x: 0, y: 0, width: 1728, height: 1080)),
        DisplayInfo(id: 1, frame: CGRect(x: -3840, y: 0, width: 3840, height: 2160)),
    ]
    let profile = CalibrationProfile(
        model: model,
        samples: samples,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        displayFingerprint: CalibrationProfile.fingerprint(for: displays)
    )
    let data = try JSONEncoder().encode(profile)
    let decoded = try JSONDecoder().decode(CalibrationProfile.self, from: data)
    #expect(decoded == profile)
    #expect(decoded.displayFingerprint == "1:3840x2160@-3840,0|2:1728x1080@0,0")
}

@Test func emulatorFeaturesProduceThreeDisplayRange() {
    // Sanity: the synthetic layout really spans the reference x range.
    let samples = makeSamples(count: 200, seed: 7)
    let xs = samples.map { Double($0.target.x) }
    #expect(xs.min()! < -3000)
    #expect(xs.max()! > 5000)
}
