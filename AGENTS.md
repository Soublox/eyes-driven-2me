# Instructions for coding agents

Read `docs/SPEC.md` first. It is the source of truth.

## Rules
1. Everything is in **English**: code, comments, docs, commit messages.
2. Stay inside the files your task owns. Do not edit `Types.swift`,
   `Package.swift` or `docs/SPEC.md` unless the task explicitly says so. If the
   spec is wrong or ambiguous, write a note in your final answer instead.
3. `EyesDrivenCore` imports only `Foundation` and `CoreGraphics`.
4. Swift language mode 5 (tools 5.10), macOS 14+. No third-party dependencies.
5. Prefer small, readable types. Public API documented with `///`.
6. Tests use **Swift Testing** (`import Testing`, `@Test`, `#expect`), live in
   `Tests/EyesDrivenCoreTests`, one file per component, deterministic (inject
   timestamps; never sleep or read the clock in tests).
7. Never add networking, analytics, or disk writes of camera frames.

## Commands
```sh
scripts/dev.sh build   # must pass with zero errors
scripts/dev.sh test    # must pass
```
`scripts/dev.sh` selects a toolchain that ships Swift Testing and the native
build system. Do not call plain `swift test` (the local Command Line Tools
lack the Testing module).

## Definition of done
- Builds with no errors and no new warnings in your files.
- Tests for every Core component you touched, all green.
- Final answer: list of files changed, what was verified (paste the last lines
  of build/test output), and any spec deviations or open questions.
