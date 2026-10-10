import Testing
@testable import EyesDrivenCore

/// `HighlightPolicy` decides when the target-window border is drawn (SPEC 4).
@Suite("HighlightPolicy")
struct HighlightPolicyTests {

    /// In the dwell-based modes the border waits until a dwell is meaningfully
    /// in progress, so a gaze sweep across windows does not flash borders.
    @Test func dwellModesHideBorderBelowThreshold() {
        #expect(HighlightPolicy.shouldDraw(progress: 0, triggerMode: .dwell) == false)
        #expect(HighlightPolicy.shouldDraw(progress: 0.10, triggerMode: .dwell) == false)
        #expect(HighlightPolicy.shouldDraw(progress: 0.15, triggerMode: .dwell) == true)
        #expect(HighlightPolicy.shouldDraw(progress: 0.5, triggerMode: .dwell) == true)
        #expect(HighlightPolicy.shouldDraw(progress: 1, triggerMode: .dwell) == true)

        #expect(HighlightPolicy.shouldDraw(progress: 0, triggerMode: .dwellOrNod) == false)
        #expect(HighlightPolicy.shouldDraw(progress: 0.149, triggerMode: .dwellOrNod) == false)
        #expect(HighlightPolicy.shouldDraw(progress: 0.15, triggerMode: .dwellOrNod) == true)
    }

    /// Nod-only mode has progress 0 but still draws the border, showing what a
    /// nod would focus.
    @Test func nodModeAlwaysDrawsBorder() {
        #expect(HighlightPolicy.shouldDraw(progress: 0, triggerMode: .nod) == true)
        #expect(HighlightPolicy.shouldDraw(progress: 1, triggerMode: .nod) == true)
    }

    /// The threshold value is the documented 0.15.
    @Test func thresholdIsFifteenPercent() {
        #expect(HighlightPolicy.minDwellProgress == 0.15)
    }
}
