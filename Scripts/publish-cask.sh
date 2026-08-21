#!/usr/bin/env bash
# Regenerates the Homebrew cask from a published GitHub release and pushes it
# to the tap repo, so `brew install --cask ishanmalu/tap/perch` picks it up.
#
#   Scripts/publish-cask.sh 1.0.0
#
# Requires: gh (authenticated). Creates ishanmalu/homebrew-tap if missing.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: publish-cask.sh <version>}"
REPO="ishanmalu/Perch"
TAP="ishanmalu/homebrew-tap"
DMG="Perch-$VERSION.dmg"

echo "==> Fetching checksum for $DMG from release v$VERSION"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if gh release download "v$VERSION" --repo "$REPO" --pattern "SHA256SUMS.txt" --dir "$TMP" 2>/dev/null; then
  SHA="$(grep "$DMG" "$TMP/SHA256SUMS.txt" | awk '{print $1}')"
else
  echo "    no SHA256SUMS.txt asset; hashing the DMG directly"
  gh release download "v$VERSION" --repo "$REPO" --pattern "$DMG" --dir "$TMP"
  SHA="$(shasum -a 256 "$TMP/$DMG" | awk '{print $1}')"
fi
[ -n "$SHA" ] || { echo "could not determine sha256"; exit 1; }
echo "    sha256 = $SHA"

echo "==> Rendering cask"
sed -e "s/__VERSION__/$VERSION/g" -e "s/__SHA256__/$SHA/g" homebrew/perch.rb > "$TMP/perch.rb"

echo "==> Publishing to $TAP"
if ! gh repo view "$TAP" >/dev/null 2>&1; then
  gh repo create "$TAP" --public --description "Homebrew tap for Perch" >/dev/null
fi

git clone -q "https://github.com/$TAP.git" "$TMP/tap" 2>/dev/null || {
  mkdir -p "$TMP/tap" && cd "$TMP/tap" && git init -q -b main \
    && git remote add origin "https://github.com/$TAP.git" && cd - >/dev/null
}

mkdir -p "$TMP/tap/Casks"
cp "$TMP/perch.rb" "$TMP/tap/Casks/perch.rb"
cd "$TMP/tap"
if [ ! -f README.md ]; then
  cat > README.md <<TAPREADME
# Homebrew tap for Perch

\`\`\`bash
brew tap $TAP
brew install --cask --no-quarantine perch
\`\`\`

See [$REPO](https://github.com/$REPO).
TAPREADME
fi
git add -A
git commit -q -m "perch $VERSION" || { echo "    already up to date"; exit 0; }
git push -q -u origin main
echo "==> Done. Install with: brew install --cask $TAP/perch"
