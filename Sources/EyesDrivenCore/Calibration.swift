import CoreGraphics
import Foundation

/// Errors thrown while fitting a `GazeModel`.
public enum CalibrationError: Error, Equatable {
    /// Fewer than `GazeModel.minimumSampleCount` samples were provided.
    case notEnoughSamples
    /// The regularized normal-equation system could not be solved.
    case singularSystem
}

/// Polynomial ridge-regression gaze model (SPEC 3.2).
///
/// Features are standardized (per-feature mean/std) and expanded to a degree-1
/// or degree-2 basis (bias, linear terms, and for degree 2 the squares and
/// pairwise products), then mapped to the target point by two independent ridge
/// regressions solved with Gaussian elimination with partial pivoting. Pure
/// Swift, no Accelerate.
///
/// `fit(samples:)` selects the basis degree ∈ {1, 2} and the ridge penalty
/// λ ∈ {0.01, 0.1, 1, 10, 100} by leave-one-target-out cross-validation and
/// refits the winner on every sample, so a calibration with few distinct targets
/// does not overfit the 36-term degree-2 basis. Degree 2 is only considered with
/// at least `degreeTwoMinimumTargets` distinct targets.
public struct GazeModel: Codable, Equatable, Sendable {
    /// Per-feature means used for standardization.
    public private(set) var means: [Double]
    /// Per-feature standard deviations used for standardization.
    public private(set) var stds: [Double]
    /// Ridge weights for the x coordinate.
    public private(set) var weightsX: [Double]
    /// Ridge weights for the y coordinate.
    public private(set) var weightsY: [Double]
    /// `+1` if pitch increases as the user looks lower on screen, else `-1`.
    public private(set) var pitchDownSign: Int
    /// Ridge penalty applied to every non-bias term.
    public private(set) var lambda: Double
    /// Basis degree used by `predict` (1 or 2).
    public private(set) var degree: Int
    /// Mean Euclidean leave-one-target-out error (points) of the selected
    /// configuration, or `0` when the model was fit with a forced λ.
    public private(set) var crossValidationError: Double

    /// Minimum number of samples required to fit a model.
    public static let minimumSampleCount = 5
    /// Degree 2 is only considered when at least this many distinct targets exist.
    public static let degreeTwoMinimumTargets = 12
    /// Ridge penalties tried during model selection.
    public static let candidateLambdas: [Double] = [0.01, 0.1, 1, 10, 100]

    /// Number of expanded degree-2 terms (bias + linear + squares + products).
    public static var termCount: Int { termCount(degree: 2) }

    /// Number of expanded terms for a given basis degree.
    public static func termCount(degree: Int) -> Int {
        let n = FaceFeatures.featureCount
        if degree <= 1 { return 1 + n }
        return 1 + n + n + (n * (n - 1)) / 2
    }

    private init(
        means: [Double],
        stds: [Double],
        weightsX: [Double],
        weightsY: [Double],
        pitchDownSign: Int,
        lambda: Double,
        degree: Int,
        crossValidationError: Double
    ) {
        self.means = means
        self.stds = stds
        self.weightsX = weightsX
        self.weightsY = weightsY
        self.pitchDownSign = pitchDownSign
        self.lambda = lambda
        self.degree = degree
        self.crossValidationError = crossValidationError
    }

