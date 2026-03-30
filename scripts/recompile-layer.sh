#!/bin/sh
set -e
LAYER="$1"
[ -n "$LAYER" ] || { printf 'usage: recompile-layer.sh <layer>\n' >&2; exit 1; }
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONF="$REPO_ROOT/config/recompile-layers.conf"
[ -f "$CONF" ] || { printf '%s not found\n' "$CONF" >&2; exit 1; }
REPO_DIR="${REPO_DIR:-$REPO_ROOT/${ARCH:-x86_64}}"
export REPO_DIR
export PRIVKEY PUBKEY
mkdir -p "$REPO_DIR"

for apk in "$REPO_DIR"/*.apk; do
    [ -f "$apk" ] || continue
    apk add --allow-untrusted "$apk" 2>/dev/null || true
done

grep "^${LAYER} " "$CONF" | awk '{print $2}' | while read -r pkg; do
    if ls "$REPO_DIR/${pkg}-"[0-9]*.apk >/dev/null 2>&1; then
        printf 'cached  %s\n' "$pkg"
    else
        # Fallback to repack if recompile fails (e.g. missing build-deps,
        # upstream source unavailable). Without this, the package is simply
        # absent from the repo — which causes "no such package" errors for
        # anything that depends on it.
        "$SCRIPT_DIR/recompile.sh" "$pkg" || {
            printf 'WARNING: recompile failed for %s, falling back to repack\n' "$pkg" >&2
            "$SCRIPT_DIR/repack.sh" "$pkg" || printf 'WARNING: repack fallback also failed for %s\n' "$pkg" >&2
        }
    fi
done
