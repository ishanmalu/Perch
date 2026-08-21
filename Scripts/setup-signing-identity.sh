#!/usr/bin/env bash
# Creates a self-signed code-signing certificate so local builds keep a stable
# identity. Without it, ad-hoc signing gives every rebuild a new identity and
# macOS forgets the Accessibility grant each time you rebuild.
#
# Run once. It will ask for your login keychain password.
set -euo pipefail

NAME="${1:-Perch Dev}"

if security find-identity -v -p codesigning | grep -q "$NAME"; then
  echo "Signing identity '$NAME' already exists."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/ext.cnf" <<CNF
[req]
distinguished_name = dn
prompt = no
x509_extensions = v3
[dn]
CN = $NAME
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

echo "==> Generating certificate"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/ext.cnf" 2>/dev/null

# -legacy: OpenSSL 3 defaults to a PKCS#12 MAC that macOS's Security framework
# cannot verify, which fails the import with a misleading "wrong password".
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/id.p12" -passout pass:perch -name "$NAME" 2>/dev/null \
  || openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
       -out "$TMP/id.p12" -passout pass:perch -name "$NAME"

echo "==> Importing into your login keychain"
security import "$TMP/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
  -P perch -A -T /usr/bin/codesign

echo "==> Trusting it for code signing (needs your password)"
security add-trusted-cert -r trustRoot -p codeSign \
  -k "$HOME/Library/Keychains/login.keychain-db" "$TMP/cert.pem"

echo
echo "Done. Rebuild with:  Scripts/build-app.sh"
echo "Builds will now use '$NAME', so the Accessibility grant survives rebuilds."
