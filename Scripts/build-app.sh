#!/usr/bin/env bash
# Builds Perch.app into dist/. Usage: Scripts/build-app.sh [version]
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-1.0.0}"
APP="dist/Perch.app"

echo "==> Building release binary (universal)"
swift build -c release --scratch-path .build/arm64 \
  -Xswiftc -target -Xswiftc arm64-apple-macos14.0 -Xcc -arch -Xcc arm64
swift build -c release --scratch-path .build/x86_64 \
  -Xswiftc -target -Xswiftc x86_64-apple-macos14.0 -Xcc -arch -Xcc x86_64

BIN="dist/Perch-universal"
mkdir -p dist
lipo -create -output "$BIN" .build/arm64/release/Perch .build/x86_64/release/Perch
lipo -archs "$BIN"

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Perch"
rm -f "$BIN"

if [ ! -f Resources/Perch.icns ]; then
  echo "==> Generating icon"
  swift Scripts/makeicon.swift Resources >/dev/null
  iconutil -c icns Resources/Perch.iconset -o Resources/Perch.icns
fi
cp Resources/Perch.icns "$APP/Contents/Resources/Perch.icns"
sed "s/__VERSION__/$VERSION/g" Resources/Info.plist > "$APP/Contents/Info.plist"

echo "==> Signing (ad-hoc)"
codesign --force --deep --sign - --options runtime "$APP" 2>/dev/null \
  || codesign --force --deep --sign - "$APP"

echo "==> Built $APP ($VERSION)"
