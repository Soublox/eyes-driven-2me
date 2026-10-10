import Foundation

/// State produced by `DwellDetector` (SPEC 3.6).
public enum DwellState<ID: Hashable>: Equatable {
    /// Nothing is being watched for long enough to accumulate progress.
    case idle
    /// `target` has been watched for `fraction` of the required duration.
    case progressing(ID, Double)
    /// `target` completed the dwell and fired.
    case fired(ID)
}

/// Generic dwell detector: fires once when the same target stays observed for
/// `duration`; glitches shorter than `tolerance` do not reset progress
/// (SPEC 3.6).
public struct DwellDetector<ID: Hashable> {
    /// Time the same target must stay observed before firing (seconds).
    public var duration: TimeInterval
    /// Glitch tolerance for target changes (seconds).
    public var tolerance: TimeInterval

    private enum Observation: Equatable {
        case window(ID)
        case noTarget
    }

    private var current: Observation?
    private var currentStart: TimeInterval = 0
    private var firedTarget: ID?
    private var pending: Observation?
    private var pendingStart: TimeInterval = 0

    public init(duration: TimeInterval = 1.2, tolerance: TimeInterval = 0.15) {
        self.duration = duration
        self.tolerance = tolerance
    }

    /// Forget progress and history.
    public mutating func reset() {
        current = nil
        firedTarget = nil
        pending = nil
    }

    /// Observe `target` at `timestamp`. Returns the resulting state.
    @discardableResult
    public mutating func update(target: ID?, timestamp: TimeInterval) -> DwellState<ID> {
        let observation: Observation = target.map { Observation.window($0) } ?? .noTarget

        if current == nil {
            adopt(observation, at: timestamp)
            return state(at: timestamp)
        }
        if current == observation {
            pending = nil
            return state(at: timestamp)
        }

        // Nothing is currently adopted, so there is no progress to protect:
        // start tracking the new target immediately.
        if case .noTarget = current {
            adopt(observation, at: timestamp)
            return state(at: timestamp)
        }

        // The observed target differs from the current one: a glitch or a switch.
        if pending != observation {
            pending = observation
            pendingStart = timestamp
        }
        if timestamp - pendingStart >= tolerance {
            adopt(observation, at: pendingStart)
            pending = nil
            return state(at: timestamp)
        }
        // Still within tolerance: freeze progress at the moment the glitch began.
        return state(at: pendingStart)
    }

    private mutating func adopt(_ observation: Observation, at time: TimeInterval) {
        // A new observation restarts everything, including the "already fired"
        // memory, so re-acquiring this target later can fire again.
        firedTarget = nil
        current = observation
        currentStart = time
    }

    private mutating func state(at time: TimeInterval) -> DwellState<ID> {
        guard case .window(let id) = current else { return .idle }
        let elapsed = max(time - currentStart, 0)
        let fraction = duration > 0 ? min(elapsed / duration, 1.0) : 1.0
        if fraction >= 1.0 {
            // Fire exactly once on the crossing frame; afterwards report the
            // completed dwell without firing again (SPEC 3.6).
            if firedTarget == id { return .progressing(id, 1.0) }
            firedTarget = id
            return .fired(id)
        }
        return .progressing(id, fraction)
    }
}
