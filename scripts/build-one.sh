#!/bin/sh
# build-one.sh <package-name> [recompile|repack|auto]
# Build a single Debian package as an APK.
#
# Mode:
#   recompile — fetch source, build with Silex flags
#   repack    — download binary .deb, repack as .apk
#   auto      — run classify.sh to determine mode (default)
#
# Environment: same as recompile.sh / repack.sh
#   REPO_DIR, ARCH, PRIVKEY, PUBKEY, SCRIPTS_DIR

set -e

PKG="$1"
MODE="${2:-auto}"

[ -n "$PKG" ] || { printf 'build-one: package name required\n' >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

export SCRIPTS_DIR="${SCRIPTS_DIR:-$SCRIPT_DIR}"
export ARCH="${ARCH:-$(uname -m)}"
export REPO_DIR="${REPO_DIR:-$REPO_ROOT/$ARCH}"

mkdir -p "$REPO_DIR"

# Load compiler flags
[ -z "$CC" ] && [ -f "$REPO_ROOT/config/cflags.conf" ] && . "$REPO_ROOT/config/cflags.conf"

if [ "$MODE" = "auto" ]; then
    RECOMPILE_TMP=$(mktemp)
    REPACK_TMP=$(mktemp)
    trap 'rm -f "$RECOMPILE_TMP" "$REPACK_TMP"' EXIT INT TERM
    printf '%s\n' "$PKG" | "$SCRIPT_DIR/classify.sh" "$RECOMPILE_TMP" "$REPACK_TMP"
    if grep -qx "$PKG" "$RECOMPILE_TMP" 2>/dev/null; then
        MODE=recompile
    else
        MODE=repack
    fi
fi

printf 'build-one: %s [%s]\n' "$PKG" "$MODE"

case "$MODE" in
    recompile) "$SCRIPT_DIR/recompile.sh" "$PKG" ;;
    repack)    "$SCRIPT_DIR/repack.sh"    "$PKG" ;;
    *) printf 'build-one: unknown mode: %s\n' "$MODE" >&2; exit 1 ;;
esac
