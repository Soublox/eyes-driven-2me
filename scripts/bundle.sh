#!/usr/bin/env bash
# Build, assemble, sign and zip EyesDriven2me.app into dist/.
#
# Usage:
#   scripts/bundle.sh
#
# Environment:
#   VERSION        Version stamped into CFBundleShortVersionString.
#                  Default: `git describe --tags --always`.
#   SIGN_IDENTITY  codesign identity. Default "-" (ad-hoc). Set to a
#                  "Developer ID Application: ..." identity for notarized
#                  releases later.
#   SWIFT_BUILD    Build command override. Default "scripts/dev.sh build"
#                  (the local toolchain wrapper). CI sets it to "swift build".
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="EyesDriven2me"
APP="dist/${APP_NAME}.app"
CONTENTS="${APP}/Contents"
ENTITLEMENTS="Resources/${APP_NAME}.entitlements"

# Set a plist key, adding it if it does not exist yet.
plist_set() {
  local key="$1" value="$2" plist="$3"
  /usr/libexec/PlistBuddy -c "Set :${key} ${value}" "$plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :${key} string ${value}" "$plist"
}

# --- Version ---------------------------------------------------------------
VERSION="${VERSION:-$(git describe --tags --always 2>/dev/null || echo 0.0.0)}"
ZIP="dist/${APP_NAME}-${VERSION}.zip"

# --- Build (release) -------------------------------------------------------
read -r -a BUILD_CMD <<< "${SWIFT_BUILD:-scripts/dev.sh build}"
echo "==> Building release (${BUILD_CMD[*]} -c release)"
"${BUILD_CMD[@]}" -c release
BIN_DIR="$("${BUILD_CMD[@]}" -c release --show-bin-path)"
BINARY="${BIN_DIR}/${APP_NAME}"
if [[ ! -x "$BINARY" ]]; then
  echo "error: built binary not found at ${BINARY}" >&2
  exit 1
fi

# --- Assemble the bundle ---------------------------------------------------
echo "==> Assembling ${APP}"
rm -rf "$APP"
mkdir -p "${CONTENTS}/MacOS" "${CONTENTS}/Resources"
cp "$BINARY" "${CONTENTS}/MacOS/${APP_NAME}"
cp Resources/Info.plist "${CONTENTS}/Info.plist"

if [[ -f Resources/AppIcon.icns ]]; then
  echo "==> Adding app icon"
  cp Resources/AppIcon.icns "${CONTENTS}/Resources/AppIcon.icns"
  plist_set "CFBundleIconFile" "AppIcon" "${CONTENTS}/Info.plist"
fi

plist_set "CFBundleShortVersionString" "$VERSION" "${CONTENTS}/Info.plist"

# --- Sign (hardened runtime, ad-hoc by default) ----------------------------
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
echo "==> Signing with identity '${SIGN_IDENTITY}'"
codesign --force --deep --sign "$SIGN_IDENTITY" \
  --options runtime \
  --entitlements "$ENTITLEMENTS" \
  "$APP"

# --- Verify ----------------------------------------------------------------
echo "==> Verifying signature"
codesign --verify --verbose "$APP"

# --- Zip -------------------------------------------------------------------
echo "==> Zipping ${ZIP}"
ditto -c -k --keepParent "$APP" "$ZIP"

echo
echo "Done. Artifacts:"
echo "  App: ${APP}"
echo "  Zip: ${ZIP}"
