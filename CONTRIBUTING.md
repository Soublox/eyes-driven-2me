# Contributing

Thanks for your interest in Eyes Driven 2me. This project is experimental and
moving quickly — small, focused pull requests are easiest to review.

## Architecture

[`docs/SPEC.md`](docs/SPEC.md) is the source of truth. Read it before making any
non-trivial change. It describes the coordinate system, the pipeline, and the
responsibility of every file.

## The Core vs App rule

The package has two targets, and the boundary is not negotiable:

- **`EyesDrivenCore`** — pure, deterministic logic (types, math, filters,
  calibration, detectors, target resolution, focus engine, settings). It imports
  only `Foundation` and `CoreGraphics`: no AppKit, AVFoundation, Vision, or AX.
  Everything here is unit-tested.
- **`EyesDrivenApp`** — thin platform adapters (camera, Vision, window
  enumeration, Accessibility, permissions, hotkey, SwiftUI, overlay).

**Put logic in Core, keep the App thin.** If you are tempted to add a
platform framework to Core, move the decision into Core and pass it plain data.

## Tests

- Use **Swift Testing** (`import Testing`, `@Test`, `#expect`).
- Tests live in `Tests/EyesDrivenCoreTests`, one file per component.
- Tests must be deterministic: inject timestamps, never sleep, never read the
  clock.

Run them with:

```sh
scripts/dev.sh test
```

## Language

Everything is in **English**: code, comments, docs, commit messages, and PR
descriptions.

## Pull request checklist

- [ ] `scripts/dev.sh build` passes with no errors or new warnings.
- [ ] `scripts/dev.sh test` passes.
- [ ] New or changed Core components have tests.
- [ ] Changes stay inside the files the task owns; `Package.swift` and
      `docs/SPEC.md` are only changed when the task explicitly says so.
- [ ] No networking, analytics, or disk writes of camera frames.
- [ ] Documentation updated if behaviour changed.

## Reporting bugs and ideas

Use the issue templates in `.github/ISSUE_TEMPLATE/`. For security issues, do
**not** open a public issue — see [SECURITY.md](SECURITY.md).
