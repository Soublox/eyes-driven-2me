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

    init() {
        let loaded = Storage.loadSettings()
        settings = loaded

        overlay = OverlayController()
        pipeline = GazePipeline(settings: loaded)
        calibration = CalibrationController(pipeline: pipeline)

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
        calibration.start()
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
