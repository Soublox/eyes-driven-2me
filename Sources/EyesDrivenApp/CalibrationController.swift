import AppKit
import Combine
import CoreGraphics
import EyesDrivenCore
import Foundation
import QuartzCore

/// Runs the per-display 3×3 calibration (SPEC 4).
///
/// A full-screen borderless window is shown on every display. Targets are the
/// 3×3 grid at 10/50/90 % per display, randomized within a display and visited
/// in left-to-right display order. Each target settles for 0.8 s (the dot
/// shrinks), then collects for 1.0 s; every `FaceFeatures` received during
/// collection becomes a `CalibrationSample`. A target with fewer than 8 frames
/// is retried once. Esc cancels. At the end a `GazeModel` is fitted, the mean
/// error shown, and the profile saved through `Storage`.
@MainActor
final class CalibrationController: NSObject, ObservableObject {

    /// Outcome shown in the result panel.
    struct Result: Equatable {
        enum Quality: Equatable {
            case good
            case ok
            case poor
            case failed
        }
        /// Mean Euclidean error in points, nil when fitting failed.
        var errorPoints: Double?
        var quality: Quality
        var sampleCount: Int
    }

    /// Whether a session is running.
    @Published private(set) var isCalibrating = false
    /// The most recent result, if any.
    @Published private(set) var lastResult: Result?

    /// Called when the session ends (finish or cancel), so the owner can restore
    /// the overlay.
    var onEnd: (() -> Void)?

    private enum Phase {
        case settle
        case collect
    }

