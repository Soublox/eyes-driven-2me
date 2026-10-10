import CoreGraphics
import Testing
@testable import EyesDrivenCore

@Test func appendAndLatest() {
    var h = GazeHistory(duration: 3.0)
    #expect(h.latest == nil)
    h.append(CGPoint(x: 1, y: 2), at: 0)
    h.append(CGPoint(x: 3, y: 4), at: 0.5)
    #expect(h.latest == CGPoint(x: 3, y: 4))
    #expect(h.count == 2)
}

@Test func dropsSamplesOlderThanDuration() {
    var h = GazeHistory(duration: 1.0)
    h.append(CGPoint(x: 0, y: 0), at: 0)
    h.append(CGPoint(x: 1, y: 1), at: 0.5)
    h.append(CGPoint(x: 2, y: 2), at: 2.0) // samples older than 1.0 dropped
    #expect(h.count == 1)
    #expect(h.latest == CGPoint(x: 2, y: 2))
}

@Test func medianIsComponentWise() {
    var h = GazeHistory(duration: 10.0)
    h.append(CGPoint(x: 10, y: 100), at: 0.0)
    h.append(CGPoint(x: 30, y: 0), at: 0.1)
    h.append(CGPoint(x: 20, y: 50), at: 0.2)
    h.append(CGPoint(x: 999, y: 999), at: 5.0) // outside the query window
    let median = h.median(from: 0.0, to: 0.5)
    #expect(median == CGPoint(x: 20, y: 50))
}

@Test func medianAveragesTwoMiddleValues() {
    var h = GazeHistory()
    h.append(CGPoint(x: 0, y: 0), at: 0.0)
    h.append(CGPoint(x: 10, y: 20), at: 0.1)
    let median = h.median(from: 0.0, to: 0.1)
    #expect(median == CGPoint(x: 5, y: 10))
}

@Test func medianNilForEmptyRange() {
    var h = GazeHistory()
    h.append(CGPoint(x: 1, y: 1), at: 10.0)
    #expect(h.median(from: 0.0, to: 1.0) == nil)
    #expect(h.median(from: 5.0, to: 4.0) == nil)
}

@Test func resetClearsHistory() {
    var h = GazeHistory()
    h.append(CGPoint(x: 1, y: 1), at: 0)
    h.reset()
    #expect(h.latest == nil)
    #expect(h.count == 0)
}
