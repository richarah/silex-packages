#!/bin/sh
# prep-direct.sh — Direct package list approach (no dependency closure)
# Uses all-packages.list instead of seeds/resolve-deps
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export ARCH="${ARCH:-$(uname -m)}"

mkdir -p "$REPO_ROOT/lists"

# apk-tar helper is compiled by Makefile's compile-helpers target
[ -x /tmp/silex-apk-tar ] || { printf 'ERROR: apk-tar not found at /tmp/silex-apk-tar\n' >&2; exit 1; }

PACKAGES="$REPO_ROOT/config/all-packages.list"
RECOMPILE="$REPO_ROOT/lists/recompile.list"
REPACK="$REPO_ROOT/lists/repack.list"

# Generate all-packages.list if it doesn't exist
if [ ! -f "$PACKAGES" ]; then
    printf '=== generating all-packages.list ===\n'
    "$SCRIPT_DIR/get-all-packages.sh" "$PACKAGES"
fi

TOTAL_COUNT=$(wc -l < "$PACKAGES")
printf '=== processing %d packages ===\n' "$TOTAL_COUNT"

# Clear the output files
> "$RECOMPILE"
> "$REPACK"

# Load override lists
RECOMPILE_OVERRIDE="$REPO_ROOT/config/recompile-override.list"
REPACK_OVERRIDE="$REPO_ROOT/config/repack-override.list"
SKIP_LIST="$REPO_ROOT/config/skip.list"

# Create sets for fast lookup
RECOMPILE_SET=$(mktemp)
REPACK_SET=$(mktemp)
SKIP_SET=$(mktemp)
trap 'rm -f "$RECOMPILE_SET" "$REPACK_SET" "$SKIP_SET"' EXIT INT TERM

[ -f "$RECOMPILE_OVERRIDE" ] && grep -v '^#' "$RECOMPILE_OVERRIDE" | grep -v '^$' > "$RECOMPILE_SET" || touch "$RECOMPILE_SET"
[ -f "$REPACK_OVERRIDE" ] && grep -v '^#' "$REPACK_OVERRIDE" | grep -v '^$' > "$REPACK_SET" || touch "$REPACK_SET"
[ -f "$SKIP_LIST" ] && grep -v '^#' "$SKIP_LIST" | grep -v '^$' > "$SKIP_SET" || touch "$SKIP_SET"

# Process each package
processed=0
skipped=0
to_recompile=0
to_repack=0

while IFS= read -r pkg; do
    [ -z "$pkg" ] && continue
    processed=$((processed + 1))

    # Progress indicator every 1000 packages
    if [ $((processed % 1000)) -eq 0 ]; then
        printf '  processed %d/%d packages...\n' "$processed" "$TOTAL_COUNT"
    fi

    # Skip if in skip.list (packages already in container)
    if grep -qFx "$pkg" "$SKIP_SET"; then
        skipped=$((skipped + 1))
        continue
    fi

    # Check override lists first
    if grep -qFx "$pkg" "$RECOMPILE_SET"; then
        echo "$pkg" >> "$RECOMPILE"
        to_recompile=$((to_recompile + 1))
        continue
    fi

    if grep -qFx "$pkg" "$REPACK_SET"; then
        echo "$pkg" >> "$REPACK"
        to_repack=$((to_repack + 1))
        continue
    fi

    # Default: everything goes to repack (we're not building from source)
    # Since this is about serving Debian packages via APK
    echo "$pkg" >> "$REPACK"
    to_repack=$((to_repack + 1))
done < "$PACKAGES"

# Add required-repo.list packages if they exist
REQUIRED_REPO="$REPO_ROOT/config/required-repo.list"
if [ -f "$REQUIRED_REPO" ]; then
    printf '=== adding required-repo.list packages ===\n'
    added=0
    while IFS= read -r pkg; do
        [ -z "$pkg" ] || [ "${pkg#\#}" != "$pkg" ] && continue
        if apt-cache show "$pkg" >/dev/null 2>&1; then
            if ! grep -qFx "$pkg" "$REPACK"; then
                echo "$pkg" >> "$REPACK"
                added=$((added + 1))
            fi
        fi
    done < "$REQUIRED_REPO"
    printf 'Added %d required packages\n' "$added"
fi

printf '\n=== Summary ===\n'
printf 'Total packages: %d\n' "$TOTAL_COUNT"
printf 'Skipped: %d\n' "$skipped"
printf 'To recompile: %d\n' "$to_recompile"
printf 'To repack: %d\n' "$to_repack"
printf 'Lists written to %s\n' "$REPO_ROOT/lists/"