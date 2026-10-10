import CoreGraphics
import Foundation

/// Pure decision-maker combining dwell, nod and target resolution (SPEC 3.8).
///
/// The only place that turns gaze, nods and a window snapshot into
/// `FocusAction`s. It performs no I/O and is fully deterministic given the
/// inputs and timestamps.
public final class FocusEngine {
    private var settings: AppSettings
    private let excludedPIDs: Set<Int32>

    private var windows: [WindowInfo] = []
    private var displays: [DisplayInfo] = []
    private var frontmostWindowID: UInt32?

    private var dwell: DwellDetector<UInt32>
    private var history: GazeHistory

    private var cooldownUntil: TimeInterval = -.infinity
    private var lastHighlight: (id: UInt32?, progress: Double)?
    private var disabledHighlightEmitted = false

    /// Create an engine for the given settings.
    public init(settings: AppSettings, excludedPIDs: Set<Int32> = []) {
        self.settings = settings
        self.excludedPIDs = excludedPIDs
        self.dwell = DwellDetector(duration: settings.dwellSeconds)
        self.history = GazeHistory(duration: 3.0)
    }

    // MARK: - Inputs

    /// Replace the window snapshot and frontmost window.
    public func updateWindows(_ windows: [WindowInfo], displays: [DisplayInfo], frontmostWindowID: UInt32?) {
        self.windows = windows
        self.displays = displays
        self.frontmostWindowID = frontmostWindowID
    }

    /// Apply new settings; update the dwell duration accordingly.
    public func updateSettings(_ newSettings: AppSettings) {
        let wasEnabled = settings.isEnabled
        settings = newSettings
        dwell.duration = newSettings.dwellSeconds
        if newSettings.isEnabled != wasEnabled {
            disabledHighlightEmitted = false
            lastHighlight = nil
        }
    }

    /// The app focused `windowID` at `timestamp` (for example via a nod it
    /// handled elsewhere). Suppresses re-focusing it during the cooldown.
    public func notifyFocused(windowID: UInt32, at timestamp: TimeInterval) {
        frontmostWindowID = windowID
        cooldownUntil = max(cooldownUntil, timestamp + settings.cooldownSeconds)
    }

    /// Feed a filtered gaze point.
    public func ingest(gaze: CGPoint, at timestamp: TimeInterval) -> [FocusAction] {
        guard settings.isEnabled else { return disabledActions() }

        history.append(gaze, at: timestamp)
        let resolved = resolve(gaze)
        var actions: [FocusAction] = []

        // The window the user is already typing in (frontmost) never
        // accumulates dwell: highlight it with progress 0 and restart the dwell
        // from zero, so moving the gaze to another window does not inherit
        // progress from the frontmost one (SPEC 3.8).
        if let frontmost = resolved, frontmost.id == frontmostWindowID {
            dwell.reset()
            appendHighlight(frontmost, progress: 0, into: &actions)
            return actions
        }

        if settings.triggerMode == .nod {
            appendHighlight(resolved, progress: 0, into: &actions)
            return actions
        }

        let state = dwell.update(target: resolved?.id, timestamp: timestamp)

        let target: WindowInfo?
        let progress: Double
        var firedID: UInt32?
        switch state {
        case .idle:
            target = resolved
            progress = 0
        case .progressing(let id, let fraction):
            target = window(id) ?? resolved
            progress = fraction
        case .fired(let id):
            target = window(id) ?? resolved
            progress = 1
            firedID = id
        }

        appendHighlight(target, progress: progress, into: &actions)

        if let id = firedID, let fired = window(id) {
            if let action = attemptFocus(fired, at: timestamp, reason: .dwell) {
                actions.append(action)
            } else if timestamp < cooldownUntil {
                // The dwell completed while the cooldown was still active.
                // Restart it so the target focuses as soon as the cooldown
                // elapses instead of losing the completed dwell (SPEC 3.8).
                dwell.reset()
            }
        }
        return actions
    }

    /// Feed a completed nod event.
    public func ingest(nod: NodEvent) -> [FocusAction] {
        guard settings.isEnabled else { return disabledActions() }
        guard settings.triggerMode != .dwell else { return [] }

        let start = nod.startTimestamp
        guard let median = history.median(from: start - 0.35, to: start - 0.05) else { return [] }
        guard let target = resolve(median) else { return [] }
        guard let action = attemptFocus(target, at: nod.endTimestamp, reason: .nod) else { return [] }
        return [action]
    }

    // MARK: - Helpers

    private func resolve(_ point: CGPoint) -> WindowInfo? {
        TargetResolver.resolve(
            point: point,
            windows: windows,
            displays: displays,
            excludedPIDs: excludedPIDs
        )
    }

    private func window(_ id: UInt32) -> WindowInfo? {
        windows.first { $0.id == id }
    }

    private func disabledActions() -> [FocusAction] {
        guard !disabledHighlightEmitted else { return [] }
        disabledHighlightEmitted = true
        lastHighlight = (nil, 0)
        return [.highlight(nil, progress: 0)]
    }

    private func attemptFocus(
        _ w: WindowInfo,
        at timestamp: TimeInterval,
        reason: FocusReason
    ) -> FocusAction? {
        if let front = frontmostWindowID, w.id == front { return nil }
        if timestamp < cooldownUntil { return nil }

        cooldownUntil = timestamp + settings.cooldownSeconds
        return .focus(w, reason: reason)
    }

    /// Emit a highlight only when the target id or the 0.05-rounded progress changes.
    private func appendHighlight(_ target: WindowInfo?, progress: Double, into actions: inout [FocusAction]) {
        let rounded = min(max((progress / 0.05).rounded() * 0.05, 0), 1)
        if let last = lastHighlight, last.id == target?.id, abs(last.progress - rounded) < 1e-9 {
            return
        }
        lastHighlight = (target?.id, rounded)
        actions.append(.highlight(target, progress: rounded))
    }
}
