#!/bin/sh
# setup-keys.sh
# Set up APK signing keys with proper fingerprint-based naming.
# Usage: setup-keys.sh /path/to/private.rsa /path/to/public.rsa.pub
#
# The public key will be copied to /etc/apk/keys/ with its fingerprint-based name.

set -e

PRIVKEY="${1:-/tmp/silex-keys/silex-packages.rsa}"
PUBKEY="${2:-/tmp/silex-keys/silex-packages.rsa.pub}"

[ -f "$PRIVKEY" ] || { echo "Private key not found: $PRIVKEY" >&2; exit 1; }
[ -f "$PUBKEY" ]  || { echo "Public key not found: $PUBKEY" >&2; exit 1; }

# Get the key ID (last 8 chars of fingerprint)
KEYID=$(openssl rsa -in "$PRIVKEY" -pubout 2>/dev/null | \
        openssl dgst -sha1 | \
        sed 's/^.* //' | \
        tail -c 9)

# APK expects the key as -KEYID.rsa.pub
KEYNAME="-${KEYID}.rsa.pub"

echo "Key fingerprint: $KEYID"
echo "Key filename: $KEYNAME"

# Copy to /etc/apk/keys/ with proper name
mkdir -p /etc/apk/keys
cp "$PUBKEY" "/etc/apk/keys/$KEYNAME"
echo "Installed to /etc/apk/keys/$KEYNAME"

# Also copy to keys/ directory for archival
mkdir -p keys
cp "$PUBKEY" "keys/$KEYNAME"
echo "Archived to keys/$KEYNAME"