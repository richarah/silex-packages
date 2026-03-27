#!/bin/sh
# recompile-layer.sh <layer-number>
# Build all packages in the given layer.
# Previous layers' .apk artifacts must be in $REPO_DIR.
set -e
LAYER="$1"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONF="$REPO_ROOT/config/recompile-layers.conf"

[ -f "$CONF" ] || { printf 'recompile-layer: %s not found\n' "$CONF" >&2; exit 1; }

# Install previous layers' packages so build-deps resolve
if [ "$LAYER" -gt 0 ] && ls "$REPO_DIR"/*.apk >/dev/null 2>&1; then
    printf 'installing previous layers from %s\n' "$REPO_DIR"
    dpkg-deb () { :; }  # not needed, we use apt
    for apk in "$REPO_DIR"/*.apk; do
        # extract to system paths so configure/cmake finds them
        tar xzf "$apk" -C / 2>/dev/null || true
    done
fi

# Build this layer's packages
grep "^${LAYER} " "$CONF" | awk '{print $2}' | while read -r pkg; do
    if ls "$REPO_DIR/${pkg}-"[0-9]*.apk >/dev/null 2>&1; then
        printf 'cached  %s\n' "$pkg"
    else
        "$SCRIPT_DIR/recompile.sh" "$pkg" || printf 'WARNING: recompile failed for %s\n' "$pkg" >&2
    fi
done
