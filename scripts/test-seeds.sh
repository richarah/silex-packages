#!/bin/bash
# Test and validate seeds.list
# Usage: ./scripts/test-seeds.sh [--verbose]

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

VERBOSE=0
[ "$1" = "--verbose" ] && VERBOSE=1

log() {
    if [ "$VERBOSE" = 1 ]; then
        printf "[test-seeds] %s\n" "$1" >&2
    fi
}

printf "=== Seeds List Validation ===\n\n"

# Check if seeds.list exists
if [ ! -f "$REPO_ROOT/lists/seeds.list" ]; then
    printf "ERROR: lists/seeds.list not found\n" >&2
    exit 1
fi

# Read seeds.list, skip comments and blank lines
SEEDS=$(grep -v '^#' "$REPO_ROOT/lists/seeds.list" | grep -v '^$')
TOTAL_PACKAGES=$(printf '%s' "$SEEDS" | wc -l)

printf "Total packages in seeds.list: %d\n" "$TOTAL_PACKAGES"

# Test 1: Check all packages exist in Debian
printf "\n[1/4] Checking all packages exist in Debian Bookworm...\n"
MISSING=0
while IFS= read -r pkg; do
    if ! apt-cache show "$pkg" >/dev/null 2>&1; then
        printf "  Missing: %s\n" "$pkg" >&2
        MISSING=$((MISSING + 1))
    fi
done <<< "$SEEDS"

if [ "$MISSING" -gt 0 ]; then
    printf "  ✗ Found %d missing packages\n" "$MISSING"
    exit 1
else
    printf "  ✓ All %d packages exist\n" "$TOTAL_PACKAGES"
fi

# Test 2: Calculate total compressed size
printf "\n[2/4] Calculating total package size...\n"
TOTAL_SIZE=0
while IFS= read -r pkg; do
    size=$(apt-cache show "$pkg" 2>/dev/null | grep "^Size:" | awk '{print $2}')
    TOTAL_SIZE=$((TOTAL_SIZE + ${size:-0}))
done <<< "$SEEDS"

SIZE_MB=$((TOTAL_SIZE / 1024 / 1024))
SIZE_GB=$((SIZE_MB / 1024))
printf "  Total size: %dMB (~%dGB)\n" "$SIZE_MB" "$SIZE_GB"

# Check against limit
source "$REPO_ROOT/config/pkg-selection.conf"
LIMIT_GB=$MAX_SIZE_GB
if [ "$SIZE_GB" -gt $((LIMIT_GB + 1)) ]; then
    printf "  ✗ Size %dGB exceeds limit %dGB\n" "$SIZE_GB" "$LIMIT_GB"
    exit 1
else
    printf "  ✓ Within size limit (%dGB configured)\n" "$LIMIT_GB"
fi

# Test 3: Check critical packages are present
printf "\n[3/4] Checking for critical packages...\n"
CRITICAL="libssl3 libcurl4 zlib1g libc6 libgcc-s1 libstdc++6 curl wget git gcc make"
CRITICAL_MISSING=0

for pkg in $CRITICAL; do
    if printf '%s' "$SEEDS" | grep -q "^${pkg}$"; then
        printf "  ✓ %s\n" "$pkg"
    else
        printf "  ✗ MISSING: %s\n" "$pkg"
        CRITICAL_MISSING=$((CRITICAL_MISSING + 1))
    fi
done

if [ "$CRITICAL_MISSING" -gt 0 ]; then
    printf "  ✗ Missing %d critical packages\n" "$CRITICAL_MISSING"
    exit 1
else
    printf "  ✓ All critical packages present\n"
fi

# Test 4: Check for obvious bloat exclusions
printf "\n[4/4] Checking for excluded packages...\n"
BLOAT_PATTERNS=".*-doc$ .*-dbg$ fonts-.* games-.* gnome-.* kde-.*"
BLOAT_FOUND=0

for pattern in $BLOAT_PATTERNS; do
    if printf '%s' "$SEEDS" | grep -qE "$pattern"; then
        printf "  ✗ Found excluded pattern: %s\n" "$pattern"
        BLOAT_FOUND=$((BLOAT_FOUND + 1))
    fi
done

if [ "$BLOAT_FOUND" -gt 0 ]; then
    printf "  ✗ Found %d bloat packages that should be excluded\n" "$BLOAT_FOUND"
else
    printf "  ✓ No obvious bloat packages found\n"
fi

# Summary
printf "\n=== Summary ===\n"
printf "Packages: %d\n" "$TOTAL_PACKAGES"
printf "Size: ~%dGB (limit: %dGB)\n" "$SIZE_GB" "$LIMIT_GB"
printf "Status: ✓ PASS\n"

exit 0
