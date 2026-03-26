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

# Remove any packages not in the expected gzip APK format.
# Catches stale packages from format migrations (e.g. a prior zstd attempt).
for _apk in "$REPO_DIR"/*.apk; do
    [ -f "$_apk" ] || continue
    if ! gzip -t "$_apk" >/dev/null 2>&1; then
        printf 'removing incompatible package: %s\n' "$(basename "$_apk")"
        rm -f "$_apk"
    fi
done
unset _apk

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

# Repack first (fast, no compilation); run in parallel.
# Skip packages whose .apk already exists in REPO_DIR (resume-safe).
printf '=== repacking %d packages ===\n' "$(wc -l < "$REPACK_LIST")"
grep -v '^[[:space:]]*$' "$REPACK_LIST" | grep -v '^[[:space:]]*#' | \
    xargs -P "$(nproc)" -n 1 sh -c '
        if ls "$REPO_DIR/$1-"[0-9]*.apk >/dev/null 2>&1; then
            printf "cached  %s\n" "$1"
        else
            "$SCRIPTS_DIR/repack.sh" "$1" ||
            printf "WARNING: repack failed for %s\n" "$1" >&2
        fi' sh

# Recompile (slow). Build deps come from system apt, not our repo, so
# packages can be built in parallel.
# Skip packages whose .apk already exists in REPO_DIR (resume-safe).
printf '=== recompiling %d packages ===\n' "$(wc -l < "$RECOMPILE_LIST")"
grep -v '^[[:space:]]*$' "$RECOMPILE_LIST" | grep -v '^[[:space:]]*#' | \
    xargs -P "$(nproc)" -n 1 sh -c '
        if ls "$REPO_DIR/$1-"[0-9]*.apk >/dev/null 2>&1; then
            printf "cached  %s\n" "$1"
        else
            "$SCRIPTS_DIR/recompile.sh" "$1" ||
            printf "WARNING: recompile failed for %s\n" "$1" >&2
        fi' sh

printf '=== generating index ===\n'
"$SCRIPT_DIR/index.sh"

printf '=== done ===\n'
printf '%d .apk files in %s\n' "$(ls "$REPO_DIR"/*.apk 2>/dev/null | wc -l)" "$REPO_DIR"
