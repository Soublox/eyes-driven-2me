import CoreGraphics
import Foundation
import Testing
@testable import EyesDrivenCore

private let display = DisplayInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))

private func win(_ id: UInt32, _ rect: CGRect, pid: Int32 = 100) -> WindowInfo {
    WindowInfo(id: id, pid: pid, appName: "App", title: "T", frame: rect)
}

private func isFocus(_ action: FocusAction, _ reason: FocusReason? = nil) -> Bool {
    if case .focus(_, let r) = action { return reason == nil || r == reason }
    return false
}

private func focusTarget(_ action: FocusAction) -> WindowInfo? {
    if case .focus(let w, _) = action { return w }
    return nil
}

private func isHighlight(_ action: FocusAction) -> Bool {
    if case .highlight = action { return true }
    return false
}

private func isClearing(_ action: FocusAction) -> Bool {
    if case .highlight(let w, let p) = action { return w == nil && p == 0 }
    return false
}

@Test func dwellFocusFires() {
    var settings = AppSettings()
    settings.dwellSeconds = 0.3
    settings.cooldownSeconds = 0.2
    let engine = FocusEngine(settings: settings)
    let a = win(1, CGRect(x: 0, y: 0, width: 800, height: 600))
    engine.updateWindows([a], displays: [display], frontmostWindowID: 42)

    var actions: [FocusAction] = []
    var t = 0.0
    while t <= 0.45 {
        actions += engine.ingest(gaze: CGPoint(x: 400, y: 300), at: t)
        t += 0.05
    }
    #expect(actions.contains { isFocus($0, .dwell) })
    #expect(focusTarget(actions.first { isFocus($0, .dwell) }!)?.id == 1)
}

@Test func frontmostWindowNeverFires() {
    var settings = AppSettings()
    settings.dwellSeconds = 0.3
    let engine = FocusEngine(settings: settings)
    let a = win(1, CGRect(x: 0, y: 0, width: 800, height: 600))
    engine.updateWindows([a], displays: [display], frontmostWindowID: 1)

    var actions: [FocusAction] = []
    var t = 0.0
    while t <= 1.0 {
        actions += engine.ingest(gaze: CGPoint(x: 400, y: 300), at: t)
        t += 0.05
    }
    #expect(!actions.contains { isFocus($0) })
}

@Test func cooldownIsRespected() {
    var settings = AppSettings()
    settings.dwellSeconds = 0.3
    settings.cooldownSeconds = 0.5
    let engine = FocusEngine(settings: settings)
    let a = win(1, CGRect(x: 0, y: 0, width: 800, height: 600))
    let b = win(2, CGRect(x: 1000, y: 0, width: 800, height: 600))
    engine.updateWindows([a, b], displays: [display], frontmostWindowID: 42)

    var events: [(TimeInterval, UInt32)] = []
    var t = 0.0
    while t <= 0.4 {
        for action in engine.ingest(gaze: CGPoint(x: 400, y: 300), at: t) where isFocus(action) {
            events.append((t, focusTarget(action)!.id))
        }
        t += 0.05
    }
    while t <= 1.2 {
        for action in engine.ingest(gaze: CGPoint(x: 1400, y: 300), at: t) where isFocus(action) {
            events.append((t, focusTarget(action)!.id))
        }
        t += 0.05
    }
    let aFocus = events.first { $0.1 == 1 }
    let bFocus = events.first { $0.1 == 2 }
    #expect(aFocus != nil)
    #expect(bFocus != nil)
    // A fired around 0.30; its cooldown ends at ~0.80. B's dwell completed at
    // ~0.75 but must not focus before the cooldown elapsed.
    if let aFocus, let bFocus {
        #expect(bFocus.0 >= aFocus.0 + settings.cooldownSeconds - 0.001)
    }
}

