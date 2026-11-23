#!/bin/sh
# Builds Deeanes.app (Apple Silicon) into ./build
set -eu
cd "$(dirname "$0")"

APP=build/Deeanes.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -target arm64-apple-macos13.0 -o "$APP/Contents/MacOS/Deeanes" Sources/*.swift

cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
lipo -info "$APP/Contents/MacOS/Deeanes"
echo "Built $APP"
