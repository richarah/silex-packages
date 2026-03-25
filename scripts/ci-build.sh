#!/bin/sh
# Run inside cgr.dev/chainguard/wolfi-base:latest from the workspace root.
# Required env: SILEX_PKG_RSA  SILEX_PKG_RSA_PUB
# Optional env: CFLAGS_MARCH  (default: x86-64-v3)
set -e

MARCH="${CFLAGS_MARCH:-x86-64-v3}"
export FORCE_UNSAFE_CONFIGURE=1
ABUILD_VER=3.15.0

# wolfi-base defaults to apk.cgr.dev/chainguard (auth-required, lacks build tools).
# Switch to the public Wolfi repo.
echo "https://packages.wolfi.dev/os" > /etc/apk/repositories
apk update -q

# abuild is not in packages.wolfi.dev/os (Wolfi uses melange, not abuild).
# Build abuild from Alpine source — all C files use standard libc, so this
# compiles cleanly on Wolfi/glibc.
apk add --no-cache gcc make pkgconf scdoc openssl openssl-dev zlib-dev wget clang mold pigz

wget -q "https://github.com/alpinelinux/abuild/archive/refs/tags/${ABUILD_VER}.tar.gz" \
    -O /tmp/abuild.tar.gz
tar -xzf /tmp/abuild.tar.gz -C /tmp
make -C /tmp/abuild-${ABUILD_VER} CC=gcc CFLAGS="-O2 -g -pedantic" prefix=/usr
make -C /tmp/abuild-${ABUILD_VER} install prefix=/usr
rm -rf /tmp/abuild-${ABUILD_VER} /tmp/abuild.tar.gz

sed "s/-march=x86-64-v3/-march=$MARCH/" abuild.conf > /etc/abuild.conf

mkdir -p /etc/apk/keys ~/.abuild
printf '%s\n' "$SILEX_PKG_RSA"     > /etc/apk/keys/silex-packages.rsa
printf '%s\n' "$SILEX_PKG_RSA_PUB" > /etc/apk/keys/silex-packages.rsa.pub
cp /etc/apk/keys/silex-packages.rsa.pub keys/
echo 'PACKAGER_PRIVKEY="/etc/apk/keys/silex-packages.rsa"' > ~/.abuild/abuild.conf

chmod +x scripts/build-all.sh scripts/build-one.sh scripts/index.sh
if [ -n "${1:-}" ]; then
    scripts/build-one.sh "$1"
else
    scripts/build-all.sh
fi
scripts/index.sh
