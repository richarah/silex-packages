#!/bin/sh
# recompile-all.sh — recompile all packages in lists/recompile.list.
# Skips packages already built.
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export ARCH="${ARCH:-$(uname -m)}"
export REPO_DIR="${REPO_DIR:-$REPO_ROOT/$ARCH}"
export SCRIPTS_DIR="$SCRIPT_DIR"

mkdir -p "$REPO_DIR"

[ -f "$REPO_ROOT/config/cflags.conf" ] && . "$REPO_ROOT/config/cflags.conf"
export CC CXX CFLAGS CXXFLAGS LDFLAGS STRIP
export PRIVKEY PUBKEY

LIST="$REPO_ROOT/lists/recompile.list"
[ -f "$LIST" ] || { printf 'recompile-all: %s not found\n' "$LIST" >&2; exit 1; }

# Compile apk-tar helper
cc -O2 -o /tmp/silex-apk-tar "$SCRIPT_DIR/apk-tar.c" ||
    { printf 'ERROR: failed to compile apk-tar.c\n' >&2; exit 1; }

printf '=== recompiling %d packages ===\n' "$(wc -l < "$LIST")"

while IFS= read -r pkg; do
    [ -n "$pkg" ] || continue
    case "$pkg" in '#'*) continue ;; esac
    if ls "$REPO_DIR/$pkg-"[0-9]*.apk >/dev/null 2>&1; then
        printf 'cached  %s\n' "$pkg"
    else
        "$SCRIPT_DIR/recompile.sh" "$pkg" ||
            printf 'WARNING: recompile failed for %s\n' "$pkg" >&2
    fi
done < "$LIST"

printf '=== recompile done ===\n'
