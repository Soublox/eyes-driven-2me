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
    // The model-selection fields survive the round trip.
    #expect(decoded.degree == model.degree)
    #expect(decoded.lambda == model.lambda)
    #expect(decoded.crossValidationError == model.crossValidationError)
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

// MARK: - Model selection (SPEC 3.2)

/// Deterministic SplitMix64 (Steele et al. 2014) with Box–Muller Gaussian
/// draws, so these tests never touch `SystemRandomNumberGenerator`.
private struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    private mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in `[0, 1)`.
    mutating func unit() -> Double { Double(next() >> 11) * 0x1.0p-53 }

    /// Standard normal via the Box–Muller transform.
    mutating func gaussian() -> Double {
        let u1 = Swift.max(unit(), 1e-12)
        let u2 = unit()
        return (-2 * Foundation.log(u1)).squareRoot() * Foundation.cos(2 * Double.pi * u2)
    }

    mutating func normal(_ mean: Double, _ sd: Double) -> Double { mean + sd * gaussian() }
}

/// Ground truth for a *realistic* calibration: essentially linear in yaw/pitch,
/// mapped across the reference three-display row (x ∈ roughly [-3840, 5416],
/// y ∈ [0, 2160]). The quadratic curvature real webcams show is tiny compared
/// with the per-frame feature noise, so a degree-2 basis buys nothing.
private func realisticTarget(yaw: Double, pitch: Double) -> CGPoint {
    let x = 788.0 + 9500.0 * yaw + 40.0 * yaw * yaw
    let y = 1080.0 + 3000.0 * pitch + 15.0 * pitch * pitch
    return CGPoint(x: x, y: y)
}

/// The 3×3 target grid on each of the three reference displays (27 targets).
private func realisticGrid() -> [(yaw: Double, pitch: Double)] {
    let displays: [(minX: Double, width: Double)] = [
        (-3840, 3840),  // external left 4K
        (0, 1728),      // MacBook built-in
        (1728, 3688),   // external right 4K
    ]
    var out: [(yaw: Double, pitch: Double)] = []
    for display in displays {
        for fx in [0.1, 0.5, 0.9] {
            for fy in [0.1, 0.5, 0.9] {
                let x = display.minX + fx * display.width
                let y = fy * 2160.0
                out.append((yaw: (x - 788.0) / 9500.0, pitch: (y - 1080.0) / 3000.0))
            }
        }
    }
    return out
}

/// A second 3×3 grid on each display at different fractions, i.e. targets that
/// were never part of the calibration grid.
private func realisticGridOffGrid() -> [(yaw: Double, pitch: Double)] {
    let displays: [(minX: Double, width: Double)] = [
        (-3840, 3840), (0, 1728), (1728, 3688),
    ]
    var out: [(yaw: Double, pitch: Double)] = []
    for display in displays {
        for fx in [0.3, 0.7] {
            for fy in [0.3, 0.7] {
                let x = display.minX + fx * display.width
                let y = fy * 2160.0
                out.append((yaw: (x - 788.0) / 9500.0, pitch: (y - 1080.0) / 3000.0))
            }
        }
    }
    return out
}

/// One noisy per-frame observation for a given head pose. The true target
/// depends mostly on yaw/pitch; iris and face-center features carry correlated
/// but ultimately nuisance variation, exactly like a real webcam.
private func realisticFrame(yaw: Double, pitch: Double, rng: inout SplitMix64) -> FaceFeatures {
    let leftIris = CGPoint(
        x: 0.5 + 0.20 * yaw + rng.normal(0, 0.02),
        y: 0.5 + 0.20 * pitch + rng.normal(0, 0.02)
    )
    let rightIris = CGPoint(
        x: 0.5 + 0.20 * yaw + rng.normal(0, 0.02),
        y: 0.5 + 0.20 * pitch + rng.normal(0, 0.02)
    )
    return FaceFeatures(
        timestamp: 0,
        yaw: yaw + rng.normal(0, 0.008),
        pitch: pitch + rng.normal(0, 0.008),
        roll: rng.normal(0, 0.02),
        leftIris: leftIris,
        rightIris: rightIris,
        leftEyeOpenness: 0.3,
        rightEyeOpenness: 0.3,
        faceCenter: CGPoint(
            x: 0.5 + 0.15 * yaw + rng.normal(0, 0.02),
            y: 0.5 + 0.15 * pitch + rng.normal(0, 0.02)
        ),
        faceSize: 0.3 + 0.05 * yaw + rng.normal(0, 0.02)
    )
}

