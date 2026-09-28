#!/bin/bash
# One-time setup: a self-signed "B-Side Local Signing" identity in a dedicated
# keychain, so bundle.sh signs every build with the same designated requirement
# and macOS privacy (TCC) grants survive rebuilds.
set -euo pipefail

NAME="B-Side Local Signing"
KEYCHAIN="$HOME/Library/Keychains/bside-signing.keychain-db"
# Guards only a local self-signed key; bundle.sh unlocks with it unattended.
PASSWORD="bside-local"

if [ -f "$KEYCHAIN" ]; then
    echo "$KEYCHAIN already exists; nothing to do."
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.cfg" <<CFG
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$NAME
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CFG

# The system LibreSSL: OpenSSL 3's default PKCS#12 encryption fails to import
# into the macOS keychain ("MAC verification failed").
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/cert.cfg" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -out "$WORK/identity.p12" -passout pass:x -name "$NAME"

security create-keychain -p "$PASSWORD" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"
security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P x -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "$PASSWORD" "$KEYCHAIN" >/dev/null

# codesign only finds an untrusted identity through the user search list.
EXISTING=()
while IFS= read -r line; do
    EXISTING+=("$(echo "$line" | tr -d '"' | xargs)")
done < <(security list-keychains -d user)
security list-keychains -d user -s "${EXISTING[@]}" "$KEYCHAIN"

echo "Created \"$NAME\" in $KEYCHAIN."
