#!/bin/sh
# sign.sh <privkey> <pubkey> <file>
# Sign an APK index using the format abuild-sign uses.
set -e

PRIVKEY="$1"
PUBKEY="$2"
FILE="$3"

[ -f "$PRIVKEY" ] || { printf 'sign: %s: not found\n' "$PRIVKEY" >&2; exit 1; }
[ -f "$PUBKEY"  ] || { printf 'sign: %s: not found\n' "$PUBKEY"  >&2; exit 1; }
[ -f "$FILE"    ] || { printf 'sign: %s: not found\n' "$FILE"    >&2; exit 1; }

PUBKEY_NAME=$(basename "$PUBKEY")
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT INT TERM

SIGFILE=".SIGN.RSA.${PUBKEY_NAME}"

# RSA-SHA1 signature
openssl dgst -sha1 -sign "$PRIVKEY" -out "$TMPDIR/$SIGFILE" "$FILE"

# posix tar, then strip the two 512-byte end-of-archive null blocks
cd "$TMPDIR"
tar --format=posix \
    --pax-option="exthdr.name=%d/PaxHeaders/%f,atime:=0,ctime:=0" \
    --owner=0 --group=0 --numeric-owner \
    --no-recursion -f - -c "$SIGFILE" > raw.tar

# tar appends 2x 512-byte null blocks at the end. remove them.
RAW_SIZE=$(wc -c < raw.tar)
CUT_SIZE=$((RAW_SIZE - 1024))
head -c "$CUT_SIZE" raw.tar | gzip -n -9 > sig.tar.gz

# prepend signature to file
TMPOUT=$(mktemp)
cat sig.tar.gz "$FILE" > "$TMPOUT"
mv "$TMPOUT" "$FILE"
