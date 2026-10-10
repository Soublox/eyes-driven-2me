import Foundation
import Testing
@testable import EyesDrivenCore

private let dt = 1.0 / 30.0

private func run(_ detector: NodDetector, _ samples: [(TimeInterval, Double)]) -> [NodEvent] {
    var events: [NodEvent] = []
    for (t, p) in samples {
        if let e = detector.process(pitch: p, timestamp: t) { events.append(e) }
    }
    return events
}

/// A quick down-and-up nod of `amplitude` for the given down direction.
private func nodTrace(
    downSign: Double,
    amplitude: Double,
    t0: Double = 1.0,
    half: Double = 0.2
) -> (samples: [(TimeInterval, Double)], start: TimeInterval) {
    var out: [(TimeInterval, Double)] = []
    var t = 0.0
    while t < t0 { out.append((t, 0)); t += dt }
    let downStart = t
    while t < downStart + half {
        let s = (t - downStart) / half
        out.append((t, downSign * amplitude * s)); t += dt
    }
    let upStart = t
    while t < upStart + half {
        let s = (t - upStart) / half
        out.append((t, downSign * amplitude * (1 - s))); t += dt
    }
    for _ in 0..<10 { out.append((t, 0)); t += dt }
    return (out, downStart)
}

@Test func cleanNodFiresExactlyOnceWithCorrectStart() {
    let detector = NodDetector()
    let (samples, start) = nodTrace(downSign: -1, amplitude: 0.2)
    let events = run(detector, samples)
    #expect(events.count == 1)
    let event = events[0]
    // start is the first frame past 25% of minAmplitude: within one frame of downStart.
    #expect(event.startTimestamp >= start - 1e-6)
    #expect(event.startTimestamp <= start + dt + 1e-6)
    #expect(event.endTimestamp > event.startTimestamp)
}

@Test func slowLookDownDoesNotFire() {
    let detector = NodDetector()
    var samples: [(TimeInterval, Double)] = []
    var t = 0.0
    while t < 1.0 { samples.append((t, 0)); t += dt }
    // Ramp down to -0.15 over 0.2 s then hold for 1.5 s.
    let rampStart = t
    while t < rampStart + 0.2 {
        samples.append((t, -0.15 * (t - rampStart) / 0.2)); t += dt
    }
    while t < rampStart + 1.7 { samples.append((t, -0.15)); t += dt }
    // Return.
    let upStart = t
    while t < upStart + 0.2 {
        samples.append((t, -0.15 + 0.15 * (t - upStart) / 0.2)); t += dt
    }
    #expect(run(detector, samples).isEmpty)
}

@Test func upFirstMotionDoesNotFire() {
    let detector = NodDetector()
    let (samples, _) = nodTrace(downSign: 1, amplitude: 0.2) // moves up first for downSign -1
    #expect(run(detector, samples).isEmpty)
}

@Test func tooSmallAmplitudeDoesNotFire() {
    let detector = NodDetector()
    let (samples, _) = nodTrace(downSign: -1, amplitude: 0.05) // below minAmplitude 0.10
    #expect(run(detector, samples).isEmpty)
}

@Test func cooldownBlocksSecondImmediateNod() {
    let detector = NodDetector()
    let (first, _) = nodTrace(downSign: -1, amplitude: 0.2, t0: 1.0)
    var all = first
    // Second nod right after the first; cooldown (1.0 s) must block it.
    let (second, _) = nodTrace(downSign: -1, amplitude: 0.2, t0: 0.0, half: 0.2)
    let offset = 1.6
    all.append(contentsOf: second.map { ($0.0 + offset, $0.1) })
    #expect(run(detector, all).count == 1)
}

@Test func nodFiresAfterCooldownElapses() {
    let detector = NodDetector()
    let (first, _) = nodTrace(downSign: -1, amplitude: 0.2, t0: 1.0)
    var all = first
    let (second, _) = nodTrace(downSign: -1, amplitude: 0.2, t0: 0.0, half: 0.2)
    let offset = 4.0 // well past the 1.0 s cooldown
    all.append(contentsOf: second.map { ($0.0 + offset, $0.1) })
    #expect(run(detector, all).count == 2)
}

@Test func worksWithPositiveDownSign() {
    let detector = NodDetector(downSign: 1)
    let (samples, _) = nodTrace(downSign: 1, amplitude: 0.2)
    #expect(run(detector, samples).count == 1)
}

@Test func sensitivityMapping() {
    #expect(abs(NodDetectorConfig.config(forSensitivity: 0).minAmplitude - 0.16) < 1e-9)
    #expect(abs(NodDetectorConfig.config(forSensitivity: 1).minAmplitude - 0.05) < 1e-9)
    #expect(abs(NodDetectorConfig.config(forSensitivity: 0.5).minAmplitude - 0.105) < 1e-9)
    // Out-of-range values clamp.
    #expect(abs(NodDetectorConfig.config(forSensitivity: -1).minAmplitude - 0.16) < 1e-9)
    #expect(abs(NodDetectorConfig.config(forSensitivity: 2).minAmplitude - 0.05) < 1e-9)
}

@Test func resetClearsState() {
    let detector = NodDetector()
    let (samples, _) = nodTrace(downSign: -1, amplitude: 0.2)
    _ = run(detector, samples)
    detector.reset()
    let (again, _) = nodTrace(downSign: -1, amplitude: 0.2, t0: 0.0)
    // A fresh detector on the same trace fires once.
    #expect(run(detector, again).count == 1)
}
