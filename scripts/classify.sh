#!/bin/sh
# classify.sh <recompile-output> <repack-output>
# Read package names from stdin (one per line), classify each as
# recompile or repack, write to the two output files.
#
# Classification rules (in order):
#   1. Name found in config/recompile-override.list -> recompile
#   2. Name found in config/repack-override.list    -> repack
#   3. Package contains versioned .so.N files        -> recompile
#      (these are actual shared libraries that benefit from -O3/-flto)
#   4. Otherwise                                     -> repack
#
# "Versioned .so" means files matching *.so.[0-9]* in the package
# content listing. Unversioned .so symlinks (as found in -dev packages)
# do NOT trigger recompile.
#
# Requires: apt-get, dpkg-deb
# Must run inside a Debian bookworm container (apt sources configured).

set -e

RECOMPILE_OUT="$1"
REPACK_OUT="$2"

[ -n "$RECOMPILE_OUT" ] || { printf 'classify: recompile output path required\n' >&2; exit 1; }
[ -n "$REPACK_OUT"    ] || { printf 'classify: repack output path required\n' >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

RECOMPILE_OVERRIDE="$REPO_ROOT/config/recompile-override.list"
REPACK_OVERRIDE="$REPO_ROOT/config/repack-override.list"

: > "$RECOMPILE_OUT"
: > "$REPACK_OUT"

# Temp dir: one file per package containing "recompile" or "repack"
WORK_DIR=$(mktemp -d)
AUTO_LIST=$(mktemp)
# Helper script avoids quoting hell inside xargs sh -c
HELPER=$(mktemp)
trap 'rm -rf "$WORK_DIR" "$AUTO_LIST" "$HELPER"' EXIT INT TERM

# Phase 1: process overrides (sequential — fast grep checks only);
#          queue remaining packages for parallel inspection.
while IFS= read -r pkg; do
    case "$pkg" in ''|'#'*) continue ;; esac
    if [ -f "$RECOMPILE_OVERRIDE" ] && grep -qx "$pkg" "$RECOMPILE_OVERRIDE" 2>/dev/null; then
        printf '%s\n' "$pkg" >> "$RECOMPILE_OUT"
        printf 'classify: %s -> recompile (override)\n' "$pkg"
    elif [ -f "$REPACK_OVERRIDE" ] && grep -qx "$pkg" "$REPACK_OVERRIDE" 2>/dev/null; then
        printf '%s\n' "$pkg" >> "$REPACK_OUT"
        printf 'classify: %s -> repack (override)\n' "$pkg"
    else
        printf '%s\n' "$pkg" >> "$AUTO_LIST"
    fi
done

# Phase 2: parallel classification — download each .deb and inspect content.
# Each worker writes its result ("recompile" or "repack") to $WORK_DIR/$pkg.
# apt-get download is I/O-bound so nproc workers fill the pipe well.
cat > "$HELPER" << 'HELPER_SCRIPT'
#!/bin/sh
pkg="$1"
DL=$(mktemp -d)
RESULT=repack
if ( cd "$DL" && apt-get download "$pkg" -q 2>/dev/null ); then
    DEB=$(ls "$DL"/*.deb 2>/dev/null | head -1)
    if [ -f "$DEB" ]; then
        # Skip symlink lines (first char 'l') — their $NF is the symlink target,
        # which may falsely match \.so\.[0-9] (e.g. libssl.so -> libssl.so.3).
        if dpkg-deb -c "$DEB" 2>/dev/null \
                | awk '$1 !~ /^l/ {print $NF}' \
                | grep -qE '\.so\.[0-9]'; then
            RESULT=recompile
        fi
    else
        printf 'classify: %s: no .deb found after download, defaulting to repack\n' "$pkg" >&2
    fi
else
    printf 'classify: %s: apt-get download failed, defaulting to repack\n' "$pkg" >&2
fi
rm -rf "$DL"
printf '%s\n' "$RESULT" > "${WORK_DIR}/${pkg}"
printf 'classify: %s -> %s\n' "$pkg" "$RESULT"
HELPER_SCRIPT
chmod +x "$HELPER"

export WORK_DIR
< "$AUTO_LIST" xargs -P "$(nproc)" -n 1 "$HELPER"

# Phase 3: collect results from WORK_DIR, append to output files in input order.
n_recompile=0
n_repack=0
while IFS= read -r pkg; do
    case "$pkg" in ''|'#'*) continue ;; esac
    f="$WORK_DIR/$pkg"
    [ -f "$f" ] || continue
    result=$(cat "$f")
    case "$result" in
        recompile) printf '%s\n' "$pkg" >> "$RECOMPILE_OUT"; n_recompile=$((n_recompile + 1)) ;;
        *)         printf '%s\n' "$pkg" >> "$REPACK_OUT";    n_repack=$((n_repack + 1)) ;;
    esac
done < "$AUTO_LIST"

# Include overrides in final count
_rc=$(grep -c . "$RECOMPILE_OUT" 2>/dev/null || printf '0')
_rp=$(grep -c . "$REPACK_OUT"    2>/dev/null || printf '0')
printf 'classify: done. recompile=%s repack=%s\n' "$_rc" "$_rp"
