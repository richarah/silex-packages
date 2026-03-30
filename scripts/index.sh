#!/bin/sh
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

    apk index --allow-untrusted --arch "$ARCH" --output "${DIR}/APKINDEX.tar.gz" "$DIR"/*.apk

    # Post-process: strip Debian :any/:native arch qualifiers from dependency entries.
    # Cached APKs may have been built with old mkpkginfo.sh that didn't strip these.
    # APK does not understand Debian arch qualifiers and will fail to resolve them.
    # NOTE: must list files explicitly (not '.') to avoid './APKINDEX' path in tar,
    # which APK cannot parse ("file format not supported").
    IDX_TMP=$(mktemp -d)
    tar -xzf "${DIR}/APKINDEX.tar.gz" -C "$IDX_TMP"
    if [ -f "$IDX_TMP/APKINDEX" ]; then
        sed -i '/^D:/ s/:[a-z][a-z0-9]*//g' "$IDX_TMP/APKINDEX"
        TARFILES="APKINDEX"
        [ -f "$IDX_TMP/DESCRIPTION" ] && TARFILES="$TARFILES DESCRIPTION"
        # shellcheck disable=SC2086
        tar -czf "${DIR}/APKINDEX.tar.gz" -C "$IDX_TMP" $TARFILES
        printf 'index: stripped :any/:native qualifiers from APKINDEX\n'
    fi
    rm -rf "$IDX_TMP"

    printf 'index: %s/APKINDEX.tar.gz\n' "$DIR"
}

if [ -n "$REPO_DIR" ]; then
    ARCH="${ARCH:-$(uname -m)}"
    do_index "$REPO_DIR" "$ARCH"
else
    do_index "$REPO_ROOT/x86_64"  x86_64
    do_index "$REPO_ROOT/aarch64" aarch64
fi
