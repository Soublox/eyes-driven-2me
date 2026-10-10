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
    // Highlight may be emitted (frontmost target with progress 0) but never
    // with a nonzero progress ring.
    #expect(progressValues.allSatisfy { $0 == 0 })
    #expect(actions.contains { isHighlight($0) })
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
