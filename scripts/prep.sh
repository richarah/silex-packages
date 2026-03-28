#!/bin/sh
# prep.sh — resolve dependency closure and classify packages.
# Outputs repack.list and recompile.list to $REPO_ROOT/lists/
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export ARCH="${ARCH:-$(uname -m)}"

mkdir -p "$REPO_ROOT/lists"

# Compile apk-tar helper
cc -O2 -o /tmp/silex-apk-tar "$SCRIPT_DIR/apk-tar.c" ||
    { printf 'ERROR: failed to compile apk-tar.c\n' >&2; exit 1; }

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
    trap "rm -f '$CLOSURE' '$CLOSURE_FILTERED'" EXIT INT TERM
    comm -23 <(sort "$CLOSURE") <(grep -v "^#" "$SKIP_LIST" | grep -v "^$" | awk '{print $1}' | sort) > "$CLOSURE_FILTERED"
    FILTERED_COUNT=$(wc -l < "$CLOSURE_FILTERED")
    SKIPPED=$((CLOSURE_COUNT - FILTERED_COUNT))
    printf 'Filtered out %d packages from skip.list\n' "$SKIPPED"
    CLOSURE="$CLOSURE_FILTERED"
fi

printf '=== classifying packages ===\n'
"$SCRIPT_DIR/classify.sh" "$RECOMPILE" "$REPACK" < "$CLOSURE"

printf '=== prep done ===\n'
printf 'recompile: %d\n' "$(wc -l < "$RECOMPILE")"
printf 'repack:    %d\n' "$(wc -l < "$REPACK")"
