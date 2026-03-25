#!/bin/sh
# index.sh
# Generate and sign APKINDEX.tar.gz for the x86_64 and aarch64 package dirs.
#
# Environment:
#   PRIVKEY  — path to RSA private key (required for signing)
#   PUBKEY   — path to RSA public key  (required for signing)
#   REPO_DIR — explicit directory to index (optional;
#              defaults to both x86_64/ and aarch64/ under repo root)
#
# Requires: apk (static binary), openssl, tar

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

do_index() {
    DIR="$1"
    ARCH="$2"

    [ -d "$DIR" ] || return 0

    count=$(ls "$DIR"/*.apk 2>/dev/null | wc -l)
    [ "$count" -eq 0 ] && { printf 'index: %s: no .apk files, skipping\n' "$DIR"; return 0; }

    printf 'index: %s (%d packages)\n' "$DIR" "$count"

    (cd "$DIR" && apk index \
        --allow-untrusted \
        --rewrite-arch "$ARCH" \
        -o APKINDEX.tar.gz \
        *.apk)

    if [ -n "$PRIVKEY" ] && [ -n "$PUBKEY" ]; then
        "$SCRIPT_DIR/sign.sh" "$PRIVKEY" "$PUBKEY" "$DIR/APKINDEX.tar.gz"
        printf 'index: signed %s/APKINDEX.tar.gz\n' "$DIR"
    else
        printf 'index: WARNING: no signing keys, index is unsigned\n'
    fi
}

if [ -n "$REPO_DIR" ]; then
    ARCH="${ARCH:-$(uname -m)}"
    do_index "$REPO_DIR" "$ARCH"
else
    do_index "$REPO_ROOT/x86_64"  x86_64
    do_index "$REPO_ROOT/aarch64" aarch64
fi
