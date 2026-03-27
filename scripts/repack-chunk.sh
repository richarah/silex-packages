#!/bin/sh
# repack-chunk.sh <chunk> <total>
# Repack every Nth package from lists/repack.list.
# Chunk is 0-indexed. Skips packages already built.
set -e
CHUNK="$1"
TOTAL="$2"

[ -n "$CHUNK" ] || { printf 'usage: repack-chunk.sh <chunk> <total>\n' >&2; exit 1; }
[ -n "$TOTAL" ] || { printf 'usage: repack-chunk.sh <chunk> <total>\n' >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export ARCH="${ARCH:-$(uname -m)}"
export REPO_DIR="${REPO_DIR:-$REPO_ROOT/$ARCH}"
export SCRIPTS_DIR="$SCRIPT_DIR"
export PRIVKEY PUBKEY

mkdir -p "$REPO_DIR"

[ -f "$REPO_ROOT/config/cflags.conf" ] && . "$REPO_ROOT/config/cflags.conf"
export CC CXX CFLAGS CXXFLAGS LDFLAGS STRIP
export PRIVKEY PUBKEY

LIST="$REPO_ROOT/lists/repack.list"
[ -f "$LIST" ] || { printf 'repack-chunk: %s not found\n' "$LIST" >&2; exit 1; }

# Compile apk-tar helper
cc -O2 -o /tmp/silex-apk-tar "$SCRIPT_DIR/apk-tar.c" ||
    { printf 'ERROR: failed to compile apk-tar.c\n' >&2; exit 1; }

TOTAL_PKGS=$(wc -l < "$LIST")
printf 'repack-chunk: chunk %s/%s (%d total packages)\n' "$CHUNK" "$TOTAL" "$TOTAL_PKGS"

sed -n "$((CHUNK + 1))~${TOTAL}p" "$LIST" | while IFS= read -r pkg; do
    [ -n "$pkg" ] || continue
    if ls "$REPO_DIR/$pkg-"[0-9]*.apk >/dev/null 2>&1; then
        printf 'cached  %s\n' "$pkg"
    else
        "$SCRIPT_DIR/repack.sh" "$pkg" ||
            printf 'WARNING: repack failed for %s\n' "$pkg" >&2
    fi
done

printf 'repack-chunk %s: done\n' "$CHUNK"
