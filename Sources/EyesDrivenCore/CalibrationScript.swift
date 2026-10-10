import Foundation

/// Pure selection of the spoken guidance lines for the calibration flow (SPEC 4).
///
/// This type only decides *which* line to speak and with which values: it
/// returns localization keys plus the small arguments the format strings need
/// (a 1-based screen number and a position-phrase key). It never localizes and
/// never touches AppKit or a speech engine, so the decisions are deterministic
/// and unit-testable. The app layer maps the keys to `Localizable.strings` and
/// hands the resulting text to `VoiceGuide`.
public enum CalibrationScript {

    /// Where a display sits in the left-to-right display order.
    public enum Position: String, Equatable, Sendable {
        /// The only connected display.
        case only
        case left
        case center
        case right

        /// Localization key of the spoken position phrase (plain text, no
        /// leading conjunction).
        public var key: String { "voice.position.\(rawValue)" }
    }

    /// One spoken line: a localization key plus the values its format string
    /// needs (`%d` screen number, `%@` position phrase).
    public struct Line: Equatable, Sendable {
        /// Localization key of the line, e.g. `voice.start`.
        public let key: String
        /// 1-based screen number for the `%d` argument, when the line has one.
        public let screen: Int?
        /// Localization key of the position phrase for the `%@` argument.
        public let positionKey: String?

        public init(key: String, screen: Int? = nil, positionKey: String? = nil) {
            self.key = key
            self.screen = screen
            self.positionKey = positionKey
        }
    }

    /// Mean-error good threshold in points: below this the result is `.good`
    /// (same value the result panel uses).
    public static let goodErrorThreshold = 150.0
    /// Mean-error ok threshold in points: below this the result is `.ok`.
    public static let okErrorThreshold = 350.0

    /// Position of a display in the left-to-right order.
    ///
    /// `displayIndex` is 0-based and `count` is the number of displays. A single
    /// display is `.only`; with several, the leftmost is `.left`, the rightmost
    /// is `.right` and everything in between is `.center`.
    public static func position(displayIndex: Int, count: Int) -> Position {
        guard count > 1 else { return .only }
        if displayIndex <= 0 { return .left }
        if displayIndex >= count - 1 { return .right }
        return .center
    }

    /// Localization key of the position phrase for a display.
    public static func positionKey(displayIndex: Int, count: Int) -> String {
        position(displayIndex: displayIndex, count: count).key
    }

    /// The opening line, naming screen 1 and its position. With a single display
    /// it is the position-free `voice.start.single` line.
    public static func startLine(displayCount: Int) -> Line {
        guard displayCount > 1 else {
            return Line(key: "voice.start.single")
        }
        return Line(
            key: "voice.start",
            screen: 1,
            positionKey: positionKey(displayIndex: 0, count: displayCount)
        )
    }

    /// The per-screen line spoken before a display's 3·2·1 countdown.
    public static func nextScreenLine(displayIndex: Int, count: Int) -> Line {
        Line(
            key: "voice.nextScreen",
            screen: displayIndex + 1,
            positionKey: positionKey(displayIndex: displayIndex, count: count)
        )
    }

    /// Whether to announce "almost done" now: exactly two targets remain and the
    /// line has not been spoken yet this session.
    public static func shouldAnnounceAlmostDone(remaining: Int, alreadyAnnounced: Bool) -> Bool {
        remaining == 2 && !alreadyAnnounced
    }

    /// Localization key of the closing line for a mean error in points, or nil
    /// when there is no error to report (the fit failed — nothing is spoken).
    public static func finishedKey(errorPoints: Double?) -> String? {
        guard let errorPoints else { return nil }
        if errorPoints < goodErrorThreshold { return "voice.finished.good" }
        if errorPoints < okErrorThreshold { return "voice.finished.ok" }
        return "voice.finished.poor"
    }
}
