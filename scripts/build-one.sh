#!/bin/sh
set -e

REPO="$(cd "$(dirname "$0")/.." && pwd)"
APORTS="$REPO/aports"

if [ -z "$1" ]; then
    echo "usage: build-one.sh <pkgname>" >&2
    exit 1
fi

pkg="$1"
dir="$APORTS/$pkg"

if [ ! -f "$dir/APKBUILD" ]; then
    echo "error: no APKBUILD for '$pkg' at $dir" >&2
    exit 1
fi

echo "=== building $pkg ==="
cd "$dir"
abuild -F -r -P "$REPO"
