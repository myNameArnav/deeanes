#!/bin/sh
# Builds a universal (arm64 + x86_64) Deeanes.app into ./build
set -eu
cd "$(dirname "$0")"

APP=build/Deeanes.app
rm -rf build
mkdir -p "$APP/Contents/MacOS"

for arch in arm64 x86_64; do
  swiftc -O -target "$arch-apple-macos13.0" -o "build/deeanes-$arch" Sources/*.swift
done
lipo -create build/deeanes-arm64 build/deeanes-x86_64 -output "$APP/Contents/MacOS/Deeanes"
rm build/deeanes-*

cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
lipo -info "$APP/Contents/MacOS/Deeanes"
echo "Built $APP"
