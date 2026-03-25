#!/bin/sh
# Populate sha512sums in every APKBUILD.
# Run once after writing new APKBUILDs, commit the result.
# Requires: wget, sha512sum, network access. Does NOT require abuild.
#
# TODO: replace with plain `abuild checksum` once the rootless-Docker/root
#       privilege issue is resolved. abuild refuses to run as uid 0; in
#       rootless Docker only uid 0 maps back to the host user, so we can't
#       use abuild here without either a non-root uid that still has write
#       access or a privileged container. Until then this script replicates
#       what `abuild checksum` does for single-source APKBUILDs.
set -e

REPO="$(cd "$(dirname "$0")/.." && pwd)"
APORTS="$REPO/aports"
PKG="${1:-}"

if [ -n "$PKG" ]; then
    dirs="$APORTS/$PKG"
else
    dirs=$(find "$APORTS" -name APKBUILD -exec dirname {} \; | sort)
fi

failed=""

for dir in $dirs; do
    [ -f "$dir/APKBUILD" ] || continue
    pkg=$(basename "$dir")

    # Skip packages that already have a real checksum
    if ! grep -q '^sha512sums="SKIP"' "$dir/APKBUILD"; then
        echo "=== checksum: $pkg (already done, skipping) ==="
        continue
    fi

    echo "=== checksum: $pkg ==="
    (
        cd "$dir"
        . ./APKBUILD
        [ -n "$source" ] || { echo "  no source, skipping"; exit 0; }
        # Handle filename::url rename syntax (e.g. GitHub archive renames)
        case "$source" in
            *::*) filename="${source%%::*}"; url="${source##*::}" ;;
            *)    url="$source"; filename=$(basename "$url") ;;
        esac
        tmpfile="/tmp/apkchecksum-$$-$filename"
        echo "  fetching $url"
        wget -q -O "$tmpfile" "$url" || { echo "  FAILED: $url"; rm -f "$tmpfile"; exit 1; }
        checksum=$(sha512sum "$tmpfile" | awk '{print $1}')
        rm -f "$tmpfile"
        sed -i "s|^sha512sums=.*|sha512sums=\"$checksum  $filename\"|" ./APKBUILD
        echo "  ok: $checksum"
    ) || failed="$failed $pkg"
done

if [ -n "$failed" ]; then
    echo ""
    echo "=== FAILED packages:$failed ==="
    exit 1
fi

echo "=== checksums done — commit the updated APKBUILDs ==="
