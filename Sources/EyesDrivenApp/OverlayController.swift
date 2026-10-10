import AppKit
import CoreGraphics
import EyesDrivenCore
import Foundation

/// Draws the target-window highlight (with dwell progress) and the optional
/// debug gaze dot on one click-through window per screen (SPEC 4).
///
/// Each window is borderless, transparent, ignores mouse events, sits at the
/// screen-saver level and joins every space so it never steals focus.
@MainActor
final class OverlayController {

    /// Borderless overlay window that can never become key or main.
    private final class OverlayWindow: NSWindow {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    /// View that draws the highlight and gaze dot in AppKit view coordinates
    /// (bottom-left origin, y up), as produced by `ScreenGeometry`.
    final class OverlayView: NSView {
        /// Target window frame in this view's coordinates, or nil.
        var targetRect: CGRect?
        /// Dwell progress 0...1.
        var progress: Double = 0
        /// Gaze point in this view's coordinates, or nil.
        var gazePoint: CGPoint?
        var showHighlight = true
        var showGazeDot = false
        /// Whether the large, high-contrast test dot is drawn instead of the
        /// 12 pt settings dot (menu / result-panel gaze test).
        var testMode = false
        /// The countdown label drawn near the top-center, or nil.
        var testLabel: String?

        override var isOpaque: Bool { false }

        override func draw(_ dirtyRect: NSRect) {
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            context.clear(bounds)

            if showHighlight, let targetRect, !targetRect.isEmpty {
                drawHighlight(targetRect)
            }
            if showGazeDot, let gazePoint {
                drawGazeDot(gazePoint)
            }
            if testMode, let testLabel {
                drawTestLabel(testLabel)
            }
        }

        private func drawHighlight(_ rect: CGRect) {
            let outline = rect.insetBy(dx: 2, dy: 2)
            let border = NSBezierPath(roundedRect: outline, xRadius: 12, yRadius: 12)
            border.lineWidth = 4
            NSColor.controlAccentColor.withAlphaComponent(0.9).setStroke()
            border.stroke()

            guard progress > 0.001 else { return }

            // A subtle progress ring at the frame center.
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let radius: CGFloat = 22
            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = 4
            NSColor.controlAccentColor.withAlphaComponent(0.18).setStroke()
            track.stroke()

            let arc = NSBezierPath()
            arc.appendArc(
                withCenter: center,
                radius: radius,
                startAngle: 90,
                endAngle: 90 - 360 * progress,
                clockwise: true
            )
            arc.lineWidth = 4
            arc.lineCapStyle = .round
            NSColor.controlAccentColor.setStroke()
            arc.stroke()
        }

        private func drawGazeDot(_ point: CGPoint) {
            guard let context = NSGraphicsContext.current?.cgContext else { return }

            // Test mode: a large, high-contrast dot in a color distinct from
            // the (accent-colored) border, with a white ring and a soft shadow.
            let diameter: CGFloat = testMode ? 36 : 12
            let fillColor = testMode ? NSColor.systemPink : NSColor.controlAccentColor
            let ringColor = NSColor.white

            if testMode {
                context.saveGState()
                context.setShadow(
                    offset: CGSize(width: 0, height: -2),
                    blur: 14,
                    color: NSColor.black.withAlphaComponent(0.55).cgColor
                )
            }

            let dot = CGRect(
                x: point.x - diameter / 2,
                y: point.y - diameter / 2,
                width: diameter,
                height: diameter
            )
            let path = NSBezierPath(ovalIn: dot)
            fillColor.withAlphaComponent(testMode ? 1 : 0.85).setFill()
            path.fill()
            path.lineWidth = testMode ? 3 : 1.5
            ringColor.withAlphaComponent(testMode ? 1 : 0.9).setStroke()
            path.stroke()

            if testMode {
                context.restoreGState()
            }
        }

