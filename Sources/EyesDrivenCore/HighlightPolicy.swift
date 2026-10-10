import Foundation

/// Decides whether the overlay should draw the target-window border for a given
/// dwell `progress` and `triggerMode` (SPEC 3.8, 4).
///
/// While the eyes just sweep across windows the dwell progress is tiny, and a
/// border flashing for every window the gaze crosses is noise. In the
/// dwell-based modes the border is therefore drawn only once a dwell is
/// meaningfully in progress (`progress >= minDwellProgress`). In `.nod`-only
/// mode progress is always 0, so the border is drawn anyway: it shows which
/// window a nod would focus.
public enum HighlightPolicy {

    /// Dwell progress (0...1) at which the border starts to be drawn in the
    /// dwell-based trigger modes.
    public static let minDwellProgress = 0.15

    /// Whether the target-window border should be drawn.
    ///
    /// - Parameters:
    ///   - progress: Current dwell progress, 0...1.
    ///   - triggerMode: The active trigger mode.
    /// - Returns: `true` when the border should be visible.
    public static func shouldDraw(progress: Double, triggerMode: TriggerMode) -> Bool {
        if triggerMode == .nod { return true }
        return progress >= minDwellProgress
    }
}
