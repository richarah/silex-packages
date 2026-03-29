#!/bin/sh
# resolve-deps-simple.sh
# Get direct dependencies only, filter to real packages.
# Much simpler and more reliable than trying to compute full closure.
#
# Strategy:
#   1. For each seed package, get direct deps only
#   2. Verify each package actually exists in Debian
#   3. Cache the result
#
# Requires: apt-cache
# Must run inside a Debian bookworm container

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SEEDS="$REPO_ROOT/config/seeds.list"
SKIP="$REPO_ROOT/config/skip.list"
CACHE="$REPO_ROOT/.closure-cache"

[ -f "$SEEDS" ] || { printf 'resolve-deps: %s not found\n' "$SEEDS" >&2; exit 1; }

SKIP_TMP=$(mktemp)
trap 'rm -f "$SKIP_TMP"' EXIT INT TERM

if [ -f "$SKIP" ]; then
    grep -v '^#' "$SKIP" | grep -v '^[[:space:]]*$' > "$SKIP_TMP"
fi

# Check cache validity (same as before)
CACHE_VALID=false
if [ -f "$CACHE" ] && [ "$CACHE" -nt "$SEEDS" ]; then
    if [ ! -f "$SKIP" ] || [ "$CACHE" -nt "$SKIP" ]; then
        CACHE_VALID=true
    fi
fi

if [ "$CACHE_VALID" = true ]; then
    printf 'resolve-deps: using cached closure (%s)\n' "$(wc -l < "$CACHE")" >&2
    cat "$CACHE"
    exit 0
fi

printf 'resolve-deps: computing closure from seeds...\n' >&2

# Get seeds + their direct dependencies only
# No recursion, just immediate deps
{
    # Include seeds themselves
    grep -v '^#' "$SEEDS" | grep -v '^[[:space:]]*$'

    # Get direct dependencies for each seed
    grep -v '^#' "$SEEDS" | grep -v '^[[:space:]]*$' | while read -r pkg; do
        apt-cache depends --no-recommends --no-suggests \
            --no-conflicts --no-breaks --no-replaces --no-enhances \
            "$pkg" 2>/dev/null | grep '^  ' | sed 's/.*: //'
    done
} | sort -u | \
grep -vFxf "$SKIP_TMP" | \
xargs -P "$(nproc)" -n 1 sh -c \
    'apt-cache show "$1" >/dev/null 2>&1 && printf "%s\n" "$1"' sh | \
sort -u | tee "$CACHE"

printf 'resolve-deps: closure cached (%d packages)\n' "$(wc -l < "$CACHE")" >&2