@Test func nodUsesGazeFromBeforeTheNodStart() {
    var settings = AppSettings()
    settings.triggerMode = .dwellOrNod
    settings.cooldownSeconds = 0.2
    let engine = FocusEngine(settings: settings)
    let a = win(1, CGRect(x: 0, y: 0, width: 800, height: 600))
    let b = win(2, CGRect(x: 1000, y: 0, width: 800, height: 600))
    engine.updateWindows([a, b], displays: [display], frontmostWindowID: 42)

    // Looking at A just before the nod.
    for t in stride(from: 0.70, through: 0.90, by: 0.05) {
        _ = engine.ingest(gaze: CGPoint(x: 400, y: 300), at: t)
    }
    // The gaze jumps to B as the nod happens.
    _ = engine.ingest(gaze: CGPoint(x: 1400, y: 300), at: 1.0)

    let actions = engine.ingest(nod: NodEvent(startTimestamp: 1.0, endTimestamp: 1.2))
    let focus = actions.first { isFocus($0, .nod) }
    #expect(focusTarget(focus!)?.id == 1)
}

@Test func disabledEmitsHighlightOnceAndNoFocus() {
    var settings = AppSettings()
    settings.isEnabled = false
    let engine = FocusEngine(settings: settings)
    let a = win(1, CGRect(x: 0, y: 0, width: 800, height: 600))
    engine.updateWindows([a], displays: [display], frontmostWindowID: 42)

    let first = engine.ingest(gaze: CGPoint(x: 400, y: 300), at: 0.0)
    #expect(first.count == 1)
    #expect(isClearing(first[0]))
    #expect(engine.ingest(gaze: CGPoint(x: 400, y: 300), at: 1.0).isEmpty)
    #expect(engine.ingest(nod: NodEvent(startTimestamp: 0, endTimestamp: 0.32)).isEmpty)
}

@Test func dwellModeIgnoresNods() {
    var settings = AppSettings()
    settings.triggerMode = .dwell
    let engine = FocusEngine(settings: settings)
    let a = win(1, CGRect(x: 0, y: 0, width: 800, height: 600))
    engine.updateWindows([a], displays: [display], frontmostWindowID: 42)

    for t in stride(from: 0.70, through: 0.90, by: 0.05) {
        _ = engine.ingest(gaze: CGPoint(x: 400, y: 300), at: t)
    }
    #expect(engine.ingest(nod: NodEvent(startTimestamp: 1.0, endTimestamp: 1.2)).isEmpty)
}

@Test func nodModeIgnoresDwell() {
    var settings = AppSettings()
    settings.triggerMode = .nod
    settings.cooldownSeconds = 0.2
    let engine = FocusEngine(settings: settings)
    let a = win(1, CGRect(x: 0, y: 0, width: 800, height: 600))
    engine.updateWindows([a], displays: [display], frontmostWindowID: 42)

    var actions: [FocusAction] = []
    var t = 0.0
    while t <= 2.0 {
        actions += engine.ingest(gaze: CGPoint(x: 400, y: 300), at: t)
        t += 0.05
    }
    #expect(!actions.contains { isFocus($0) })

    for t in stride(from: 2.10, through: 2.35, by: 0.05) {
        _ = engine.ingest(gaze: CGPoint(x: 400, y: 300), at: t)
    }
    let nod = engine.ingest(nod: NodEvent(startTimestamp: 2.4, endTimestamp: 2.6))
    #expect(nod.contains { isFocus($0, .nod) })
}

@Test func highlightEmittedOnlyWhenTargetOrProgressChanges() {
    var settings = AppSettings()
    settings.dwellSeconds = 10
    let engine = FocusEngine(settings: settings)
    let a = win(1, CGRect(x: 0, y: 0, width: 800, height: 600))
    engine.updateWindows([a], displays: [display], frontmostWindowID: 42)

    let first = engine.ingest(gaze: CGPoint(x: 400, y: 300), at: 0.0)
    #expect(first.contains { isHighlight($0) })
    // Same target, progress still rounds to the same 0.05 step -> no highlight.
    let second = engine.ingest(gaze: CGPoint(x: 400, y: 300), at: 0.1)
    #expect(!second.contains { isHighlight($0) })
    // Progress advanced enough to cross a 0.05 step -> a new highlight.
    let third = engine.ingest(gaze: CGPoint(x: 400, y: 300), at: 0.6)
    #expect(third.contains { isHighlight($0) })
}

