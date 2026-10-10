import AppKit
import Combine
import CoreGraphics
import EyesDrivenCore
import Foundation
import QuartzCore

/// Runs the per-display 3×3 calibration (SPEC 4, round 3).
///
/// A full-screen borderless window is shown on every display with a dark
/// translucent backdrop. The primary display first presents an intro screen with
/// a mini map of the display layout; Space starts the session, Esc cancels.
///
/// Targets are the 3×3 grid at 10/50/90 % per display, shuffled within a display
/// and visited left-to-right. Before a display's first target the other displays
/// dim further, the active display gets an accent border, and a 3·2·1 countdown
/// with system ticks plays in its center (a distinct sound marks the start).
/// Each target then settles for 0.8 s (the dot shrinks) and collects for 1.0 s
/// (a progress ring fills); the first 0.15 s of each collect window are skipped.
///
/// Keys: Space pauses/resumes, R redoes the current target, Esc cancels. At the
/// end the samples are cleaned (per-target outliers removed), a `GazeModel` is
/// fitted, a per-display quality report is computed and the profile is saved
/// through `Storage`.
///
/// Spoken guidance (`VoiceGuide`, on-device `AVSpeechSynthesizer`) follows the
/// app language: the opening line after Space names screen 1 and its position,
/// each further screen is announced before its countdown (which waits for the
/// line to finish), "almost done" is played once when two targets remain, a
/// hands-off prompt at most once per 5 s, pause/resume and cancel lines, and a
/// closing line with the quality. The lines are chosen by the pure
/// `CalibrationScript` in Core. Toggled by `AppSettings.calibrationVoice`; when
/// off, the flow is exactly as before.
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
        /// Samples used for the fit (after cleaning).
        var sampleCount: Int
        /// Leave-one-target-out cross-validation error (points).
        var crossValidationError: Double
        /// Per-display quality, left-to-right.
        var displays: [DisplayQuality]
        /// 1-based indices of displays that could not be told apart.
        var indistinguishableDisplays: [Int]
    }

    /// Whether a session is running.
    @Published private(set) var isCalibrating = false
    /// Whether the running session is paused.
    @Published private(set) var isPaused = false
    /// The most recent result, if any.
    @Published private(set) var lastResult: Result?

    /// Called when the session ends (finish or cancel), so the owner can restore
    /// the overlay.
    var onEnd: (() -> Void)?
    /// Called by the result panel's "Recalibrate" button.
    var onRecalibrate: (() -> Void)?
    /// Called by the result panel's "Test" button.
    var onTest: (() -> Void)?
    /// Whether calibration sounds are enabled (from `AppSettings`).
    var soundsEnabled = true
    /// Whether spoken guidance is enabled (from `AppSettings`). When off the
    /// flow runs exactly as before, with no speech.
    var voiceEnabled = true

    private enum Phase {
        case intro
        case countdown
        case settle
        case collect
    }

    /// One calibration target and the display (left-to-right index) it belongs to.
    private struct Target {
        let point: CGPoint
        let displayIndex: Int
    }

    private final class CalibrationWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }

    private final class CalibrationView: NSView {
        var backdropAlpha: CGFloat = 0.72
        var showsBorder = false
        var dotCenter: CGPoint?
        var dotRadius: CGFloat = 9
        /// Collection progress 0...1, or nil while settling.
        var collectProgress: Double?
        /// Big countdown numeral (3, 2, 1), or nil.
        var countdownNumber: Int?
        /// Progress 0...1 within the current countdown second (scale/fade).
        var countdownProgress: CGFloat = 0
        /// "Screen 2 of 3 · Point 4 of 9".
        var progressLabel: String?
        /// Shown while the tracking-quality gate rejects calibration frames.
        var showTrackingHint = false
        var paused = false
        /// Intro screen content is drawn only on the primary display.
        var introVisible = false
        /// Mini-map rects in a top-left origin (y down) local space.
        var miniMapRects: [CGRect] = []
        var miniMapSize: CGSize = .zero
        /// Index (into `miniMapRects`) of the active display during the session.
        var miniMapActiveIndex: Int?

        override var isOpaque: Bool { false }

        /// Reset every visual to its resting state.
        func reset() {
            backdropAlpha = 0.72
            showsBorder = false
            dotCenter = nil
            dotRadius = 9
            collectProgress = nil
            countdownNumber = nil
            countdownProgress = 0
            progressLabel = nil
            showTrackingHint = false
            paused = false
            introVisible = false
            miniMapRects = []
            miniMapSize = .zero
            miniMapActiveIndex = nil
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.black.withAlphaComponent(backdropAlpha).setFill()
            bounds.fill()

            if showsBorder {
                drawActiveBorder()
            }
            if introVisible {
                drawIntro()
            } else if let progressLabel {
                drawProgressLabel(progressLabel)
            }
            if let countdownNumber {
                drawCountdown(countdownNumber)
            }
            if let dotCenter {
                drawDot(at: dotCenter)
            }
            if paused {
                drawPaused()
            }
        }

        // MARK: Intro

        private func drawIntro() {
            let titleAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 34, weight: .semibold),
                .foregroundColor: NSColor.white.withAlphaComponent(0.98),
            ]
            let lineAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 16, weight: .regular),
                .foregroundColor: NSColor.white.withAlphaComponent(0.88),
            ]
            let footerAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 14, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.75),
            ]

            let title = NSAttributedString(string: "Calibration", attributes: titleAttributes)
            let lines = [
                "You will look at a dot on each of your screens.",
                "Keep your head natural and follow the dot with your eyes.",
                "It takes about one minute.",
            ].map { NSAttributedString(string: $0, attributes: lineAttributes) }
            let footer = NSAttributedString(
                string: "Press Space to start · Esc to cancel",
                attributes: footerAttributes
            )

            let spacing: CGFloat = 10
            var blockHeight = title.size().height + spacing
            for line in lines { blockHeight += line.size().height + spacing }
            blockHeight += miniMapSize.height + spacing
            blockHeight += footer.size().height

            var top = bounds.midY + blockHeight / 2
            drawCentered(title, top: top)
            top -= title.size().height + spacing
            for line in lines {
                drawCentered(line, top: top)
                top -= line.size().height + spacing
            }
            if miniMapSize.height > 0 {
                let origin = CGPoint(x: bounds.midX - miniMapSize.width / 2, y: top - miniMapSize.height)
                drawMiniMap(origin: origin)
                top -= miniMapSize.height + spacing
            }
            drawCentered(footer, top: top)
        }

        /// Draw a string centered horizontally with its top edge at `top`.
        private func drawCentered(_ string: NSAttributedString, top: CGFloat) {
            let size = string.size()
            string.draw(at: CGPoint(x: (bounds.width - size.width) / 2, y: top - size.height))
        }

        /// `origin` is the bottom-left of the map area in view coordinates.
        private func drawMiniMap(origin: CGPoint) {
            for (index, rect) in miniMapRects.enumerated() {
                let flipped = CGRect(
                    x: origin.x + rect.minX,
                    y: origin.y + miniMapSize.height - rect.maxY,
                    width: rect.width,
                    height: rect.height
                )
                let path = NSBezierPath(roundedRect: flipped, xRadius: 6, yRadius: 6)
                let active = index == miniMapActiveIndex
                NSColor.white.withAlphaComponent(active ? 0.22 : 0.10).setFill()
                path.fill()
                path.lineWidth = active ? 2.5 : 1.5
                if active {
                    NSColor.controlAccentColor.setStroke()
                } else {
                    NSColor.white.withAlphaComponent(0.45).setStroke()
                }
                path.stroke()
            }
        }

        // MARK: Session chrome

        private func drawActiveBorder() {
            let path = NSBezierPath(rect: bounds.insetBy(dx: 6, dy: 6))
            path.lineWidth = 8
            NSColor.controlAccentColor.withAlphaComponent(0.55).setStroke()
            path.stroke()
        }

        private func drawProgressLabel(_ label: String) {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 16, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.9),
            ]
            let string = NSAttributedString(string: label, attributes: attributes)
            let size = string.size()
            string.draw(at: CGPoint(
                x: (bounds.width - size.width) / 2,
                y: bounds.height - size.height - 56
            ))

            let hintAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor.white.withAlphaComponent(0.5),
            ]
            let hint = NSAttributedString(
                string: "Space pause · R redo · Esc cancel",
                attributes: hintAttributes
            )
            let hintSize = hint.size()
            hint.draw(at: CGPoint(x: (bounds.width - hintSize.width) / 2, y: 40))

            if showTrackingHint {
                drawTrackingHint()
            }
        }

        /// Small prompt shown while the gate rejects frames (hand on the face).
        private func drawTrackingHint() {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 15, weight: .medium),
                .foregroundColor: NSColor.systemYellow.withAlphaComponent(0.95),
            ]
            let string = NSAttributedString(
                string: "Keep your hands away from your face",
                attributes: attributes
            )
            let size = string.size()
            string.draw(at: CGPoint(x: (bounds.width - size.width) / 2, y: 70))
        }

        private func drawCountdown(_ number: Int) {
            let progress = countdownProgress
            let alpha: CGFloat
            if progress < 0.15 {
                alpha = progress / 0.15
            } else if progress > 0.85 {
                alpha = (1 - progress) / 0.15
            } else {
                alpha = 1
            }
            let scale = 1.0 + 0.18 * (1 - min(progress / 0.25, 1))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 140 * scale, weight: .bold),
                .foregroundColor: NSColor.white.withAlphaComponent(0.35 + 0.65 * alpha),
            ]
            let string = NSAttributedString(string: "\(number)", attributes: attributes)
            let size = string.size()
            string.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
        }

        private func drawPaused() {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 22, weight: .semibold),
                .foregroundColor: NSColor.white.withAlphaComponent(0.95),
            ]
            let string = NSAttributedString(string: "Paused — press Space to resume", attributes: attributes)
            let size = string.size()
            let padding = CGSize(width: 24, height: 16)
            let box = CGRect(
                x: bounds.midX - size.width / 2 - padding.width,
                y: bounds.midY - size.height / 2 - padding.height,
                width: size.width + padding.width * 2,
                height: size.height + padding.height * 2
            )
            let pill = NSBezierPath(roundedRect: box, xRadius: 16, yRadius: 16)
            NSColor.black.withAlphaComponent(0.5).setFill()
            pill.fill()
            string.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
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
    private var sortedDisplays: [DisplayInfo] = []
    private var targets: [Target] = []

    private var index = 0
    private var attempts = 0
    private var samples: [CalibrationSample] = []
    private var currentSamples: [CalibrationSample] = []

    private var phase: Phase = .intro
    private var phaseStart: CFTimeInterval = 0
    private var collectStart: CFTimeInterval = 0
    private var paused = false
    private var pauseBegan: CFTimeInterval = 0
    private var lastCountdownNumber = 0
    private var lastDisplayIndex = -1
    private var primaryHeight: CGFloat = 0

    private var timer: Timer?
    private var keyMonitor: Any?
    private var resultWindow: NSWindow?

    /// On-device speech for the guided flow (nil-effect when `voiceEnabled` is off).
    private let voice = VoiceGuide()
    /// True between pressing Space on the intro and the opening line finishing.
    private var sessionStarting = false
    /// False while a countdown is waiting for its spoken line to finish.
    private var countdownActive = false
    /// The "almost done" line is announced at most once per session.
    private var almostDoneAnnounced = false
    /// Timestamp of the last hands-off warning, to rate-limit it to once per 5 s.
    private var lastHandsWarning: CFTimeInterval = 0

    private let settleDuration: CFTimeInterval = 0.8
    private let collectDuration: CFTimeInterval = 1.0
    private let countdownDuration: CFTimeInterval = 3.0
    private let collectSkip: CFTimeInterval = 0.15
    private let minFramesPerTarget = 8

    init(pipeline: GazePipeline) {
        self.pipeline = pipeline
        super.init()
    }

    // MARK: - Session control

    /// Start a calibration session. Activates the app so the keys are delivered.
    func start() {
        guard !isCalibrating else { return }

        displays = WindowCatalog.displays()
        guard !displays.isEmpty else {
            showResult(Result(
                errorPoints: nil,
                quality: .failed,
                sampleCount: 0,
                crossValidationError: 0,
                displays: [],
                indistinguishableDisplays: []
            ))
            return
        }

        sortedDisplays = displays.sorted { $0.frame.minX < $1.frame.minX }
        targets = makeTargets()
        samples = []
        currentSamples = []
        index = 0
        attempts = 0
        paused = false
        isPaused = false
        lastDisplayIndex = -1
        lastResult = nil
        almostDoneAnnounced = false
        sessionStarting = false
        countdownActive = false
        lastHandsWarning = 0
        voice.stop()

        NSApp.activate(ignoringOtherApps: true)
        buildSurfaces()
        isCalibrating = true
        showIntro()
        installKeyMonitor()

        pipeline?.calibrationSink = { [weak self] features, reliable in
            self?.receive(features, reliable: reliable)
        }
        pipeline?.beginCalibration()
        startTimer()
    }

    /// Cancel the session without saving anything.
    func cancel() {
        guard isCalibrating else { return }
        lastResult = nil
        teardown()
        closeResultPanel()
        speak(VoiceScript.cancelled)
    }

    // MARK: - Targets

    private func makeTargets() -> [Target] {
        var result: [Target] = []
        for (displayIndex, display) in sortedDisplays.enumerated() {
            for point in CalibrationLayout.points(in: display.frame).shuffled() {
                result.append(Target(point: point, displayIndex: displayIndex))
            }
        }
        return result
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

    private func surface(forDisplayIndex index: Int) -> Surface? {
        guard index >= 0, index < sortedDisplays.count else { return nil }
        let frame = sortedDisplays[index].frame
        return surfaces.first { $0.displayFrame == frame }
            ?? surface(containing: CGPoint(x: frame.midX, y: frame.midY))
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
    }

    private func hideSurfaces() {
        for surface in surfaces {
            surface.window.orderOut(nil)
        }
        surfaces = []
    }

    /// Make the given window key so the key monitor receives Space/R/Esc.
    private func bringToKey(_ surface: Surface?) {
        guard let surface else { return }
        NSApp.activate(ignoringOtherApps: true)
        surface.window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Intro

    private func showIntro() {
        phase = .intro
        phaseStart = CACurrentMediaTime()
        activeSurface = nil
        paused = false
        isPaused = false
        sessionStarting = false
        countdownActive = false

        let mapSize = CGSize(width: 320, height: 160)
        let mapRects = CalibrationLayout.miniMap(displays: sortedDisplays, size: mapSize, padding: 4)
        for surface in surfaces {
            surface.view.reset()
            surface.view.backdropAlpha = 0.72
            surface.view.introVisible = surface.isPrimary
            surface.view.miniMapRects = surface.isPrimary ? mapRects : []
            surface.view.miniMapSize = surface.isPrimary ? mapSize : .zero
            surface.view.needsDisplay = true
        }
        showSurfaces()
        bringToKey(surfaces.first { $0.isPrimary } ?? surfaces.first)
    }

    // MARK: - Target loop

    private func startTargets() {
        index = 0
        attempts = 0
        beginCurrentTarget()
    }

    private func beginCurrentTarget() {
        guard index < targets.count else {
            finish()
            return
        }
        let target = targets[index]
        if target.displayIndex != lastDisplayIndex {
            beginCountdown(displayIndex: target.displayIndex)
        } else {
            beginSettle()
        }
    }

    private func beginCountdown(displayIndex: Int) {
        phase = .countdown
        paused = false
        isPaused = false
        currentSamples = []
        lastCountdownNumber = 0
        countdownActive = false
        activeSurface = surface(forDisplayIndex: displayIndex)
        prepareSessionChrome(displayIndex: displayIndex)
        bringToKey(activeSurface)

        if displayIndex == 0 {
            // Screen 1 was already named by the opening line.
            startCountdown()
        } else {
            // The countdown waits for the line to finish (item: spoken flow).
            speak(VoiceScript.nextScreen(displayIndex: displayIndex, count: sortedDisplays.count)) { [weak self] in
                self?.startCountdown()
            }
        }
    }

    /// Start the 3·2·1 countdown, once any spoken line has finished.
    private func startCountdown() {
        guard isCalibrating, phase == .countdown else { return }
        countdownActive = true
        phaseStart = CACurrentMediaTime()
        lastCountdownNumber = 0
        updateCountdown()
    }

    /// Dim the other displays and highlight the active one.
    private func prepareSessionChrome(displayIndex: Int) {
        for surface in surfaces {
            surface.view.reset()
            let isActive = surface === activeSurface
            surface.view.backdropAlpha = isActive ? 0.55 : 0.85
            surface.view.showsBorder = isActive
            surface.view.miniMapActiveIndex = nil
            surface.view.needsDisplay = true
        }
    }

    private func updateCountdown() {
        let elapsed = CACurrentMediaTime() - phaseStart
        let remaining = Int(ceil(countdownDuration - elapsed))
        let number = max(min(remaining, 3), 0)
        if number != lastCountdownNumber {
            lastCountdownNumber = number
            if number > 0 { play("Tink") }
        }
        let fraction = elapsed - floor(elapsed)
        activeSurface?.view.countdownNumber = number > 0 ? number : nil
        activeSurface?.view.countdownProgress = CGFloat(min(max(fraction, 0), 1))
        activeSurface?.view.needsDisplay = true
    }

    private func beginSettle() {
        phase = .settle
        phaseStart = CACurrentMediaTime()
        currentSamples = []
        play("Tink", volume: 0.4)

        // "Almost done" is announced during the settle of the target that leaves
        // exactly two remaining, once per session (allowed inside the collect
        // window, so it is not tied to the settle completing).
        let remaining = targets.count - index
        if CalibrationScript.shouldAnnounceAlmostDone(remaining: remaining, alreadyAnnounced: almostDoneAnnounced) {
            almostDoneAnnounced = true
            speak(VoiceScript.almostDone)
        }

        guard let surface = activeSurface else { return }
        let point = targets[index].point
        surface.view.dotCenter = ScreenGeometry.appKitPoint(
            fromCG: point,
            screenFrame: surface.screenFrame,
            primaryHeight: primaryHeight
        )
        surface.view.dotRadius = 26
        surface.view.collectProgress = nil
        surface.view.countdownNumber = nil
        surface.view.showTrackingHint = false
        surface.view.progressLabel = progressLabel()
        surface.view.needsDisplay = true
    }

    private func beginCollect() {
        phase = .collect
        phaseStart = CACurrentMediaTime()
        collectStart = phaseStart
        currentSamples = []
        activeSurface?.view.collectProgress = 0
        activeSurface?.view.showTrackingHint = false
        activeSurface?.view.needsDisplay = true
    }

    private func receive(_ features: FaceFeatures, reliable: Bool) {
        guard isCalibrating, !paused, phase == .collect, index < targets.count else { return }

        // Frames the tracking-quality gate marks unreliable (hand on the face,
        // unstable tracking) are never collected. A target that ends with too
        // few good frames is retried; while rejecting, prompt the user.
        if !reliable {
            if activeSurface?.view.showTrackingHint != true {
                activeSurface?.view.showTrackingHint = true
                activeSurface?.view.needsDisplay = true
            }
            announceHandsIfNeeded()
            return
        }
        if activeSurface?.view.showTrackingHint == true {
            activeSurface?.view.showTrackingHint = false
            activeSurface?.view.needsDisplay = true
        }

        guard CACurrentMediaTime() - collectStart >= collectSkip else { return }
        currentSamples.append(CalibrationSample(features: features, target: targets[index].point))
    }

    private func finishTarget() {
        if currentSamples.count < minFramesPerTarget, attempts < 1 {
            attempts += 1
            currentSamples = []
            beginSettle()
            return
        }
        samples.append(contentsOf: currentSamples)
        currentSamples = []
        index += 1
        attempts = 0

        if index < targets.count {
            beginCurrentTarget()
        } else {
            finish()
        }
    }

    private func progressLabel() -> String {
        guard index < targets.count else { return "" }
        let target = targets[index]
        let screen = target.displayIndex + 1
        let screenCount = sortedDisplays.count
        let before = targets[..<index].filter { $0.displayIndex == target.displayIndex }.count
        let perDisplay = targets.filter { $0.displayIndex == target.displayIndex }.count
        return "Screen \(screen) of \(screenCount) · Point \(before + 1) of \(perDisplay)"
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
        guard isCalibrating, !paused else { return }
        let elapsed = CACurrentMediaTime() - phaseStart

        switch phase {
        case .intro:
            break
        case .countdown:
            guard countdownActive else { break }
            updateCountdown()
            if elapsed >= countdownDuration {
                lastDisplayIndex = activeSurface.flatMap(displayIndexOf(surface:)) ?? lastDisplayIndex
                play("Pop")
                beginSettle()
            }
        case .settle:
            let progress = min(elapsed / settleDuration, 1)
            activeSurface?.view.dotRadius = 26 - 17 * CGFloat(progress)
            activeSurface?.view.needsDisplay = true
            if elapsed >= settleDuration {
                beginCollect()
            }
        case .collect:
            activeSurface?.view.collectProgress = min(elapsed / collectDuration, 1)
            activeSurface?.view.progressLabel = progressLabel()
            activeSurface?.view.needsDisplay = true
            if elapsed >= collectDuration {
                finishTarget()
            }
        }
    }

    private func displayIndexOf(surface: Surface) -> Int? {
        sortedDisplays.firstIndex { $0.frame == surface.displayFrame }
    }

    // MARK: - Keys

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            switch event.keyCode {
            case 53: // Esc
                MainActor.assumeIsolated { self?.cancel() }
                return nil
            case 49: // Space
                MainActor.assumeIsolated { self?.handleSpace() }
                return nil
            case 15: // R
                MainActor.assumeIsolated { self?.redoCurrentTarget() }
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
    }

    private func handleSpace() {
        guard isCalibrating else { return }
        if phase == .intro {
            startSession()
        } else {
            togglePause()
        }
    }

    /// Speak the opening line, then begin the target loop when it finishes. With
    /// voice guidance off the line completes immediately, so this is a no-op
    /// delay (exactly the previous behaviour).
    private func startSession() {
        guard phase == .intro, !sessionStarting else { return }
        sessionStarting = true
        speak(VoiceScript.start(displayCount: sortedDisplays.count)) { [weak self] in
            guard let self else { return }
            self.sessionStarting = false
            self.startTargets()
        }
    }

    private func togglePause() {
        guard isCalibrating, phase != .intro else { return }
        if paused {
            phaseStart += CACurrentMediaTime() - pauseBegan
            paused = false
            isPaused = false
            speak(VoiceScript.resumed)
            // If the pause cut off a screen's spoken line before its countdown
            // started, begin the countdown now.
            if phase == .countdown, !countdownActive {
                startCountdown()
            }
        } else {
            paused = true
            pauseBegan = CACurrentMediaTime()
            isPaused = true
            voice.stop()
            speak(VoiceScript.paused)
        }
        for surface in surfaces {
            surface.view.paused = paused
            surface.view.needsDisplay = true
        }
    }

    private func redoCurrentTarget() {
        guard isCalibrating, index < targets.count else { return }
        guard phase == .settle || phase == .collect else { return }
        paused = false
        isPaused = false
        attempts = 0
        currentSamples = []
        for surface in surfaces {
            surface.view.paused = false
        }
        beginSettle()
    }

    // MARK: - Voice

    /// Speak `line` through the on-device synthesizer. When voice guidance is
    /// off, `completion` runs immediately so the flow proceeds unchanged.
    private func speak(_ line: VoiceLine, completion: (() -> Void)? = nil) {
        guard voiceEnabled else {
            completion?()
            return
        }
        voice.speak(line, completion: completion)
    }

    /// Warn about hands on the face / unstable tracking, at most once per 5 s.
    private func announceHandsIfNeeded() {
        let now = CACurrentMediaTime()
        guard now - lastHandsWarning >= 5 else { return }
        lastHandsWarning = now
        speak(VoiceScript.hands)
    }

    // MARK: - Sounds

    private func play(_ name: String, volume: Float = 1) {
        guard soundsEnabled else { return }
        guard let sound = NSSound(named: name) else { return }
        sound.volume = volume
        sound.play()
    }

    // MARK: - Finish

    private func finish() {
        teardown()

        guard samples.count >= GazeModel.minimumSampleCount else {
            showResult(Result(
                errorPoints: nil,
                quality: .failed,
                sampleCount: samples.count,
                crossValidationError: 0,
                displays: [],
                indistinguishableDisplays: []
            ))
            return
        }

        let cleaned = CalibrationCleaner.clean(samples)
        guard cleaned.count >= GazeModel.minimumSampleCount else {
            showResult(Result(
                errorPoints: nil,
                quality: .failed,
                sampleCount: cleaned.count,
                crossValidationError: 0,
                displays: [],
                indistinguishableDisplays: []
            ))
            return
        }

        do {
            let model = try GazeModel.fit(samples: cleaned)
            let error = model.meanError(on: cleaned)
            let report = CalibrationQuality.report(
                model: model,
                samples: cleaned,
                displays: sortedDisplays
            )
            let profile = CalibrationProfile(
                model: model,
                samples: cleaned,
                createdAt: Date(),
                displayFingerprint: CalibrationProfile.fingerprint(for: WindowCatalog.displays())
            )
            Storage.saveCalibration(profile)
            pipeline?.reloadCalibration()

            let quality: Result.Quality = error < 150 ? .good : (error < 350 ? .ok : .poor)
            if let line = VoiceScript.finished(errorPoints: error) {
                speak(line)
            }
            showResult(Result(
                errorPoints: error,
                quality: quality,
                sampleCount: cleaned.count,
                crossValidationError: report.crossValidationError,
                displays: report.displays,
                indistinguishableDisplays: report.indistinguishableDisplays
            ))
        } catch {
            showResult(Result(
                errorPoints: nil,
                quality: .failed,
                sampleCount: cleaned.count,
                crossValidationError: 0,
                displays: [],
                indistinguishableDisplays: []
            ))
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
        paused = false
        isPaused = false
        sessionStarting = false
        countdownActive = false
        voice.stop()
        isCalibrating = false
        onEnd?()
    }

    // MARK: - Result panel

    private func showResult(_ result: Result) {
        lastResult = result
        closeResultPanel()

        let label = NSTextField(wrappingLabelWithString: resultMessage(result))
        label.alignment = .center
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = 420

        let done = NSButton(title: "Done", target: self, action: #selector(closeResultPanel))
        done.keyEquivalent = "\r"
        let recalibrate = NSButton(title: "Recalibrate", target: self, action: #selector(recalibratePressed))
        let test = NSButton(title: "Test", target: self, action: #selector(testPressed))
        test.isEnabled = result.errorPoints != nil

        let buttons = NSStackView(views: [done, recalibrate, test])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.distribution = .fillEqually

        let stack = NSStackView(views: [label, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 18
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
            contentRect: CGRect(x: 0, y: 0, width: 480, height: 280),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Calibration"
        panel.isReleasedWhenClosed = false
        panel.contentView = container
        panel.center()
        resultWindow = panel
        // The app is an `.accessory` menu-bar app, so the panel would otherwise
        // open behind other apps' windows. Raise it (and activate) explicitly.
        WindowActivation.raise(panel)
        WindowActivation.activateAndRaise(titled: "Calibration")
    }

    /// Human-readable result text: overall error, cross-validation error, the
    /// per-display error and any separability warning.
    private func resultMessage(_ result: Result) -> String {
        guard let points = result.errorPoints else {
            return "Calibration could not be completed (\(result.sampleCount) frames).\n"
                + "Check the camera and try again."
        }

        var lines: [String] = []
        switch result.quality {
        case .good:
            lines.append("Mean error: \(Int(points.rounded())) pt — good.")
        case .ok:
            lines.append("Mean error: \(Int(points.rounded())) pt — okay.")
            lines.append("Recalibrating in better light may improve it.")
        case .poor:
            lines.append("Mean error: \(Int(points.rounded())) pt — poor.")
            lines.append("Try better lighting and recalibrate.")
        case .failed:
            break
        }
        lines.append(String(format: "Cross-validation error: %.0f pt.", result.crossValidationError))
        lines.append("Calibration saved.")
        lines.append("")
        for display in result.displays {
            lines.append(String(
                format: "Display %d: %.0f pt (%d samples)",
                display.displayIndex,
                display.meanErrorPoints,
                display.sampleCount
            ))
        }
        for index in result.indistinguishableDisplays {
            lines.append("")
            lines.append("⚠ Display \(index) could not be told apart — make sure you turned toward it.")
        }
        return lines.joined(separator: "\n")
    }

    @objc private func closeResultPanel() {
        resultWindow?.close()
        resultWindow = nil
    }

    @objc private func recalibratePressed() {
        closeResultPanel()
        onRecalibrate?()
    }

    @objc private func testPressed() {
        // Close the panel first, then run the 15 s test (item C).
        closeResultPanel()
        onTest?()
    }
}
