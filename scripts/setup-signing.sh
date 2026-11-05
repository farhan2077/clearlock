#!/bin/zsh
# Creates a stable self-signed code-signing identity in a dedicated keychain.
# macOS ties Accessibility permission and update verification to this
# certificate, so keep .signing/ backed up: losing it means every user must
# re-grant permissions and cannot auto-update to builds signed by a new cert.
set -euo pipefail

ROOT=${0:A:h:h}
DIR="$ROOT/.signing"
NAME="ClearLock Self-Signed"
KEYCHAIN="$DIR/clearlock-signing.keychain-db"
KC_PASS="clearlock"   # protects only this local keychain; the key never leaves it

if [[ -f "$KEYCHAIN" ]]; then
  echo "Signing keychain already exists at $KEYCHAIN"
  exit 0
fi

mkdir -p "$DIR"
cd "$DIR"

cat > cert.cnf <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 7300 \
  -keyout key.pem -out cert.pem -config cert.cnf 2>/dev/null
P12_PASS=$(openssl rand -hex 16)
openssl pkcs12 -export -legacy -inkey key.pem -in cert.pem \
  -name "$NAME" -out identity.p12 -passout "pass:$P12_PASS"

security create-keychain -p "$KC_PASS" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"   # no auto-lock timeout
security unlock-keychain -p "$KC_PASS" "$KEYCHAIN"
security import identity.p12 -k "$KEYCHAIN" -P "$P12_PASS" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KC_PASS" "$KEYCHAIN" >/dev/null

rm -f key.pem identity.p12 cert.cnf
echo "Created signing identity \"$NAME\" in $KEYCHAIN"