@Test func updateSettingsChangesDwellDuration() {
    var settings = AppSettings()
    settings.dwellSeconds = 2.0
    let engine = FocusEngine(settings: settings)
    let a = win(1, CGRect(x: 0, y: 0, width: 800, height: 600))
    engine.updateWindows([a], displays: [display], frontmostWindowID: 42)

    var faster = settings
    faster.dwellSeconds = 0.3
    engine.updateSettings(faster)

    var actions: [FocusAction] = []
    var t = 0.0
    while t <= 0.4 {
        actions += engine.ingest(gaze: CGPoint(x: 400, y: 300), at: t)
        t += 0.05
    }
    #expect(actions.contains { isFocus($0, .dwell) })
}

// MARK: - Frontmost dwell (SPEC 3.8)

/// Regression: dwelling on the frontmost window must not accumulate progress.
/// Before the fix the engine kept a completed dwell alive and, worse, carried
/// the accumulated progress over to the next window.
@Test func frontmostDwellDoesNotAccumulate() {
    var settings = AppSettings()
    settings.dwellSeconds = 0.3
    settings.cooldownSeconds = 0.2
    let engine = FocusEngine(settings: settings)
    let a = win(1, CGRect(x: 0, y: 0, width: 800, height: 600))
    engine.updateWindows([a], displays: [display], frontmostWindowID: 1)

    var actions: [FocusAction] = []
    var progressValues: [Double] = []
    var t = 0.0
    while t <= 1.2 {
        for action in engine.ingest(gaze: CGPoint(x: 400, y: 300), at: t) {
            actions.append(action)
            if case .highlight(_, let p) = action { progressValues.append(p) }
        }
        t += 0.05
    }
    #expect(!actions.contains { isFocus($0) })
    // Highlight may be emitted, but as a clear (nil, progress 0): the user is
    // already in the frontmost window, so no border is drawn.
    #expect(progressValues.allSatisfy { $0 == 0 })
    #expect(actions.contains { isClearing($0) })
}

/// Leaving the frontmost window restarts dwell from zero for the next one.
@Test func dwellRestartsWhenLeavingFrontmostWindow() {
    var settings = AppSettings()
    settings.dwellSeconds = 0.3
    settings.cooldownSeconds = 0.2
    let engine = FocusEngine(settings: settings)
    let a = win(1, CGRect(x: 0, y: 0, width: 800, height: 600))
    let b = win(2, CGRect(x: 1000, y: 0, width: 800, height: 600))
    engine.updateWindows([a, b], displays: [display], frontmostWindowID: 1)

    // Spend far longer than the dwell time looking at the frontmost window A.
    var t = 0.0
    while t <= 1.0 {
        _ = engine.ingest(gaze: CGPoint(x: 400, y: 300), at: t)
        t += 0.05
    }

    // Move to B: the first highlight must report fresh (zero) progress.
    let moved = engine.ingest(gaze: CGPoint(x: 1400, y: 300), at: t)
    let firstProgress = moved.compactMap { action -> Double? in
        if case .highlight(let w, let p) = action, w?.id == 2 { return p }
        return nil
    }.first
    #expect(firstProgress == 0.0)

    // And B still fires after a full dwell of its own.
    var actions: [FocusAction] = []
    while t <= 1.0 + 0.35 {
        actions += engine.ingest(gaze: CGPoint(x: 1400, y: 300), at: t)
        t += 0.05
    }
    #expect(actions.contains { isFocus($0, .dwell) })
}

/// After `notifyFocused(windowID:)` that window is frontmost, so looking at it
/// must not progress or fire.
@Test func windowFocusedViaNotifyDoesNotProgress() {
    var settings = AppSettings()
    settings.dwellSeconds = 0.3
    settings.cooldownSeconds = 0.2
    let engine = FocusEngine(settings: settings)
    let a = win(1, CGRect(x: 0, y: 0, width: 800, height: 600))
    engine.updateWindows([a], displays: [display], frontmostWindowID: 42)

    engine.notifyFocused(windowID: 1, at: 0.0)

    var actions: [FocusAction] = []
    var progressValues: [Double] = []
    var t = 0.05
    while t <= 1.2 {
        for action in engine.ingest(gaze: CGPoint(x: 400, y: 300), at: t) {
            actions.append(action)
            if case .highlight(_, let p) = action { progressValues.append(p) }
        }
        t += 0.05
    }
    #expect(!actions.contains { isFocus($0) })
    // The dwell never accumulates on the just-focused window.
    #expect(progressValues.allSatisfy { $0 == 0 })
}

