#!/usr/bin/env bash
# Developer wrapper around SwiftPM.
# Usage: scripts/dev.sh build|test|run [extra swift args]
#
# Toolchain selection:
#   1. Xcode, when installed (preferred; it ships Swift Testing). A DEVELOPER_DIR
#      pointing at the Command Line Tools is ignored because CLT lacks Testing.
#   2. A swift.org toolchain installed with swiftly (~/.swiftly/bin/swift),
#      using the native build system.
#   3. Whatever `swift` is on PATH.
set -euo pipefail
cd "$(dirname "$0")/.."

XCODE_DEV="/Applications/Xcode.app/Contents/Developer"
EXTRA=()

if [[ "${DEVELOPER_DIR:-}" == /Library/Developer/CommandLineTools* ]]; then
  unset DEVELOPER_DIR
fi

if [[ -d "$XCODE_DEV" ]]; then
  export DEVELOPER_DIR="${DEVELOPER_DIR:-$XCODE_DEV}"
  SWIFT="$(xcrun --find swift)"
elif [[ -x "$HOME/.swiftly/bin/swift" ]]; then
  SWIFT="$HOME/.swiftly/bin/swift"
  EXTRA=(--build-system native)   # avoids "Could not initialize build system" without Xcode
else
  SWIFT="$(command -v swift)"
fi

cmd="${1:-build}"; shift || true
exec "$SWIFT" "$cmd" ${EXTRA[@]+"${EXTRA[@]}"} "$@"
