import Foundation

/// User-facing settings, persisted as JSON (SPEC 3.9).
///
/// Decoding tolerates missing keys (each falls back to its default) and clamps
/// values into range so old or corrupt files never break the app.
public struct AppSettings: Codable, Equatable, Sendable {
    /// Master on/off switch.
    public var isEnabled: Bool
    /// Which trigger(s) activate focus.
    public var triggerMode: TriggerMode
    /// Dwell duration in seconds (clamped to `dwellSecondsRange`).
    public var dwellSeconds: Double
    /// Warp the mouse cursor to the focused window center.
    public var moveCursorToFocusedWindow: Bool
    /// Nod sensitivity in `0...1` (clamped); maps to nod amplitude.
    public var nodSensitivity: Double
    /// Cooldown after a focus, seconds.
    public var cooldownSeconds: Double
    /// Draw a highlight around the current target window.
    public var showTargetHighlight: Bool
    /// Draw the debug gaze dot.
    public var showGazeDot: Bool
    /// Play system sounds during calibration (ticks, start, target appear).
    public var calibrationSounds: Bool
    /// Preferred camera device unique id, or nil for the default camera.
    public var cameraUniqueID: String?
    /// Whether the global hotkey is registered.
    public var hotKeyEnabled: Bool
    /// Pause gaze focus while the mouse is being used (SPEC 3.9).
    public var pauseOnMouseActivity: Bool
    /// Pause gaze focus while typing (SPEC 3.9).
    public var pauseOnKeyboardActivity: Bool
    /// Seconds of no manual input before focus resumes (clamped to `manualInputQuietSecondsRange`).
    public var manualInputQuietSeconds: Double
    /// Pause focusing while a hand covers the face or tracking is unstable (SPEC 3.10).
    public var pauseWhenFaceCovered: Bool

    /// Allowed range for `dwellSeconds`.
    public static let dwellSecondsRange: ClosedRange<Double> = 0.3...5.0
    /// Allowed range for `nodSensitivity`.
    public static let nodSensitivityRange: ClosedRange<Double> = 0.0...1.0
    /// Allowed range for `manualInputQuietSeconds`.
    public static let manualInputQuietSecondsRange: ClosedRange<Double> = 0.3...5.0

    public init(
        isEnabled: Bool = true,
        triggerMode: TriggerMode = .dwellOrNod,
        dwellSeconds: Double = 1.2,
        moveCursorToFocusedWindow: Bool = false,
        nodSensitivity: Double = 0.5,
        cooldownSeconds: Double = 0.8,
        showTargetHighlight: Bool = true,
        showGazeDot: Bool = false,
        calibrationSounds: Bool = true,
        cameraUniqueID: String? = nil,
        hotKeyEnabled: Bool = true,
        pauseOnMouseActivity: Bool = true,
        pauseOnKeyboardActivity: Bool = true,
        manualInputQuietSeconds: Double = 1.5,
        pauseWhenFaceCovered: Bool = true
    ) {
        self.isEnabled = isEnabled
        self.triggerMode = triggerMode
        self.dwellSeconds = dwellSeconds
        self.moveCursorToFocusedWindow = moveCursorToFocusedWindow
        self.nodSensitivity = nodSensitivity
        self.cooldownSeconds = cooldownSeconds
        self.showTargetHighlight = showTargetHighlight
        self.showGazeDot = showGazeDot
        self.calibrationSounds = calibrationSounds
        self.cameraUniqueID = cameraUniqueID
        self.hotKeyEnabled = hotKeyEnabled
        self.pauseOnMouseActivity = pauseOnMouseActivity
        self.pauseOnKeyboardActivity = pauseOnKeyboardActivity
        self.manualInputQuietSeconds = manualInputQuietSeconds
        self.pauseWhenFaceCovered = pauseWhenFaceCovered
        clamp()
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled
        case triggerMode
        case dwellSeconds
        case moveCursorToFocusedWindow
        case nodSensitivity
        case cooldownSeconds
        case showTargetHighlight
        case showGazeDot
        case calibrationSounds
        case cameraUniqueID
        case hotKeyEnabled
        case pauseOnMouseActivity
        case pauseOnKeyboardActivity
        case manualInputQuietSeconds
        case pauseWhenFaceCovered
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        triggerMode = try c.decodeIfPresent(TriggerMode.self, forKey: .triggerMode) ?? .dwellOrNod
        dwellSeconds = try c.decodeIfPresent(Double.self, forKey: .dwellSeconds) ?? 1.2
        moveCursorToFocusedWindow = try c.decodeIfPresent(Bool.self, forKey: .moveCursorToFocusedWindow) ?? false
        nodSensitivity = try c.decodeIfPresent(Double.self, forKey: .nodSensitivity) ?? 0.5
        cooldownSeconds = try c.decodeIfPresent(Double.self, forKey: .cooldownSeconds) ?? 0.8
        showTargetHighlight = try c.decodeIfPresent(Bool.self, forKey: .showTargetHighlight) ?? true
        showGazeDot = try c.decodeIfPresent(Bool.self, forKey: .showGazeDot) ?? false
        calibrationSounds = try c.decodeIfPresent(Bool.self, forKey: .calibrationSounds) ?? true
        cameraUniqueID = try c.decodeIfPresent(String.self, forKey: .cameraUniqueID)
        hotKeyEnabled = try c.decodeIfPresent(Bool.self, forKey: .hotKeyEnabled) ?? true
        pauseOnMouseActivity = try c.decodeIfPresent(Bool.self, forKey: .pauseOnMouseActivity) ?? true
        pauseOnKeyboardActivity = try c.decodeIfPresent(Bool.self, forKey: .pauseOnKeyboardActivity) ?? true
        manualInputQuietSeconds = try c.decodeIfPresent(Double.self, forKey: .manualInputQuietSeconds) ?? 1.5
        pauseWhenFaceCovered = try c.decodeIfPresent(Bool.self, forKey: .pauseWhenFaceCovered) ?? true
        clamp()
    }

    private mutating func clamp() {
        dwellSeconds = min(
            max(dwellSeconds, AppSettings.dwellSecondsRange.lowerBound),
            AppSettings.dwellSecondsRange.upperBound
        )
        nodSensitivity = min(
            max(nodSensitivity, AppSettings.nodSensitivityRange.lowerBound),
            AppSettings.nodSensitivityRange.upperBound
        )
        manualInputQuietSeconds = min(
            max(manualInputQuietSeconds, AppSettings.manualInputQuietSecondsRange.lowerBound),
            AppSettings.manualInputQuietSecondsRange.upperBound
        )
    }
}
