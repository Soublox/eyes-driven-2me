import AppKit
import ApplicationServices
import CoreGraphics
import EyesDrivenCore
import Foundation

/// Brings a `WindowInfo` to the front and gives it keyboard focus through the
/// Accessibility (AX) API, with `NSRunningApplication` activation as a fallback.
///
/// On macOS 14+ cooperative activation can ignore `NSRunningApplication.activate`
/// when called from a background app, so setting the app element's
/// `kAXFrontmostAttribute` is the primary path.
enum WindowFocuser {

    /// Whether this process is trusted for the Accessibility API.
    static func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Focuses `window`. Returns `true` when an AX window was raised or the app
    /// was activated. When `moveCursor` is set, the mouse cursor is warped to
    /// the window's center in CG global coordinates.
    @discardableResult
    static func focus(_ window: WindowInfo, moveCursor: Bool) -> Bool {
        let app = AXUIElementCreateApplication(window.pid)

        var raised = false
        if let axWindow = matchWindow(for: window, in: app) {
            _ = AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
            _ = AXUIElementSetAttributeValue(axWindow, kAXMainAttribute as CFString, kCFBooleanTrue)
            raised = true
        }

        // Primary activation path on macOS 14+.
        _ = AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)

        let activated = NSRunningApplication(processIdentifier: window.pid)?
            .activate(from: .current, options: [.activateAllWindows]) ?? false

        if moveCursor {
            let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
            _ = CGWarpMouseCursorPosition(center)
            _ = CGAssociateMouseAndMouseCursorPosition(1)
        }

        return raised || activated
    }

    // MARK: - AX window matching

    /// Picks the AX window that corresponds to `window`: an exact title match is
    /// preferred, otherwise the closest position/size match within ±4 pt.
    private static func matchWindow(for window: WindowInfo, in app: AXUIElement) -> AXUIElement? {
        guard let axWindows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] else {
            return nil
        }

        if let title = window.title, !title.isEmpty {
            for axWindow in axWindows where attribute(axWindow, kAXTitleAttribute) as? String == title {
                return axWindow
            }
        }
        return axWindows.first { geometricallyMatches($0, window) }
    }

    private static func geometricallyMatches(_ element: AXUIElement, _ window: WindowInfo) -> Bool {
        guard let frame = frame(of: element) else { return false }
        let tolerance: CGFloat = 4
        return abs(frame.origin.x - window.frame.origin.x) <= tolerance
            && abs(frame.origin.y - window.frame.origin.y) <= tolerance
            && abs(frame.size.width - window.frame.size.width) <= tolerance
            && abs(frame.size.height - window.frame.size.height) <= tolerance
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let positionValue = attribute(element, kAXPositionAttribute),
              let sizeValue = attribute(element, kAXSizeAttribute),
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else { return nil }

        return CGRect(origin: origin, size: size)
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value
    }
}
