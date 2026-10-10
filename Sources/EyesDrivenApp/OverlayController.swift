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
            let diameter: CGFloat = 12
            let dot = CGRect(
                x: point.x - diameter / 2,
                y: point.y - diameter / 2,
                width: diameter,
                height: diameter
            )
            let path = NSBezierPath(ovalIn: dot)
            NSColor.controlAccentColor.withAlphaComponent(0.85).setFill()
            path.fill()
            path.lineWidth = 1.5
            NSColor.white.withAlphaComponent(0.9).setStroke()
            path.stroke()
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
        for surface in surfaces {
            let view = surface.view
            view.showHighlight = showHighlight
            view.showGazeDot = showGazeDot
            view.progress = progress

            if showHighlight, let target {
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
