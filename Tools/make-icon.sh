#!/bin/zsh
# Produit Resources/AppIcon.icns à partir de Tools/make-icon.swift.
set -euo pipefail
cd "${0:A:h}/.."
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
swift Tools/make-icon.swift "$WORK/icon.png"
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$WORK/icon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$WORK/icon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
echo Resources/AppIcon.icns
