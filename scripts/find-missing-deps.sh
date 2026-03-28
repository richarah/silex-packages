#!/bin/bash
# Find missing runtime dependencies in current seeds.list
# This analyzes what we ALREADY have and finds what's missing
# Much faster than regenerating from scratch
#
# Usage: ./scripts/find-missing-deps.sh [--auto-add]

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

AUTO_ADD=0
[ "$1" = "--auto-add" ] && AUTO_ADD=1

log() {
    printf "[find-missing-deps] %s\n" "$1" >&2
}

log "Analyzing current packages for missing runtime dependencies..."

# Get all packages we have in seeds.list
SEEDS=$(grep -v '^#' "$REPO_ROOT/lists/seeds.list" 2>/dev/null | grep -v '^$' || true)

if [ -z "$SEEDS" ]; then
    log "ERROR: seeds.list is empty or missing"
    exit 1
fi

TOTAL=$(printf '%s' "$SEEDS" | wc -l)
log "Processing $TOTAL packages from seeds.list..."

# Extract all dependencies
TEMP_DEPS=$(mktemp)
trap "rm -f $TEMP_DEPS" EXIT

# Get all dependencies for packages we have
printf '%s' "$SEEDS" | while read -r pkg; do
    apt-cache depends --no-recommends --no-suggests --no-conflicts --no-breaks "$pkg" 2>/dev/null | \
        grep "^\s" | sed 's/[<>|].*//; s/^ *//' | sort -u
done | sort -u > "$TEMP_DEPS"

log "Found $(wc -l < "$TEMP_DEPS") unique dependencies"

# Find which ones are NOT in our seeds
MISSING=$(mktemp)
trap "rm -f $MISSING" EXIT

while IFS= read -r dep; do
    [ -z "$dep" ] && continue

    # Skip virtual packages
    if ! apt-cache show "$dep" >/dev/null 2>&1; then
        continue
    fi

    # Check if in seeds
    if ! printf '%s' "$SEEDS" | grep -q "^${dep}$"; then
        echo "$dep" >> "$MISSING"
    fi
done < "$TEMP_DEPS"

MISSING_COUNT=$(wc -l < "$MISSING")
log "Found $MISSING_COUNT packages needed but not in seeds.list"

if [ "$MISSING_COUNT" = "0" ]; then
    printf "\n✓ All dependencies satisfied!\n"
    exit 0
fi

# Categorize missing packages
printf "\n=== Missing Runtime Dependencies ===\n\n"

# Critical (lib* runtime packages)
printf "[CRITICAL] Runtime libraries:\n"
grep "^lib" "$MISSING" | grep -v "\-dev$" | grep -v "\-doc$" | head -20 | while read -r pkg; do
    printf "  + %s\n" "$pkg"
done

# Utilities
printf "\n[UTILITIES] Essential tools:\n"
grep -v "^lib" "$MISSING" | grep -E "^(curl|wget|git|make|gcc|g\+\+|python|perl|ruby|nodejs)" | head -10 | while read -r pkg; do
    printf "  + %s\n" "$pkg"
done

# Show all for reference
printf "\n=== All %d missing packages ===\n" "$MISSING_COUNT"
sort "$MISSING" | nl

if [ "$AUTO_ADD" = 1 ]; then
    printf "\n[AUTO-ADD MODE] Adding missing packages to seeds.list...\n"

    # Backup current
    cp "$REPO_ROOT/lists/seeds.list" "$REPO_ROOT/lists/seeds.list.pre-auto"

    # Append missing packages (deduped)
    sort -u "$MISSING" >> "$REPO_ROOT/lists/seeds.list"

    # Re-sort and deduplicate
    sort -u "$REPO_ROOT/lists/seeds.list" > "$REPO_ROOT/lists/seeds.list.tmp"
    mv "$REPO_ROOT/lists/seeds.list.tmp" "$REPO_ROOT/lists/seeds.list"

    printf "✓ Added %d packages to seeds.list (backup: seeds.list.pre-auto)\n" "$MISSING_COUNT"
    printf "\nRun 'make test-seeds' to validate.\n"
else
    printf "\nTo auto-add these to seeds.list, run:\n"
    printf "  ./scripts/find-missing-deps.sh --auto-add\n"
fi
