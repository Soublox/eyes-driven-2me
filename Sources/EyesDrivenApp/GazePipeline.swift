import AppKit
import Combine
import CoreMedia
import EyesDrivenCore
import Foundation

/// Glue between the camera, the gaze model, the focus engine and the UI
/// (SPEC 4). Owns the camera, the Vision face tracker, the point filter, the
/// nod detector and the focus engine (excluding this process's own windows).
///
/// ## Threading
/// Camera frames are delivered on the camera's private serial queue. `FaceTracker`
/// (Vision) runs there and produces a `FaceFeatures` value; only that value is
/// hopped to the main actor. All prediction, filtering, focus decisions,
/// window snapshotting and UI/AppKit work happen on the main actor. Timestamps
/// always come from the camera clock (`FaceFeatures.timestamp`), never `Date()`.
@MainActor
final class GazePipeline: ObservableObject {

    /// What the UI should report about calibration.
    enum CalibrationState: Equatable {
        /// No calibration has been saved yet.
        case missing
        /// A calibration exists but the display layout changed.
        case stale
        /// A usable model exists; `errorPoints` is its mean training error.
        case ok(errorPoints: Double)
    }

    /// Missing system permissions, as a set.
    struct PermissionProblem: OptionSet, Equatable {
        let rawValue: Int
        /// Camera access is denied or restricted.
        static let camera = PermissionProblem(rawValue: 1 << 0)
        /// The Accessibility API is not trusted.
        static let accessibility = PermissionProblem(rawValue: 1 << 1)
    }

    // MARK: - Published status

    /// Whether the camera is currently capturing.
    @Published private(set) var isRunning = false
    /// Frames processed in the last second.
    @Published private(set) var fps: Double = 0
    /// Whether a face was seen in the most recent frame.
    @Published private(set) var faceDetected = false
    /// Application name of the current target window, if any.
    @Published private(set) var currentTargetName: String?
    /// Reason of the most recent focus action.
    @Published private(set) var lastFocusReason: FocusReason?
    /// Calibration status for the UI.
    @Published private(set) var calibrationState: CalibrationState = .missing
    /// Missing system permissions.
    @Published private(set) var permissionProblem: PermissionProblem = []

    // MARK: - Collaborators

    /// Draws the highlight and the debug gaze dot. Owned by `AppModel`.
    weak var overlay: OverlayController?

    /// While set, every frame is forwarded here and no gaze/nod processing
    /// happens. Used by `CalibrationController`.
    var calibrationSink: ((FaceFeatures) -> Void)?

    // MARK: - Internal state

    private var settings: AppSettings
    private let capture = CameraCapture()
    private let tracker = FaceTracker()
    private let filter = PointFilter()
    private let nodDetector = NodDetector()
    private let engine: FocusEngine

    private var model: GazeModel?
    private var profile: CalibrationProfile?

    private var cameraRunning = false
    private var calibrating = false

    private var frameCount = 0
    private var lastGazeTimestamp: TimeInterval = 0

    private var windowTimer: Timer?
    private var fpsTimer: Timer?
    private var screenObserver: NSObjectProtocol?

