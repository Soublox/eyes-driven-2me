import CoreGraphics
import Foundation
import Testing
@testable import EyesDrivenCore

private struct LCG {
    var state: UInt64
    init(seed: UInt64 = 0xdead_beef_cafe_1234) { state = seed }
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(UInt64(1) << 53)
    }
}

@Test func firstSamplePassesThrough() {
    let f = OneEuroFilter()
    #expect(f.filter(3.2, at: 0.0) == 3.2)
}

@Test func constantInputConverges() {
    let f = OneEuroFilter()
    var out = 0.0
    var t = 0.0
    for _ in 0..<300 {
        out = f.filter(5.0, at: t)
        t += 1.0 / 30.0
    }
    #expect(abs(out - 5.0) < 1e-3)
}

@Test func reducesJitterVarianceOfNoisyConstant() {
    let f = OneEuroFilter(minCutoff: 1.0, beta: 0.007)
    var rng = LCG()
    var inputs: [Double] = []
    var outputs: [Double] = []
    var t = 0.0
    for i in 0..<400 {
        let x = 10.0 + (rng.next() * 2 - 1) // noisy constant in [9, 11]
        let y = f.filter(x, at: t)
        if i >= 100 { // after warm-up
            inputs.append(x)
            outputs.append(y)
        }
        t += 1.0 / 30.0
    }
    #expect(variance(outputs) < variance(inputs) * 0.5)
}

@Test func resetReturnsToPassThrough() {
    let f = OneEuroFilter()
    _ = f.filter(1.0, at: 0.0)
    _ = f.filter(9.0, at: 0.1)
    f.reset()
    #expect(f.filter(4.0, at: 0.2) == 4.0)
}

@Test func pointFilterTracksBothAxes() {
    let pf = PointFilter()
    let first = pf.filter(CGPoint(x: 12, y: -3), at: 0.0)
    #expect(first == CGPoint(x: 12, y: -3))
    _ = pf.filter(CGPoint(x: 12, y: -3), at: 1.0 / 30.0)
    pf.reset()
    let again = pf.filter(CGPoint(x: 7, y: 7), at: 1.0)
    #expect(again == CGPoint(x: 7, y: 7))
}

private func variance(_ values: [Double]) -> Double {
    let mean = values.reduce(0, +) / Double(values.count)
    return values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
}
