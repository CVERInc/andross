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

# SwiftPM resource bundles (they carry scrcpy-server, which the embedded screen
# cannot start without). Without this the .app still runs on the machine that
# built it — Bundle.module quietly falls back to the .build directory — and
# breaks on every other one, which is the only kind of machine a release ever
# lands on. Copy them, then check the payload is really in there.
for bundle in ".build/$CONFIG"/*.bundle; do
  [ -e "$bundle" ] && cp -R "$bundle" "$DEST/Contents/Resources/"
done

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

# Ask the installed binary, from its install path, whether it can find and trust its own
# scrcpy-server — the same lookup and the same checksum the embedded screen performs.
#
# The check this replaces asserted that a path of THIS SCRIPT's choosing existed. Such a check can
# only confirm that the copy above landed where it aimed; it cannot notice the app looking
# somewhere else, because the two paths have different authors and nothing reconciles them. The
# lookup here is correct today (ScrcpyClient.serverSearchBases), which is exactly why the weaker
# check never failed — and why it would not have failed if the lookup changed underneath it.
echo "▸ verifying the app can load its resources from $DEST"
"$DEST/Contents/MacOS/AndrossApp" --verify-resources

echo "✓ Build complete! Application created at: $DEST"
echo "  You can double-click it in Finder (first time: right-click → Open if macOS warns it's unsigned)."
