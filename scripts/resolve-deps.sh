#!/bin/sh
# resolve-deps.sh
# Compute the full transitive dependency closure of seeds.list.
# Output: one package name per line, sorted, deduplicated.
#
# Caches result to .closure-cache to avoid recomputing every run.
#
# Must run inside a Debian bookworm container with deb-src lines
# in /etc/apt/sources.list and apt-get update already run.
#
# Filters:
#   - Packages in config/skip.list are removed from the output.
#   - Virtual packages (no binary available) are silently skipped.
#   - Lines starting with # or blank lines in seeds.list are skipped.
#
# Closure depth: 2 levels (seeds + their deps + their deps' deps).
# This ensures transitive deps like libgnutls30→libunistring2 are included.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SEEDS="$REPO_ROOT/config/seeds.list"
SKIP="$REPO_ROOT/config/skip.list"
CACHE="$REPO_ROOT/.closure-cache"
SELF="$SCRIPT_DIR/resolve-deps.sh"

[ -f "$SEEDS" ] || { printf 'resolve-deps: %s not found\n' "$SEEDS" >&2; exit 1; }

SKIP_TMP=$(mktemp)
trap 'rm -f "$SKIP_TMP"' EXIT INT TERM

if [ -f "$SKIP" ]; then
    grep -v '^#' "$SKIP" | grep -v '^[[:space:]]*$' | awk '{print $1}' > "$SKIP_TMP" || true
fi

# Use cache if it exists, is non-empty, and is newer than seeds.list, skip.list,
# AND this script itself (so closure depth changes invalidate the cache).
CACHE_VALID=false
if [ -f "$CACHE" ] && [ "$(wc -l < "$CACHE")" -gt 0 ] \
        && [ "$CACHE" -nt "$SEEDS" ] && [ "$CACHE" -nt "$SELF" ]; then
    if [ ! -f "$SKIP" ] || [ "$CACHE" -nt "$SKIP" ]; then
        CACHE_VALID=true
    fi
fi

if [ "$CACHE_VALID" = true ]; then
    printf 'resolve-deps: using cached closure (%s)\n' "$(wc -l < "$CACHE")" >&2
    cat "$CACHE"
    exit 0
fi

printf 'resolve-deps: computing closure from seeds (2 levels)...\n' >&2

# Helper: get direct deps of packages listed on stdin
# Strips version constraints and filters to valid Debian package names.
get_deps() {
    while IFS= read -r pkg; do
        apt-cache depends --no-recommends --no-suggests \
            --no-conflicts --no-breaks --no-replaces --no-enhances \
            "$pkg" 2>/dev/null \
            | grep '^  [A-Z]' \
            | sed 's/.*: //; s/ (.*//'
    done | grep -E '^[a-z0-9][a-z0-9.+:-]*$'
}

SEEDS_CLEAN=$(grep -v '^#' "$SEEDS" | grep -v '^[[:space:]]*$')

# Level 0: seeds themselves
LEVEL0=$(printf '%s\n' "$SEEDS_CLEAN")

# Level 1: direct deps of seeds
LEVEL1=$(printf '%s\n' "$SEEDS_CLEAN" | get_deps)

# Combine levels 0+1, dedup, apply skip filter
L01=$(printf '%s\n%s\n' "$LEVEL0" "$LEVEL1" | \
      grep -E '^[a-z0-9][a-z0-9.+:-]*$' | sort -u | \
      grep -vFxf "$SKIP_TMP")

printf 'resolve-deps: level 0+1 = %d packages\n' "$(printf '%s\n' "$L01" | wc -l)" >&2

# Level 2: deps of level-1 packages not already in L01
LEVEL2=$(printf '%s\n' "$LEVEL1" | grep -E '^[a-z0-9][a-z0-9.+:-]*$' | sort -u | get_deps)

# Final closure: union of all levels, dedup, skip filter
printf '%s\n%s\n' "$L01" "$LEVEL2" | \
    grep -E '^[a-z0-9][a-z0-9.+:-]*$' | sort -u | \
    grep -vFxf "$SKIP_TMP" | \
    tee "$CACHE"

printf 'resolve-deps: closure cached (%d packages)\n' "$(wc -l < "$CACHE")" >&2