    /// Fit a model from calibration samples.
    ///
    /// When `lambda` is nil (the default) the basis degree and the ridge
    /// penalty are chosen by leave-one-target-out cross-validation (samples that
    /// share a target point form one fold) and the winner is refit on every
    /// sample. Passing an explicit `lambda` skips model selection and forces a
    /// degree-2 model with that penalty.
    ///
    /// - Throws: `CalibrationError.notEnoughSamples` when fewer than
    ///   `minimumSampleCount` samples are given; `CalibrationError.singularSystem`
    ///   if the normal equations cannot be solved.
    public static func fit(samples: [CalibrationSample], lambda forcedLambda: Double? = nil) throws -> GazeModel {
        guard samples.count >= minimumSampleCount else { throw CalibrationError.notEnoughSamples }

        let sign = computePitchDownSign(of: samples)

        if let lambda = forcedLambda {
            guard let fit = fitCore(samples: samples, degree: 2, lambda: lambda) else {
                throw CalibrationError.singularSystem
            }
            return GazeModel(
                means: fit.means,
                stds: fit.stds,
                weightsX: fit.weightsX,
                weightsY: fit.weightsY,
                pitchDownSign: sign,
                lambda: lambda,
                degree: 2,
                crossValidationError: 0
            )
        }

        let groups = groupByTarget(samples)
        var degrees = [1]
        if groups.count >= degreeTwoMinimumTargets { degrees.append(2) }

        var bestDegree = 1
        var bestLambda = candidateLambdas[0]
        var bestError = Double.infinity
        for degree in degrees {
            for lambda in candidateLambdas {
                let error = leaveOneTargetOutError(
                    samples: samples, groups: groups, degree: degree, lambda: lambda
                )
                if error < bestError {
                    bestError = error
                    bestDegree = degree
                    bestLambda = lambda
                }
            }
        }

        guard let fit = fitCore(samples: samples, degree: bestDegree, lambda: bestLambda) else {
            throw CalibrationError.singularSystem
        }
        return GazeModel(
            means: fit.means,
            stds: fit.stds,
            weightsX: fit.weightsX,
            weightsY: fit.weightsY,
            pitchDownSign: sign,
            lambda: bestLambda,
            degree: bestDegree,
            crossValidationError: bestError
        )
    }

    /// Predict the target point (global CG coordinates) for a frame.
    public func predict(_ features: FaceFeatures) -> CGPoint {
        GazeModel.predict(
            means: means,
            stds: stds,
            weightsX: weightsX,
            weightsY: weightsY,
            degree: degree,
            features: features
        )
    }

    /// Mean Euclidean prediction error (points) over the given samples.
    public func meanError(on samples: [CalibrationSample]) -> Double {
        guard !samples.isEmpty else { return 0 }
        var total = 0.0
        for sample in samples {
            let p = predict(sample.features)
            total += (Double(p.x - sample.target.x) * Double(p.x - sample.target.x)
                + Double(p.y - sample.target.y) * Double(p.y - sample.target.y)).squareRoot()
        }
        return total / Double(samples.count)
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case means, stds, weightsX, weightsY, pitchDownSign, lambda, degree, crossValidationError
    }

