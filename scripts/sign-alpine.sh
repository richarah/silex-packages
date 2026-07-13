#!/bin/sh
# sign-alpine.sh <arch>
# Called from CI. Runs abuild-sign inside an Alpine container.
# Expects PRIVKEY, PUBKEY, REPO_DIR to be set.
set -e
ARCH="$1"
DIR="${REPO_DIR:-$ARCH}"

[ -f "$DIR/APKINDEX.tar.gz" ] || { printf 'sign-alpine: no index to sign\n' >&2; exit 1; }
[ -f "$PRIVKEY" ] || { printf 'sign-alpine: PRIVKEY not set\n' >&2; exit 1; }
[ -f "$PUBKEY" ] || { printf 'sign-alpine: PUBKEY not set\n' >&2; exit 1; }

PUBKEY_NAME=$(basename "$PUBKEY")

# abuild-sign needs PACKAGER_PRIVKEY
export PACKAGER_PRIVKEY="$PRIVKEY"

# Sign the INDEX. This is what establishes trust: apk verifies the signed index,
# and the index carries a C: checksum for every package.
abuild-sign -k "$PRIVKEY" "$DIR/APKINDEX.tar.gz"

# Sign each PACKAGE too.
#
# The index signature alone is enough for apk to TRUST and INSTALL a package --
# and it does. But apk-tools 2.14 additionally emits, per unsigned package:
#
#   WARNING: <pkg>: support for packages without embedded checksums will be
#            dropped in apk-tools 3.
#
# and folds those into its "N errors" summary, which reads alarmingly even though
# nothing failed. Alpine's own packages are individually signed (each .apk has a
# .SIGN.RSA.* member prepended to its control stream); ours were not, because
# this step only ever signed the index. Signing each package removes the warning
# and is what apk-tools 3 will require.
#
# NOTE: this is O(packages) abuild-sign calls -- ~1750 per arch -- so it adds a
# few minutes to the signing job. Idempotent: abuild-sign replaces any existing
# signature, so re-running is safe.
_count=0
for _apk in "$DIR"/*.apk; do
    [ -f "$_apk" ] || continue
    abuild-sign -k "$PRIVKEY" "$_apk"
    _count=$((_count + 1))
done
printf 'sign-alpine: signed index + %d packages in %s\n' "$_count" "$DIR" >&2
