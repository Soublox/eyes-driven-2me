import AppKit

/// Brings the app's own windows to the front even though it runs as an
/// `.accessory` (menu-bar) app (SPEC 4).
///
/// SwiftUI's `openWindow` does not activate the app, so a window opened from the
/// menu bar appears *behind* the frontmost app's windows (verified: the Settings
/// window existed on screen but was covered). Activating alone is not always
/// enough because the window may not exist yet on the current run-loop turn, so
/// the raise is also retried over the next few turns.
@MainActor
enum WindowActivation {

    /// Activate the app and, over the next few run-loop turns, bring the window
    /// whose title is `title` to the front (key + ordered front regardless).
    static func activateAndRaise(titled title: String) {
        NSApp.activate(ignoringOtherApps: true)
        raise(title: title, attemptsRemaining: 12)
    }

    /// Raise a window that already exists: make it key and force it in front of
    /// other apps' windows.
    static func raise(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    /// Retry raising the window with `title` over the next run-loop turns, until
    /// SwiftUI has created it.
    private static func raise(title: String, attemptsRemaining: Int) {
        guard attemptsRemaining > 0 else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if let window = NSApp.windows.first(where: { $0.title == title }) {
                    raise(window)
                } else {
                    raise(title: title, attemptsRemaining: attemptsRemaining - 1)
                }
            }
        }
    }
}