/// With the detector now firing exactly once, staying on a non-frontmost window
/// focuses it a single time and never again.
@Test func dwellFiresOnceWhileStaying() {
    var settings = AppSettings()
    settings.dwellSeconds = 0.3
    settings.cooldownSeconds = 0.2
    let engine = FocusEngine(settings: settings)
    let a = win(1, CGRect(x: 0, y: 0, width: 800, height: 600))
    engine.updateWindows([a], displays: [display], frontmostWindowID: 42)

    var focusCount = 0
    var t = 0.0
    while t <= 2.0 {
        for action in engine.ingest(gaze: CGPoint(x: 400, y: 300), at: t) where isFocus(action) {
            focusCount += 1
        }
        t += 0.05
    }
    #expect(focusCount == 1)
}

// MARK: - Frontmost clears the border (SPEC 3.8, round 4)

/// Looking at the already-focused (frontmost) window must clear the highlight
/// rather than draw a border on the window the user is already in.
@Test func gazeAtFrontmostClearsHighlight() {
    var settings = AppSettings()
    settings.dwellSeconds = 0.3
    let engine = FocusEngine(settings: settings)
    let a = win(1, CGRect(x: 0, y: 0, width: 800, height: 600))
    engine.updateWindows([a], displays: [display], frontmostWindowID: 1)

    let actions = engine.ingest(gaze: CGPoint(x: 400, y: 300), at: 0.0)
    #expect(actions.contains { isClearing($0) })
    // No highlight carries the frontmost window.
    let highlightsWindow = actions.contains { action in
        if case .highlight(let w, _) = action { return w != nil }
        return false
    }
    #expect(!highlightsWindow)
    #expect(!actions.contains { isFocus($0) })
}

/// After a focus fires and `notifyFocused` reports it, looking at the same
/// window clears the border again (the focused window is now frontmost).
@Test func gazeAtJustFocusedWindowClearsHighlight() {
    var settings = AppSettings()
    settings.dwellSeconds = 0.3
    settings.cooldownSeconds = 0.2
    let engine = FocusEngine(settings: settings)
    let a = win(1, CGRect(x: 0, y: 0, width: 800, height: 600))
    engine.updateWindows([a], displays: [display], frontmostWindowID: 42)

    // Dwell until A is focused.
    var t = 0.0
    var focused = false
    while t <= 0.6, !focused {
        focused = engine.ingest(gaze: CGPoint(x: 400, y: 300), at: t).contains { isFocus($0, .dwell) }
        t += 0.05
    }
    #expect(focused)

    // The pipeline reports the focus back; A is now frontmost.
    engine.notifyFocused(windowID: 1, at: t)

    let after = engine.ingest(gaze: CGPoint(x: 400, y: 300), at: t + 0.05)
    #expect(after.contains { isClearing($0) })
    #expect(!after.contains { isFocus($0) })
}

/// Moving the gaze from the frontmost window to another window highlights that
/// window and its dwell progress grows.
@Test func movingFromFrontmostHighlightsOtherWindowWithProgress() {
    var settings = AppSettings()
    settings.dwellSeconds = 0.4
    settings.cooldownSeconds = 0.2
    let engine = FocusEngine(settings: settings)
    let a = win(1, CGRect(x: 0, y: 0, width: 800, height: 600))
    let b = win(2, CGRect(x: 1000, y: 0, width: 800, height: 600))
    engine.updateWindows([a, b], displays: [display], frontmostWindowID: 1)

    // Look at the frontmost window A for a while: the border stays cleared.
    var t = 0.0
    while t <= 0.5 {
        _ = engine.ingest(gaze: CGPoint(x: 400, y: 300), at: t)
        t += 0.05
    }

    // Sweep to B: it is highlighted and its progress grows toward the dwell.
    var sawB = false
    var maxProgress = 0.0
    while t <= 0.7 {
        for action in engine.ingest(gaze: CGPoint(x: 1400, y: 300), at: t) {
            if case .highlight(let w, let p) = action, w?.id == 2 {
                sawB = true
                maxProgress = max(maxProgress, p)
            }
        }
        t += 0.05
    }
    #expect(sawB)
    #expect(maxProgress > 0)
}

