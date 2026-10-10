import CoreGraphics
import EyesDrivenCore
import Foundation

/// Diagnostic CLI entry points, kept out of `main.swift` so the SwiftUI app can
/// own process startup. `runIfRequested` returns `false` when no diagnostic flag
/// is present, letting the caller fall through to launching the app.
enum Diagnostics {

    /// Human-readable usage text, printed for `--help` and when no flag matched.
    static let usage = """
    Eyes Driven 2me — platform diagnostic

    Usage:
      EyesDriven2me --windows                      Print displays and on-screen windows.
      EyesDriven2me --camera [--camera-seconds N]  Run the camera + face tracker (default 10 s).
      EyesDriven2me --focus <windowID>             Focus the window with the given id.
      EyesDriven2me --gaze [--camera-seconds N]    Predict gaze with the saved calibration; print point, display and window.
      EyesDriven2me --say <key>                    Speak one guidance line and exit (checks the voice).
      EyesDriven2me --help                         Print this help.
    """

    /// Runs a CLI diagnostic if one was requested; returns false when no
    /// diagnostic flag is present.
    static func runIfRequested(_ arguments: [String]) -> Bool {
        let args = Array(arguments.dropFirst())

        if args.contains("--help") || args.contains("-h") {
            print(usage)
            return true
        }
        if args.contains("--windows") {
            runWindows()
            return true
        }
        if args.contains("--camera") {
            runCamera(seconds: cameraSeconds(in: args))
            return true
        }
        if args.contains("--gaze") {
            runGaze(seconds: cameraSeconds(in: args))
            return true
        }
        if args.contains("--say") {
            runSay(args)
            return true
        }
        if let index = args.firstIndex(of: "--focus") {
            if index + 1 < args.count, let id = UInt32(args[index + 1]) {
                runFocus(id: id)
            } else {
                print("--focus needs a numeric window id.")
            }
            return true
        }
        return false
    }

    // MARK: - Argument parsing

    /// `--camera-seconds N`, defaulting to 10 when absent or malformed.
    private static func cameraSeconds(in arguments: [String]) -> Double {
        guard let index = arguments.firstIndex(of: "--camera-seconds"),
              index + 1 < arguments.count,
              let seconds = Double(arguments[index + 1]), seconds > 0
        else { return 10 }
        return seconds
    }