/// Mean Euclidean prediction error (points) of `model` over fresh noisy frames
/// drawn for every target in `grid`.
private func heldOutError(
    _ model: GazeModel,
    over grid: [(yaw: Double, pitch: Double)],
    frames: Int,
    seed: UInt64
) -> Double {
    var rng = SplitMix64(seed: seed)
    var total = 0.0
    var count = 0.0
    for target in grid {
        let point = realisticTarget(yaw: target.yaw, pitch: target.pitch)
        for _ in 0..<frames {
            let f = realisticFrame(yaw: target.yaw, pitch: target.pitch, rng: &rng)
            let p = model.predict(f)
            total += hypot(Double(p.x - point.x), Double(p.y - point.y))
            count += 1
        }
    }
    return total / count
}

/// Regression (critical): on a realistic 27-target calibration (25 noisy frames
/// each) the CV-selected model must generalize to fresh noisy frames better than
/// a forced degree-2/λ=0.01 model — both on the calibration targets and on
/// targets that were never calibrated. The old code always returned the forced
/// model, so the two errors were identical and both `<` comparisons failed.
@Test func crossValidationPicksBetterModelThanForcedDegreeTwo() throws {
    let grid = realisticGrid()
    #expect(grid.count == 27)
    #expect(Set(grid.map { "\($0.yaw),\($0.pitch)" }).count == 27)

    var rng = SplitMix64(seed: 0x0A11CE_5EED)
    var samples: [CalibrationSample] = []
    for target in grid {
        let point = realisticTarget(yaw: target.yaw, pitch: target.pitch)
        for _ in 0..<25 {
            samples.append(CalibrationSample(
                features: realisticFrame(yaw: target.yaw, pitch: target.pitch, rng: &rng),
                target: point
            ))
        }
    }
    // Sanity: the synthetic layout really spans the three-display x range.
    let xs = samples.map { Double($0.target.x) }
    #expect(xs.min()! < -3000)
    #expect(xs.max()! > 5000)

    let selected = try GazeModel.fit(samples: samples)
    let forced = try GazeModel.fit(samples: samples, lambda: 0.01)

    // Fresh noisy frames on the calibration targets.
    #expect(heldOutError(selected, over: grid, frames: 25, seed: 0xFEED_FACE)
        < heldOutError(forced, over: grid, frames: 25, seed: 0xFEED_FACE))

    // Fresh noisy frames on targets that were never calibrated: the true test.
    let offGrid = realisticGridOffGrid()
    #expect(heldOutError(selected, over: offGrid, frames: 25, seed: 0xBEEF)
        < heldOutError(forced, over: offGrid, frames: 25, seed: 0xBEEF))
}

/// With only 5 distinct targets the degree-2 basis is not even a candidate.
@Test func fiveTargetsSelectDegreeOne() throws {
    let grid = [
        (yaw: -0.30, pitch: -0.20), (yaw: 0.00, pitch: 0.20), (yaw: 0.30, pitch: -0.20),
        (yaw: -0.15, pitch: 0.25), (yaw: 0.15, pitch: 0.05),
    ]
    var rng = SplitMix64(seed: 0x5)
    var samples: [CalibrationSample] = []
    for target in grid {
        let point = CGPoint(x: 500 + target.yaw * 5000, y: 1000 + target.pitch * 3000)
        for _ in 0..<15 {
            let f = realisticFrame(yaw: target.yaw, pitch: target.pitch, rng: &rng)
            samples.append(CalibrationSample(features: f, target: point))
        }
    }
    let model = try GazeModel.fit(samples: samples)
    #expect(model.degree == 1)
}