        /// A small floating label near the top-center with a dark pill behind it
        /// so it stays legible over any window.
        private func drawTestLabel(_ text: String) {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 16, weight: .semibold),
                .foregroundColor: NSColor.white,
            ]
            let string = NSAttributedString(string: text, attributes: attributes)
            let size = string.size()
            let padding = CGSize(width: 18, height: 9)
            let origin = CGPoint(
                x: (bounds.width - size.width) / 2,
                y: bounds.maxY - size.height - 28
            )
            let box = CGRect(
                x: origin.x - padding.width,
                y: origin.y - padding.height,
                width: size.width + padding.width * 2,
                height: size.height + padding.height * 2
            )
            let pill = NSBezierPath(roundedRect: box, xRadius: 12, yRadius: 12)
            NSColor.systemPink.withAlphaComponent(0.9).setFill()
            pill.fill()
            string.draw(at: origin)
        }
    }

    /// One window + view per screen, with the geometry needed to convert.
    private final class Surface {
        let window: OverlayWindow
        let view: OverlayView
        let screenFrame: CGRect

        init(window: OverlayWindow, view: OverlayView, screenFrame: CGRect) {
            self.window = window
            self.view = view
            self.screenFrame = screenFrame
        }
    }

    private var surfaces: [Surface] = []
    private var target: WindowInfo?
    private var gaze: CGPoint?
    private var progress: Double = 0
    private var showHighlight = true
    private var showGazeDot = false
    private var triggerMode: TriggerMode = .dwellOrNod
    private var testMode = false
    private var testLabel: String?
    private var visible = false
    private var primaryHeight: CGFloat = 0
    private var screenObserver: NSObjectProtocol?

    init() {
        rebuild()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.rebuild() }
        }
    }

    // MARK: - API

    /// Show `target` (nil clears) with dwell `progress` 0...1.
    func update(target: WindowInfo?, progress: Double) {
        self.target = target
        self.progress = min(max(progress, 0), 1)
        refresh()
    }

    /// Show the gaze dot at `gaze` (nil clears), in CoreGraphics global coords.
    func update(gaze: CGPoint?) {
        self.gaze = gaze
        refresh()
    }

    /// Apply the display-related settings (highlight and gaze dot visibility).
    func apply(settings: AppSettings) {
        showHighlight = settings.showTargetHighlight
        showGazeDot = settings.showGazeDot
        triggerMode = settings.triggerMode
        refresh()
    }

    /// Turn the 15 s gaze test on or off. While on, the dot is drawn large and
    /// high-contrast and `label` (the countdown text) floats near the top-center
    /// of the display the gaze point is on. Pass `label: nil` to hide it.
    func setGazeDotTest(active: Bool, label: String?) {
        testMode = active
        testLabel = label
        refresh()
    }

    /// Show or hide every overlay window.
    func setVisible(_ visible: Bool) {
        guard visible != self.visible else { return }
        self.visible = visible
        for surface in surfaces {
            if visible {
                surface.window.orderFrontRegardless()
            } else {
                surface.window.orderOut(nil)
            }
        }
    }

    /// Remove the screen-parameters observer.
    func shutdown() {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        screenObserver = nil
    }

    // MARK: - Private

    private func rebuild() {
        for surface in surfaces {
            surface.window.orderOut(nil)
        }
        primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        surfaces = NSScreen.screens.map { screen in
            // NOTE: no `screen:` argument. With it, AppKit treats `contentRect`
            // as relative to that screen and applies the screen origin twice
            // (verified: a screen at x=-3840 produced a window at x=-7680).
            // Pin the frame explicitly after creation as well.
            let window = OverlayWindow(
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
            window.ignoresMouseEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            window.isReleasedWhenClosed = false

            let view = OverlayView(frame: CGRect(origin: .zero, size: screen.frame.size))
            window.contentView = view
            return Surface(window: window, view: view, screenFrame: screen.frame)
        }
        refresh()
        if visible {
            for surface in surfaces {
                surface.window.orderFrontRegardless()
            }
        }
    }

    private func refresh() {
        // In test mode the countdown label follows the dot: draw it only on the
        // display that contains the gaze point (the main display before there is
        // a gaze point).
        let testSurfaceIndex: Int? = {
            guard testMode else { return nil }
            guard let gaze else { return surfaces.isEmpty ? nil : 0 }
            return surfaces.firstIndex { surface in
                let point = ScreenGeometry.appKitPoint(
                    fromCG: gaze,
                    screenFrame: surface.screenFrame,
                    primaryHeight: primaryHeight
                )
                return CGRect(origin: .zero, size: surface.screenFrame.size).contains(point)
            }
        }()

        // Do not flash the border while the eyes just sweep across windows: in
        // the dwell modes it appears only once the dwell is meaningfully in
        // progress (nod-only mode always draws it).
        let drawHighlight = showHighlight
            && target != nil
            && HighlightPolicy.shouldDraw(progress: progress, triggerMode: triggerMode)

        for (index, surface) in surfaces.enumerated() {
            let view = surface.view
            view.showHighlight = showHighlight
            view.showGazeDot = showGazeDot
            view.progress = progress
            view.testMode = testMode
            view.testLabel = index == testSurfaceIndex ? testLabel : nil

            if drawHighlight, let target {
                view.targetRect = ScreenGeometry.appKitRect(
                    fromCG: target.frame,
                    screenFrame: surface.screenFrame,
                    primaryHeight: primaryHeight
                )
            } else {
                view.targetRect = nil
            }

            if showGazeDot, let gaze {
                view.gazePoint = ScreenGeometry.appKitPoint(
                    fromCG: gaze,
                    screenFrame: surface.screenFrame,
                    primaryHeight: primaryHeight
                )
            } else {
                view.gazePoint = nil
            }

            view.needsDisplay = true
        }
    }
}
