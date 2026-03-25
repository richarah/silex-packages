#!/bin/sh
# build-all.sh
# Full pipeline: resolve dependency closure -> classify -> repack/recompile -> index.
#
# Environment:
#   ARCH     — target architecture (default: $(uname -m))
#   PRIVKEY  — RSA private key path (for signing)
#   PUBKEY   — RSA public key path  (for signing)
#
# Requires: apt-get, dpkg-deb, dpkg-source, openssl, apk (static binary),
#           clang, mold, ninja (for recompile path)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

export ARCH="${ARCH:-$(uname -m)}"
export REPO_DIR="${REPO_DIR:-$REPO_ROOT/$ARCH}"
export SCRIPTS_DIR="$SCRIPT_DIR"

mkdir -p "$REPO_DIR"

# Load Silex compiler flags
[ -f "$REPO_ROOT/config/cflags.conf" ] && . "$REPO_ROOT/config/cflags.conf"

# Export for child scripts
export CC CXX CFLAGS CXXFLAGS LDFLAGS STRIP
export PRIVKEY PUBKEY REPO_DIR ARCH SCRIPTS_DIR

CLOSURE=$(mktemp)
RECOMPILE_LIST=$(mktemp)
REPACK_LIST=$(mktemp)
trap 'rm -f "$CLOSURE" "$RECOMPILE_LIST" "$REPACK_LIST"' EXIT INT TERM

printf '=== resolving dependency closure ===\n'
"$SCRIPT_DIR/resolve-deps.sh" > "$CLOSURE"
printf '%d packages in closure\n' "$(wc -l < "$CLOSURE")"

printf '=== classifying packages ===\n'
"$SCRIPT_DIR/classify.sh" "$RECOMPILE_LIST" "$REPACK_LIST" < "$CLOSURE"

# Repack first (fast, no compilation)
printf '=== repacking %d packages ===\n' "$(wc -l < "$REPACK_LIST")"
while IFS= read -r pkg; do
    case "$pkg" in ''|'#'*) continue ;; esac
    "$SCRIPT_DIR/repack.sh" "$pkg" || \
        printf 'WARNING: repack failed for %s\n' "$pkg" >&2
done < "$REPACK_LIST"

# Recompile (slow, in dependency order)
# Since Debian's dependency resolver guarantees a valid install order, building
# packages serially in the closure order is safe. For packages that need build
# deps from our own repo, those deps were repacked first and are available.
printf '=== recompiling %d packages ===\n' "$(wc -l < "$RECOMPILE_LIST")"
while IFS= read -r pkg; do
    case "$pkg" in ''|'#'*) continue ;; esac
    "$SCRIPT_DIR/recompile.sh" "$pkg" || \
        printf 'WARNING: recompile failed for %s\n' "$pkg" >&2
done < "$RECOMPILE_LIST"

printf '=== generating index ===\n'
"$SCRIPT_DIR/index.sh"

printf '=== done ===\n'
printf '%d .apk files in %s\n' "$(ls "$REPO_DIR"/*.apk 2>/dev/null | wc -l)" "$REPO_DIR"
