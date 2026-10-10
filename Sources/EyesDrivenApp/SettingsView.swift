import EyesDrivenCore
import SwiftUI

/// Settings form shown in the app's `Window` scene (SPEC 4).
///
/// Every change persists immediately through `Storage` and applies live (the
/// pipeline, the overlay and the hotkey are updated by `AppModel.updateSettings`).
struct SettingsView: View {
    @ObservedObject var model: AppModel

    @State private var cameras: [CameraDevice] = []

    var body: some View {
        Form {
            Section("Trigger") {
                Picker("Mode", selection: triggerModeBinding) {
                    Text("Dwell").tag(TriggerMode.dwell)
                    Text("Nod").tag(TriggerMode.nod)
                    Text("Dwell or Nod").tag(TriggerMode.dwellOrNod)
                }
                .pickerStyle(.segmented)

                sliderRow(
                    "Dwell",
                    value: dwellBinding,
                    range: AppSettings.dwellSecondsRange,
                    display: String(format: "%.1f s", model.settings.dwellSeconds)
                )
                sliderRow(
                    "Nod sensitivity",
                    value: nodSensitivityBinding,
                    range: AppSettings.nodSensitivityRange,
                    display: String(format: "%.2f", model.settings.nodSensitivity)
                )
                sliderRow(
                    "Cooldown",
                    value: cooldownBinding,
                    range: 0.3...3.0,
                    display: String(format: "%.1f s", model.settings.cooldownSeconds)
                )
            }

            Section("Feedback") {
                Toggle("Highlight target window", isOn: highlightBinding)
                Toggle("Show gaze dot", isOn: gazeDotBinding)
                Toggle("Move cursor to focused window", isOn: moveCursorBinding)
            }

            Section("Camera") {
                Picker("Camera", selection: cameraBinding) {
                    Text("Default (built-in)").tag("")
                    ForEach(cameras) { device in
                        Text(device.name).tag(device.uniqueID)
                    }
                    if let current = model.settings.cameraUniqueID, !cameras.contains(where: { $0.uniqueID == current }) {
                        Text("Current camera").tag(current)
                    }
                }
                Toggle("Global hotkey (⌃⌥⌘E)", isOn: hotKeyBinding)
            }

            Section("Calibration") {
                calibrationInfo
                Toggle("Calibration sounds", isOn: calibrationSoundsBinding)
                Button("Recalibrate…") {
                    model.startCalibration()
                }
                .disabled(model.calibration.isCalibrating)
            }

            Section {
                Text("All processing happens on this Mac. No frames are stored or sent.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 440, minHeight: 560)
        .onAppear {
            cameras = CameraCapture.availableCameras()
        }
    }

    // MARK: - Calibration info

    @ViewBuilder
    private var calibrationInfo: some View {
        if let info = model.calibrationInfo() {
            Text("Calibrated \(info.date.formatted(date: .abbreviated, time: .shortened))")
            Text(String(format: "Mean error: %.0f pt", info.error))
            if info.stale {
                Label("Display layout changed — recalibrate", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        } else {
            Text("Not calibrated yet.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Rows

    private func sliderRow(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        display: String
    ) -> some View {
        HStack {
            Text(title)
            Slider(value: value, in: range)
            Text(display)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
        }
    }

    // MARK: - Bindings

    private var triggerModeBinding: Binding<TriggerMode> {
        Binding(
            get: { model.settings.triggerMode },
            set: { value in model.updateSettings { $0.triggerMode = value } }
        )
    }

    private var dwellBinding: Binding<Double> {
        Binding(
            get: { model.settings.dwellSeconds },
            set: { value in model.updateSettings { $0.dwellSeconds = value } }
        )
    }

    private var nodSensitivityBinding: Binding<Double> {
        Binding(
            get: { model.settings.nodSensitivity },
            set: { value in model.updateSettings { $0.nodSensitivity = value } }
        )
    }

    private var cooldownBinding: Binding<Double> {
        Binding(
            get: { model.settings.cooldownSeconds },
            set: { value in model.updateSettings { $0.cooldownSeconds = value } }
        )
    }

    private var highlightBinding: Binding<Bool> {
        Binding(
            get: { model.settings.showTargetHighlight },
            set: { value in model.updateSettings { $0.showTargetHighlight = value } }
        )
    }

    private var gazeDotBinding: Binding<Bool> {
        Binding(
            get: { model.settings.showGazeDot },
            set: { value in model.updateSettings { $0.showGazeDot = value } }
        )
    }

    private var calibrationSoundsBinding: Binding<Bool> {
        Binding(
            get: { model.settings.calibrationSounds },
            set: { value in model.updateSettings { $0.calibrationSounds = value } }
        )
    }

    private var moveCursorBinding: Binding<Bool> {
        Binding(
            get: { model.settings.moveCursorToFocusedWindow },
            set: { value in model.updateSettings { $0.moveCursorToFocusedWindow = value } }
        )
    }

    private var hotKeyBinding: Binding<Bool> {
        Binding(
            get: { model.settings.hotKeyEnabled },
            set: { value in model.updateSettings { $0.hotKeyEnabled = value } }
        )
    }

    private var cameraBinding: Binding<String> {
        Binding(
            get: { model.settings.cameraUniqueID ?? "" },
            set: { value in model.updateSettings { $0.cameraUniqueID = value.isEmpty ? nil : value } }
        )
    }
}