    /// The integer value of `flag`, or nil when it is absent or malformed.
    private static func intValue(_ flag: String, in arguments: [String]) -> Int? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return Int(arguments[index + 1])
    }

    // MARK: - --say

    /// Speaks one calibration line and exits, so the voice and the localization
    /// can be checked without running a full session. `--displays N` (default 3)
    /// and `--display-index N` (default 1) shape the start / next-screen lines.
    private static func runSay(_ arguments: [String]) {
        guard let index = arguments.firstIndex(of: "--say"), index + 1 < arguments.count else {
            print("--say needs a key. See --help.")
            return
        }
        let key = arguments[index + 1]
        let displays = intValue("--displays", in: arguments) ?? 3
        let displayIndex = intValue("--display-index", in: arguments) ?? 1

        guard let line = sayLine(key: key, displays: displays, displayIndex: displayIndex) else {
            print("Unknown --say key '\(key)'. See --help for the accepted keys.")
            return
        }

        let guide = VoiceGuide()
        print("Speaking [\(VoiceGuide.preferredLanguage())]: \(line.text)")
        var finished = false
        guide.speak(line) { finished = true }
        let deadline = Date().addingTimeInterval(15)
        while !finished, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        print(finished ? "Done." : "Timed out.")
    }

    /// Map a `--say` key to a localized line, mirroring the calibration flow.
    private static func sayLine(key: String, displays: Int, displayIndex: Int) -> VoiceLine? {
        switch key {
        case "start": return VoiceScript.start(displayCount: displays)
        case "start.single": return VoiceScript.start(displayCount: 1)
        case "nextScreen": return VoiceScript.nextScreen(displayIndex: displayIndex, count: displays)
        case "almostDone": return VoiceScript.almostDone
        case "finished.good": return VoiceScript.finished(errorPoints: 0)
        case "finished.ok": return VoiceScript.finished(errorPoints: 200)
        case "finished.poor": return VoiceScript.finished(errorPoints: 500)
        case "hands": return VoiceScript.hands
        case "paused": return VoiceScript.paused
        case "resumed": return VoiceScript.resumed
        case "cancelled": return VoiceScript.cancelled
        default: return nil
        }
    }

    // MARK: - --windows

    private static func runWindows() {
        let displays = WindowCatalog.displays()
        print("Displays (\(displays.count)):")
        for display in displays {
            let frame = display.frame
            print(String(format: "  id=%-10u  origin=(%.0f, %.0f)  size=%.0fx%.0f",
                         display.id, frame.origin.x, frame.origin.y, frame.width, frame.height))
        }

        let windows = WindowCatalog.windows()
        print("Windows (\(windows.count), front-to-back):")
        for window in windows.prefix(50) {
            let frame = window.frame
            let title = window.title.map { "\u{201C}\($0)\u{201D}" } ?? "<no title>"
            let metrics = String(format: "[%.0f, %.0f %.0fx%.0f]",
                                 frame.origin.x, frame.origin.y, frame.width, frame.height)
            print("  id=\(window.id)  layer=\(window.layer)  pid=\(window.pid)  \(metrics)  \(window.appName) — \(title)")
        }
    }

    // MARK: - --gaze

    /// Runs camera → tracker → saved GazeModel → PointFilter and prints, every
    /// ~0.5 s, the filtered gaze point, the display it falls on and the window
    /// `TargetResolver` would pick. Headless check of the full prediction path.
    private static func runGaze(seconds: Double) {
        guard let profile = Storage.loadCalibration() else {
            print("No calibration saved. Calibrate from the menu first.")
            return
        }
        let model = profile.model
        print(String(format: "Model: degree %d, lambda %.2f, CV error %.0f pt, stale: %@",
                     model.degree, model.lambda, model.crossValidationError,
                     Storage.isStale(profile) ? "yes" : "no"))
        let displays = WindowCatalog.displays()
        let capture = CameraCapture()
        let tracker = FaceTracker()
        let lock = NSLock()
        var latest: FaceFeatures?
        capture.onFrame = { buffer in
            let features = tracker.process(buffer)
            lock.lock(); latest = features ?? latest; lock.unlock()
        }
        do { try capture.start(cameraUniqueID: nil) } catch {
            print("Could not start the camera: \(error.localizedDescription)"); return
        }
        let filter = PointFilter()
        let timer = Timer(timeInterval: 0.5, repeats: true) { _ in
            lock.lock(); let f = latest; lock.unlock()
            guard let f else { print("  no face"); return }
            let point = filter.filter(model.predict(f), at: f.timestamp)
            let display = displays.firstIndex { $0.frame.contains(point) }
                .map { "display \(displays[$0].id)" } ?? "off-screen"
            let windows = WindowCatalog.windows()
            let target = TargetResolver.resolve(point: point, windows: windows, displays: displays,
                                                excludedPIDs: [getpid()])
            print(String(format: "  gaze (%6.0f, %5.0f)  yaw %+.2f pitch %+.2f  %@  → %@",
                         point.x, point.y, f.yaw, f.pitch, display, target?.appName ?? "-"))
        }
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        timer.invalidate()
        capture.stop()
    }

    // MARK: - --camera

    /// Runs the camera + face tracker for `seconds` and prints one aggregate line
    /// per second: mean and standard deviation of yaw, pitch and the per-eye
    /// averaged iris position, plus frames per second and the fraction of frames
    /// that contained a face. It also reports the tracking-quality signals (mean
    /// landmarksConfidence, mean captureQuality, max handOverlap) and how often
    /// the `TrackingQualityGate` marked frames unreliable, with the reasons seen.
    /// This lets the reader tune the gate thresholds with real data.
    private static func runCamera(seconds: Double) {
        let capture = CameraCapture()
        let tracker = FaceTracker()
        let stats = CameraStats()

        capture.onFrame = { buffer in
            stats.add(tracker.process(buffer))
        }

        switch Permissions.cameraStatus {
        case .authorized:
            break
        case .notDetermined:
            print("Requesting camera access…")
            Task { _ = await Permissions.requestCamera() }
        default:
            print("Camera access is \(Permissions.cameraStatusDescription()). Enable it in System Settings ▸ Privacy & Security ▸ Camera.")
        }

        do {
            try capture.start(cameraUniqueID: nil)
            print(String(format: "Camera started. Reporting per-second aggregates for %.0f s…", seconds))
        } catch {
            print("Could not start the camera: \(error.localizedDescription)")
        }

        var reportedSeconds = 0
        let flush = Timer(timeInterval: 1.0, repeats: true) { _ in
            reportedSeconds += 1
            if let line = stats.flush(second: reportedSeconds) {
                print(line)
            }
        }
        RunLoop.main.add(flush, forMode: .common)

        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        flush.invalidate()

        // Report any frames captured after the last full second.
        if let tail = stats.flush(second: reportedSeconds + 1) {
            print(tail)
        }

        capture.stop()
        print("Camera run finished.")
    }

    // MARK: - --focus

    private static func runFocus(id: UInt32) {
        let windows = WindowCatalog.windows()
        guard let window = windows.first(where: { $0.id == id }) else {
            print("No on-screen window with id \(id).")
            return
        }
        if !WindowFocuser.isTrusted() {
            print("Accessibility permission is not granted; focusing may fail. Enable it in System Settings ▸ Privacy & Security ▸ Accessibility.")
        }
        let focused = WindowFocuser.focus(window, moveCursor: false)
        print(focused
              ? "Focused window #\(id) (\(window.appName))."
              : "Could not focus window #\(id) (\(window.appName)).")
    }
}

