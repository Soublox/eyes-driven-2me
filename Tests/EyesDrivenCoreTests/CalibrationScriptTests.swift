import Foundation
import Testing
@testable import EyesDrivenCore

// MARK: - Positions

@Test func singleDisplayIsOnly() {
    #expect(CalibrationScript.position(displayIndex: 0, count: 1) == .only)
    #expect(CalibrationScript.positionKey(displayIndex: 0, count: 1) == "voice.position.only")
}

@Test func twoDisplaysHaveNoCenter() {
    #expect(CalibrationScript.positionKey(displayIndex: 0, count: 2) == "voice.position.left")
    #expect(CalibrationScript.positionKey(displayIndex: 1, count: 2) == "voice.position.right")
}

@Test func threeDisplaysHaveLeftCenterRight() {
    #expect(CalibrationScript.positionKey(displayIndex: 0, count: 3) == "voice.position.left")
    #expect(CalibrationScript.positionKey(displayIndex: 1, count: 3) == "voice.position.center")
    #expect(CalibrationScript.positionKey(displayIndex: 2, count: 3) == "voice.position.right")
}

@Test func fourDisplaysCenterCoversTheMiddleOnes() {
    #expect(CalibrationScript.positionKey(displayIndex: 0, count: 4) == "voice.position.left")
    #expect(CalibrationScript.positionKey(displayIndex: 1, count: 4) == "voice.position.center")
    #expect(CalibrationScript.positionKey(displayIndex: 2, count: 4) == "voice.position.center")
    #expect(CalibrationScript.positionKey(displayIndex: 3, count: 4) == "voice.position.right")
}

@Test func outOfRangeIndexesFallBackToTheEdges() {
    #expect(CalibrationScript.positionKey(displayIndex: -1, count: 3) == "voice.position.left")
    #expect(CalibrationScript.positionKey(displayIndex: 99, count: 3) == "voice.position.right")
}

// MARK: - Start line

@Test func startLineForSingleDisplayOmitsPosition() {
    let line = CalibrationScript.startLine(displayCount: 1)
    #expect(line == CalibrationScript.Line(key: "voice.start.single"))
}

@Test func startLineNamesScreenOneAndItsPosition() {
    #expect(CalibrationScript.startLine(displayCount: 2) == CalibrationScript.Line(
        key: "voice.start", screen: 1, positionKey: "voice.position.left"
    ))
    #expect(CalibrationScript.startLine(displayCount: 3) == CalibrationScript.Line(
        key: "voice.start", screen: 1, positionKey: "voice.position.left"
    ))
}

// MARK: - Per-screen line

@Test func nextScreenLineCarriesScreenNumberAndPosition() {
    #expect(CalibrationScript.nextScreenLine(displayIndex: 1, count: 3) == CalibrationScript.Line(
        key: "voice.nextScreen", screen: 2, positionKey: "voice.position.center"
    ))
    #expect(CalibrationScript.nextScreenLine(displayIndex: 2, count: 3) == CalibrationScript.Line(
        key: "voice.nextScreen", screen: 3, positionKey: "voice.position.right"
    ))
}

// MARK: - Almost done

@Test func almostDoneFiresOnceWhenTwoRemain() {
    #expect(CalibrationScript.shouldAnnounceAlmostDone(remaining: 2, alreadyAnnounced: false))
    #expect(!CalibrationScript.shouldAnnounceAlmostDone(remaining: 2, alreadyAnnounced: true))
    #expect(!CalibrationScript.shouldAnnounceAlmostDone(remaining: 3, alreadyAnnounced: false))
    #expect(!CalibrationScript.shouldAnnounceAlmostDone(remaining: 1, alreadyAnnounced: false))
    #expect(!CalibrationScript.shouldAnnounceAlmostDone(remaining: 0, alreadyAnnounced: false))
}

// MARK: - Finished line thresholds

@Test func finishedQualityThresholds() {
    #expect(CalibrationScript.finishedKey(errorPoints: 0) == "voice.finished.good")
    #expect(CalibrationScript.finishedKey(errorPoints: 149.9) == "voice.finished.good")
    #expect(CalibrationScript.finishedKey(errorPoints: 150) == "voice.finished.ok")
    #expect(CalibrationScript.finishedKey(errorPoints: 349.9) == "voice.finished.ok")
    #expect(CalibrationScript.finishedKey(errorPoints: 350) == "voice.finished.poor")
    #expect(CalibrationScript.finishedKey(errorPoints: 1_000) == "voice.finished.poor")
}

@Test func finishedKeyIsNilWhenThereIsNoError() {
    #expect(CalibrationScript.finishedKey(errorPoints: nil) == nil)
}
