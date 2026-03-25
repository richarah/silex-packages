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

# openssf-compiler-options (a Wolfi dep) wraps /usr/bin/clang → gcc-wrapper
# (adds linker hardening flags that break configure tests).  Its post-install
# hook re-creates the symlink on every makedep install, so a one-shot ln -sf
# does not survive abuild's makedep step.
#
# abuild's readconfig() in functions.sh uses `local _CC=cc` as a default,
# making /etc/abuild.conf's CC= assignment silently ignored.  CC/CXX must be
# exported in the *calling environment* before abuild runs so readconfig saves
# and restores the right value via CC=${_CC-$CC}.
#
# Detect the versioned binary (e.g. /usr/bin/clang-22).  The versioned path
# is never overwritten by the openssf hook; exporting it as CC bypasses both
# the wrapper symlink and the readconfig default.
CLANG_BIN=$(ls /usr/bin/clang-[0-9]* 2>/dev/null | head -1)
CLANGPP_BIN=$(ls /usr/bin/clang++-[0-9]* 2>/dev/null | head -1)
CC_BIN="${CLANG_BIN:-clang}"
CXX_BIN="${CLANGPP_BIN:-clang++}"

wget -q "https://github.com/alpinelinux/abuild/archive/refs/tags/${ABUILD_VER}.tar.gz" \
    -O /tmp/abuild.tar.gz
tar -xzf /tmp/abuild.tar.gz -C /tmp
make -C /tmp/abuild-${ABUILD_VER} CC=gcc CFLAGS="-O2 -g -pedantic" prefix=/usr
make -C /tmp/abuild-${ABUILD_VER} install prefix=/usr
rm -rf /tmp/abuild-${ABUILD_VER} /tmp/abuild.tar.gz

# Wrapper: force --allow-untrusted before any subcommand so Wolfi's apk does
# not reject packages signed with our custom key during intermediate index
# steps.  --allow-untrusted suppresses ENOKEY (key not found in /etc/apk/keys)
# which is what we get when the silex pubkey is intentionally absent there.
# Placing the flag before the subcommand ensures it is parsed as a global flag
# regardless of apk version.
cat > /usr/local/bin/apk-silex << 'APKWRAP'
#!/bin/sh
exec /usr/bin/apk --allow-untrusted "$@"
APKWRAP
chmod +x /usr/local/bin/apk-silex

cat > /etc/abuild.conf << ABUILDCONF
export CC="$CC_BIN"
export CXX="$CXX_BIN"
export CFLAGS="-O3 -march=$MARCH -flto=thin -fomit-frame-pointer"
export CXXFLAGS="\$CFLAGS"
export LDFLAGS="-fuse-ld=mold -flto=thin"
export JOBS=\$(nproc)
export ABUILD_GZIP="pigz -9"
export STRIP="strip --strip-unneeded"
# Override apk binary: use the wrapper that prepends --allow-untrusted so
# abuild's update_abuildrepo_index does not fail on our custom-signed packages.
export APK=/usr/local/bin/apk-silex
ABUILDCONF

mkdir -p /etc/apk/keys ~/.abuild
printf '%s\n' "$SILEX_PKG_RSA" > /etc/apk/keys/silex-packages.rsa
# Write the public key to /tmp, NOT /etc/apk/keys/.
# apk index --allow-untrusted suppresses ENOKEY (key not found) but NOT
# EKEYREJECTED (key found, verification fails).  Keeping the pubkey out of
# /etc/apk/keys/ during the build ensures every intermediate apk index call
# gets ENOKEY, which --allow-untrusted then silences.  abuild-sign only uses
# the pubkey path to derive the signature filename; it never reads the file.
if [ -n "${SILEX_PKG_RSA_PUB:-}" ]; then
    printf '%s\n' "$SILEX_PKG_RSA_PUB" > /tmp/silex-packages.rsa.pub
elif openssl rsa -in /etc/apk/keys/silex-packages.rsa -check -noout 2>/dev/null; then
    openssl rsa -in /etc/apk/keys/silex-packages.rsa -pubout \
        -out /tmp/silex-packages.rsa.pub
else
    # Key is missing or malformed; generate an ephemeral pair for this run.
    printf 'WARNING: generating ephemeral signing key\n' >&2
    openssl genrsa -out /etc/apk/keys/silex-packages.rsa 4096 2>/dev/null
    openssl rsa -in /etc/apk/keys/silex-packages.rsa -pubout \
        -out /tmp/silex-packages.rsa.pub 2>/dev/null
fi
cp /tmp/silex-packages.rsa.pub keys/
printf 'PACKAGER="Silex CI <noreply@richarah.github.io>"\nPACKAGER_PRIVKEY="/etc/apk/keys/silex-packages.rsa"\nPACKAGER_PUBKEY="/tmp/silex-packages.rsa.pub"\n' \
    > ~/.abuild/abuild.conf

# Verify key pair consistency.
printf 'keypair-test' > /tmp/ktest
openssl dgst -sha1 -sign /etc/apk/keys/silex-packages.rsa \
    -out /tmp/ktest.sig /tmp/ktest 2>/dev/null
if openssl dgst -sha1 -verify /tmp/silex-packages.rsa.pub \
    -signature /tmp/ktest.sig /tmp/ktest 2>/dev/null; then
    printf 'KEYPAIR: OK (pub=%s)\n' \
        "$(head -1 /tmp/silex-packages.rsa.pub)"
else
    printf 'KEYPAIR: MISMATCH — package signatures will not verify\n' >&2
fi
rm -f /tmp/ktest /tmp/ktest.sig

# abuild-sudo requires the abuild group to exist (even for root)
addgroup -S abuild 2>/dev/null || groupadd -r abuild 2>/dev/null || true

export CC="$CC_BIN"
export CXX="$CXX_BIN"

# Diagnostics: confirm environment before building.
printf '=== apk version ===\n'; /usr/bin/apk --version
printf '=== /etc/apk/keys/ ===\n'; ls /etc/apk/keys/
printf '=== APK wrapper ===\n'; cat /usr/local/bin/apk-silex
printf '=== grep APK in /etc/abuild.conf ===\n'; grep APK /etc/abuild.conf || true
printf '=== APK env var ===\n'; printenv APK || printf "(unset)\n"
# Sanity-test the wrapper: does apk index --allow-untrusted exit 0 on a
# freshly-signed .apk?  Build a minimal test to detect Wolfi behavior.
printf '=== abuild-sign from PATH ===\n'; command -v abuild-sign; abuild-sign --version 2>&1 || true
printf '=== test: apk index --allow-untrusted on scratch ===\n'
mkdir -p /tmp/pkgtest
cd /tmp/pkgtest
# Build a trivial signed apk with our key to test apk index --allow-untrusted
apk_name="testpkg-0.0.1-r0.apk"
tar czf "$apk_name" --files-from=/dev/null 2>/dev/null || true
abuild-sign "$apk_name" 2>&1 || true
printf 'exit: %s\n' "$?"
/usr/bin/apk --allow-untrusted index -o /tmp/pkgtest/APKINDEX.tar.gz "$apk_name" 2>&1
printf 'apk-index exit: %s\n' "$?"
/usr/local/bin/apk-silex index -o /tmp/pkgtest/APKINDEX2.tar.gz "$apk_name" 2>&1
printf 'apk-silex-index exit: %s\n' "$?"
cd /work
printf '=== end diagnostics ===\n'

chmod +x scripts/build-all.sh scripts/build-one.sh scripts/index.sh
if [ -n "${1:-}" ]; then
    scripts/build-one.sh "$1"
else
    scripts/build-all.sh
fi
scripts/index.sh
