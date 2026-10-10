import CoreGraphics
import CoreMedia
import EyesDrivenCore
import Foundation
import Vision

/// Converts camera frames into `FaceFeatures` with a two-stage Vision pipeline.
///
/// Stage 1 runs `VNDetectFaceRectanglesRequest` (revision 3) and keeps the
/// largest face. That request is the only one that reports continuous head
/// pose on macOS 27: `VNDetectFaceLandmarksRequest` returns yaw = 0, roll = 0
/// and pitch = nil, so its pose is never trusted. Stage 2 runs
/// `VNDetectFaceLandmarksRequest` on the same frame with
/// `inputFaceObservations` set to that face to obtain the iris and eye
/// contours.
///
/// Both requests go through the same reused `VNSequenceRequestHandler`. They
/// are two independent (non-tracking) requests, so the handler's temporal
/// sequence state is irrelevant; calling `perform` twice per frame reuses one
/// handler instead of allocating a fresh one every frame. The landmarks
/// request only starts once the rectangles result is known, so the two cannot
/// be batched into a single `perform` call.
///
/// Vision's landmark points (`VNFaceLandmarkRegion2D.normalizedPoints`) are used
/// only as a *relative* space: the iris is normalized inside each eye contour's
/// own bounding box and openness is the eye aspect ratio, so the absolute
/// landmark coordinate space never leaks out. `faceCenter`/`faceSize` come from
/// the rectangles observation's normalized bounding box. No frame data is
/// written to disk or sent anywhere.
final class FaceTracker {

    private let sequenceHandler = VNSequenceRequestHandler()
    private let rectanglesRequest = VNDetectFaceRectanglesRequest()
    private let landmarksRequest = VNDetectFaceLandmarksRequest()
    private let captureQualityRequest = VNDetectFaceCaptureQualityRequest()
    private let handPoseRequest = VNDetectHumanHandPoseRequest()

    /// Frame counter, used to run the (more expensive) hand-pose request on
    /// every second frame and reuse the last overlap in between.
    private var frameIndex = 0
    private var lastHandOverlap: Double = 0

    init() {
        rectanglesRequest.revision = VNDetectFaceRectanglesRequestRevision3
        landmarksRequest.revision = VNDetectFaceLandmarksRequest.currentRevision
        captureQualityRequest.revision = VNDetectFaceCaptureQualityRequestRevision3
        handPoseRequest.revision = VNDetectHumanHandPoseRequest.currentRevision
        handPoseRequest.maximumHandCount = 2
    }

    /// Runs face detection on one frame and returns the features of the largest
    /// detected face, or `nil` when there is no face or no landmarks.
    func process(_ sampleBuffer: CMSampleBuffer) -> FaceFeatures? {
        let presentation = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let timestamp = presentation.isNumeric ? CMTimeGetSeconds(presentation) : 0

        // Stage 1: face rectangles, which carry continuous yaw/pitch/roll.
        do {
            try sequenceHandler.perform([rectanglesRequest], on: sampleBuffer)
        } catch {
            return nil
        }
        guard let faces = rectanglesRequest.results, !faces.isEmpty,
              let face = faces.max(by: { $0.boundingBox.width < $1.boundingBox.width })
        else { return nil }

        // Stage 2: landmarks for the chosen face, on the same frame.
        landmarksRequest.inputFaceObservations = [face]
        do {
            try sequenceHandler.perform([landmarksRequest], on: sampleBuffer)
        } catch {
            return nil
        }
        guard let observation = landmarksRequest.results?.first,
              let landmarks = observation.landmarks
        else { return nil }

        let box = face.boundingBox

        // Stage 3: face capture quality, tied to the chosen face.
        captureQualityRequest.inputFaceObservations = [face]
        var captureQuality: Double?
        do {
            try sequenceHandler.perform([captureQualityRequest], on: sampleBuffer)
            captureQuality = captureQualityRequest.results?.first?.faceCaptureQuality.map(Double.init)
        } catch {
            captureQuality = nil
        }

        // Stage 4: hand-pose overlap, every second frame (reuse in between).
        frameIndex += 1
        let handOverlap: Double
        if frameIndex % 2 == 1 {
            handOverlap = measureHandOverlap(on: sampleBuffer, faceBox: box)
            lastHandOverlap = handOverlap
        } else {
            handOverlap = lastHandOverlap
        }

        return FaceFeatures(
            timestamp: timestamp,
            // Pose comes from the rectangles observation; the landmark request
            // never reports it. Landmark estimates are a last-resort fallback.
            yaw: radians(face.yaw) ?? estimateYaw(landmarks: landmarks),
            pitch: radians(face.pitch) ?? estimatePitch(landmarks: landmarks),
            roll: radians(face.roll) ?? 0,
            leftIris: irisPosition(pupil: landmarks.leftPupil, eye: landmarks.leftEye) ?? CGPoint(x: 0.5, y: 0.5),
            rightIris: irisPosition(pupil: landmarks.rightPupil, eye: landmarks.rightEye) ?? CGPoint(x: 0.5, y: 0.5),
            leftEyeOpenness: eyeOpenness(landmarks.leftEye),
            rightEyeOpenness: eyeOpenness(landmarks.rightEye),
            faceCenter: CGPoint(x: box.midX, y: box.midY),
            faceSize: Double(box.width),
            landmarksConfidence: Double(landmarks.confidence),
            captureQuality: captureQuality,
            handOverlap: handOverlap
        )
    }

    // MARK: - Tracking reliability measurements

    /// Fraction (`0...1`) of confidently recognized hand joints (confidence
    /// > 0.3) that fall inside `faceBox` expanded by 20 %. Hand joints and the
    /// face box are both in Vision's normalized image space (bottom-left
    /// origin), so they are compared directly. 0 when no hand is seen or no
    /// joint is confident enough.
    private func measureHandOverlap(on sampleBuffer: CMSampleBuffer, faceBox: CGRect) -> Double {
        do {
            try sequenceHandler.perform([handPoseRequest], on: sampleBuffer)
        } catch {
            return 0
        }
        guard let hands = handPoseRequest.results, !hands.isEmpty else { return 0 }

        let expanded = faceBox.insetBy(dx: -faceBox.width * 0.1, dy: -faceBox.height * 0.1)
        var confident = 0
        var inside = 0
        for hand in hands {
            guard let points = try? hand.recognizedPoints(.all) else { continue }
            for point in points.values where point.confidence > 0.3 {
                confident += 1
                if expanded.contains(point.location) { inside += 1 }
            }
        }
        guard confident > 0 else { return 0 }
        return Double(inside) / Double(confident)
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
