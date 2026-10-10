import CoreGraphics
import Foundation
import Testing
@testable import EyesDrivenCore

/// A clean `FaceFeatures` frame; override the fields a test cares about.
private func frame(
    at timestamp: TimeInterval,
    yaw: Double = 0,
    pitch: Double = 0,
    landmarksConfidence: Double = 1,
    captureQuality: Double? = 0.9,
    handOverlap: Double = 0
) -> FaceFeatures {
    FaceFeatures(
        timestamp: timestamp,
        yaw: yaw,
        pitch: pitch,
        roll: 0,
        leftIris: CGPoint(x: 0.5, y: 0.5),
        rightIris: CGPoint(x: 0.5, y: 0.5),
        leftEyeOpenness: 0.3,
        rightEyeOpenness: 0.3,
        faceCenter: CGPoint(x: 0.5, y: 0.5),
        faceSize: 0.3,
        landmarksConfidence: landmarksConfidence,
        captureQuality: captureQuality,
        handOverlap: handOverlap
    )
}

private let frameStep = 1.0 / 30.0

@Test func cleanStreamIsReliable() {
    var gate = TrackingQualityGate()
    for index in 0..<10 {
        let quality = gate.process(frame(at: Double(index) * frameStep))
        #expect(quality.isReliable)
        #expect(quality.reasons.isEmpty)
    }
}

@Test func oneLowConfidenceFrameIsUnreliableThenRecoversAfterHalfASecond() {
    var gate = TrackingQualityGate()
    // Establish a reliable stream.
    for index in 0..<5 {
        #expect(gate.process(frame(at: Double(index) * frameStep)).isReliable)
    }

    // The bad frame is unreliable immediately, with the landmark reason.
    let bad = gate.process(frame(at: 6 * frameStep, landmarksConfidence: 0.2))
    #expect(!bad.isReliable)
    #expect(bad.reasons.contains(.lowLandmarkConfidence))

    // From the first clean frame the gate counts a recovery window: still
    // unreliable (recovering) well before 0.5 s, reliable only on/after 0.5 s.
    let recoveryStart = 7 * frameStep
    var reliableFrameIndex: Int?
    var index = 7
    while index < 40, reliableFrameIndex == nil {
        let quality = gate.process(frame(at: Double(index) * frameStep))
        if quality.isReliable {
            reliableFrameIndex = index
        } else {
            #expect(quality.reasons.contains(.recovering))
        }
        index += 1
    }

    #expect(reliableFrameIndex != nil)
    if let reliableFrameIndex {
        let recoveredAt = Double(reliableFrameIndex) * frameStep
        // Not before the recovery window elapsed...
        #expect(recoveredAt - recoveryStart >= 0.5 - 1e-6)
        // ...and not far after it (it recovers on the first frame past 0.5 s).
        #expect(recoveredAt - recoveryStart < 0.5 + frameStep)
    }
}

@Test func handOverlapMarksHandOnFace() {
    var gate = TrackingQualityGate()
    let quality = gate.process(frame(at: 0, handOverlap: 0.3))
    #expect(!quality.isReliable)
    #expect(quality.reasons.contains(.handOnFace))
}

@Test func lowCaptureQualityFailsButNilCaptureQualityDoesNot() {
    var gate = TrackingQualityGate()
    #expect(!gate.process(frame(at: 0, captureQuality: 0.1)).isReliable)
    #expect(gate.process(frame(at: frameStep, captureQuality: 0.1)).reasons.contains(.lowCaptureQuality))

    var nilGate = TrackingQualityGate()
    #expect(nilGate.process(frame(at: 0, captureQuality: nil)).isReliable)
}

@Test func poseJumpInOneFrameIsUnreliable() {
    var gate = TrackingQualityGate()
    #expect(gate.process(frame(at: 0, yaw: 0)).isReliable)
    let quality = gate.process(frame(at: frameStep, yaw: 0.4))
    #expect(!quality.isReliable)
    #expect(quality.reasons.contains(.poseJump))
}

@Test func largeChangeAcrossALongGapIsNotAJump() {
    var gate = TrackingQualityGate()
    #expect(gate.process(frame(at: 0, yaw: 0)).isReliable)
    // 2 rad over a 0.5 s gap: not a glitch, so the frame is still reliable.
    let quality = gate.process(frame(at: 0.5, yaw: 2.0))
    #expect(quality.isReliable)
    #expect(quality.reasons.isEmpty)
}

@Test func resetReturnsToReliable() {
    var gate = TrackingQualityGate()
    _ = gate.process(frame(at: 0, handOverlap: 0.5))
    #expect(!gate.process(frame(at: frameStep, handOverlap: 0.5)).isReliable)
    gate.reset()
    #expect(gate.process(frame(at: 1.0)).isReliable)
}
