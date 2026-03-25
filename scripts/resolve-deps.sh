#!/bin/sh
# resolve-deps.sh
# Compute the full transitive dependency closure of seeds.list.
# Output: one package name per line, sorted, deduplicated.
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

[ -f "$SEEDS" ] || { printf 'resolve-deps: %s not found\n' "$SEEDS" >&2; exit 1; }

# Build a combined skip pattern (one name per line -> awk exact match)
SKIP_TMP=$(mktemp)
trap 'rm -f "$SKIP_TMP"' EXIT INT TERM

if [ -f "$SKIP" ]; then
    grep -v '^#' "$SKIP" | grep -v '^[[:space:]]*$' > "$SKIP_TMP"
fi

# Expand dependency closure for each seed package
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
    | grep -v '^<'  # skip virtual package refs like <python3:any>
done \
| sort -u \
| while IFS= read -r dep; do
    # Skip packages from skip list
    if grep -qx "$dep" "$SKIP_TMP" 2>/dev/null; then
        continue
    fi
    # Skip if no binary package exists (virtual packages, arch:all meta, etc.)
    if apt-cache show "$dep" >/dev/null 2>&1; then
        printf '%s\n' "$dep"
    fi
done \
| sort -u
