#!/usr/bin/env bash
# Developer wrapper: picks a toolchain that ships Swift Testing.
# Usage: scripts/dev.sh build|test|run [extra swift args]
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -x "$HOME/.swiftly/bin/swift" ]]; then
  SWIFT="$HOME/.swiftly/bin/swift"   # swift.org toolchain (works without Xcode)
else
  SWIFT="$(command -v swift)"
fi

cmd="${1:-build}"; shift || true
# The native build system avoids "Could not initialize build system" with CLT-only setups.
exec "$SWIFT" "$cmd" --build-system native "$@" 2> >(grep -v "has been deprecated" >&2)
