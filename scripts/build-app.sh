#!/bin/bash
# Build a double-clickable andross.app from the SwiftUI target — no Xcode needed.
#
#   ./scripts/build-app.sh                 # release build → /Applications/andross.app
#   ./scripts/build-app.sh debug           # faster debug build
#   ./scripts/build-app.sh release /tmp/andross.app   # custom destination

set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
DEST="${2:-/Applications/andross.app}"

echo "▸ swift build -c $CONFIG --product AndrossApp"
swift build -c "$CONFIG" --product AndrossApp
BIN=".build/$CONFIG/AndrossApp"

rm -rf "$DEST"
mkdir -p "$DEST/Contents/MacOS" "$DEST/Contents/Resources"
cp "$BIN" "$DEST/Contents/MacOS/AndrossApp"
cp assets/andross.icns "$DEST/Contents/Resources/andross.icns"

cat > "$DEST/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>andross</string>
  <key>CFBundleDisplayName</key><string>andross</string>
  <key>CFBundleIdentifier</key><string>net.cver.andross</string>
  <key>CFBundleExecutable</key><string>AndrossApp</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>andross</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Android Package</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Default</string>
      <key>LSItemContentTypes</key>
      <array><string>com.android.package-archive</string></array>
    </dict>
  </array>
  <key>UTImportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>com.android.package-archive</string>
      <key>UTTypeDescription</key><string>Android Package</string>
      <key>UTTypeConformsTo</key>
      <array><string>public.data</string><string>public.archive</string></array>
      <key>UTTypeTagSpecification</key>
      <dict>
        <key>public.filename-extension</key><array><string>apk</string></array>
      </dict>
    </dict>
  </array>
</dict>
</plist>
PLIST

chmod +x "$DEST/Contents/MacOS/AndrossApp"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

echo "✓ Build complete! Application created at: $DEST"
echo "  You can double-click it in Finder (first time: right-click → Open if macOS warns it's unsigned)."
