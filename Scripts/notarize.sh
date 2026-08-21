#!/usr/bin/env bash
# Signs, notarizes and staples a built Perch.app, then rebuilds the DMG around
# it and staples that too.
#
#   Scripts/notarize.sh dist/Perch.app 1.4.0
#
# Requires an Apple Developer Program membership and these variables:
#
#   SIGNING_IDENTITY   "Developer ID Application: Your Name (TEAMID)"
#   APPLE_ID           your Apple ID email
#   APPLE_TEAM_ID      10-character team ID
#   APPLE_APP_PASSWORD app-specific password from appleid.apple.com
#
# Without them, builds stay ad-hoc signed and macOS quarantines the download.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:-dist/Perch.app}"
VERSION="${2:-0.0.0}"
DMG="dist/Perch-$VERSION.dmg"

: "${SIGNING_IDENTITY:?set SIGNING_IDENTITY}"
: "${APPLE_ID:?set APPLE_ID}"
: "${APPLE_TEAM_ID:?set APPLE_TEAM_ID}"
: "${APPLE_APP_PASSWORD:?set APPLE_APP_PASSWORD}"

echo "==> Signing with a hardened runtime"
# Notarization requires the hardened runtime and a secure timestamp; an ad-hoc
# signature satisfies neither.
codesign --force --deep --options runtime --timestamp \
         --sign "$SIGNING_IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "==> Rebuilding the DMG around the signed app"
STAGE="dist/dmg-stage"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/Perch.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Perch $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo "==> Signing the DMG"
codesign --force --sign "$SIGNING_IDENTITY" --timestamp "$DMG"

echo "==> Submitting to Apple (this usually takes 1-5 minutes)"
xcrun notarytool submit "$DMG" \
  --apple-id "$APPLE_ID" \
  --team-id "$APPLE_TEAM_ID" \
  --password "$APPLE_APP_PASSWORD" \
  --wait

echo "==> Stapling the ticket"
# Stapling puts the ticket inside the file so Gatekeeper clears it even offline.
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo "==> Verifying as Gatekeeper will see it"
spctl -a -t open --context context:primary-signature -vv "$DMG"

echo
echo "==> Notarized: $DMG"
shasum -a 256 "$DMG"
