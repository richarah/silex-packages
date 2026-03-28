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

# Use cache if it exists and is newer than seeds.list
if [ -f "$CACHE" ] && [ "$CACHE" -nt "$SEEDS" ]; then
    printf 'resolve-deps: using cached closure (%s)\n' "$(wc -l < "$CACHE")" >&2
    cat "$CACHE"
    exit 0
fi

printf 'resolve-deps: computing closure from seeds...\n' >&2

# Expand dependency closure for each seed, deduplicate, filter skip list,
# then verify each package has a real binary in parallel (apt-cache show).
grep -v '^#' "$SEEDS" | grep -v '^[[:space:]]*$' | while IFS= read -r pkg; do
    apt-cache depends \
        --recurse \
        --no-recommends \
        --no-suggests \
        --no-conflicts \
        --no-breaks \
        --no-replaces \
        --no-enhances \
        "$pkg" 2>/dev/null \
    | grep '^[[:alnum:]]' \
    | grep -v '^<'
done \
| sort -u \
| grep -vFxf "$SKIP_TMP" \
| xargs -P "$(nproc)" -n 1 sh -c \
    'apt-cache show "$1" >/dev/null 2>&1 && printf "%s\n" "$1"' sh \
| sort -u | tee "$CACHE"

printf 'resolve-deps: closure cached (%d packages)\n' "$(wc -l < "$CACHE")" >&2
