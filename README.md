<p align="center"><img src="docs/assets/icon.png" width="160" alt="Eyes Driven 2me icon"></p>

# Eyes Driven 2me

**Look at a window. It gets focus.**

[![CI](https://github.com/Soublox/eyes-driven-2me/actions/workflows/ci.yml/badge.svg)](https://github.com/Soublox/eyes-driven-2me/actions/workflows/ci.yml)

Eyes Driven 2me is an open-source (MIT) macOS menu-bar app that watches you
through the webcam, estimates where on the desktop you are looking, and gives
keyboard focus to the window under your gaze when you confirm with a **dwell**
or a quick **head nod**.

> ⚠️ **Experimental.** This is an early prototype. Gaze estimation from a
> regular webcam is approximate — expect to distinguish a display or half of a
> display, not individual buttons. Behaviour and accuracy will change between
> releases.

## How it works

```
camera → head pose + iris → calibrated gaze → window under gaze → dwell or nod → focus
```

1. The webcam streams frames at ~30 fps.
2. Vision face landmarks give head pose and iris position.
3. A calibrated regression maps those features to a point on your desktop.
4. The point is resolved to the top-most visible window under it.
5. You confirm with a dwell (keep looking) or a head nod, and that window is
   raised and focused via the Accessibility API.

Nothing else happens — no clicking, no typing, no sending anything anywhere.

## Privacy

- **100% on-device.** All processing happens on your Mac.
- **No network.** The app makes no network requests.
- **No frames stored.** Camera frames are processed in memory and discarded;
  they are never written to disk or transmitted.
- The camera is only read while the app is enabled.

## Requirements

- macOS 14 (Sonoma) or newer.
- Apple Silicon (recommended) or Intel — releases are universal binaries.
  **Intel support is experimental:** Vision runs without the Neural Engine, so
  tracking may run below 30 fps. Please report what you get:
  `/Applications/EyesDriven2me.app/Contents/MacOS/EyesDriven2me --camera`
  (prints fps per second) in an
  [issue](https://github.com/Soublox/eyes-driven-2me/issues) with your Mac model.
- A webcam (the built-in FaceTime camera works well).
- **Camera** and **Accessibility** permissions.

## Install

1. Download the latest `EyesDriven2me-<version>.dmg` from
   [Releases](https://github.com/Soublox/eyes-driven-2me/releases).
2. Open it and drag **Eyes Driven 2me** onto the **Applications** folder
   (a `.zip` with the same app is also attached to every release).
3. The first time, **right-click the app → Open** and confirm. Builds are not
   notarized yet, so Gatekeeper will warn about an unidentified developer.

   If the app is still blocked, clear the quarantine flag:

   ```sh
   xattr -dr com.apple.quarantine /Applications/EyesDriven2me.app
   ```

## First run

1. Launch the app — it appears in the menu bar.
2. Grant **Camera** and **Accessibility** permissions when prompted (the app
   offers shortcuts to the right System Settings panes).
3. Choose **Calibrate…** and follow the on-screen targets on every display.

## Usage

- **Dwell** — keep looking at a window; after the dwell time it takes focus.
- **Nod** — look at a window and give one quick down-and-up nod.
- **Hotkey** — `⌃⌥⌘E` globally enables/disables the app.
- **Cursor warp** — optionally move the mouse cursor to the center of the newly
  focused window.

Pick the trigger mode in the menu-bar menu or in **Settings…**.

## Tips for accuracy

- Use good, even **front lighting** — avoid strong backlight or side shadows.
- Keep the **camera centered** relative to your face and your displays.
- **Recalibrate** whenever you move, change displays, or shift your chair
  significantly.

## Build from source

Requires Xcode or a [swift.org](https://www.swift.org/install/) toolchain
(Swift 5.10+). The local `scripts/dev.sh` wrapper picks a toolchain that ships
Swift Testing.

```sh
scripts/dev.sh build      # build (debug)
scripts/dev.sh test       # run tests
scripts/bundle.sh         # release .app + zip in dist/ (universal)
scripts/make-dmg.sh       # drag-to-Applications .dmg from the bundled app
```

> `swift test` needs Xcode or a swift.org toolchain — the plain Command Line
> Tools do not ship the `Testing` module. `scripts/dev.sh` handles this.

### Keep permissions across rebuilds

Ad-hoc signed builds get a new identity every time, so macOS forgets the
Accessibility permission after each rebuild. Create a local self-signed
signing identity once:

```sh
scripts/create-local-signing-identity.sh
```

`scripts/bundle.sh` then signs with it automatically. Grant Accessibility one
last time; later rebuilds keep it. (Local development only — public releases
will use a Developer ID certificate and notarization.)

Useful diagnostics: `EyesDriven2me --help` (`--windows`, `--camera`, `--gaze`,
`--focus <id>`).

## Roadmap

- Blink trigger (long or double blink).
- Diagnostics window with camera preview.
- Launch at login.
- Notarized releases.
- Homebrew cask.

## Contributing

Contributions are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md). For security
issues, see [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE) © Soublox
