# Eyes Driven 2me — Specification (v0.1)

> Look at a window. It gets focus. No mouse.

Eyes Driven 2me is an open-source (MIT) macOS menu-bar app that watches the user
through the webcam, estimates where on the desktop they are looking, finds the
window under that point, and gives it keyboard focus when the user confirms with
a **dwell** (keep looking for N seconds) or a **head nod** (one quick down-and-up
"yes" movement).

- Website: https://eyesdriven2.me (later)
- Repository: https://github.com/soublox/eyes-driven-2me
- Platform: macOS 14 (Sonoma) or newer, Apple Silicon and Intel
- License: MIT
- Privacy: 100% on-device. No network access, no frames stored, ever.

## 1. Goals and non-goals

### Goals (v0.1)
1. Estimate gaze from a regular webcam using head pose + iris position.
2. Resolve the gaze point to the top-most visible window under it, across all
   displays.
3. Trigger focus by **dwell** (configurable, default 1.2 s) and/or **head nod**.
4. Optionally warp the mouse cursor to the center of the newly focused window.
5. Per-user calibration across all connected displays.
6. Menu-bar UI: enable/disable, trigger mode, settings, calibrate, quit.
7. Global hotkey to pause/resume (default `⌃⌥⌘E`).
8. Visual feedback: highlight around the target window with dwell progress;
   optional debug gaze dot.

### Non-goals (v0.1)
- Pixel-precise gaze or clicking/typing by eye.
- Blink trigger (planned for v0.2).
- Mac App Store distribution (Accessibility API rules out the sandbox).
- Windows/Linux.

### Reference setup (the author's)
Three displays side by side: external 4K (left) | MacBook built-in (center) |
external 4K (right). External displays are usually split in 2 halves
(window A | window B), sometimes 3 (A | B over C). Expected precision target:
reliably distinguish display + half; quarter regions are a stretch goal.

## 2. Architecture

```
Camera (AVFoundation, ~30 fps)
  -> FaceTracker (Vision face landmarks)        -> FaceFeatures
  -> GazeModel (calibrated ridge regression)    -> raw gaze point (global)
  -> PointFilter (One-Euro)                     -> smoothed gaze point
  -> GazeHistory (ring buffer)
  -> FocusEngine  <- window snapshot (WindowCatalog)
                  <- NodDetector (pitch stream)
                  -> actions: highlight(window, progress) | focus(window)
  -> WindowFocuser (Accessibility API) + optional cursor warp
  -> OverlayController (highlight + debug dot)
```

Two SwiftPM targets:

| Target | Kind | Contents | Rules |
|---|---|---|---|
| `EyesDrivenCore` | library | Pure, deterministic logic: types, math, filters, calibration model, detectors, target resolution, focus engine, settings model | Imports only `Foundation` and `CoreGraphics`. No AppKit, AVFoundation, Vision, AX. Fully unit-tested. |
| `EyesDrivenApp` | executable | Camera, Vision, window enumeration, AX focusing, permissions, hotkey, SwiftUI menu bar, calibration UI, overlay, glue | Thin platform adapters; logic belongs in Core. |

### 2.1 Coordinate system (IMPORTANT)
All screen geometry in Core uses **CoreGraphics global coordinates**: origin at
the top-left of the main display, x to the right, **y down**, units = points.
This is what `CGWindowListCopyWindowInfo` (`kCGWindowBounds`) and
`CGDisplayBounds` return. AppKit (`NSScreen`, `NSWindow`) uses a bottom-left
origin, y up; the App layer converts with:

```
cgY = primaryScreenHeight - nsY - height   // primary = NSScreen.screens[0]
```

Camera/Vision coordinates (normalized, bottom-left origin) never leave
`FaceTracker`; it converts everything into `FaceFeatures`.

### 2.2 Sign conventions
- Calibration learns the mapping, so yaw/iris signs do not matter for gaze.
- The nod detector needs to know which pitch direction is "down". Calibration
  derives it (correlation between pitch and target y) and stores it in
  `GazeModel.pitchDownSign` (+1 or -1). Default before calibration: `-1`.

## 3. Core components (EyesDrivenCore)

Shared types live in `Sources/EyesDrivenCore/Types.swift` (already written; do
not change signatures without updating this spec).

### 3.1 `FaceFeatures`
Per-frame measurements from `FaceTracker`. See Types.swift. `featureVector`
returns the base vector used by the gaze model:
`[yaw, pitch, irisX, irisY, faceCenterX, faceCenterY, faceSize]` where irisX/Y
are the average of both eyes.

### 3.2 `GazeModel` (Calibration.swift)
- Input: `[CalibrationSample]` (features + target point in global coords).
- Standardize each base feature (store mean/std; std floor 1e-6).
- Expand to degree-2 polynomial terms: bias, linear terms, squares, pairwise
  products of the standardized base vector.
