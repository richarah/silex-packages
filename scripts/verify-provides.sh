#!/bin/sh
# Fail if any APKBUILD is missing provides=.
# Run in CI before building. Also run locally with: scripts/verify-provides.sh
set -e
APORTS="$(dirname "$0")/../aports"
FAIL=0
for f in "$APORTS"/*/APKBUILD; do
    if ! grep -q '^provides=' "$f"; then
        echo "MISSING provides= in $f" >&2
        FAIL=1
    fi
done
if [ "$FAIL" -eq 0 ]; then
    echo "All APKBUILDs have provides=."
fi
exit $FAIL