/// `reset()` forgets a half-finished dwell, so resuming after focus handling
/// was suspended does not fire from a stale start timestamp.
@Test func resetClearsInProgressDwell() {
    var settings = AppSettings()
    settings.dwellSeconds = 1.0
    let engine = FocusEngine(settings: settings)
    let a = win(1, CGRect(x: 0, y: 0, width: 800, height: 600))
    engine.updateWindows([a], displays: [display], frontmostWindowID: 42)

    // Accumulate most of the dwell.
    for t in stride(from: 0.0, through: 0.8, by: 0.1) {
        _ = engine.ingest(gaze: CGPoint(x: 400, y: 300), at: t)
    }
    engine.reset()

    // After a long pause the first frame restarts the dwell (no instant fire).
    let actions = engine.ingest(gaze: CGPoint(x: 400, y: 300), at: 12.0)
    #expect(!actions.contains { isFocus($0) })
    let progress = actions.compactMap { action -> Double? in
        if case .highlight(let w, let p) = action, w?.id == 1 { return p }
        return nil
    }.first
    #expect(progress == 0.0)
}

// MARK: - Manual input wins over gaze (SPEC 3.8, round 5)

/// The side-by-side scenario from the user report: two windows A|B, the gaze
/// rests on A while the user keeps using the mouse (window B). Manual input is
/// continuously active, so A must never focus and the highlight stays cleared.
@Test func manualInputSuppressesDwellFocus() {
    var settings = AppSettings()
    settings.dwellSeconds = 0.3
    settings.cooldownSeconds = 0.2
    let engine = FocusEngine(settings: settings)
    let a = win(1, CGRect(x: 0, y: 0, width: 800, height: 600))
    let b = win(2, CGRect(x: 1000, y: 0, width: 800, height: 600))
    engine.updateWindows([a, b], displays: [display], frontmostWindowID: 42)

    var actions: [FocusAction] = []
    var t = 0.0
    while t <= 3.0 {
        actions += engine.ingest(gaze: CGPoint(x: 400, y: 300), at: t, secondsSinceManualInput: 0.1)
        t += 0.05
    }
    #expect(!actions.contains { isFocus($0) })
    // No highlight ever carries a window while manual input is active.
    let highlightsWindow = actions.contains { action in
        if case .highlight(let w, _) = action { return w != nil }
        return false
    }
    #expect(!highlightsWindow)
}

/// Once the user stops, dwell restarts from zero and only fires after a full
/// `dwellSeconds` measured from the moment input became quiet.
@Test func dwellRestartsAfterManualInputStops() {
    var settings = AppSettings()
    settings.dwellSeconds = 0.5
    settings.cooldownSeconds = 0.2
    settings.manualInputQuietSeconds = 1.5
    let engine = FocusEngine(settings: settings)
    let a = win(1, CGRect(x: 0, y: 0, width: 800, height: 600))
    engine.updateWindows([a], displays: [display], frontmostWindowID: 42)

    // Input stays "active" (0.1 s ago) up to and including t = 1.0.
    var t = 0.0
    while t <= 1.0 {
        _ = engine.ingest(gaze: CGPoint(x: 400, y: 300), at: t, secondsSinceManualInput: 0.1)
        t += 0.05
    }

    // First quiet frame: 1.05 (input is now 1.6 s old, past the 1.5 s threshold).
    let quietMoment = t
    var firedAt: TimeInterval?
    while t <= 2.0, firedAt == nil {
        let fired = engine.ingest(gaze: CGPoint(x: 400, y: 300), at: t, secondsSinceManualInput: 1.6)
            .contains { isFocus($0, .dwell) }
        if fired { firedAt = t }
        t += 0.05
    }
    #expect(firedAt != nil)
    // A full dwell after the quiet moment — progress could not be inherited.
    if let firedAt {
        #expect(firedAt >= quietMoment + settings.dwellSeconds - 0.001)
    }
}

