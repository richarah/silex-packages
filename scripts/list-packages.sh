#!/bin/sh
# Print all package names that have an APKBUILD.

APORTS="$(cd "$(dirname "$0")/../aports" && pwd)"

for dir in "$APORTS"/*/; do
    [ -f "$dir/APKBUILD" ] || continue
    basename "$dir"
done
