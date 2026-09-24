#!/bin/bash
# Build WebDock.app into ./build
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=build/WebDock.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/WebDock "$APP/Contents/MacOS/WebDock"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# App icon: iconutil only accepts the standard icon_*.png names, so stage just those.
ICONSET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONSET"
cp BrowserBarIcon.iconset/icon_*.png "$ICONSET/"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"

codesign --force --sign - "$APP" >/dev/null

echo "Built $APP"
