#!/usr/bin/env bash
# Creates a local code signing certificate once and prints its name.
#
# Ad-hoc signing gives the app a different identity on every build, and macOS keys microphone
# and system-audio permission to that identity — so every reinstall silently dropped the
# permissions and capture returned digital silence. A stable self-signed certificate keeps the
# identity, and the permissions, across rebuilds. Same trick as in wisper-clone.
set -euo pipefail

# Reuse a local signing certificate that already exists on this machine before creating one:
# adding a new trusted certificate needs an admin prompt, and the identity's name is cosmetic —
# what matters is that it stays the same across rebuilds.
PREFERRED="OpenTranscribe Local Code Signing"
EXISTING="$(security find-identity -v -p codesigning | sed -n 's/.*"\(.*Local Code Signing\)".*/\1/p' | head -1)"
if [ -n "$EXISTING" ]; then
    echo "$EXISTING"
    exit 0
fi
IDENTITY_NAME="$PREFERRED"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

KEY_FILE="$TEMP_DIR/key.pem"
CERT_FILE="$TEMP_DIR/cert.cer"
P12_FILE="$TEMP_DIR/identity.p12"
P12_PASSWORD="opentranscribe-local"

openssl req \
    -newkey rsa:2048 -nodes -keyout "$KEY_FILE" \
    -x509 -days 3650 -out "$CERT_FILE" \
    -subj "/CN=$IDENTITY_NAME/" \
    -addext "keyUsage=digitalSignature" \
    -addext "extendedKeyUsage=codeSigning" >/dev/null 2>&1

openssl pkcs12 -export -legacy \
    -inkey "$KEY_FILE" -in "$CERT_FILE" -out "$P12_FILE" \
    -passout "pass:$P12_PASSWORD" >/dev/null 2>&1

security import "$P12_FILE" -k "$KEYCHAIN" -P "$P12_PASSWORD" -T /usr/bin/codesign >/dev/null
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$CERT_FILE" >/dev/null

echo "$IDENTITY_NAME"
