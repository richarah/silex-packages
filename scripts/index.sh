#!/bin/sh
# index.sh
# Generate and sign APKINDEX.tar.gz for the x86_64 and aarch64 package dirs.
#
# Environment:
#   PRIVKEY  — path to RSA private key (used by apk mkndx --sign-key)
#   REPO_DIR — explicit directory to index (optional;
#              defaults to both x86_64/ and aarch64/ under repo root)
#
# Requires: apk (static binary)
#
# Uses 'apk mkndx' (v3 index format) instead of 'apk index' (v2).
# The v2 format (apk index) produces a gzip'd tar; prepending a separate
# signature gzip stream (old abuild-sign method) makes apk v3 report
# "file format is invalid or inconsistent". apk mkndx integrates signing
# via --sign-key and produces a format apk v3 update can read.

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

    if [ -f "$PRIVKEY" ] && [ -s "$PRIVKEY" ]; then
        (cd "$DIR" && apk mkndx \
            --allow-untrusted \
            --arch "$ARCH" \
            --sign-key "$PRIVKEY" \
            -o APKINDEX.tar.gz \
            *.apk)
        printf 'index: signed %s/APKINDEX.tar.gz\n' "$DIR"
    else
        (cd "$DIR" && apk mkndx \
            --allow-untrusted \
            --arch "$ARCH" \
            -o APKINDEX.tar.gz \
            *.apk)
        printf 'index: WARNING: no signing key, index is unsigned\n'
    fi
}

if [ -n "$REPO_DIR" ]; then
    ARCH="${ARCH:-$(uname -m)}"
    do_index "$REPO_DIR" "$ARCH"
else
    do_index "$REPO_ROOT/x86_64"  x86_64
    do_index "$REPO_ROOT/aarch64" aarch64
fi
