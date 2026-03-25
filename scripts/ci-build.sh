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
printf 'PACKAGER="Silex CI <noreply@richarah.github.io>"\nPACKAGER_PRIVKEY="/etc/apk/keys/silex-packages.rsa"\n' \
    > ~/.abuild/abuild.conf

# abuild-sudo requires the abuild group to exist (even for root)
addgroup -S abuild 2>/dev/null || groupadd -r abuild 2>/dev/null || true

# Verify C compiler works with our CFLAGS before handing off to abuild
echo "=== compiler check ===" >&2
echo "${CC:-cc}" >&2
"${CC:-cc}" --version >&2 || true
echo 'int main(void){return 0;}' > /tmp/_cctest.c
"${CC:-cc}" -c $CFLAGS /tmp/_cctest.c -o /tmp/_cctest.o 2>&1 || \
    { echo "WARN: $CC -c $CFLAGS failed; falling back to gcc without flto" >&2
      export CC=gcc CXX=g++
      export CFLAGS="${CFLAGS//-flto=thin/}"
      export CXXFLAGS="${CXXFLAGS//-flto=thin/}"
      export LDFLAGS="${LDFLAGS//-flto=thin/}"
      sed "s/CC=.*/CC=gcc/; s/CXX=.*/CXX=g++/; s/-flto=thin//g" /etc/abuild.conf > /tmp/abuild.conf.tmp
      mv /tmp/abuild.conf.tmp /etc/abuild.conf; }

chmod +x scripts/build-all.sh scripts/build-one.sh scripts/index.sh
if [ -n "${1:-}" ]; then
    scripts/build-one.sh "$1"
else
    scripts/build-all.sh
fi
scripts/index.sh
