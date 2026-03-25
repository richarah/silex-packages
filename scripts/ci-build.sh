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

# openssf-compiler-options wraps /usr/bin/clang → gcc-wrapper (adds linker
# hardening flags that produce stderr, breaking configure tests).  Its
# post-install hook re-creates the symlink on every makedep install, so
# a one-shot ln -sf does not survive abuild's makedep step.
# Fix: pin CC/CXX to the absolute versioned binary (e.g. /usr/bin/clang-22),
# which the hook never overwrites.  Write abuild.conf directly to avoid
# sed quoting ambiguity with double-quoted variable expansion in POSIX sh.
CLANG_BIN=$(ls /usr/bin/clang-[0-9]* 2>/dev/null | head -1)
CLANGPP_BIN=$(ls /usr/bin/clang++-[0-9]* 2>/dev/null | head -1)
CC_BIN="${CLANG_BIN:-clang}"
CXX_BIN="${CLANGPP_BIN:-clang++}"
printf 'resolved CC=%s  CXX=%s\n' "$CC_BIN" "$CXX_BIN" >&2
ls -la /usr/bin/clang* /usr/lib/llvm*/bin/clang* 2>/dev/null >&2 || true
find /etc/clang /usr/lib/clang /usr/share/openssf* -name "*.cfg" -o -name "flags" 2>/dev/null >&2 | head -20 || true

wget -q "https://github.com/alpinelinux/abuild/archive/refs/tags/${ABUILD_VER}.tar.gz" \
    -O /tmp/abuild.tar.gz
tar -xzf /tmp/abuild.tar.gz -C /tmp
make -C /tmp/abuild-${ABUILD_VER} CC=gcc CFLAGS="-O2 -g -pedantic" prefix=/usr
make -C /tmp/abuild-${ABUILD_VER} install prefix=/usr
rm -rf /tmp/abuild-${ABUILD_VER} /tmp/abuild.tar.gz

cat > /etc/abuild.conf << ABUILDCONF
export CC="$CC_BIN"
export CXX="$CXX_BIN"
export CFLAGS="-O3 -march=$MARCH -flto=thin -fomit-frame-pointer"
export CXXFLAGS="\$CFLAGS"
export LDFLAGS="-fuse-ld=mold -flto=thin"
export JOBS=\$(nproc)
export ABUILD_GZIP="pigz -9"
export STRIP="strip --strip-unneeded"
ABUILDCONF
echo "=== /etc/abuild.conf ===" >&2
cat /etc/abuild.conf >&2
echo 'int main(){return 0;}' > /tmp/conftest.c
printf '=== test compile output: [%s] ===\n' \
    "$("$CC_BIN" -c "-O3" "-march=$MARCH" "-flto=thin" "-fomit-frame-pointer" /tmp/conftest.c -o /tmp/conftest.o 2>&1 || true)" >&2

mkdir -p /etc/apk/keys ~/.abuild
printf '%s\n' "$SILEX_PKG_RSA"     > /etc/apk/keys/silex-packages.rsa
printf '%s\n' "$SILEX_PKG_RSA_PUB" > /etc/apk/keys/silex-packages.rsa.pub
cp /etc/apk/keys/silex-packages.rsa.pub keys/
printf 'PACKAGER="Silex CI <noreply@richarah.github.io>"\nPACKAGER_PRIVKEY="/etc/apk/keys/silex-packages.rsa"\n' \
    > ~/.abuild/abuild.conf

# abuild-sudo requires the abuild group to exist (even for root)
addgroup -S abuild 2>/dev/null || groupadd -r abuild 2>/dev/null || true

# abuild's readconfig() in functions.sh uses `local _CC=cc` as a default,
# making /etc/abuild.conf's CC= setting ignored.  CC/CXX must be exported
# in the *calling environment* before abuild runs so readconfig saves and
# restores the right value via CC=${_CC-$CC}.
export CC="$CC_BIN"
export CXX="$CXX_BIN"

chmod +x scripts/build-all.sh scripts/build-one.sh scripts/index.sh
if [ -n "${1:-}" ]; then
    scripts/build-one.sh "$1"
else
    scripts/build-all.sh
fi
scripts/index.sh
