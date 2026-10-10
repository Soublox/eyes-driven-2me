import CoreGraphics
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
