#!/bin/sh
# sign.sh <privkey> <pubkey> <file>
# Sign an APKINDEX.tar.gz (or .apk) using the APK v3 format.
# Produces a single gzip stream containing both signature and original file.
set -e

PRIVKEY="$1"
PUBKEY="$2"
FILE="$3"

[ -f "$PRIVKEY" ] || { printf 'sign: %s: private key not found\n' "$PRIVKEY" >&2; exit 1; }
[ -f "$PUBKEY"  ] || { printf 'sign: %s: public key not found\n'  "$PUBKEY"  >&2; exit 1; }
[ -f "$FILE"    ] || { printf 'sign: %s: file not found\n'         "$FILE"    >&2; exit 1; }

PUBKEY_NAME=$(basename "$PUBKEY")
SIGFILE=".SIGN.RSA.${PUBKEY_NAME}"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT INT TERM

# Compute SHA-1 signature of the file (apk expects SHA-1, not SHA-256)
openssl dgst -sha1 -sign "$PRIVKEY" -out "$TMPDIR/$SIGFILE" "$FILE"

# Create a single gzip stream containing both signature and original file
# This is the key difference: tar then gzip once, not gzip then cat
tar -C "$TMPDIR" -cf - "$SIGFILE" "$FILE" | gzip -9 > "${FILE}.signed"
mv "${FILE}.signed" "$FILE"

printf 'signed: %s\n' "$FILE"
