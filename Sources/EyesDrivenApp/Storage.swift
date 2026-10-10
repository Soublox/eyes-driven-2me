import EyesDrivenCore
import Foundation

/// Persistence for settings and the calibration profile (SPEC 4).
///
/// Settings live in `UserDefaults` under `settings.v1` as JSON; the calibration
/// profile is a JSON file in
/// `~/Library/Application Support/EyesDriven2me/calibration.json`, written
/// atomically. No camera frames are ever written; this is the only disk I/O.
enum Storage {

    /// `UserDefaults` key for the encoded `AppSettings`.
    static let settingsKey = "settings.v1"

    /// `UserDefaults` key remembering that the Accessibility prompt was shown.
    static let permissionsPromptedKey = "permissions.prompted.v1"

    // MARK: - Settings

    /// Load persisted settings, falling back to defaults when absent or corrupt.
    static func loadSettings() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: settingsKey) else {
            return AppSettings()
        }
        return (try? JSONDecoder().decode(AppSettings.self, from: data)) ?? AppSettings()
    }

    /// Persist settings immediately.
    static func saveSettings(_ settings: AppSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: settingsKey)
    }

    // MARK: - Permission prompt bookkeeping

    /// Whether the first-launch permission prompts have already been shown.
    static var hasPromptedPermissions: Bool {
        UserDefaults.standard.bool(forKey: permissionsPromptedKey)
    }

    /// Remember that the first-launch permission prompts have been shown.
    static func markPermissionsPrompted() {
        UserDefaults.standard.set(true, forKey: permissionsPromptedKey)
    }

    // MARK: - Calibration

    /// Location of the calibration file.
    static var calibrationURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("EyesDriven2me", isDirectory: true)
            .appendingPathComponent("calibration.json")
    }

    /// Load the saved calibration profile, if any.
    static func loadCalibration() -> CalibrationProfile? {
        guard let data = try? Data(contentsOf: calibrationURL) else { return nil }
        return try? decoder.decode(CalibrationProfile.self, from: data)
    }

    /// Save a calibration profile atomically, creating the directory if needed.
    /// - Returns: `true` when the file was written.
    @discardableResult
    static func saveCalibration(_ profile: CalibrationProfile) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: calibrationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(profile)
            try data.write(to: calibrationURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Delete the saved calibration, if any.
    static func clearCalibration() {
        try? FileManager.default.removeItem(at: calibrationURL)
    }

    /// A profile is stale when the display layout it was captured against no
    /// longer matches the connected displays (SPEC 4).
    static func isStale(_ profile: CalibrationProfile) -> Bool {
        profile.displayFingerprint != CalibrationProfile.fingerprint(for: WindowCatalog.displays())
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
