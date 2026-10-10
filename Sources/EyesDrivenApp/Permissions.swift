import AVFoundation
import ApplicationServices
import AppKit
import Foundation

/// System permission helpers: camera access and the Accessibility API.
enum Permissions {

    /// Current camera authorization status for this process.
    static var cameraStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    /// Human-readable camera status, for diagnostics.
    static func cameraStatusDescription() -> String {
        switch cameraStatus {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not determined"
        @unknown default: return "unknown"
        }
    }

    /// Requests camera access, returning whether it was granted.
    static func requestCamera() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    /// Whether this process is trusted for the Accessibility API. When `prompt`
    /// is `true` and the process is not yet trusted, macOS shows the system
    /// prompt pointing at System Settings.
    static func accessibilityGranted(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Opens System Settings ▸ Privacy & Security ▸ Camera.
    static func openCameraSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")
    }

    /// Opens System Settings ▸ Privacy & Security ▸ Accessibility.
    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    private static func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
