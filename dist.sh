#!/bin/sh
# Builds the app and packages it for a release: build/Deeanes-<version>.dmg and .zip
set -eu
cd "$(dirname "$0")"
./build.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
APP=build/Deeanes.app
DMG=build/Deeanes-$VERSION.dmg

# Drag-to-install disk image (app + Applications shortcut, custom volume icon). Needs uv.
rm -f "$DMG"
uvx --quiet dmgbuild -s tools/dmg-settings.py -D app="$APP" -D icon=Resources/AppIcon.icns Deeanes "$DMG"

rm -f "build/Deeanes-$VERSION.zip"
ditto -c -k --keepParent "$APP" "build/Deeanes-$VERSION.zip"

shasum -a 256 "$DMG" "build/Deeanes-$VERSION.zip"
