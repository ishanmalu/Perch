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

# A stable identity keeps macOS from treating each rebuild as a brand new app,
# which would reset the Accessibility grant every time. Scripts/setup-signing-identity.sh
# creates one; without it we fall back to ad-hoc.
# Preference order: an explicit override, then a real Developer ID (the only
# kind Apple will notarize), then the local self-signed identity, then ad-hoc.
DEVELOPER_ID="$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')"
IDENTITY="${PERCH_SIGN_IDENTITY:-${DEVELOPER_ID:-Perch Dev}}"

if [ -n "$DEVELOPER_ID" ] && [ "$IDENTITY" = "$DEVELOPER_ID" ]; then
  echo "==> Signing as '$IDENTITY' (hardened runtime, notarizable)"
  codesign --force --deep --options runtime --timestamp --sign "$IDENTITY" "$APP"
elif security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
  echo "==> Signing as '$IDENTITY'"
  codesign --force --deep --sign "$IDENTITY" "$APP"
else
  echo "==> Signing (ad-hoc; run Scripts/setup-signing-identity.sh for a stable identity)"
  codesign --force --deep --sign - "$APP"
fi

echo "==> Built $APP ($VERSION)"
