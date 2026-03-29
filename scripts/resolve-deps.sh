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
CLOSURE_SCRIPT="$SCRIPT_DIR/resolve-closure.py"

[ -f "$SEEDS" ] || { printf 'resolve-deps: %s not found\n' "$SEEDS" >&2; exit 1; }

SKIP_TMP=$(mktemp)
trap 'rm -f "$SKIP_TMP"' EXIT INT TERM

if [ -f "$SKIP" ]; then
    grep -v '^#' "$SKIP" | grep -v '^[[:space:]]*$' > "$SKIP_TMP"
fi

# Use cache if it exists and is newer than ALL of:
# - seeds.list
# - skip.list
# - resolve-closure.py (the script itself)
# If any are newer than cache, recompute to ensure correctness
CACHE_VALID=false
if [ -f "$CACHE" ] && [ "$CACHE" -nt "$SEEDS" ]; then
    # Also check if skip.list has changed
    if [ ! -f "$SKIP" ] || [ "$CACHE" -nt "$SKIP" ]; then
        # Also check if the Python script has changed
        if [ ! -f "$CLOSURE_SCRIPT" ] || [ "$CACHE" -nt "$CLOSURE_SCRIPT" ]; then
            CACHE_VALID=true
        fi
    fi
fi

if [ "$CACHE_VALID" = true ]; then
    printf 'resolve-deps: using cached closure (%s)\n' "$(wc -l < "$CACHE")" >&2
    cat "$CACHE"
    exit 0
fi

printf 'resolve-deps: computing closure from seeds...\n' >&2

# Use apt-rdepends for proper transitive closure computation
# Much faster and more reliable than Python subprocess calls
which apt-rdepends >/dev/null 2>&1 || apt-get install -y apt-rdepends >/dev/null 2>&1

# Process each seed and get recursive dependencies
grep -v '^#' "$SEEDS" | grep -v '^[[:space:]]*$' | while IFS= read -r pkg; do
    apt-rdepends --follow=Depends --print-state "$pkg" 2>/dev/null | grep "^  " | sed 's/^  //'
    echo "$pkg"  # Include the seed itself
done | sort -u | grep -vFxf "$SKIP_TMP" | tee "$CACHE"

printf 'resolve-deps: closure cached (%d packages)\n' "$(wc -l < "$CACHE")" >&2
