#!/usr/bin/env bash
# Builds Perch.app and wraps it in a distributable DMG.
# Usage: Scripts/make-dmg.sh [version]
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-1.0.0}"
DMG="dist/Perch-$VERSION.dmg"
STAGE="dist/dmg-stage"

Scripts/build-app.sh "$VERSION"

echo "==> Staging"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R dist/Perch.app "$STAGE/Perch.app"
ln -s /Applications "$STAGE/Applications"

echo "==> Creating DMG"
hdiutil create -volname "Perch $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo "==> $DMG"
shasum -a 256 "$DMG"
