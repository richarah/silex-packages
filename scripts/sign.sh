#!/bin/sh
# sign.sh <privkey> <pubkey> <file>
# Sign an APK package or APKINDEX.tar.gz using the APK signing format.
#
# The APK signing format (identical to abuild-sign):
#   1. Compute RSA-SHA1 signature of <file>
#   2. Store signature in .SIGN.RSA.<basename-of-pubkey>
#   3. Pack that file into a small gzip'd tar (the "signature envelope")
#   4. Prepend the signature envelope to <file>
#
# The result is a valid multi-stream gzip file. apk-tools reads the first
# stream to verify the signature, then reads the second stream for content.
#
# Requires: openssl, tar

set -e

PRIVKEY="$1"
PUBKEY="$2"
FILE="$3"

[ -f "$PRIVKEY" ] || { printf 'sign: %s: private key not found\n' "$PRIVKEY" >&2; exit 1; }
[ -f "$PUBKEY"  ] || { printf 'sign: %s: public key not found\n'  "$PUBKEY"  >&2; exit 1; }
[ -f "$FILE"    ] || { printf 'sign: %s: file not found\n'         "$FILE"    >&2; exit 1; }

PUBKEY_NAME=$(basename "$PUBKEY")
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT INT TERM

SIGFILE=".SIGN.RSA.${PUBKEY_NAME}"

# Generate RSA SHA-1 signature (SHA-1 is what apk-tools expects)
openssl dgst -sha1 -sign "$PRIVKEY" -out "$TMPDIR/$SIGFILE" "$FILE"

# Pack signature into a small gzip'd tar
tar -C "$TMPDIR" -czf "$TMPDIR/sig.tar.gz" "$SIGFILE"

# Prepend signature envelope to the file (gzip stream concatenation)
TMPOUT=$(mktemp)
cat "$TMPDIR/sig.tar.gz" "$FILE" > "$TMPOUT"
mv "$TMPOUT" "$FILE"