/// A nod that completes while manual input is active must not focus.
@Test func nodDuringManualInputDoesNotFocus() {
    var settings = AppSettings()
    settings.triggerMode = .dwellOrNod
    settings.cooldownSeconds = 0.2
    let engine = FocusEngine(settings: settings)
    let a = win(1, CGRect(x: 0, y: 0, width: 800, height: 600))
    let b = win(2, CGRect(x: 1000, y: 0, width: 800, height: 600))
    engine.updateWindows([a, b], displays: [display], frontmostWindowID: 42)

    // Gaze history exists (looking at A), but manual input is active throughout.
    for t in stride(from: 0.70, through: 1.20, by: 0.05) {
        _ = engine.ingest(gaze: CGPoint(x: 400, y: 300), at: t, secondsSinceManualInput: 0.2)
    }
    let actions = engine.ingest(nod: NodEvent(startTimestamp: 1.0, endTimestamp: 1.2))
    #expect(!actions.contains { isFocus($0) })
}

/// The quiet threshold is exclusive: at exactly `manualInputQuietSeconds`
/// manual input is no longer active and dwell works normally, just below it
/// focus is paused.
@Test func manualInputQuietThresholdBoundary() {
    var settings = AppSettings()
    settings.dwellSeconds = 0.3
    settings.cooldownSeconds = 0.2
    settings.manualInputQuietSeconds = 1.5
    let a = win(1, CGRect(x: 0, y: 0, width: 800, height: 600))

    // Exactly at the threshold: not paused -> dwell fires.
    let atThreshold = FocusEngine(settings: settings)
    atThreshold.updateWindows([a], displays: [display], frontmostWindowID: 42)
    var resumed: [FocusAction] = []
    var t = 0.0
    while t <= 0.4 {
        resumed += atThreshold.ingest(gaze: CGPoint(x: 400, y: 300), at: t, secondsSinceManualInput: 1.5)
        t += 0.05
    }
    #expect(resumed.contains { isFocus($0, .dwell) })

    // Just below the threshold: paused -> no focus.
    let belowThreshold = FocusEngine(settings: settings)
    belowThreshold.updateWindows([a], displays: [display], frontmostWindowID: 42)
    var paused: [FocusAction] = []
    t = 0.0
    while t <= 0.4 {
        paused += belowThreshold.ingest(gaze: CGPoint(x: 400, y: 300), at: t, secondsSinceManualInput: 1.49)
        t += 0.05
    }
    #expect(!paused.contains { isFocus($0) })
}

// MARK: - Tracking reliability (SPEC 3.10)

/// While tracking is unreliable the engine clears the highlight and forgets any
/// half-finished dwell, so the glitch cannot fire focus and progress restarts
/// from zero once tracking is trusted again.
@Test func unreliableIngestClearsHighlightAndResetsDwell() {
    var settings = AppSettings()
    settings.dwellSeconds = 0.5
    settings.cooldownSeconds = 0.2
    let engine = FocusEngine(settings: settings)
    let a = win(1, CGRect(x: 0, y: 0, width: 800, height: 600))
    engine.updateWindows([a], displays: [display], frontmostWindowID: 42)

    // Accumulate most of the dwell on A.
    var t = 0.0
    while t <= 0.4 {
        _ = engine.ingest(gaze: CGPoint(x: 400, y: 300), at: t)
        t += 0.05
    }

    // An unreliable frame clears the highlight and never focuses.
    let cleared = engine.ingest(unreliableAt: t)
    #expect(cleared.contains { isClearing($0) })
    #expect(!cleared.contains { isFocus($0) })

    // The dwell restarts from zero: the next gaze frame reports fresh progress
    // and does not fire from the pre-glitch start timestamp.
    let next = engine.ingest(gaze: CGPoint(x: 400, y: 300), at: t + 0.05)
    let progress = next.compactMap { action -> Double? in
        if case .highlight(let w, let p) = action, w?.id == 1 { return p }
        return nil
    }.first
    #expect(progress == 0.0)
    #expect(!next.contains { isFocus($0) })
}
