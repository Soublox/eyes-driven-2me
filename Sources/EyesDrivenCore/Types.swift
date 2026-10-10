import CoreGraphics
import Foundation

// Shared types for Eyes Driven 2me. See docs/SPEC.md.
// All screen geometry uses CoreGraphics global coordinates
// (origin top-left of the main display, y grows downward, points).

/// Per-frame measurements extracted from the camera by `FaceTracker`.
public struct FaceFeatures: Sendable, Equatable, Codable {
    /// Monotonic timestamp in seconds.
    public var timestamp: TimeInterval
    /// Head rotation in radians (as reported by Vision; signs are learned by calibration).
    public var yaw: Double
    public var pitch: Double
    public var roll: Double
    /// Pupil position normalized within each eye's bounding box (0...1 on both axes).
    public var leftIris: CGPoint
    public var rightIris: CGPoint
    /// Eye aspect ratio (height / width) per eye. Lower = more closed.
    public var leftEyeOpenness: Double
    public var rightEyeOpenness: Double
    /// Face bounding box center in normalized image coordinates (0...1).
    public var faceCenter: CGPoint
    /// Face bounding box width normalized to image width (proxy for distance).
    public var faceSize: Double

    public init(
        timestamp: TimeInterval,
        yaw: Double,
        pitch: Double,
        roll: Double,
        leftIris: CGPoint,
        rightIris: CGPoint,
        leftEyeOpenness: Double,
        rightEyeOpenness: Double,
        faceCenter: CGPoint,
        faceSize: Double
    ) {
        self.timestamp = timestamp
        self.yaw = yaw
        self.pitch = pitch
        self.roll = roll
        self.leftIris = leftIris
        self.rightIris = rightIris
        self.leftEyeOpenness = leftEyeOpenness
        self.rightEyeOpenness = rightEyeOpenness
        self.faceCenter = faceCenter
        self.faceSize = faceSize
    }

    /// Base feature vector for the gaze model:
    /// `[yaw, pitch, irisX, irisY, faceCenterX, faceCenterY, faceSize]`
    /// where irisX/irisY are the average of both eyes.
    public var featureVector: [Double] {
        let irisX = Double(leftIris.x + rightIris.x) / 2
        let irisY = Double(leftIris.y + rightIris.y) / 2
        return [yaw, pitch, irisX, irisY, Double(faceCenter.x), Double(faceCenter.y), faceSize]
    }

    public static let featureCount = 7
}

/// One calibration observation: what the face looked like while staring at `target`.
public struct CalibrationSample: Sendable, Equatable, Codable {
    public var features: FaceFeatures
    /// Target point in global CG coordinates.
    public var target: CGPoint

    public init(features: FaceFeatures, target: CGPoint) {
        self.features = features
        self.target = target
    }
}

/// A display in global CG coordinates.
public struct DisplayInfo: Sendable, Equatable, Hashable, Codable {
    public var id: UInt32
    public var frame: CGRect

    public init(id: UInt32, frame: CGRect) {
        self.id = id
        self.frame = frame
    }
}

/// An on-screen window as reported by CGWindowList.
public struct WindowInfo: Sendable, Equatable, Hashable, Codable {
    public var id: UInt32
    public var pid: Int32
    public var appName: String
    /// May be nil without Screen Recording permission.
    public var title: String?
    /// Global CG coordinates.
    public var frame: CGRect
    public var layer: Int
    public var alpha: Double
    public var isOnScreen: Bool

    public init(
        id: UInt32,
        pid: Int32,
        appName: String,
        title: String?,
        frame: CGRect,
        layer: Int = 0,
        alpha: Double = 1,
        isOnScreen: Bool = true
    ) {
        self.id = id
        self.pid = pid
        self.appName = appName
        self.title = title
        self.frame = frame
        self.layer = layer
        self.alpha = alpha
        self.isOnScreen = isOnScreen
    }
}

/// A completed head nod.
public struct NodEvent: Sendable, Equatable {
    public var startTimestamp: TimeInterval
    public var endTimestamp: TimeInterval

    public init(startTimestamp: TimeInterval, endTimestamp: TimeInterval) {
        self.startTimestamp = startTimestamp
        self.endTimestamp = endTimestamp
    }
}

public enum TriggerMode: String, Sendable, Codable, CaseIterable {
    case dwell
    case nod
    case dwellOrNod
}

public enum FocusReason: String, Sendable, Equatable {
    case dwell
    case nod
}

/// Output of `FocusEngine`.
public enum FocusAction: Sendable, Equatable {
    /// Current target window (nil = none) and dwell progress 0...1.
    case highlight(WindowInfo?, progress: Double)
    /// Give focus to this window.
    case focus(WindowInfo, reason: FocusReason)
}
