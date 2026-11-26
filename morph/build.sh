#!/bin/bash
# Builds Morph.app (Apple silicon + Intel) and Morph.zip into morph/build. Needs Xcode's command-line tools.
set -euo pipefail
cd "$(dirname "$0")"
rm -rf build
mkdir -p build

for arch in arm64 x86_64; do
  swiftc -O -target "$arch-apple-macos12.0" -o "build/Morph-$arch" Sources/*.swift
done
lipo -create -output build/Morph build/Morph-arm64 build/Morph-x86_64

APP=build/Morph.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/Morph "$APP/Contents/MacOS/Morph"
cp Info.plist "$APP/Contents/Info.plist"

# The icon is drawn by the app itself, so there are no image files to keep in the repo.
ICONSET=build/Morph.iconset
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  build/Morph --icon "$ICONSET/icon_${size}x${size}.png" "$size"
  build/Morph --icon "$ICONSET/icon_${size}x${size}@2x.png" "$((size * 2))"
done
iconutil -c icns -o "$APP/Contents/Resources/AppIcon.icns" "$ICONSET"

codesign --force --sign - "$APP"
(cd build && ditto -c -k --keepParent Morph.app Morph.zip)
rm -rf build/Morph build/Morph-arm64 build/Morph-x86_64 "$ICONSET"
echo "Built $PWD/$APP"