// MARK: - Camera statistics

/// Accumulates frames between one-second report windows, then computes the mean
/// and standard deviation of the pose and iris signals for that window, plus the
/// tracking-quality signals and how often the gate marked frames unreliable.
private final class CameraStats {

    private let lock = NSLock()
    private var frames = 0
    private var faces = 0
    private var yaw: [Double] = []
    private var pitch: [Double] = []
    private var irisX: [Double] = []
    private var irisY: [Double] = []
    private var landmarks: [Double] = []
    private var capture: [Double] = []
    private var hand: [Double] = []

    /// One gate instance for the whole run, so its hysteresis is contiguous.
    private var gate = TrackingQualityGate()
    private var unreliableFrames = 0
    private var reasonsSeen: Set<TrackingQuality.Reason> = []

    /// Counts one frame (with or without a face) and records its features.
    func add(_ features: FaceFeatures?) {
        lock.lock()
        defer { lock.unlock() }

        frames += 1
        guard let features else { return }
        faces += 1
        yaw.append(features.yaw)
        pitch.append(features.pitch)
        irisX.append(Double((features.leftIris.x + features.rightIris.x) / 2))
        irisY.append(Double((features.leftIris.y + features.rightIris.y) / 2))

        landmarks.append(features.landmarksConfidence)
        if let quality = features.captureQuality { capture.append(quality) }
        hand.append(features.handOverlap)

        let verdict = gate.process(features)
        if !verdict.isReliable {
            unreliableFrames += 1
            reasonsSeen.formUnion(verdict.reasons)
        }
    }

    /// Returns a one-line report for the just-finished window and resets it, or
    /// `nil` when no frames arrived during the window.
    func flush(second: Int) -> String? {
        lock.lock()
        defer { lock.unlock() }

        guard frames > 0 else { return nil }

        let facePercent = Double(faces) / Double(frames) * 100
        let yawStat = Stats(yaw)
        let pitchStat = Stats(pitch)
        let irisXStat = Stats(irisX)
        let irisYStat = Stats(irisY)
        let landmarksStat = Stats(landmarks)
        let captureStat = Stats(capture)
        let handMax = hand.max() ?? 0
        let unreliablePercent = faces > 0 ? Double(unreliableFrames) / Double(faces) * 100 : 0
        let captureText = capture.isEmpty ? "n/a" : String(format: "%.2f", captureStat.mean)
        let reasonsText = reasonsSeen.isEmpty
            ? "-"
            : reasonsSeen.map(\.rawValue).sorted().joined(separator: ",")

        let line = String(
            format: "t=%2ds  fps=%3d  face=%3.0f%%  yaw mean=%+.3f std=%.3f  pitch mean=%+.3f std=%.3f  irisX mean=%.3f std=%.3f  irisY mean=%.3f std=%.3f  landmarks mean=%.2f  capture mean=%@  hand max=%.2f  unreliable=%3.0f%%  reasons=[%@]",
            second, frames, facePercent,
            yawStat.mean, yawStat.std,
            pitchStat.mean, pitchStat.std,
            irisXStat.mean, irisXStat.std,
            irisYStat.mean, irisYStat.std,
            landmarksStat.mean, captureText, handMax, unreliablePercent, reasonsText
        )

        frames = 0
        faces = 0
        yaw.removeAll(keepingCapacity: true)
        pitch.removeAll(keepingCapacity: true)
        irisX.removeAll(keepingCapacity: true)
        irisY.removeAll(keepingCapacity: true)
        landmarks.removeAll(keepingCapacity: true)
        capture.removeAll(keepingCapacity: true)
        hand.removeAll(keepingCapacity: true)
        unreliableFrames = 0
        reasonsSeen.removeAll()

        return line
    }
}

/// Mean and population standard deviation of a sample window.
private struct Stats {
    let mean: Double
    let std: Double

    init(_ values: [Double]) {
        guard !values.isEmpty else {
            mean = 0
            std = 0
            return
        }
        let average = values.reduce(0, +) / Double(values.count)
        mean = average
        let variance = values.reduce(0) { $0 + ($1 - average) * ($1 - average) } / Double(values.count)
        std = variance.squareRoot()
    }
}
