#!/bin/bash
# Render the andross icon and pack it into assets/andross.icns.
set -euo pipefail
cd "$(dirname "$0")/.."

swift scripts/make-icon.swift

ICONSET=/tmp/andross.iconset
rm -rf "$ICONSET"
mkdir -p "$ICONSET"

SRC=assets/icon-1024.png
for size in 16 32 128 256 512; do
  sips -z $size $size "$SRC" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  retina=$((size * 2))
  sips -z $retina $retina "$SRC" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET" -o assets/andross.icns
rm -rf "$ICONSET"
echo "✓ assets/andross.icns"
