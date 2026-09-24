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

# Regenerate the icon only when the source art is newer; the build should not
# need Pillow just to produce an unchanged .icns.
if [ BrowserBarIcon.iconset/BrowserBar_1024.png -nt Resources/AppIcon.icns ]; then
    python3 Scripts/make-icon.py || echo "warning: could not rebuild icon" >&2
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Sign with a stable identity so the keychain and privacy grants survive
# rebuilds; an ad-hoc signature changes every build and macOS treats each one
# as a new app. Identities are matched by SHA-1 hash because two certificates
# with the same common name make codesign refuse an ambiguous match. Override
# with CODESIGN_IDENTITY.
IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    IDENTITY="$(security find-identity -v -p codesigning \
        | awk '/Developer ID Application/ {print $2; exit}' || true)"
fi
if [ -z "$IDENTITY" ]; then
    IDENTITY="$(security find-identity -v -p codesigning \
        | awk '/Apple Development/ {print $2; exit}' || true)"
fi
if [ -z "$IDENTITY" ]; then
    IDENTITY="-"
    echo "warning: no signing identity found; ad-hoc signing." >&2
fi

codesign --force --sign "$IDENTITY" "$APP"
codesign -dv "$APP" 2>&1 | grep -E "^(Authority|TeamIdentifier)=" | head -2 || true

echo "Built $APP"
