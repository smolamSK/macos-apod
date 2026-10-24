#!/usr/bin/env bash
# build-app.sh — build APOD.app from the Swift package: release binary, Info.plist, icon,
# ad-hoc signature. Notifications, the login item and Terminal automation need the bundle.
#
#   scripts/build-app.sh            builds ./APOD.app
#   scripts/build-app.sh --install  also copies it to /Applications and opens it
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=1.0.0
APP=APOD.app

swift build -c release --product APOD
BIN=$(swift build -c release --show-bin-path)/APOD

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/APOD"

if [[ ! -f build/AppIcon.icns ]]; then
    mkdir -p build
    swift scripts/make-icon.swift build/AppIcon.iconset
    iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat >"$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>io.github.smolamsk.apod-mac</string>
    <key>CFBundleName</key><string>APOD</string>
    <key>CFBundleDisplayName</key><string>NASA APOD</string>
    <key>CFBundleExecutable</key><string>APOD</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>APOD recolours its Terminal profile to match the new picture.</string>
    <key>NSHumanReadableCopyright</key><string>GPL-2.0-or-later. Pictures © their authors, as credited on APOD.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "built $PWD/$APP"

if [[ ${1:-} == --install ]]; then
    osascript -e 'tell application "APOD" to quit' 2>/dev/null || true
    rm -rf "/Applications/$APP"
    cp -R "$APP" /Applications/
    open "/Applications/$APP"
    echo "installed /Applications/$APP"
fi