    /// Create the pipeline for the given settings. By default this process's own
    /// windows are excluded from targeting (its menu bar and overlays).
    init(settings: AppSettings, excludedPIDs: Set<Int32>? = nil) {
        self.settings = settings
        let excluded = excludedPIDs ?? [ProcessInfo.processInfo.processIdentifier]
        self.engine = FocusEngine(settings: settings, excludedPIDs: excluded)
        self.nodDetector.config = NodDetectorConfig.config(forSensitivity: settings.nodSensitivity)

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleScreenChange() }
        }

        refreshWindows()
        refreshPermissions()
    }

    // MARK: - Lifecycle & settings

    /// Apply new settings, restarting the camera if its device changed.
    func applySettings(_ newSettings: AppSettings) {
        let cameraChanged = newSettings.cameraUniqueID != settings.cameraUniqueID
        settings = newSettings
        engine.updateSettings(newSettings)
        nodDetector.config = NodDetectorConfig.config(forSensitivity: newSettings.nodSensitivity)
        if cameraChanged, cameraRunning {
            stopCamera()
        }
        updateCameraRunning()
    }

    /// Load the calibration profile from disk and (re)apply it.
    func reloadCalibration() {
        profile = Storage.loadCalibration()
        applyProfile()
    }

    /// Refresh the permission status shown by the UI.
    func refreshPermissions() {
        var problems: PermissionProblem = []
        switch Permissions.cameraStatus {
        case .denied, .restricted:
            problems.insert(.camera)
        default:
            break
        }
        if !WindowFocuser.isTrusted() {
            problems.insert(.accessibility)
        }
        if problems != permissionProblem {
            permissionProblem = problems
        }
    }

    /// Stop the camera and timers. Called when the owner tears the pipeline down.
    func shutdown() {
        calibrating = false
        stopCamera()
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        screenObserver = nil
    }

    // MARK: - Calibration hooks

    /// Start capturing for calibration even when tracking is disabled, and clear
    /// the overlay.
    func beginCalibration() {
        calibrating = true
        overlay?.update(target: nil, progress: 0)
        overlay?.update(gaze: nil)
        updateCameraRunning()
    }

    /// End the calibration capture session.
    func endCalibration() {
        calibrating = false
        updateCameraRunning()
    }

    // MARK: - Frame handling

    private func handleScreenChange() {
        refreshWindows()
        reloadCalibration()
    }

    private func applyProfile() {
        guard let profile else {
            if model != nil {
                model = nil
                resetSmoothing()
            }
            calibrationState = .missing
            return
        }
        if Storage.isStale(profile) {
            if model != nil {
                model = nil
                resetSmoothing()
            }
            calibrationState = .stale
            return
        }
        if model != profile.model {
            resetSmoothing()
        }
        model = profile.model
        nodDetector.downSign = profile.model.pitchDownSign
        calibrationState = .ok(errorPoints: profile.model.meanError(on: profile.samples))
    }

    private func resetSmoothing() {
        filter.reset()
        nodDetector.reset()
    }

    // MARK: - Camera

    private func updateCameraRunning() {
        let shouldRun = settings.isEnabled || calibrating
        if shouldRun, !cameraRunning {
            startCamera()
        } else if !shouldRun, cameraRunning {
            stopCamera()
        }
    }

    private func startCamera() {
        switch Permissions.cameraStatus {
        case .denied, .restricted:
            permissionProblem.insert(.camera)
            return
        default:
            break
        }

        let tracker = self.tracker
        capture.onFrame = { [weak self] buffer in
            // Camera queue: Vision runs here, off the main actor.
            let features = tracker.process(buffer)
            Task { @MainActor in
                self?.handle(features)
            }
        }

        do {
            try capture.start(cameraUniqueID: settings.cameraUniqueID)
            cameraRunning = true
            isRunning = true
            startTimers()
            refreshPermissions()
        } catch {
            permissionProblem.insert(.camera)
            cameraRunning = false
            isRunning = false
        }
    }

    private func stopCamera() {
        capture.stop()
        cameraRunning = false
        isRunning = false
        fps = 0
        frameCount = 0
        faceDetected = false
        stopTimers()
        currentTargetName = nil
        overlay?.update(target: nil, progress: 0)
        overlay?.update(gaze: nil)
    }

    private func handle(_ features: FaceFeatures?) {
        frameCount += 1

        guard let features else {
            faceDetected = false
            if calibrationSink == nil {
                overlay?.update(gaze: nil)
            }
            return
        }
        faceDetected = true

        if let calibrationSink {
            calibrationSink(features)
            return
        }

        guard settings.isEnabled, let model else { return }

        let raw = model.predict(features)
        let filtered = filter.filter(raw, at: features.timestamp)
        overlay?.update(gaze: filtered)
        lastGazeTimestamp = features.timestamp

        apply(engine.ingest(gaze: filtered, at: features.timestamp))

        if let event = nodDetector.process(pitch: features.pitch, timestamp: features.timestamp) {
            apply(engine.ingest(nod: event))
        }
    }

    private func apply(_ actions: [FocusAction]) {
        for action in actions {
            switch action {
            case .highlight(let window, let progress):
                overlay?.update(target: window, progress: progress)
                currentTargetName = window?.appName
            case .focus(let window, let reason):
                _ = WindowFocuser.focus(window, moveCursor: settings.moveCursorToFocusedWindow)
                engine.notifyFocused(windowID: window.id, at: lastGazeTimestamp)
                lastFocusReason = reason
                currentTargetName = window.appName
            }
        }
    }

    // MARK: - Window snapshot

    private func refreshWindows() {
        let windows = WindowCatalog.windows()
        let displays = WindowCatalog.displays()
        engine.updateWindows(
            windows,
            displays: displays,
            frontmostWindowID: WindowCatalog.frontmostWindowID(in: windows)
        )
    }

    // MARK: - Timers

    private func startTimers() {
        if windowTimer == nil {
            refreshWindows()
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshWindows() }
            }
            RunLoop.main.add(timer, forMode: .common)
            windowTimer = timer
        }
        if fpsTimer == nil {
            let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tickSecond() }
            }
            RunLoop.main.add(timer, forMode: .common)
            fpsTimer = timer
        }
    }

    private func stopTimers() {
        windowTimer?.invalidate()
        windowTimer = nil
        fpsTimer?.invalidate()
        fpsTimer = nil
    }

    private func tickSecond() {
        fps = Double(frameCount)
        frameCount = 0
        refreshPermissions()
    }
}
