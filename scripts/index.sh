#!/bin/sh
# index.sh
# Generate and sign APKINDEX.tar.gz for package directories.

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

    TEMP_INDEX="${DIR}/APKINDEX.tmp"
    
    # Generate unsigned index first
    apk index --arch "$ARCH" --output "$TEMP_INDEX" "$DIR"/*.apk

    # Sign the index if private key is available
    if [ -n "$PRIVKEY" ] && [ -f "$PRIVKEY" ] && [ -s "$PRIVKEY" ]; then
        apk sign --sign-key "$PRIVKEY" --output "${DIR}/APKINDEX.tar.gz" "$TEMP_INDEX"
        rm -f "$TEMP_INDEX"
        printf 'index: signed %s/APKINDEX.tar.gz\n' "$DIR"
    else
        # Fallback to unsigned (for local testing)
        mv "$TEMP_INDEX" "${DIR}/APKINDEX.tar.gz"
        printf 'index: WARNING: unsigned %s/APKINDEX.tar.gz (no private key)\n' "$DIR"
    fi
}

if [ -n "$REPO_DIR" ]; then
    ARCH="${ARCH:-$(uname -m)}"
    do_index "$REPO_DIR" "$ARCH"
else
    do_index "$REPO_ROOT/x86_64"  x86_64
    do_index "$REPO_ROOT/aarch64" aarch64
fi
