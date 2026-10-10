import AppKit
import EyesDrivenCore
import SwiftUI

/// Contents of the menu-bar extra (SPEC 4).
///
/// Rendered as a native menu (`MenuBarExtra` with `.menu` style): a status line,
/// the current target, the enabled toggle, trigger mode, display toggles,
/// calibrate/settings, permission fixes and quit.
struct MenuBarContent: View {
    @ObservedObject var model: AppModel

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(statusLine)

        if let target = model.pipeline.currentTargetName, model.settings.isEnabled {
            Text("Target: \(target)")
        }

        Divider()

        Toggle("Enabled (⌃⌥⌘E)", isOn: Binding(
            get: { model.settings.isEnabled },
            set: { value in model.updateSettings { $0.isEnabled = value } }
        ))

        Picker("Trigger", selection: Binding(
            get: { model.settings.triggerMode },
            set: { value in model.updateSettings { $0.triggerMode = value } }
        )) {
            Text("Dwell").tag(TriggerMode.dwell)
            Text("Nod").tag(TriggerMode.nod)
            Text("Dwell or Nod").tag(TriggerMode.dwellOrNod)
        }

        Toggle("Show gaze dot", isOn: Binding(
            get: { model.settings.showGazeDot },
            set: { value in model.updateSettings { $0.showGazeDot = value } }
        ))

        Toggle("Move cursor to focused window", isOn: Binding(
            get: { model.settings.moveCursorToFocusedWindow },
            set: { value in model.updateSettings { $0.moveCursorToFocusedWindow = value } }
        ))

        Divider()

        Button("Calibrate…") {
            model.startCalibration()
        }
        .disabled(model.calibration.isCalibrating)

        Button("Test gaze") {
            model.startGazeDotTest()
        }
        .disabled(model.pipeline.calibrationState == .missing)

        Button("Settings…") {
            openWindow(id: "settings")
            WindowActivation.activateAndRaise(titled: "Eyes Driven 2me Settings")
        }

        if model.pipeline.permissionProblem.contains(.camera) {
            Button("Grant Camera Access…") {
                Permissions.openCameraSettings()
            }
        }
        if model.pipeline.permissionProblem.contains(.accessibility) {
            Button("Grant Accessibility Access…") {
                Permissions.openAccessibilitySettings()
            }
        }

        Divider()

        Button("Quit Eyes Driven 2me") {
            NSApplication.shared.terminate(nil)
        }
    }

    /// One-line status for the top of the menu.
    private var statusLine: String {
        let pipeline = model.pipeline

        if pipeline.permissionProblem.contains(.camera) {
            return "Camera access needed"
        }
        if !model.settings.isEnabled {
            return "Paused"
        }
        if pipeline.manualInputActive {
            return "Paused · mouse/keyboard in use"
        }
        switch pipeline.calibrationState {
        case .missing:
            return "Calibration needed"
        case .stale:
            return "Calibration stale — recalibrate"
        case .ok:
            if let issue = pipeline.trackingIssue {
                return issue
            }
            guard pipeline.isRunning else { return "Starting…" }
            let face = pipeline.faceDetected ? "face ✓" : "no face"
            return "Tracking · \(Int(pipeline.fps.rounded())) fps · \(face)"
        }
    }
}
