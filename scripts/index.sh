#!/bin/sh
set -e

REPO="$(cd "$(dirname "$0")/.." && pwd)"

for arch in x86_64 aarch64; do
    dir="$REPO/$arch"
    [ -d "$dir" ] || continue
    count=$(ls "$dir"/*.apk 2>/dev/null | wc -l)
    [ "$count" -eq 0 ] && { echo "=== skip $arch (no .apk files) ==="; continue; }
    echo "=== indexing $arch ($count packages) ==="
    cd "$dir"
    apk index \
        --rewrite-arch "$arch" \
        -o APKINDEX.tar.gz \
        *.apk
    abuild-sign APKINDEX.tar.gz
    cd "$REPO"
done

echo "=== index done ==="
