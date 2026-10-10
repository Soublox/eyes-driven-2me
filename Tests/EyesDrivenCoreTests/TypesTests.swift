import CoreGraphics
import Foundation
import Testing
@testable import EyesDrivenCore

@Test func featureVectorAveragesIris() {
    let f = FaceFeatures(
        timestamp: 0, yaw: 0.1, pitch: -0.2, roll: 0,
        leftIris: CGPoint(x: 0.4, y: 0.6), rightIris: CGPoint(x: 0.6, y: 0.4),
        leftEyeOpenness: 0.3, rightEyeOpenness: 0.3,
        faceCenter: CGPoint(x: 0.5, y: 0.5), faceSize: 0.3
    )
    #expect(f.featureVector == [0.1, -0.2, 0.5, 0.5, 0.5, 0.5, 0.3])
    #expect(f.featureVector.count == FaceFeatures.featureCount)
}

/// A `calibration.json` saved before the tracking-quality fields existed still
/// decodes; the new fields fall back to their defaults.
@Test func faceFeaturesDecodesLegacyJSONWithDefaults() throws {
    let original = FaceFeatures(
        timestamp: 1.5, yaw: 0.1, pitch: -0.2, roll: 0.05,
        leftIris: CGPoint(x: 0.4, y: 0.6), rightIris: CGPoint(x: 0.6, y: 0.4),
        leftEyeOpenness: 0.3, rightEyeOpenness: 0.25,
        faceCenter: CGPoint(x: 0.5, y: 0.5), faceSize: 0.3,
        landmarksConfidence: 0.9, captureQuality: 0.7, handOverlap: 0.2
    )

    // Strip the tracking-quality keys to emulate an old file.
    let encoded = try JSONEncoder().encode(original)
    guard let jsonObject = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
        Issue.record("FaceFeatures did not encode to a JSON object")
        return
    }
    var object = jsonObject
    object.removeValue(forKey: "landmarksConfidence")
    object.removeValue(forKey: "captureQuality")
    object.removeValue(forKey: "handOverlap")
    let legacy = try JSONSerialization.data(withJSONObject: object)

    let decoded = try JSONDecoder().decode(FaceFeatures.self, from: legacy)
    #expect(decoded.landmarksConfidence == 1)
    #expect(decoded.captureQuality == nil)
    #expect(decoded.handOverlap == 0)
    // The original fields survive.
    #expect(decoded.yaw == 0.1)
    #expect(decoded.pitch == -0.2)
    #expect(decoded.faceSize == 0.3)
    #expect(decoded.faceCenter == CGPoint(x: 0.5, y: 0.5))
}
