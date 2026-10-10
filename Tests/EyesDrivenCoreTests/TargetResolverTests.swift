import CoreGraphics
import Testing
@testable import EyesDrivenCore

private let display4K = DisplayInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 3840, height: 2160))

private func window(_ id: UInt32, _ rect: CGRect, pid: Int32 = 100) -> WindowInfo {
    WindowInfo(id: id, pid: pid, appName: "App", title: "T", frame: rect)
}

@Test func frontMostContainingWindowWins() {
    let front = window(2, CGRect(x: 0, y: 0, width: 800, height: 600))
    let back = window(1, CGRect(x: 0, y: 0, width: 1000, height: 800))
    let hit = TargetResolver.resolve(
        point: CGPoint(x: 100, y: 100),
        windows: [front, back],
        displays: [display4K]
    )
    #expect(hit?.id == 2)
}

@Test func excludedPIDIsSkipped() {
    let front = window(2, CGRect(x: 0, y: 0, width: 800, height: 600), pid: 999)
    let back = window(1, CGRect(x: 0, y: 0, width: 1000, height: 800), pid: 100)
    let hit = TargetResolver.resolve(
        point: CGPoint(x: 100, y: 100),
        windows: [front, back],
        displays: [display4K],
        excludedPIDs: [999]
    )
    #expect(hit?.id == 1)
}

@Test func tinyAndNonZeroLayerWindowsAreSkipped() {
    let tiny = window(1, CGRect(x: 0, y: 0, width: 100, height: 100))
    let overlay = window(2, CGRect(x: 0, y: 0, width: 800, height: 600))
    let big = window(3, CGRect(x: 0, y: 0, width: 600, height: 600))
    let hit = TargetResolver.resolve(
        point: CGPoint(x: 50, y: 50),
        windows: [tiny, WindowInfo(id: 2, pid: 100, appName: "A", title: nil, frame: overlay.frame, layer: 5), big],
        displays: [display4K]
    )
    #expect(hit?.id == 3)
}

@Test func snapToNearestWithinDistance() {
    let w = window(1, CGRect(x: 500, y: 500, width: 400, height: 400))
    // 50 pt above the top edge.
    let hit = TargetResolver.resolve(
        point: CGPoint(x: 700, y: 450),
        windows: [w],
        displays: [display4K]
    )
    #expect(hit?.id == 1)
}

@Test func nilBeyondSnapDistance() {
    let w = window(1, CGRect(x: 500, y: 500, width: 400, height: 400))
    // 400 pt above the top edge.
    let hit = TargetResolver.resolve(
        point: CGPoint(x: 700, y: 100),
        windows: [w],
        displays: [display4K]
    )
    #expect(hit == nil)
}

@Test func nilWhenNoDisplayContainsPoint() {
    let w = window(1, CGRect(x: 0, y: 0, width: 800, height: 600))
    let hit = TargetResolver.resolve(
        point: CGPoint(x: 3000, y: 3000),
        windows: [w],
        displays: [DisplayInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100))]
    )
    #expect(hit == nil)
}

@Test func fourKDisplaySplitInHalvesResolvesCorrectHalf() {
    let left = window(1, CGRect(x: 0, y: 0, width: 1920, height: 2160))
    let right = window(2, CGRect(x: 1920, y: 0, width: 1920, height: 2160))
    let windows = [left, right]

    let leftHit = TargetResolver.resolve(
        point: CGPoint(x: 100, y: 1080), windows: windows, displays: [display4K])
    let rightHit = TargetResolver.resolve(
        point: CGPoint(x: 3000, y: 1080), windows: windows, displays: [display4K])
    #expect(leftHit?.id == 1)
    #expect(rightHit?.id == 2)
}

@Test func offlineWindowIsIgnored() {
    let off = WindowInfo(id: 1, pid: 100, appName: "A", title: nil,
                         frame: CGRect(x: 0, y: 0, width: 800, height: 600), isOnScreen: false)
    let on = window(2, CGRect(x: 0, y: 0, width: 800, height: 600))
    let hit = TargetResolver.resolve(
        point: CGPoint(x: 100, y: 100), windows: [off, on], displays: [display4K])
    #expect(hit?.id == 2)
}