- Fit two independent ridge regressions (x and y) via normal equations
  `(XᵀX + λI)w = Xᵀy` (do not regularize the bias), solved with Cholesky or
  Gaussian elimination with partial pivoting. Pure Swift, no Accelerate.
- `fit` throws `CalibrationError.notEnoughSamples` when fewer than 5 samples.
- `predict(_:) -> CGPoint`, `meanError(on:) -> Double` (mean Euclidean
  distance in points).
- `pitchDownSign`: sign of Pearson correlation between pitch and target y
  (+1 if pitch increases as the user looks lower on screen, else -1).
- `Codable` so it can be persisted. `CalibrationProfile` wraps model + samples
  + date + display layout fingerprint.

### 3.3 Filters (Filters.swift)
- `OneEuroFilter` (scalar) — standard 1€ filter (Casiez et al. 2012) with
  `minCutoff` (default 1.0), `beta` (default 0.007), `dCutoff` (default 1.0),
  driven by timestamps (seconds). First sample passes through.
- `PointFilter` — two OneEuroFilters for x/y; `reset()`.

### 3.4 `GazeHistory` (GazeHistory.swift)
- Ring buffer of `(timestamp, CGPoint)`, capacity by duration (default 3 s).
- `append(_:at:)`, `median(from:to:) -> CGPoint?` (component-wise median of
  samples in the time interval), `latest`.
- Used to look up "where was the user looking just before the nod started".

### 3.5 `NodDetector` (NodDetector.swift)
Detects one quick nod: head pitch goes "down" (per `downSign`) by at least
`minAmplitude` relative to a baseline, then comes back up to within
`returnRatio * peakAmplitude` of the baseline, all within
`minDuration...maxDuration`. Single movement — no double nod required.

Config defaults: `minAmplitude = 0.10 rad (~6°)`, `minDuration = 0.12 s`,
`maxDuration = 0.80 s`, `returnRatio = 0.35`, `cooldown = 1.0 s`,
`baselineTimeConstant = 0.6 s` (EMA; baseline only updates while idle).
- `process(pitch:timestamp:) -> NodEvent?` returns an event once, on the frame
  the return completes. `NodEvent` carries `startTimestamp` (when the downward
  excursion began, i.e. first frame beyond 25% of minAmplitude) and
  `endTimestamp`.
- An excursion that exceeds `maxDuration` is abandoned (user just looked down)
  and the baseline re-seeds.
- Upward-first motion never fires.
- `reset()`.

### 3.6 `DwellDetector` (DwellDetector.swift)
Generic over `ID: Hashable`.
- `update(target: ID?, timestamp:) -> DwellState`.
- States: `.idle`, `.progressing(target, fraction 0...1)`, `.fired(target)`.
- Fires once when the same target has been continuously observed for
  `duration`. Glitches shorter than `tolerance` (default 0.15 s) to another
  target or nil do not reset progress.
- After firing it will not fire again for that target until the target changes
  (then returns `.idle`/progress for the new one).
- `reset()`.

### 3.7 `TargetResolver` (TargetResolver.swift)
`static func resolve(point:windows:displays:excludedPIDs:minSize:snapDistance:) -> WindowInfo?`
- `windows` are in front-to-back order (as CGWindowList returns them).
- Candidates: `layer == 0`, `isOnScreen`, width and height ≥ `minSize`
  (default 120), `pid` not excluded, `alpha > 0.1`.
- Return the first candidate whose frame contains the point.
- Otherwise, if the point lies on (or is clamped to the nearest) display, return
  the candidate on that display with the smallest distance from the point to
  its frame if ≤ `snapDistance` (default 160 pt). Else nil.
- Visibility: a candidate counts as "on a display" if its frame intersects that
  display. Occlusion is handled implicitly by front-to-back order.

### 3.8 `FocusEngine` (FocusEngine.swift)
Pure decision-maker, the only place combining the pieces above.
- Inputs (methods): `ingest(gaze: CGPoint, at:)`, `ingest(nod: NodEvent)`,
  `updateWindows(_ windows:, displays:, frontmostWindowID:)`,
  `updateSettings(_:)`, `notifyFocused(windowID:at:)`.
- Output: each ingest returns `[FocusAction]`:
  - `.highlight(WindowInfo?, progress: Double)` — current target and dwell
    progress (0 when nod-only mode), nil clears.
  - `.focus(WindowInfo, reason: .dwell | .nod)`.
- Rules:
  - Disabled settings → only `.highlight(nil, 0)` once, no focus.
  - Targets equal to the current frontmost window never fire.
  - `cooldown` (settings.cooldownSeconds, default 0.8 s) after any focus.
  - Nod: target = resolve(median gaze in `[start - 0.35, start - 0.05]`).
  - Trigger modes: `.dwell`, `.nod`, `.dwellOrNod`.

