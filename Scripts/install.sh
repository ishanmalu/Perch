#!/usr/bin/env bash
# Builds the current source and installs it over /Applications/Perch.app.
# This is the update path when you're running a local build rather than a
# published release.
#
#   Scripts/install.sh [version]
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-$(date +%Y.%m.%d)}"

Scripts/build-app.sh "$VERSION"

echo "==> Verifying the build"
dist/Perch.app/Contents/MacOS/Perch --selftest >/dev/null

if pgrep -f "Perch.app/Contents/MacOS/Perch" >/dev/null; then
  echo "==> Quitting the running copy"
  osascript -e 'quit app "Perch"' 2>/dev/null || pkill -f "Perch.app/Contents/MacOS/Perch" || true
  sleep 1
fi

echo "==> Installing to /Applications"
rm -rf /Applications/Perch.app
cp -R dist/Perch.app /Applications/Perch.app

echo "==> Launching"
open /Applications/Perch.app
sleep 2
if pgrep -f "Perch.app/Contents/MacOS/Perch" >/dev/null; then
  echo "==> Perch $VERSION is running"
else
  echo "!! Perch did not stay running — check Console.app for a crash report"
  exit 1
fi
