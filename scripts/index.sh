#!/bin/sh
set -e

REPO="$(cd "$(dirname "$0")/.." && pwd)"

for arch in x86_64 aarch64; do
    # packages land in aports/$arch/ due to abuild's repo-name computation
    dir="$REPO/aports/$arch"
    [ -d "$dir" ] || continue
    count=$(ls "$dir"/*.apk 2>/dev/null | wc -l)
    [ "$count" -eq 0 ] && { echo "=== skip $arch (no .apk files) ==="; continue; }
    echo "=== indexing $arch ($count packages) ==="
    cd "$dir"
    # --allow-untrusted: Wolfi's apk verifies .apk signatures when indexing;
    # bypass so packages signed with our custom key are accepted.
    apk index \
        --allow-untrusted \
        --rewrite-arch "$arch" \
        -o APKINDEX.tar.gz \
        *.apk
    abuild-sign APKINDEX.tar.gz
    cd "$REPO"
done

echo "=== index done ==="