### 3.9 `AppSettings` (Settings.swift)
`Codable, Equatable` with defaults:
`isEnabled = true`, `triggerMode = .dwellOrNod`, `dwellSeconds = 1.2`
(clamped 0.3...5.0), `moveCursorToFocusedWindow = false`,
`nodSensitivity = 0.5` (0...1, maps to minAmplitude 0.16...0.05 rad linearly),
`cooldownSeconds = 0.8`, `showTargetHighlight = true`, `showGazeDot = false`,
`cameraUniqueID: String? = nil`, `hotKeyEnabled = true`.
Decoding must tolerate missing keys (fall back to defaults) so new settings
don't break old saved files.

## 4. App components (EyesDrivenApp)

| File | Responsibility |
|---|---|
| `CameraCapture.swift` | `AVCaptureSession`, device selection by `uniqueID` (default: built-in FaceTime camera, else first video device), 640×480 or nearest, delivers `CMSampleBuffer` on a serial queue. `availableCameras()`. Start/stop. |
| `FaceTracker.swift` | `VNDetectFaceLandmarksRequest` (latest revision) + `VNSequenceRequestHandler`; picks the largest face; produces `FaceFeatures`. Yaw/pitch/roll from the observation (radians); if nil, fallback estimates from landmarks (nose vs. face box). Iris = pupil position normalized within each eye contour bounding box. Eye openness = eye contour height / width. |
| `WindowCatalog.swift` | `CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)` → `[WindowInfo]` front-to-back; `displays()` via `CGGetActiveDisplayList` + `CGDisplayBounds`; frontmost window id (first layer-0 window owned by `NSWorkspace.shared.frontmostApplication`). Window titles may be nil without Screen Recording permission — never required. |
| `WindowFocuser.swift` | Focus a `WindowInfo` via AX: `AXUIElementCreateApplication(pid)`, find the AX window whose position/size match `frame` (±4 pt; prefer title match when available), `AXRaise`, set `kAXMainAttribute`, set app `kAXFrontmostAttribute = true`, then `NSRunningApplication.activate()` as a fallback. Optional cursor warp to the frame center (`CGWarpMouseCursorPosition` + `CGAssociateMouseAndMouseCursorPosition(1)`). Note: on macOS 14+ cooperative activation can ignore `activate()` from background apps — the AX frontmost attribute is the primary path. |
| `Permissions.swift` | Camera (`AVCaptureDevice`), Accessibility (`AXIsProcessTrustedWithOptions`); helpers to open the right System Settings panes. |
| `HotKey.swift` | Carbon `RegisterEventHotKey` global hotkey (no permission needed), default `⌃⌥⌘E`, callback on main thread. |
| `GazePipeline.swift` | Glue: camera → tracker → model → filter → history → FocusEngine → focuser/overlay. Owns the `NodDetector`. Refreshes the window snapshot at ~4 Hz on the main thread. Publishes status (fps, face detected, current target) for the UI. |
| `CalibrationController.swift` | Full-screen borderless window on every display; shows targets sequentially (5 per display: center + 4 points inset 12% from the edges); per target: 0.9 s settle, then 0.9 s collect; stores the per-feature median as one sample. Esc cancels. Fits `GazeModel`, shows mean error, saves `CalibrationProfile`. |
| `OverlayController.swift` | One click-through, transparent, borderless window per display at `.screenSaver` level, `ignoresMouseEvents = true`, joins all spaces; draws the target frame highlight with a dwell progress indicator and the optional gaze dot. |
| `Storage.swift` | Persist `AppSettings` (UserDefaults, JSON) and `CalibrationProfile` (`~/Library/Application Support/EyesDriven2me/calibration.json`). |
| `MenuBar.swift`, `SettingsView.swift`, `EyesDrivenApp.swift` | SwiftUI `MenuBarExtra` app (`@main`), activation policy `.accessory`. Menu: status line, Enabled toggle, trigger mode picker, Calibrate…, Settings…, Show gaze dot, Quit. |

Info.plist (embedded in the binary via `-sectcreate` so `swift run` works, and
copied into the `.app` by `scripts/bundle.sh`): `NSCameraUsageDescription`,
`LSUIElement = YES`, bundle id `me.eyesdriven2.app`.

## 5. Build, test, distribute
- `swift build`, `swift test` (Swift Testing). `scripts/bundle.sh` builds a
  release `EyesDriven2me.app` with ad-hoc signing into `dist/`.
- CI: GitHub Actions on `macos-15`: build + test on every push/PR.
- Later: Developer ID signing + notarization, Homebrew cask, GitHub Pages site.

## 6. Roadmap
- v0.1 — dwell + nod, calibration, menu bar, overlay (this spec).
- v0.2 — blink trigger (long or double blink), diagnostics window with camera
  preview, per-display recalibration, launch at login.
- v0.3 — signed/notarized releases, Homebrew cask, landing page.
