import CoreGraphics
import CoreMedia
import EyesDrivenCore
import Foundation
import Vision

/// Converts camera frames into `FaceFeatures` using Vision face landmarks.
///
/// Vision's landmark points (`VNFaceLandmarkRegion2D.normalizedPoints`) are used
/// only as a *relative* space: the iris is normalized inside each eye contour's
/// own bounding box and openness is the eye aspect ratio, so the absolute
/// landmark coordinate space never leaks out. `faceCenter`/`faceSize` come from
/// the observation's normalized bounding box. No frame data is written to disk
/// or sent anywhere.
final class FaceTracker {

    private let sequenceHandler = VNSequenceRequestHandler()
    private let request: VNDetectFaceLandmarksRequest

    init() {
        let request = VNDetectFaceLandmarksRequest()
        request.revision = VNDetectFaceLandmarksRequest.currentRevision
        self.request = request
    }

    /// Runs face-landmark detection on one frame and returns the features of the
    /// largest detected face, or `nil` when there is no face or no landmarks.
    func process(_ sampleBuffer: CMSampleBuffer) -> FaceFeatures? {
        let presentation = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let timestamp = presentation.isNumeric ? CMTimeGetSeconds(presentation) : 0

        do {
            try sequenceHandler.perform([request], on: sampleBuffer)
        } catch {
            return nil
        }

        guard let observations = request.results, !observations.isEmpty else { return nil }
        guard let face = observations.max(by: { $0.boundingBox.width < $1.boundingBox.width }) else {
            return nil
        }
        guard let landmarks = face.landmarks else { return nil }

        let box = face.boundingBox

        return FaceFeatures(
            timestamp: timestamp,
            yaw: radians(face.yaw) ?? estimateYaw(landmarks: landmarks),
            pitch: radians(face.pitch) ?? estimatePitch(landmarks: landmarks),
            roll: radians(face.roll) ?? 0,
            leftIris: irisPosition(pupil: landmarks.leftPupil, eye: landmarks.leftEye) ?? CGPoint(x: 0.5, y: 0.5),
            rightIris: irisPosition(pupil: landmarks.rightPupil, eye: landmarks.rightEye) ?? CGPoint(x: 0.5, y: 0.5),
            leftEyeOpenness: eyeOpenness(landmarks.leftEye),
            rightEyeOpenness: eyeOpenness(landmarks.rightEye),
            faceCenter: CGPoint(x: box.midX, y: box.midY),
            faceSize: Double(box.width)
        )
    }

    // MARK: - Measurements

    private func radians(_ value: NSNumber?) -> Double? {
        value?.doubleValue
    }

    /// Pupil position normalized (clamped to 0...1) inside the eye contour's own
    /// bounding box. Both regions are in the same landmark coordinate space.
    private func irisPosition(
        pupil: VNFaceLandmarkRegion2D?,
        eye: VNFaceLandmarkRegion2D?
    ) -> CGPoint? {
        guard let pupil, pupil.pointCount > 0, let eye, eye.pointCount > 0 else { return nil }
        let eyeBox = boundingBox(of: eye)
        guard eyeBox.width > 0, eyeBox.height > 0 else { return nil }
        let pupilCenter = centroid(of: pupil)
        let nx = (pupilCenter.x - eyeBox.minX) / eyeBox.width
        let ny = (pupilCenter.y - eyeBox.minY) / eyeBox.height
        return CGPoint(x: clampUnit(nx), y: clampUnit(ny))
    }

    /// Eye aspect ratio (contour height / width). Lower means more closed.
    private func eyeOpenness(_ eye: VNFaceLandmarkRegion2D?) -> Double {
        guard let eye, eye.pointCount > 0 else { return 0 }
        let box = boundingBox(of: eye)
        guard box.width > 0 else { return 0 }
        return Double(box.height / box.width)
    }

    // MARK: - Landmark fallbacks

    /// Rough yaw estimate used only when Vision leaves `VNFaceObservation.yaw`
    /// nil. The horizontal offset of the nose crest from the face-landmark
    /// centroid, as a fraction of the face width, is scaled by π so a half-face
    /// offset lands near ±π/2 (roughly radians). Sign matches Vision's yaw
    /// convention (positive = counterclockwise); calibration, not this value,
    /// drives the gaze mapping.
    private func estimateYaw(landmarks: VNFaceLandmarks2D) -> Double {
        guard let face = referenceBox(landmarks), face.width > 0,
              let nose = landmarks.noseCrest ?? landmarks.nose, nose.pointCount > 0
        else { return 0 }
        let center = centroid(of: nose)
        return clampRadians(Double((center.x - face.midX) / face.width) * .pi)
    }

    /// Rough pitch estimate used only when Vision leaves `VNFaceObservation.pitch`
    /// nil. Same idea as `estimateYaw` but vertical: the nose crest offset from
    /// the face-landmark centroid over the face height, scaled by π. Positive
    /// follows Vision's convention (nodding down); sign is approximate and is
    /// learned by calibration via `GazeModel.pitchDownSign`.
    private func estimatePitch(landmarks: VNFaceLandmarks2D) -> Double {
        guard let face = referenceBox(landmarks), face.height > 0,
              let nose = landmarks.noseCrest ?? landmarks.nose, nose.pointCount > 0
        else { return 0 }
        let center = centroid(of: nose)
        return clampRadians(Double((center.y - face.midY) / face.height) * .pi)
    }

    /// Bounding box of every landmark point, used as the reference frame for the
    /// yaw/pitch fallbacks. Space-agnostic: it is the same coordinate space the
    /// nose points live in.
    private func referenceBox(_ landmarks: VNFaceLandmarks2D) -> CGRect? {
        guard let all = landmarks.allPoints, all.pointCount > 0 else { return nil }
        return boundingBox(of: all)
    }

    // MARK: - Geometry helpers

    private func boundingBox(of region: VNFaceLandmarkRegion2D) -> CGRect {
        let points = region.normalizedPoints
        guard let first = points.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func centroid(of region: VNFaceLandmarkRegion2D) -> CGPoint {
        let points = region.normalizedPoints
        guard !points.isEmpty else { return .zero }
        var sumX = 0.0, sumY = 0.0
        for point in points {
            sumX += Double(point.x)
            sumY += Double(point.y)
        }
        let count = Double(points.count)
        return CGPoint(x: sumX / count, y: sumY / count)
    }

    private func clampUnit(_ value: CGFloat) -> CGFloat {
        min(max(value, 0), 1)
    }

    private func clampRadians(_ value: Double) -> Double {
        min(max(value, -.pi / 2), .pi / 2)
    }
}
