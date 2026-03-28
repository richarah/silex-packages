#!/bin/sh
# prep.sh — resolve dependency closure and classify packages.
# Outputs repack.list and recompile.list to $REPO_ROOT/lists/
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export ARCH="${ARCH:-$(uname -m)}"

mkdir -p "$REPO_ROOT/lists"

# apk-tar helper is compiled by Makefile's compile-helpers target
# Check that it exists
[ -x /tmp/silex-apk-tar ] || { printf 'ERROR: apk-tar not found at /tmp/silex-apk-tar (compile-helpers target must run first)\n' >&2; exit 1; }

CLOSURE=$(mktemp)
RECOMPILE="$REPO_ROOT/lists/recompile.list"
REPACK="$REPO_ROOT/lists/repack.list"
trap 'rm -f "$CLOSURE"' EXIT INT TERM

printf '=== resolving dependency closure ===\n'
"$SCRIPT_DIR/resolve-deps.sh" > "$CLOSURE"
CLOSURE_COUNT=$(wc -l < "$CLOSURE")
printf '%d packages in closure\n' "$CLOSURE_COUNT"

printf '=== filtering skip.list packages ===\n'
SKIP_LIST="$REPO_ROOT/config/skip.list"
if [ -f "$SKIP_LIST" ]; then
    # Create filtered closure: packages NOT in skip.list
    CLOSURE_FILTERED=$(mktemp)
    SKIP_NAMES=$(mktemp)
    trap "rm -f '$CLOSURE' '$CLOSURE_FILTERED' '$SKIP_NAMES'" EXIT INT TERM
    grep -v "^#" "$SKIP_LIST" | grep -v "^$" | awk '{print $1}' | sort > "$SKIP_NAMES"
    sort "$CLOSURE" | comm -23 - "$SKIP_NAMES" > "$CLOSURE_FILTERED"
    FILTERED_COUNT=$(wc -l < "$CLOSURE_FILTERED")
    SKIPPED=$((CLOSURE_COUNT - FILTERED_COUNT))
    printf 'Filtered out %d packages from skip.list\n' "$SKIPPED"
    CLOSURE="$CLOSURE_FILTERED"
fi

printf '=== classifying packages ===\n'
"$SCRIPT_DIR/classify.sh" "$RECOMPILE" "$REPACK" < "$CLOSURE"

# Force include packages from repack-override.list even if filtered by skip.list
# These are needed in the final repository but protected in CI by skip.list
REPACK_OVERRIDE="$REPO_ROOT/config/repack-override.list"
if [ -f "$REPACK_OVERRIDE" ]; then
    printf '=== adding repack-override.list packages ===\n'
    grep -v "^#" "$REPACK_OVERRIDE" | grep -v "^$" | while IFS= read -r pkg; do
        if ! grep -qx "$pkg" "$REPACK" 2>/dev/null; then
            printf '%s\n' "$pkg" >> "$REPACK"
        fi
    done
    printf 'added repack-override packages to repack.list\n'
fi

printf '=== prep done ===\n'
printf 'recompile: %d\n' "$(wc -l < "$RECOMPILE")"
printf 'repack:    %d\n' "$(wc -l < "$REPACK")"
