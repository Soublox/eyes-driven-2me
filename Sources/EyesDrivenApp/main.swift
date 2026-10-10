import Foundation
import EyesDrivenCore

// Eyes Driven 2me — platform diagnostic CLI.
//
// Temporary entry point: it exercises the platform adapters (window catalog,
// camera + Vision face tracker, Accessibility focus) without any UI. It will be
// replaced by the SwiftUI menu-bar app.

let arguments = Array(CommandLine.arguments.dropFirst())

func printUsage() {
    print("""
    Eyes Driven 2me — platform diagnostic

    Usage:
      EyesDriven2me --windows              Print displays and on-screen windows.
      EyesDriven2me --camera               Run the camera + face tracker for 10 s.
      EyesDriven2me --focus <windowID>     Focus the window with the given id.
      EyesDriven2me                        Print this help.
    """)
}

func runWindows() {
    let displays = WindowCatalog.displays()
    print("Displays (\(displays.count)):")
    for display in displays {
        let frame = display.frame
        print(String(format: "  id=%-10u  origin=(%.0f, %.0f)  size=%.0fx%.0f",
                     display.id, frame.origin.x, frame.origin.y, frame.width, frame.height))
    }

    let windows = WindowCatalog.windows()
    print("Windows (\(windows.count), front-to-back):")
    for window in windows.prefix(50) {
        let frame = window.frame
        let title = window.title.map { "\u{201C}\($0)\u{201D}" } ?? "<no title>"
        let metrics = String(format: "[%.0f, %.0f %.0fx%.0f]",
                             frame.origin.x, frame.origin.y, frame.width, frame.height)
        print("  id=\(window.id)  layer=\(window.layer)  pid=\(window.pid)  \(metrics)  \(window.appName) — \(title)")
    }
}

func runCamera() {
    let capture = CameraCapture()
    let tracker = FaceTracker()
    var frameIndex = 0

    capture.onFrame = { buffer in
        frameIndex += 1
        guard frameIndex % 10 == 0 else { return }
        if let features = tracker.process(buffer) {
            print(String(format: "t=%6.2fs  yaw=%+.3f pitch=%+.3f roll=%+.3f  irisL=(%.2f, %.2f) irisR=(%.2f, %.2f)  openL=%.2f openR=%.2f  size=%.3f",
                         features.timestamp, features.yaw, features.pitch, features.roll,
                         features.leftIris.x, features.leftIris.y,
                         features.rightIris.x, features.rightIris.y,
                         features.leftEyeOpenness, features.rightEyeOpenness,
                         features.faceSize))
        } else {
            print("frame \(frameIndex): no face")
        }
    }

    switch Permissions.cameraStatus {
    case .authorized:
        break
    case .notDetermined:
        print("Requesting camera access…")
        Task { _ = await Permissions.requestCamera() }
    default:
        print("Camera access is \(Permissions.cameraStatusDescription()). Enable it in System Settings ▸ Privacy & Security ▸ Camera.")
    }

    do {
        try capture.start(cameraUniqueID: nil)
        print("Camera started. Printing every 10th frame for 10 s…")
    } catch {
        print("Could not start the camera: \(error.localizedDescription)")
    }

    // Keep the run loop alive for the capture window.
    let deadline = Date().addingTimeInterval(10)
    let keepAlive = Timer(timeInterval: 0.1, repeats: true) { _ in }
    RunLoop.main.add(keepAlive, forMode: .common)
    RunLoop.main.run(until: deadline)
    keepAlive.invalidate()

    capture.stop()
    print("Camera run finished.")
}

func runFocus(id: UInt32) {
    let windows = WindowCatalog.windows()
    guard let window = windows.first(where: { $0.id == id }) else {
        print("No on-screen window with id \(id).")
        return
    }
    if !WindowFocuser.isTrusted() {
        print("Accessibility permission is not granted; focusing may fail. Enable it in System Settings ▸ Privacy & Security ▸ Accessibility.")
    }
    let focused = WindowFocuser.focus(window, moveCursor: false)
    print(focused
          ? "Focused window #\(id) (\(window.appName))."
          : "Could not focus window #\(id) (\(window.appName)).")
}

if arguments.contains("--windows") {
    runWindows()
} else if arguments.contains("--camera") {
    runCamera()
} else if let index = arguments.firstIndex(of: "--focus"), index + 1 < arguments.count,
          let id = UInt32(arguments[index + 1]) {
    runFocus(id: id)
} else if arguments.contains("--focus") {
    print("--focus needs a numeric window id.")
} else {
    printUsage()
}
