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

n_recompile=0
n_repack=0

while IFS= read -r pkg; do
    # Skip blank lines and comments
    case "$pkg" in ''|'#'*) continue ;; esac

    # Override lists take priority
    if [ -f "$RECOMPILE_OVERRIDE" ] && grep -qx "$pkg" "$RECOMPILE_OVERRIDE" 2>/dev/null; then
        printf '%s\n' "$pkg" >> "$RECOMPILE_OUT"
        n_recompile=$((n_recompile + 1))
        printf 'classify: %s -> recompile (override)\n' "$pkg"
        continue
    fi
    if [ -f "$REPACK_OVERRIDE" ] && grep -qx "$pkg" "$REPACK_OVERRIDE" 2>/dev/null; then
        printf '%s\n' "$pkg" >> "$REPACK_OUT"
        n_repack=$((n_repack + 1))
        printf 'classify: %s -> repack (override)\n' "$pkg"
        continue
    fi

    # Download .deb into temp dir and inspect content listing
    WORK=$(mktemp -d)
    CLASSIFIED=repack

    if ( cd "$WORK" && apt-get download "$pkg" -q 2>/dev/null ); then
        DEB=$(ls "$WORK"/*.deb 2>/dev/null | head -1)
        if [ -f "$DEB" ]; then
            # Versioned shared library: *.so.N (e.g. libssl.so.3, libz.so.1.2.11)
            # Skip symlink lines (first char 'l') — their $NF is the symlink target
            # e.g. "libssl.so -> libssl.so.3" would falsely match \.so\.[0-9] on
            # the target.  Only actual versioned files (in runtime -lib packages)
            # trigger recompile; -dev packages with unversioned .so symlinks repack.
            if dpkg-deb -c "$DEB" 2>/dev/null \
                    | awk '$1 !~ /^l/ {print $NF}' \
                    | grep -qE '\.so\.[0-9]'; then
                CLASSIFIED=recompile
            fi
        else
            printf 'classify: %s: no .deb found after download, defaulting to repack\n' \
                "$pkg" >&2
        fi
    else
        printf 'classify: %s: apt-get download failed, defaulting to repack\n' \
            "$pkg" >&2
    fi

    rm -rf "$WORK"

    if [ "$CLASSIFIED" = "recompile" ]; then
        printf '%s\n' "$pkg" >> "$RECOMPILE_OUT"
        n_recompile=$((n_recompile + 1))
        printf 'classify: %s -> recompile\n' "$pkg"
    else
        printf '%s\n' "$pkg" >> "$REPACK_OUT"
        n_repack=$((n_repack + 1))
        printf 'classify: %s -> repack\n' "$pkg"
    fi
done

printf 'classify: done. recompile=%d repack=%d\n' "$n_recompile" "$n_repack"
