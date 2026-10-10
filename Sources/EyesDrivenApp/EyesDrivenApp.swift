import AppKit
import Combine
import EyesDrivenCore
import SwiftUI

/// The app object graph. Owns the persisted settings, the gaze pipeline, the
/// overlay, the calibration controller and the global hotkey, and persists
/// settings through `Storage`.
@MainActor
final class AppModel: ObservableObject {

    /// Current settings. Mutate through `updateSettings(_:)` so changes persist
    /// and apply live.
    @Published private(set) var settings: AppSettings

    /// Camera → tracker → model → filter → focus engine glue.
    let pipeline: GazePipeline
    /// Per-screen highlight / gaze-dot overlay.
    let overlay: OverlayController
    /// Per-display calibration session.
    let calibration: CalibrationController

    private var hotKey: HotKey?
    /// Previous `showGazeDot` value while the 15 s gaze test is showing the dot.
    private var gazeDotTestRestore: Bool?
    /// Repeating timer that updates the test-mode countdown label.
    private var gazeDotTestTimer: Timer?
    /// When the running gaze test ends.
    private var gazeDotTestEnd: Date?

    /// Length of the gaze-dot test, in seconds.
    static let gazeDotTestSeconds = 15

    init() {
        let loaded = Storage.loadSettings()
        settings = loaded

        overlay = OverlayController()
        pipeline = GazePipeline(settings: loaded)
        calibration = CalibrationController(pipeline: pipeline)
        calibration.soundsEnabled = loaded.calibrationSounds
        calibration.voiceEnabled = loaded.calibrationVoice
        calibration.onRecalibrate = { [weak self] in self?.startCalibration() }
        calibration.onTest = { [weak self] in self?.startGazeDotTest() }

        pipeline.overlay = overlay
        overlay.apply(settings: loaded)
        overlay.setVisible(loaded.isEnabled)
        calibration.onEnd = { [weak self] in
            guard let self else { return }
            self.overlay.setVisible(self.settings.isEnabled)
        }

        // Menu-bar app: no Dock icon, no main window.
        NSApplication.shared.setActivationPolicy(.accessory)

        requestPermissionsIfNeeded()
        pipeline.reloadCalibration()
        pipeline.applySettings(loaded)
        applyHotKey()
    }

    // MARK: - Settings

    /// Mutate, persist and apply settings in one step.
    func updateSettings(_ mutate: (inout AppSettings) -> Void) {
        var updated = settings
        mutate(&updated)
        guard updated != settings else { return }

        let hotKeyChanged = updated.hotKeyEnabled != settings.hotKeyEnabled
        settings = updated

        Storage.saveSettings(updated)
        pipeline.applySettings(updated)
        overlay.apply(settings: updated)
        if !calibration.isCalibrating {
            overlay.setVisible(updated.isEnabled)
        }
        if hotKeyChanged {
            applyHotKey()
        }
    }

    /// Toggle the master switch (used by the global hotkey).
    func toggleEnabled() {
        updateSettings { $0.isEnabled.toggle() }
    }

    // MARK: - Calibration

    /// Hide the overlay and start a calibration session.
    func startCalibration() {
        overlay.setVisible(false)
        overlay.update(target: nil, progress: 0)
        overlay.update(gaze: nil)
        calibration.soundsEnabled = settings.calibrationSounds
        calibration.voiceEnabled = settings.calibrationVoice
        calibration.start()
    }

    /// Show the large, high-contrast test gaze dot for 15 seconds with a
    /// countdown label on the display the gaze point is on, then restore the
    /// previous `showGazeDot` value. Used by the result panel's Test button and
    /// by the menu bar's "Test gaze" item.
    func startGazeDotTest() {
        guard gazeDotTestRestore == nil else { return }
        guard calibrationInfo() != nil else { return }

        gazeDotTestRestore = settings.showGazeDot

        // Ensure the camera runs and the overlay is visible so the test is
        // unmistakable, even when tracking is paused.
        updateSettings { $0.showGazeDot = true }
        pipeline.beginGazeDotTest()
        overlay.setVisible(true)
        overlay.setGazeDotTest(active: true, label: testLabel(seconds: Self.gazeDotTestSeconds))

        gazeDotTestEnd = Date().addingTimeInterval(TimeInterval(Self.gazeDotTestSeconds))
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.gazeDotTestTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        gazeDotTestTimer = timer
    }

    /// Advance the test countdown each second, ending the test at zero.
    private func gazeDotTestTick() {
        guard let end = gazeDotTestEnd, gazeDotTestRestore != nil else { return }
        let remaining = Int(ceil(end.timeIntervalSinceNow))
        if remaining <= 0 {
            endGazeDotTest()
        } else {
            overlay.setGazeDotTest(active: true, label: testLabel(seconds: remaining))
        }
    }

    /// Stop the test, remove the label and restore the previous dot setting.
    private func endGazeDotTest() {
        guard let previousDot = gazeDotTestRestore else { return }
        gazeDotTestRestore = nil
        gazeDotTestEnd = nil
        gazeDotTestTimer?.invalidate()
        gazeDotTestTimer = nil

        overlay.setGazeDotTest(active: false, label: nil)
        pipeline.endGazeDotTest()
        updateSettings { $0.showGazeDot = previousDot }
        overlay.setVisible(settings.isEnabled)
    }

    /// The floating test-mode label text for `seconds` remaining.
    private func testLabel(seconds: Int) -> String {
        "Test mode · \(seconds) s — look around; the dot should follow your eyes"
    }

    /// Date, mean error and staleness of the saved calibration, if any.
    func calibrationInfo() -> (date: Date, error: Double, stale: Bool)? {
        guard let profile = Storage.loadCalibration() else { return nil }
        return (
            profile.createdAt,
            profile.model.meanError(on: profile.samples),
            Storage.isStale(profile)
        )
    }

    // MARK: - Hotkey

    private func applyHotKey() {
        if settings.hotKeyEnabled {
            if hotKey == nil {
                hotKey = HotKey.defaultToggle { [weak self] in
                    self?.toggleEnabled()
                }
            }
        } else {
            hotKey = nil
        }
    }

    // MARK: - Permissions

    private func requestPermissionsIfNeeded() {
        if Permissions.cameraStatus == .notDetermined {
            Task { [weak self] in
                _ = await Permissions.requestCamera()
                self?.pipeline.refreshPermissions()
            }
        }
        if !WindowFocuser.isTrusted(), !Storage.hasPromptedPermissions {
            Storage.markPermissionsPrompted()
            _ = Permissions.accessibilityGranted(prompt: true)
        }
    }
}

/// SwiftUI application: a menu-bar extra plus a settings window.
///
/// Deliberately **without `@main`**: `main.swift` owns the entry point and calls
/// `EyesDrivenApp.main()`, so the executable can also expose the diagnostic CLI.
struct EyesDrivenApp: App {

    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            Image(systemName: model.settings.isEnabled ? "eye" : "eye.slash")
        }
        .menuBarExtraStyle(.menu)

        Window("Eyes Driven 2me Settings", id: "settings") {
            SettingsView(model: model)
        }
    }
}
