import AppKit
import Combine
import CoreGraphics
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
    /// Whether gaze focus is currently paused because the user is using the
    /// mouse or typing (SPEC 3.8/3.9). Updated only when it changes.
    @Published private(set) var manualInputActive = false
    /// Set while focusing is paused because a hand covers the face or tracking
    /// is unstable (SPEC 3.10), for the menu status. Nil when tracking is fine
    /// or the feature is off. Updated only when it changes.
    @Published private(set) var trackingIssue: String?

    // MARK: - Collaborators

    /// Draws the highlight and the debug gaze dot. Owned by `AppModel`.
    weak var overlay: OverlayController?

    /// While set, every frame is forwarded here (with a flag telling whether the
    /// tracking-quality gate considers it reliable) and no gaze/nod processing
    /// happens. Used by `CalibrationController`.
    var calibrationSink: ((FaceFeatures, Bool) -> Void)?

    /// While true, gaze and nods are not fed to the focus engine, so the app
    /// never changes the focused window. Set from the Settings window's
    /// `onAppear`/`onDisappear` so the user can work in Settings without the
    /// app switching focus away from it.
    var suspendFocusing = false {
        didSet {
            guard suspendFocusing != oldValue else { return }
            if suspendFocusing {
                engine.reset()
                nodDetector.reset()
                overlay?.update(target: nil, progress: 0)
            }
        }
    }

    // MARK: - Internal state

    private var settings: AppSettings
    private let capture = CameraCapture()
    private let tracker = FaceTracker()
    private let filter = PointFilter()
    private let nodDetector = NodDetector()
    private var qualityGate = TrackingQualityGate()
    private let engine: FocusEngine

    private var model: GazeModel?
    private var profile: CalibrationProfile?

    private var cameraRunning = false
    private var calibrating = false
    /// Whether the current frame stream is unreliable because of the gate
    /// (hand on the face / tracking glitch), used to reset the nod detector
    /// exactly once on entering the unreliable state (SPEC 3.10).
    private var trackingUnreliable = false
    /// True during the 15 s gaze-dot test: the camera and gaze prediction run
    /// even when tracking is disabled, so the dot can follow the eyes. The
    /// focus engine still respects `settings.isEnabled`, so nothing is focused.
    private var testingGazeDot = false

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

    /// Start running the camera for the 15 s gaze-dot test even when tracking is
    /// disabled (the focus engine stays disabled, so nothing is focused).
    func beginGazeDotTest() {
        testingGazeDot = true
        updateCameraRunning()
    }

    /// Stop the test-only camera run.
    func endGazeDotTest() {
        testingGazeDot = false
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
        qualityGate.reset()
        trackingUnreliable = false
        trackingIssue = nil
    }

    // MARK: - Camera

    private func updateCameraRunning() {
        let shouldRun = settings.isEnabled || calibrating || testingGazeDot
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
        qualityGate.reset()
        trackingUnreliable = false
        trackingIssue = nil
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

        // Tracking-quality gate (SPEC 3.10). Runs on every frame with a face so
        // the hysteresis and the pose-jump continuity stay coherent, both while
        // calibrating and while focusing.
        let quality = qualityGate.process(features)

        if let calibrationSink {
            // The controller rejects unreliable frames and shows the hands hint.
            calibrationSink(features, quality.isReliable)
            return
        }

        guard settings.isEnabled || testingGazeDot, let model else { return }

        let pauseForTracking = settings.pauseWhenFaceCovered && !quality.isReliable
        publishTrackingIssue(quality)

        if pauseForTracking {
            // Hand on the face / unstable tracking: never predict or ingest
            // gaze, hide the dot, clear the highlight and restart the dwell.
            // The nod detector is reset once on entering so the hand movement
            // cannot fire a nod and the baseline re-seeds on recovery.
            if !trackingUnreliable {
                trackingUnreliable = true
                nodDetector.reset()
            }
            overlay?.update(gaze: nil)
            guard !suspendFocusing else { return }
            apply(engine.ingest(unreliableAt: features.timestamp))
            return
        }
        trackingUnreliable = false

        let raw = model.predict(features)
        let filtered = filter.filter(raw, at: features.timestamp)
        overlay?.update(gaze: filtered)
        lastGazeTimestamp = features.timestamp

        // Manual input (mouse/keyboard) pauses gaze focus so a hand on the
        // mouse always wins over gaze (SPEC 3.8). Polled from CoreGraphics; no
        // extra permission. Publish only when the value changes.
        let pauseNow = secondsSinceManualInput < settings.manualInputQuietSeconds
        if pauseNow != manualInputActive {
            manualInputActive = pauseNow
        }

        // Suspended while our own Settings window is key: keep showing the gaze
        // dot but never act on it, so the app cannot steal focus.
        guard !suspendFocusing else { return }

        apply(engine.ingest(
            gaze: filtered,
            at: features.timestamp,
            secondsSinceManualInput: secondsSinceManualInput
        ))

        if let event = nodDetector.process(pitch: features.pitch, timestamp: features.timestamp) {
            apply(engine.ingest(nod: event))
        }
    }

    /// Update the menu status for the tracking-quality gate (SPEC 3.10),
    /// publishing only when the string changes. Nil while tracking is fine or
    /// `pauseWhenFaceCovered` is off.
    private func publishTrackingIssue(_ quality: TrackingQuality) {
        let issue: String?
        if !settings.pauseWhenFaceCovered || quality.isReliable {
            issue = nil
        } else if quality.reasons.contains(.handOnFace) {
            issue = "Paused · face partially covered"
        } else {
            issue = "Paused · tracking unstable"
        }
        if issue != trackingIssue {
            trackingIssue = issue
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

    // MARK: - Manual input

    /// Seconds since the most recent mouse/keyboard event, polled from
    /// CoreGraphics (`CGEventSource`); no additional permission is required.
    ///
    /// The minimum over the enabled event types. Returns `.infinity` when both
    /// pause flags are off, so manual input never pauses focus (SPEC 3.9).
    private var secondsSinceManualInput: TimeInterval {
        var minimum = TimeInterval.infinity
        if settings.pauseOnMouseActivity {
            for type in GazePipeline.mouseEventTypes {
                minimum = min(
                    minimum,
                    CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: type)
                )
            }
        }
        if settings.pauseOnKeyboardActivity {
            for type in GazePipeline.keyboardEventTypes {
                minimum = min(
                    minimum,
                    CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: type)
                )
            }
        }
        return minimum
    }

    private static let mouseEventTypes: [CGEventType] = [
        .mouseMoved,
        .leftMouseDown,
        .rightMouseDown,
        .otherMouseDown,
        .leftMouseDragged,
        .rightMouseDragged,
        .scrollWheel
    ]

    private static let keyboardEventTypes: [CGEventType] = [
        .keyDown,
        .flagsChanged
    ]

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
