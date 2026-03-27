#!/bin/sh
# gen-layers.sh
# Reads config/recompile-override.list, computes dependency layers
# automatically using apt-cache depends + tsort.
# Outputs config/recompile-layers.conf
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OVERRIDES="$REPO_ROOT/config/recompile-override.list"
OUTPUT="$REPO_ROOT/config/recompile-layers.conf"

[ -f "$OVERRIDES" ] || { printf 'gen-layers: %s not found\n' "$OVERRIDES" >&2; exit 1; }

# get the recompile package list (strip comments, blanks)
PKGS=$(grep -v '^\s*#' "$OVERRIDES" | grep -v '^\s*$')

# build edges: for each recompile pkg, find which of its
# dependencies are also in the recompile list
EDGES=$(mktemp)
ALLPKGS=$(mktemp)
printf '%s\n' $PKGS > "$ALLPKGS"

for pkg in $PKGS; do
    deps=$(apt-cache depends --no-recommends --no-suggests \
        --no-conflicts --no-breaks --no-replaces --no-enhances \
        "$pkg" 2>/dev/null | grep "Depends:" | sed 's/.*Depends: //')
    for dep in $deps; do
        # only edges within our recompile set matter
        if grep -qx "$dep" "$ALLPKGS"; then
            printf '%s %s\n' "$dep" "$pkg"  # dep must come before pkg
        fi
    done
done > "$EDGES"

# assign layers: layer 0 = no deps in set, then BFS
LAYERS=$(mktemp)
for pkg in $PKGS; do
    printf '0 %s\n' "$pkg"
done > "$LAYERS"

changed=1
while [ "$changed" -eq 1 ]; do
    changed=0
    while read -r dep pkg; do
        dep_layer=$(grep " ${dep}$" "$LAYERS" | awk '{print $1}')
        pkg_layer=$(grep " ${pkg}$" "$LAYERS" | awk '{print $1}')
        needed=$((dep_layer + 1))
        if [ "$needed" -gt "$pkg_layer" ]; then
            sed -i "s/^[0-9]* ${pkg}$/${needed} ${pkg}/" "$LAYERS"
            changed=1
        fi
    done < "$EDGES"
done

sort -n "$LAYERS" > "$OUTPUT"
rm -f "$EDGES" "$ALLPKGS" "$LAYERS"

# summary
max_layer=$(tail -1 "$OUTPUT" | awk '{print $1}')
printf 'gen-layers: %d packages across %d layers\n' \
    "$(wc -l < "$OUTPUT")" "$((max_layer + 1))"
for l in $(seq 0 "$max_layer"); do
    count=$(grep -c "^${l} " "$OUTPUT")
    pkgs=$(grep "^${l} " "$OUTPUT" | awk '{print $2}' | tr '\n' ' ')
    printf '  layer %d: %d packages (%s)\n' "$l" "$count" "$pkgs"
done
