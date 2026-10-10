import Foundation
import Testing
@testable import EyesDrivenCore

@Test func decodingEmptyObjectGivesDefaults() throws {
    let decoded = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
    #expect(decoded == AppSettings())
    #expect(decoded.isEnabled == true)
    #expect(decoded.triggerMode == .dwellOrNod)
    #expect(decoded.dwellSeconds == 1.2)
    #expect(decoded.nodSensitivity == 0.5)
    #expect(decoded.cooldownSeconds == 0.8)
    #expect(decoded.cameraUniqueID == nil)
}

@Test func decodingMissingKeysFallsBackToDefaults() throws {
    let json = #"{"dwellSeconds": 2.5}"#
    let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
    #expect(decoded.dwellSeconds == 2.5)
    #expect(decoded.triggerMode == .dwellOrNod)
    #expect(decoded.hotKeyEnabled == true)
}

@Test func dwellSecondsIsClampedOnDecode() throws {
    let high = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"dwellSeconds": 99}"#.utf8))
    #expect(high.dwellSeconds == 5.0)
    let low = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"dwellSeconds": 0.1}"#.utf8))
    #expect(low.dwellSeconds == 0.3)
}

@Test func nodSensitivityIsClampedOnDecode() throws {
    let high = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"nodSensitivity": 5}"#.utf8))
    #expect(high.nodSensitivity == 1.0)
    let low = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"nodSensitivity": -3}"#.utf8))
    #expect(low.nodSensitivity == 0.0)
}

@Test func clampingAppliesOnInit() {
    let s = AppSettings(dwellSeconds: 100, nodSensitivity: -1)
    #expect(s.dwellSeconds == 5.0)
    #expect(s.nodSensitivity == 0.0)
}

@Test func calibrationSoundsDefaultsOnAndDecodesTolerantly() throws {
    // Default is on.
    #expect(AppSettings().calibrationSounds == true)

    // An old saved file without the key falls back to the default.
    let legacy = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
    #expect(legacy.calibrationSounds == true)

    // An explicit value is honored.
    let off = try JSONDecoder().decode(
        AppSettings.self,
        from: Data(#"{"calibrationSounds": false}"#.utf8)
    )
    #expect(off.calibrationSounds == false)
}

@Test func roundTrip() throws {
    var s = AppSettings()
    s.isEnabled = false
    s.triggerMode = .nod
    s.dwellSeconds = 2.0
    s.moveCursorToFocusedWindow = true
    s.nodSensitivity = 0.8
    s.cooldownSeconds = 1.5
    s.showTargetHighlight = false
    s.showGazeDot = true
    s.calibrationSounds = false
    s.cameraUniqueID = "abc-123"
    s.hotKeyEnabled = false

    let data = try JSONEncoder().encode(s)
    let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
    #expect(decoded == s)
}