    private final class CalibrationWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }

    private final class CalibrationView: NSView {
        var dotCenter: CGPoint?
        var dotRadius: CGFloat = 9
        /// Collection progress 0...1, or nil while settling.
        var collectProgress: Double?
        var instruction: String?
        var showsInstruction = false

        override var isOpaque: Bool { false }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.black.withAlphaComponent(0.72).setFill()
            bounds.fill()

            if showsInstruction, let instruction {
                drawInstruction(instruction)
            }
            if let dotCenter {
                drawDot(at: dotCenter)
            }
        }

        private func drawInstruction(_ instruction: String) {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 16, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.85),
            ]
            let string = NSAttributedString(string: instruction, attributes: attributes)
            let size = string.size()
            let origin = CGPoint(
                x: (bounds.width - size.width) / 2,
                y: bounds.height - size.height - 60
            )
            string.draw(at: origin)
        }

        private func drawDot(at center: CGPoint) {
            if let ring = collectProgress {
                let radius = dotRadius + 14
                let track = NSBezierPath()
                track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
                track.lineWidth = 5
                NSColor.white.withAlphaComponent(0.25).setStroke()
                track.stroke()

                let arc = NSBezierPath()
                arc.appendArc(
                    withCenter: center,
                    radius: radius,
                    startAngle: 90,
                    endAngle: 90 - 360 * ring,
                    clockwise: true
                )
                arc.lineWidth = 5
                arc.lineCapStyle = .round
                NSColor.controlAccentColor.setStroke()
                arc.stroke()
            }

            let dot = CGRect(
                x: center.x - dotRadius,
                y: center.y - dotRadius,
                width: dotRadius * 2,
                height: dotRadius * 2
            )
            let path = NSBezierPath(ovalIn: dot)
            NSColor.controlAccentColor.setFill()
            path.fill()
            path.lineWidth = 2
            NSColor.white.withAlphaComponent(0.9).setStroke()
            path.stroke()
        }
    }

    private final class Surface {
        let window: CalibrationWindow
        let view: CalibrationView
        let screenFrame: CGRect
        let displayFrame: CGRect
        let isPrimary: Bool

        init(window: CalibrationWindow, view: CalibrationView, screenFrame: CGRect, displayFrame: CGRect, isPrimary: Bool) {
            self.window = window
            self.view = view
            self.screenFrame = screenFrame
            self.displayFrame = displayFrame
            self.isPrimary = isPrimary
        }
    }

    private weak var pipeline: GazePipeline?

    private var surfaces: [Surface] = []
    private var activeSurface: Surface?
    private var displays: [DisplayInfo] = []
    private var targets: [CGPoint] = []

    private var index = 0
    private var attempts = 0
    private var samples: [CalibrationSample] = []
    private var currentSamples: [CalibrationSample] = []

    private var phase: Phase = .settle
    private var phaseStart: CFTimeInterval = 0
    private var primaryHeight: CGFloat = 0

    private var timer: Timer?
    private var keyMonitor: Any?
    private var resultWindow: NSWindow?

    private let settleDuration: CFTimeInterval = 0.8
    private let collectDuration: CFTimeInterval = 1.0
    private let minFramesPerTarget = 8

    private let instructionText = "Follow the dot with your eyes. Keep your head natural. Esc to cancel."

    init(pipeline: GazePipeline) {
        self.pipeline = pipeline
        super.init()
    }

    // MARK: - Session control

    /// Start a calibration session. Activates the app so Esc is delivered.
    func start() {
        guard !isCalibrating else { return }

        displays = WindowCatalog.displays()
        guard !displays.isEmpty else {
            let result = Result(errorPoints: nil, quality: .failed, sampleCount: 0)
            lastResult = result
            showResultPanel(result: result)
            return
        }

        targets = CalibrationLayout.shuffledTargets(displays: displays)
        samples = []
        currentSamples = []
        index = 0
        attempts = 0
        lastResult = nil

        NSApp.activate(ignoringOtherApps: true)
        buildSurfaces()
        isCalibrating = true
        showSurfaces()
        installKeyMonitor()

        pipeline?.calibrationSink = { [weak self] features in
            self?.receive(features)
        }
        pipeline?.beginCalibration()
        beginTarget()
        startTimer()
    }

    /// Cancel the session without saving anything.
    func cancel() {
        guard isCalibrating else { return }
        lastResult = nil
        teardown()
    }

    // MARK: - Surfaces

    private func buildSurfaces() {
        primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        surfaces = NSScreen.screens.enumerated().map { index, screen in
            // NOTE: no `screen:` argument. With it, AppKit treats `contentRect`
            // as relative to that screen and applies the screen origin twice
            // (verified: a screen at x=-3840 produced a window at x=-7680).
            // Pin the frame explicitly after creation as well.
            let window = CalibrationWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.setFrame(screen.frame, display: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            window.isReleasedWhenClosed = false

            let view = CalibrationView(frame: CGRect(origin: .zero, size: screen.frame.size))
            window.contentView = view
            return Surface(
                window: window,
                view: view,
                screenFrame: screen.frame,
                displayFrame: cgFrame(for: screen),
                isPrimary: index == 0
            )
        }
    }

    private func cgFrame(for screen: NSScreen) -> CGRect {
        if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            return CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
        }
        return CGRect(origin: .zero, size: screen.frame.size)
    }

    private func surface(containing point: CGPoint) -> Surface? {
        if let hit = surfaces.first(where: { $0.displayFrame.contains(point) }) {
            return hit
        }
        return surfaces.min {
            TargetResolver.distance(from: point, to: $0.displayFrame)
                < TargetResolver.distance(from: point, to: $1.displayFrame)
        }
    }

    private func showSurfaces() {
        for surface in surfaces {
            surface.window.orderFrontRegardless()
        }
        surfaces.first?.window.makeKey()
    }

    private func hideSurfaces() {
        for surface in surfaces {
            surface.window.orderOut(nil)
        }
        surfaces = []
    }

    // MARK: - Target loop

    private func beginTarget() {
        guard index < targets.count else { return }
        phase = .settle
        phaseStart = CACurrentMediaTime()

        let target = targets[index]
        activeSurface = surface(containing: target)

        for surface in surfaces {
            surface.view.dotCenter = nil
            surface.view.collectProgress = nil
            surface.view.dotRadius = 9
            surface.view.instruction = instructionText
            surface.view.showsInstruction = surface.isPrimary
            surface.view.needsDisplay = true
        }

        if let activeSurface {
            activeSurface.view.dotCenter = ScreenGeometry.appKitPoint(
                fromCG: target,
                screenFrame: activeSurface.screenFrame,
                primaryHeight: primaryHeight
            )
            activeSurface.view.dotRadius = 26
            activeSurface.view.needsDisplay = true
        }
    }

    private func receive(_ features: FaceFeatures) {
        guard isCalibrating, phase == .collect, index < targets.count else { return }
        currentSamples.append(CalibrationSample(features: features, target: targets[index]))
    }

    private func finishTarget() {
        if currentSamples.count < minFramesPerTarget, attempts < 1 {
            attempts += 1
            beginTarget()
            return
        }
        samples.append(contentsOf: currentSamples)
        currentSamples = []
        index += 1
        attempts = 0

        if index < targets.count {
            beginTarget()
        } else {
            finish()
        }
    }

    // MARK: - Timer

    private func startTimer() {
        stopTimer()
        // The timer fires on the main run loop; assumeIsolated is therefore safe.
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard isCalibrating else { return }
        let elapsed = CACurrentMediaTime() - phaseStart

        switch phase {
        case .settle:
            let t = min(elapsed / settleDuration, 1)
            activeSurface?.view.dotRadius = 26 - 17 * CGFloat(t)
            activeSurface?.view.needsDisplay = true
            if elapsed >= settleDuration {
                phase = .collect
                phaseStart = CACurrentMediaTime()
                currentSamples = []
                activeSurface?.view.collectProgress = 0
                activeSurface?.view.needsDisplay = true
            }
        case .collect:
            activeSurface?.view.collectProgress = min(elapsed / collectDuration, 1)
            activeSurface?.view.needsDisplay = true
            if elapsed >= collectDuration {
                finishTarget()
            }
        }
    }

    // MARK: - Esc

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event } // Esc
            MainActor.assumeIsolated { self?.cancel() }
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
    }

    // MARK: - Finish

    private func finish() {
        teardown()

        guard samples.count >= GazeModel.minimumSampleCount else {
            let result = Result(errorPoints: nil, quality: .failed, sampleCount: samples.count)
            lastResult = result
            showResultPanel(result: result)
            return
        }

        do {
            let model = try GazeModel.fit(samples: samples)
            let error = model.meanError(on: samples)
            let profile = CalibrationProfile(
                model: model,
                samples: samples,
                createdAt: Date(),
                displayFingerprint: CalibrationProfile.fingerprint(for: WindowCatalog.displays())
            )
            Storage.saveCalibration(profile)
            pipeline?.reloadCalibration()

            let quality: Result.Quality = error < 150 ? .good : (error < 350 ? .ok : .poor)
            let result = Result(errorPoints: error, quality: quality, sampleCount: samples.count)
            lastResult = result
            showResultPanel(result: result)
        } catch {
            let result = Result(errorPoints: nil, quality: .failed, sampleCount: samples.count)
            lastResult = result
            showResultPanel(result: result)
        }
    }

    private func teardown() {
        stopTimer()
        removeKeyMonitor()
        pipeline?.calibrationSink = nil
        pipeline?.endCalibration()
        hideSurfaces()
        activeSurface = nil
        currentSamples = []
        isCalibrating = false
        onEnd?()
    }

    // MARK: - Result panel

    private func showResultPanel(result: Result) {
        closeResultPanel()

        let points = result.errorPoints.map { Int($0.rounded()) }
        let message: String
        switch result.quality {
        case .good:
            message = "Mean error: \(points ?? 0) pt — good.\nCalibration saved."
        case .ok:
            message = "Mean error: \(points ?? 0) pt — okay.\nRecalibrating in better light may improve it."
        case .poor:
            message = "Mean error: \(points ?? 0) pt — poor.\nTry better lighting and recalibrate."
        case .failed:
            message = "Calibration could not be completed (\(result.sampleCount) frames).\nCheck the camera and try again."
        }

        let label = NSTextField(wrappingLabelWithString: message)
        label.alignment = .center
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = 320

        let button = NSButton(title: "Done", target: self, action: #selector(closeResultPanel))
        button.keyEquivalent = "\r"

        let stack = NSStackView(views: [label, button])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -20),
        ])

        let panel = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 380, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Calibration"
        panel.isReleasedWhenClosed = false
        panel.contentView = container
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        resultWindow = panel
    }

    @objc private func closeResultPanel() {
        resultWindow?.close()
        resultWindow = nil
    }
}
