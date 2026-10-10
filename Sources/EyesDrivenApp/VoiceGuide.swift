import AVFoundation
import EyesDrivenCore
import Foundation

/// A localized line of speech, ready to be synthesized.
struct VoiceLine: Equatable {
    /// The text to speak.
    let text: String
}

/// Turns `CalibrationScript` keys (and the fixed guidance keys) into localized
/// `VoiceLine`s.
///
/// Every key is looked up in `Localizable.strings` with the English text passed
/// as the `value:` fallback, so the bare `swift run` binary — which carries no
/// bundle resources — still speaks English. Portuguese lives only in
/// `Resources/pt-BR.lproj/Localizable.strings`.
enum VoiceScript {

    /// The opening line for the given number of displays (names screen 1).
    static func start(displayCount: Int) -> VoiceLine {
        line(CalibrationScript.startLine(displayCount: displayCount))
    }

    /// The per-screen line spoken before a display's countdown.
    static func nextScreen(displayIndex: Int, count: Int) -> VoiceLine {
        line(CalibrationScript.nextScreenLine(displayIndex: displayIndex, count: count))
    }

    /// "We're almost done, just two more."
    static var almostDone: VoiceLine {
        VoiceLine(text: string("voice.almostDone", "We're almost done, just two more."))
    }

    /// The closing line for a mean error in points, or nil when the fit failed
    /// (nothing is spoken).
    static func finished(errorPoints: Double?) -> VoiceLine? {
        guard let key = CalibrationScript.finishedKey(errorPoints: errorPoints) else { return nil }
        switch key {
        case "voice.finished.ok":
            return VoiceLine(text: string(key, "Finished. Your calibration is okay."))
        case "voice.finished.poor":
            return VoiceLine(text: string(
                key,
                "Finished. Your calibration is poor. Try better lighting and run it again."
            ))
        default:
            return VoiceLine(text: string(key, "Finished. Your calibration is good."))
        }
    }

    /// "Keep your hands away from your face."
    static var hands: VoiceLine {
        VoiceLine(text: string("voice.hands", "Keep your hands away from your face."))
    }

    /// "Paused."
    static var paused: VoiceLine {
        VoiceLine(text: string("voice.paused", "Paused."))
    }

    /// "Resuming."
    static var resumed: VoiceLine {
        VoiceLine(text: string("voice.resumed", "Resuming."))
    }

    /// "Calibration cancelled."
    static var cancelled: VoiceLine {
        VoiceLine(text: string("voice.cancelled", "Calibration cancelled."))
    }

    // MARK: - Helpers

    private static func line(_ line: CalibrationScript.Line) -> VoiceLine {
        switch line.key {
        case "voice.start.single":
            return VoiceLine(text: string(line.key, "Let's start. Follow the dots on the screen."))
        case "voice.nextScreen":
            return VoiceLine(text: formatted(line.key, "Now look at screen %d, %@.", line))
        default: // voice.start
            return VoiceLine(text: formatted(
                "voice.start",
                "Let's start. Look at screen %d, %@, and follow the dots.",
                line
            ))
        }
    }

    private static func formatted(_ key: String, _ english: String, _ line: CalibrationScript.Line) -> String {
        String(format: string(key, english), line.screen ?? 1, positionPhrase(line.positionKey))
    }

    private static func positionPhrase(_ key: String?) -> String {
        switch key {
        case "voice.position.left": return string("voice.position.left", "on the left")
        case "voice.position.center": return string("voice.position.center", "in the center")
        case "voice.position.right": return string("voice.position.right", "on the right")
        default: return string("voice.position.only", "")
        }
    }

    /// `NSLocalizedString` with the English text as the in-code fallback.
    private static func string(_ key: String, _ english: String) -> String {
        NSLocalizedString(key, tableName: nil, bundle: .main, value: english, comment: "")
    }
}

/// Speaks the calibration guidance through the on-device `AVSpeechSynthesizer`
/// (no network). The voice and rate follow the app's active localization.
///
/// Use from the main thread; the completion handlers also run on the main
/// thread (the synthesizer delivers its delegate callbacks on the main queue).
///
/// `AVSpeechSynthesizerDelegate` is a `Sendable` protocol and
/// `AVSpeechSynthesizer` is not `Sendable`, so the conformance is `@unchecked`:
/// every access happens on the main thread.
final class VoiceGuide: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {

    private let synthesizer = AVSpeechSynthesizer()
    private let voice: AVSpeechSynthesisVoice?
    private let rate: Float
    private var current: AVSpeechUtterance?
    private var completion: (() -> Void)?

    /// Whether a line is currently being spoken.
    var isSpeaking: Bool { synthesizer.isSpeaking }

    override init() {
        voice = VoiceGuide.resolveVoice()
        // A touch slower than the system default reads more clearly.
        rate = AVSpeechUtteranceDefaultSpeechRate * 0.92
        super.init()
        synthesizer.delegate = self
    }

    /// Speak `line`. `completion` runs when the line finishes naturally; it is
    /// *not* called when the line is cancelled (by `stop()` or by a new `speak`).
    func speak(_ line: VoiceLine, completion: (() -> Void)? = nil) {
        stop()
        let utterance = AVSpeechUtterance(string: line.text)
        if let voice { utterance.voice = voice }
        utterance.rate = rate
        current = utterance
        self.completion = completion
        synthesizer.speak(utterance)
    }

    /// Stop any current line; its completion is not called.
    func stop() {
        current = nil
        completion = nil
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }

    // MARK: - AVSpeechSynthesizerDelegate

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        guard utterance === current else { return }
        let done = completion
        current = nil
        completion = nil
        done?()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        guard utterance === current else { return }
        current = nil
        completion = nil
    }

    // MARK: - Voice selection

    /// Pick a voice for the language of the localization in use: premium first,
    /// then enhanced, then the system default for that language.
    static func resolveVoice() -> AVSpeechSynthesisVoice? {
        let language = preferredLanguage()
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == language }
        return candidates.first { $0.quality == .premium }
            ?? candidates.first { $0.quality == .enhanced }
            ?? AVSpeechSynthesisVoice(language: language)
            ?? candidates.first
    }

    /// "pt-BR" when the app runs in Portuguese, otherwise "en-US".
    static func preferredLanguage() -> String {
        let preferred = Bundle.main.preferredLocalizations.first ?? "en"
        return preferred.lowercased().hasPrefix("pt") ? "pt-BR" : "en-US"
    }
}
