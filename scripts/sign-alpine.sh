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
abuild-sign -k "$PRIVKEY" "$DIR/APKINDEX.tar.gz"
