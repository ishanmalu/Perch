#!/usr/bin/env bash
#
# Installs the latest Perch release.
#
#   curl -fsSL https://ishanmalu.github.io/Perch/install.sh | bash
#
# Perch is signed but not notarized, because notarizing needs a paid Apple
# Developer account. macOS therefore quarantines the download and blocks the
# first launch. This does what you would otherwise do by hand: fetch the
# release, check it against the published checksum, install it, clear the
# quarantine flag, and start it.
#
# It asks for no privileges and touches nothing outside the app itself. If you
# would rather read it before running it, that is the better habit:
#
#   curl -fsSL https://ishanmalu.github.io/Perch/install.sh -o install.sh
#   less install.sh && bash install.sh
#
set -euo pipefail

REPO="ishanmalu/Perch"
API="https://api.github.com/repos/$REPO/releases/latest"

say() { printf '\033[1m==>\033[0m %s\n' "$1"; }
die() { printf '\033[1;31m!!\033[0m %s\n' "$1" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "Perch is a macOS app."
major="$(sw_vers -productVersion | cut -d. -f1)"
[ "$major" -ge 14 ] || die "Perch needs macOS 14 or newer; this is $(sw_vers -productVersion)."

say "Finding the latest release"
json="$(curl -fsSL "$API")" || die "Could not reach GitHub."
version="$(printf '%s' "$json" | sed -n 's/.*"tag_name": *"v\{0,1\}\([^"]*\)".*/\1/p' | head -1)"
[ -n "$version" ] || die "Could not read the latest version."

dmg_url="$(printf '%s' "$json" | grep -o 'https://[^"]*\.dmg' | head -1)"
sums_url="$(printf '%s' "$json" | grep -o 'https://[^"]*SHA256SUMS\.txt' | head -1)"
[ -n "$dmg_url" ] || die "That release has no disk image."
[ -n "$sums_url" ] || die "That release publishes no checksum, so it will not be installed."

tmp="$(mktemp -d)"
trap 'hdiutil detach "$tmp/mnt" -quiet -force 2>/dev/null || true; rm -rf "$tmp"' EXIT

say "Downloading Perch $version"
curl -fsSL "$dmg_url" -o "$tmp/Perch.dmg" || die "Download failed."
curl -fsSL "$sums_url" -o "$tmp/SHA256SUMS.txt" || die "Could not fetch the checksum."

say "Checking it against the published checksum"
expected="$(awk '{print $1}' "$tmp/SHA256SUMS.txt" | head -1)"
actual="$(shasum -a 256 "$tmp/Perch.dmg" | awk '{print $1}')"
[ "$expected" = "$actual" ] || die "Checksum mismatch. The download was discarded."

# /Applications is writable by admins; fall back to the user's own folder so
# this never needs sudo.
dest="/Applications"
[ -w "$dest" ] || dest="$HOME/Applications"
mkdir -p "$dest"

say "Installing to $dest"
mkdir -p "$tmp/mnt"
hdiutil attach "$tmp/Perch.dmg" -nobrowse -noautoopen -quiet -mountpoint "$tmp/mnt" \
  || die "Could not open the disk image."
[ -d "$tmp/mnt/Perch.app" ] || die "The disk image did not contain Perch."

if pgrep -f "Perch.app/Contents/MacOS/Perch" >/dev/null 2>&1; then
  say "Quitting the running copy"
  osascript -e 'quit app "Perch"' 2>/dev/null || true
  sleep 1
fi

rm -rf "$dest/Perch.app"
# ditto rather than cp: it preserves the signature's extended attributes.
ditto "$tmp/mnt/Perch.app" "$dest/Perch.app" || die "Could not copy Perch into $dest."

say "Clearing the quarantine flag"
xattr -dr com.apple.quarantine "$dest/Perch.app" 2>/dev/null || true

say "Starting Perch"
open "$dest/Perch.app"

cat <<NOTE

Perch $version is installed in $dest.

Grant Accessibility access when asked — window tiling, the switcher and the
cleaning modes need it: System Settings -> Privacy & Security -> Accessibility.

Press Control-Option-Space to open the panel.
Updates from here install themselves: press Check in the panel footer.
NOTE
