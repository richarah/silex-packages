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
printf '%d packages in closure\n' "$(wc -l < "$CLOSURE")"

printf '=== classifying packages ===\n'
"$SCRIPT_DIR/classify.sh" "$RECOMPILE" "$REPACK" < "$CLOSURE"

printf '=== prep done ===\n'
printf 'recompile: %d\n' "$(wc -l < "$RECOMPILE")"
printf 'repack:    %d\n' "$(wc -l < "$REPACK")"
