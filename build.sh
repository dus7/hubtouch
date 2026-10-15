#!/bin/bash
# Builds HubTouch.app (menu bar app) and the hubtouch command-line tool.
# Set SIGN_IDENTITY to a code signing identity so Accessibility permission survives rebuilds;
# the default ad-hoc signature needs the permission granted again after every build.
set -euo pipefail

cd "$(dirname "$0")"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
APP=build/HubTouch.app

rm -rf build
mkdir -p "$APP/Contents/MacOS"

clang -fobjc-arc -Wall -Wextra -O2 -mmacosx-version-min=13.0 \
    -framework Foundation -framework AppKit -framework ApplicationServices \
    hubtouch.m -o build/hubtouch

cp build/hubtouch "$APP/Contents/MacOS/HubTouch"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>HubTouch</string>
    <key>CFBundleIdentifier</key>
    <string>local.hubtouch</string>
    <key>CFBundleName</key>
    <string>HubTouch</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

codesign --sign "$SIGN_IDENTITY" "$APP"
echo "Built $APP and build/hubtouch"
