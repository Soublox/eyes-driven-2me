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