    /// Tolerant decoding: `lambda`, `degree` and `crossValidationError` may be
    /// absent in profiles saved by an older build. `degree` is then inferred
    /// from the number of stored weights.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        means = try c.decode([Double].self, forKey: .means)
        stds = try c.decode([Double].self, forKey: .stds)
        weightsX = try c.decode([Double].self, forKey: .weightsX)
        weightsY = try c.decode([Double].self, forKey: .weightsY)
        pitchDownSign = try c.decode(Int.self, forKey: .pitchDownSign)
        lambda = try c.decodeIfPresent(Double.self, forKey: .lambda) ?? 0.01
        degree = try c.decodeIfPresent(Int.self, forKey: .degree)
            ?? (weightsX.count > 1 + FaceFeatures.featureCount ? 2 : 1)
        crossValidationError = try c.decodeIfPresent(Double.self, forKey: .crossValidationError) ?? 0
    }

    // MARK: - Helpers

    /// A fitted set of weights (standardization + two coefficient vectors).
    private struct Fit {
        var means: [Double]
        var stds: [Double]
        var weightsX: [Double]
        var weightsY: [Double]
    }

    /// Standardized base vector -> polynomial basis (bias first).
    static func expand(_ z: [Double], degree: Int = 2) -> [Double] {
        let n = z.count
        var v = [Double]()
        v.reserveCapacity(termCount(degree: degree))
        v.append(1.0)
        v.append(contentsOf: z)
        if degree >= 2 {
            for i in 0..<n { v.append(z[i] * z[i]) }
            if n > 1 {
                for i in 0..<(n - 1) {
                    for j in (i + 1)..<n { v.append(z[i] * z[j]) }
                }
            }
        }
        return v
    }

    /// Fit standardization and the two ridge regressions for one configuration.
    /// Returns nil when the normal equations are singular.
    private static func fitCore(samples: [CalibrationSample], degree: Int, lambda: Double) -> Fit? {
        guard !samples.isEmpty else { return nil }
        let n = FaceFeatures.featureCount
        let count = Double(samples.count)

        var means = [Double](repeating: 0, count: n)
        for sample in samples {
            let f = sample.features.featureVector
            for i in 0..<n { means[i] += f[i] }
        }
        for i in 0..<n { means[i] /= count }

        var variances = [Double](repeating: 0, count: n)
        for sample in samples {
            let f = sample.features.featureVector
            for i in 0..<n {
                let d = f[i] - means[i]
                variances[i] += d * d
            }
        }
        let stds = variances.map { max(($0 / count).squareRoot(), 1e-6) }

        let m = termCount(degree: degree)
        var design = [[Double]]()
        design.reserveCapacity(samples.count)
        var targetsX = [Double]()
        var targetsY = [Double]()
        targetsX.reserveCapacity(samples.count)
        targetsY.reserveCapacity(samples.count)

        for sample in samples {
            let f = sample.features.featureVector
            var z = [Double](repeating: 0, count: n)
            for i in 0..<n { z[i] = (f[i] - means[i]) / stds[i] }
            design.append(expand(z, degree: degree))
            targetsX.append(Double(sample.target.x))
            targetsY.append(Double(sample.target.y))
        }

        // Normal equations: A = XᵀX (+ ridge on non-bias terms), b = Xᵀy.
        var a = [Double](repeating: 0, count: m * m)
        for row in design {
            for i in 0..<m {
                let ri = row[i]
                if ri == 0 { continue }
                for j in i..<m { a[i * m + j] += ri * row[j] }
            }
        }
        for i in 0..<m {
            for j in 0..<i { a[i * m + j] = a[j * m + i] }
        }
        for i in 1..<m { a[i * m + i] += lambda }

        var bx = [Double](repeating: 0, count: m)
        var by = [Double](repeating: 0, count: m)
        for (r, row) in design.enumerated() {
            for i in 0..<m {
                bx[i] += row[i] * targetsX[r]
                by[i] += row[i] * targetsY[r]
            }
        }

        guard let wx = solve(a, bx, m), let wy = solve(a, by, m) else { return nil }
        return Fit(means: means, stds: stds, weightsX: wx, weightsY: wy)
    }

    /// Predict using explicit model parameters (used during cross-validation).
    private static func predict(
        means: [Double],
        stds: [Double],
        weightsX: [Double],
        weightsY: [Double],
        degree: Int,
        features: FaceFeatures
    ) -> CGPoint {
        let f = features.featureVector
        let n = FaceFeatures.featureCount
        var z = [Double](repeating: 0, count: n)
        for i in 0..<n { z[i] = (f[i] - means[i]) / stds[i] }
        let row = expand(z, degree: degree)
        var x = 0.0
        var y = 0.0
        for i in 0..<row.count {
            x += row[i] * weightsX[i]
            y += row[i] * weightsY[i]
        }
        return CGPoint(x: x, y: y)
    }

    /// Group samples into folds: one fold per distinct target point.
    private static func groupByTarget(_ samples: [CalibrationSample]) -> [[CalibrationSample]] {
        var groups: [[CalibrationSample]] = []
        var seenTargets: [CGPoint] = []
        for sample in samples {
            if let index = seenTargets.firstIndex(of: sample.target) {
                groups[index].append(sample)
            } else {
                seenTargets.append(sample.target)
                groups.append([sample])
            }
        }
        return groups
    }

    /// Mean Euclidean held-out error of one configuration: every fold (a single
    /// target) is predicted by a model fit on all the other targets.
    private static func leaveOneTargetOutError(
        samples: [CalibrationSample],
        groups: [[CalibrationSample]],
        degree: Int,
        lambda: Double
    ) -> Double {
        var total = 0.0
        var count = 0
        for (index, heldOut) in groups.enumerated() {
            var training: [CalibrationSample] = []
            for (other, group) in groups.enumerated() where other != index {
                training.append(contentsOf: group)
            }
            guard let fit = fitCore(samples: training, degree: degree, lambda: lambda) else { continue }
            for sample in heldOut {
                let p = predict(
                    means: fit.means,
                    stds: fit.stds,
                    weightsX: fit.weightsX,
                    weightsY: fit.weightsY,
                    degree: degree,
                    features: sample.features
                )
                total += hypot(Double(p.x - sample.target.x), Double(p.y - sample.target.y))
                count += 1
            }
        }
        return count > 0 ? total / Double(count) : .infinity
    }

    /// Sign of the Pearson correlation between pitch and target y.
    private static func computePitchDownSign(of samples: [CalibrationSample]) -> Int {
        let corr = pearson(
            samples.map { $0.features.pitch },
            samples.map { Double($0.target.y) }
        )
        return corr > 0 ? 1 : -1
    }

    /// Solve `A x = b` for a dense `n × n` row-major matrix by Gaussian
    /// elimination with partial pivoting. Returns nil if singular.
    private static func solve(_ aIn: [Double], _ bIn: [Double], _ n: Int) -> [Double]? {
        var a = aIn
        var b = bIn
        for col in 0..<n {
            var pivot = col
            var best = abs(a[col * n + col])
            for r in (col + 1)..<n {
                let v = abs(a[r * n + col])
                if v > best { best = v; pivot = r }
            }
            if best < 1e-12 { return nil }
            if pivot != col {
                for c in 0..<n { a.swapAt(col * n + c, pivot * n + c) }
                b.swapAt(col, pivot)
            }
            let diag = a[col * n + col]
            for r in (col + 1)..<n {
                let factor = a[r * n + col] / diag
                if factor == 0 { continue }
                for c in col..<n { a[r * n + c] -= factor * a[col * n + c] }
                b[r] -= factor * b[col]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            var sum = b[row]
            var c = row + 1
            while c < n {
                sum -= a[row * n + c] * x[c]
                c += 1
            }
            x[row] = sum / a[row * n + row]
        }
        return x
    }

    /// Pearson correlation coefficient between two equal-length series.
    static func pearson(_ xs: [Double], _ ys: [Double]) -> Double {
        guard xs.count == ys.count, xs.count > 1 else { return 0 }
        let n = Double(xs.count)
        let mx = xs.reduce(0, +) / n
        let my = ys.reduce(0, +) / n
        var cov = 0.0
        var vx = 0.0
        var vy = 0.0
        for i in 0..<xs.count {
            let dx = xs[i] - mx
            let dy = ys[i] - my
            cov += dx * dy
            vx += dx * dx
            vy += dy * dy
        }
        let den = (vx * vy).squareRoot()
        return den == 0 ? 0 : cov / den
    }
}

/// Persisted calibration: the fitted model, the raw samples, the capture date
/// and a fingerprint of the display layout it was calibrated against.
public struct CalibrationProfile: Codable, Equatable, Sendable {
    public var model: GazeModel
    public var samples: [CalibrationSample]
    public var createdAt: Date
    public var displayFingerprint: String

    public init(
        model: GazeModel,
        samples: [CalibrationSample],
        createdAt: Date,
        displayFingerprint: String
    ) {
        self.model = model
        self.samples = samples
        self.createdAt = createdAt
        self.displayFingerprint = displayFingerprint
    }

    /// Deterministic fingerprint of a display layout, stable across launches.
    public static func fingerprint(for displays: [DisplayInfo]) -> String {
        displays
            .sorted { $0.id < $1.id }
            .map { d in
                "\(d.id):\(Int(d.frame.width.rounded()))x\(Int(d.frame.height.rounded()))"
                    + "@\(Int(d.frame.minX.rounded())),\(Int(d.frame.minY.rounded()))"
            }
            .joined(separator: "|")
    }
}
