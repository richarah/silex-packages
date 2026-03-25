#!/bin/sh
# Run inside cgr.dev/chainguard/wolfi-base:latest from the workspace root.
# Required env: SILEX_PKG_RSA  SILEX_PKG_RSA_PUB
# Optional env: CFLAGS_MARCH  (default: x86-64-v3)
set -e

MARCH="${CFLAGS_MARCH:-x86-64-v3}"

apk add --no-cache abuild build-base clang mold pigz

sed "s/-march=x86-64-v3/-march=$MARCH/" abuild.conf > /etc/abuild.conf

mkdir -p /etc/apk/keys ~/.abuild
printf '%s\n' "$SILEX_PKG_RSA"     > /etc/apk/keys/silex-packages.rsa
printf '%s\n' "$SILEX_PKG_RSA_PUB" > /etc/apk/keys/silex-packages.rsa.pub
cp /etc/apk/keys/silex-packages.rsa.pub keys/
echo 'PACKAGER_PRIVKEY="/etc/apk/keys/silex-packages.rsa"' > ~/.abuild/abuild.conf

chmod +x scripts/build-all.sh scripts/index.sh
scripts/build-all.sh
scripts/index.sh
