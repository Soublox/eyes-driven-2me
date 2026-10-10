#!/usr/bin/env bash
# Regenerate Resources/AppIcon.icns (and docs/assets/icon.png) from
# scripts/render-icon.swift. Every size is rendered from the vector drawing,
# so small sizes stay sharp instead of being downscaled.
# Usage: scripts/make-icon.sh [concept]   (default: c)
set -euo pipefail
cd "$(dirname "$0")/.."

CONCEPT="${1:-c}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET" docs/assets

render() { swift scripts/render-icon.swift "$CONCEPT" "$1" "$2" >/dev/null; }

for base in 16 32 128 256 512; do
  render "$base" "$ICONSET/icon_${base}x${base}.png"
  render "$((base * 2))" "$ICONSET/icon_${base}x${base}@2x.png"
done

iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
render 512 docs/assets/icon.png

echo "Wrote Resources/AppIcon.icns and docs/assets/icon.png (concept ${CONCEPT})"
