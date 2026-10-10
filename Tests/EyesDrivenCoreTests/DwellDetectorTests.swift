import Testing
@testable import EyesDrivenCore

@Test func firesAfterDuration() {
    var d = DwellDetector<Int>(duration: 1.0, tolerance: 0.15)
    #expect(d.update(target: 1, timestamp: 0.0) == .progressing(1, 0.0))
    let mid = d.update(target: 1, timestamp: 0.5)
    if case .progressing(1, let f) = mid {
        #expect(abs(f - 0.5) < 1e-9)
    } else {
        Issue.record("expected progressing at the midpoint")
    }
    #expect(d.update(target: 1, timestamp: 1.0) == .fired(1))
}

@Test func shortGlitchDoesNotResetProgress() {
    var d = DwellDetector<Int>(duration: 1.0, tolerance: 0.15)
    _ = d.update(target: 1, timestamp: 0.0)
    _ = d.update(target: 1, timestamp: 0.5) // 50% progress
    _ = d.update(target: 2, timestamp: 0.55) // glitch to another target (0.05 s)
    let back = d.update(target: 1, timestamp: 0.60) // back within tolerance
    if case .progressing(1, let f) = back {
        #expect(f >= 0.6) // progress preserved, not reset
    } else {
        Issue.record("expected progress to continue after a short glitch")
    }
    // Fires at the original deadline (0.0 + 1.0).
    #expect(d.update(target: 1, timestamp: 1.0) == .fired(1))
}

@Test func longSwitchResetsProgress() {
    var d = DwellDetector<Int>(duration: 1.0, tolerance: 0.15)
    _ = d.update(target: 1, timestamp: 0.0)
    _ = d.update(target: 1, timestamp: 0.5)
    _ = d.update(target: 2, timestamp: 0.55) // switch begins
    let switched = d.update(target: 2, timestamp: 0.55 + 0.15) // confirmed after tolerance
    if case .progressing(2, let f) = switched {
        #expect(abs(f - 0.15) < 1e-9) // fresh progress for the new target
    } else {
        Issue.record("expected fresh progress for the new target")
    }
    // Target 1's progress is gone; target 2 fires 1.0 s after it appeared (0.55).
    #expect(d.update(target: 2, timestamp: 1.54) != .fired(2))
    #expect(d.update(target: 2, timestamp: 1.55) == .fired(2))
}

@Test func noRefireOnSameTarget() {
    var d = DwellDetector<Int>(duration: 1.0, tolerance: 0.15)
    _ = d.update(target: 1, timestamp: 0.0)
    // Fires exactly once on the crossing frame...
    #expect(d.update(target: 1, timestamp: 1.0) == .fired(1))
    // ...then reports the completed dwell at 1.0 (SPEC 3.6), never firing again.
    #expect(d.update(target: 1, timestamp: 1.5) == .progressing(1, 1.0))
    #expect(d.update(target: 1, timestamp: 3.0) == .progressing(1, 1.0))
    #expect(d.update(target: 1, timestamp: 10.0) == .progressing(1, 1.0))
}

@Test func refiresAfterSwitchingAwayAndBack() {
    var d = DwellDetector<Int>(duration: 1.0, tolerance: 0.15)
    _ = d.update(target: 1, timestamp: 0.0)
    #expect(d.update(target: 1, timestamp: 1.0) == .fired(1))
    // Switch to 2 and dwell there.
    _ = d.update(target: 2, timestamp: 1.1)
    #expect(d.update(target: 2, timestamp: 1.1 + 1.0) == .fired(2))
    // Back to 1: must fire again after a fresh dwell.
    _ = d.update(target: 1, timestamp: 2.2)
    #expect(d.update(target: 1, timestamp: 2.2 + 1.0) == .fired(1))
}

@Test func idleWhenNoTarget() {
    var d = DwellDetector<Int>()
    #expect(d.update(target: nil, timestamp: 0.0) == .idle)
    #expect(d.update(target: nil, timestamp: 1.0) == .idle)
}

@Test func resetClearsProgress() {
    var d = DwellDetector<Int>(duration: 1.0, tolerance: 0.15)
    _ = d.update(target: 1, timestamp: 0.0)
    _ = d.update(target: 1, timestamp: 0.9)
    d.reset()
    #expect(d.update(target: 1, timestamp: 1.0) == .progressing(1, 0.0))
}

@Test func longNilGlitchResets() {
    var d = DwellDetector<Int>(duration: 1.0, tolerance: 0.15)
    _ = d.update(target: 1, timestamp: 0.0)
    _ = d.update(target: 1, timestamp: 0.5)
    _ = d.update(target: nil, timestamp: 0.6)
    #expect(d.update(target: nil, timestamp: 0.6 + 0.15) == .idle)
    // Re-acquiring target 1 starts from scratch.
    #expect(d.update(target: 1, timestamp: 1.0) == .progressing(1, 0.0))
}
