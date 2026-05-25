#!/bin/bash
# Builds TokenCat.app — a self-contained macOS menu-bar app bundle.
# Usage: ./package.sh   → produces build/TokenCat.app
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="TokenCat"
BUNDLE_ID="com.tokencat.TokenCat"
VERSION="1.0"
EXECUTABLE="tokencat"            # matches the SPM target name
OUT="build"
APP="$OUT/$APP_NAME.app"

echo "▸ Building release binary…"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/$EXECUTABLE"

echo "▸ Assembling $APP …"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/assets"

cp "$BIN" "$APP/Contents/MacOS/$EXECUTABLE"
cp -R assets/run assets/sleep "$APP/Contents/Resources/assets/"

# App icon (optional): build AppIcon.icns from assets/appicon_1024.png if present.
ICON_KEY=""
if [[ -f assets/appicon_1024.png ]]; then
  echo "▸ Building app icon…"
  ICONSET="$OUT/AppIcon.iconset"
  rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  for SPEC in "16:16x16" "32:16x16@2x" "32:32x32" "64:32x32@2x" \
              "128:128x128" "256:128x128@2x" "256:256x256" "512:256x256@2x" \
              "512:512x512" "1024:512x512@2x"; do
    PX="${SPEC%%:*}"; NAME="${SPEC##*:}"
    sips -z "$PX" "$PX" assets/appicon_1024.png --out "$ICONSET/icon_$NAME.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  rm -rf "$ICONSET"
  ICON_KEY="<key>CFBundleIconFile</key><string>AppIcon</string>"
fi

echo "▸ Writing Info.plist…"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$EXECUTABLE</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    $ICON_KEY
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>TokenCat</string>
</dict>
</plist>
PLIST

echo "▸ Ad-hoc code-signing…"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "  (codesign skipped)"

echo "✓ Done: $APP"
echo "  Run:       open \"$APP\""
echo "  Install:   cp -R \"$APP\" /Applications/"
