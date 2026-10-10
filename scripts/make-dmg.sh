#!/usr/bin/env bash
# Build dist/EyesDriven2me-<version>.dmg (drag-to-Applications installer) from
# the already-bundled dist/EyesDriven2me.app. Run scripts/bundle.sh first.
#
# Environment:
#   VERSION        Version in the file name. Default: CFBundleShortVersionString
#                  of the bundled app.
#   SIGN_IDENTITY  codesign identity for the .dmg. Default: same auto-detection
#                  as bundle.sh (local identity if present, else ad-hoc "-").
set -euo pipefail
cd "$(dirname "$0")/.."

APP="dist/EyesDriven2me.app"
[[ -d "$APP" ]] || { echo "error: $APP not found — run scripts/bundle.sh first" >&2; exit 1; }

VERSION="${VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")}"
DMG="dist/EyesDriven2me-${VERSION}.dmg"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# dmgbuild lives in a private virtualenv so it never touches the system Python.
VENV="${DMGBUILD_VENV:-.build/dmgbuild-venv}"
if [[ ! -x "$VENV/bin/dmgbuild" ]]; then
  echo "==> Installing dmgbuild into $VENV"
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install --quiet --disable-pip-version-check "dmgbuild>=1.6"
fi

echo "==> Rendering background"
swift scripts/render-dmg-background.swift 1 "$WORK/bg.png" >/dev/null
swift scripts/render-dmg-background.swift 2 "$WORK/bg@2x.png" >/dev/null
tiffutil -cathidpicheck "$WORK/bg.png" "$WORK/bg@2x.png" -out "$WORK/background.tiff" >/dev/null

echo "==> Building ${DMG}"
rm -f "$DMG" "$DMG.sha256"
"$VENV/bin/dmgbuild" -s scripts/dmg-settings.py \
  -D app="$APP" -D background="$WORK/background.tiff" \
  "Eyes Driven 2me" "$DMG"

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  LOCAL_HASH="$(security find-identity -p codesigning 2>/dev/null \
    | awk -v name='"EyesDriven2me Local Signing"' 'index($0, name) { print $2; exit }')"
  SIGN_IDENTITY="${LOCAL_HASH:--}"
fi
echo "==> Signing ${DMG} with identity '${SIGN_IDENTITY}'"
codesign --force --sign "$SIGN_IDENTITY" "$DMG"
codesign --verify --verbose "$DMG"
hdiutil verify "$DMG" >/dev/null && echo "==> hdiutil verify: OK"

( cd dist && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256" )
echo "  DMG: ${DMG}"
