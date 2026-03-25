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

# Patch abuild-sign to use RSA256 (SHA-256) instead of RSA (SHA-1).
# RSA256 changes the embedded sig filename to .SIGN.RSA256.keyname.pub; Wolfi's
# modern apk-tools understands this prefix and verifies with SHA-256.
sed -i 's/sigtype=RSA$/sigtype=RSA256/' /usr/bin/abuild-sign
printf 'abuild-sign sigtype patched to RSA256\n'

# Neutralise update_abuildrepo_index's failure path.
# abuild calls this after each package build to run `apk index *.apk`.
# Wolfi apk 2.14.x returns EKEYREJECTED during that index step (not bypassed
# by --allow-untrusted); the || branch then calls die "Failed to create index".
# Replace that die with `true` so the function silently succeeds on index failure.
# Our own pipeline handles indexing:
#   - build-all.sh _reindex_and_install: unsigned intermediate index + apk add --allow-untrusted
#   - scripts/index.sh: final abuild-signed APKINDEX published to Pages
sed -i 's/die "Failed to create index"/true/' /usr/bin/abuild
if grep -q 'die "Failed to create index"' /usr/bin/abuild; then
    printf 'WARNING: update_abuildrepo_index die patch did not apply\n' >&2
else
    printf 'abuild update_abuildrepo_index die patched to true\n'
fi

# Patch postcheck's uncompressed man page check: auto-gzip instead of e=1.
# abuild 3.15.0 postcheck() finds uncompressed man pages and sets e=1 (which
# causes die "Sanity checks failed").  Replace the e=1 with a gzip command so
# packages that install uncompressed man pages are fixed in place rather than
# rejected.  The error message still prints for visibility.
sed -i '/Found uncompressed man pages:/{n; n; s/\te=1$/\tfind "$dir"\/usr\/share\/man -name '"'"'*.[0-8]'"'"' -type f | xargs -r gzip -9 2>\/dev\/null/}' /usr/bin/abuild
if grep -q 'xargs -r gzip' /usr/bin/abuild; then
    printf 'abuild postcheck: auto-gzip man pages patch applied\n'
else
    printf 'WARNING: auto-gzip man pages patch did not apply\n' >&2
fi

# APK wrapper: prepends --allow-untrusted to every abuild-initiated apk call.
# Needed for makedep resolution from the unsigned intermediate APKINDEX created
# by build-all.sh's _reindex_and_install.
printf '#!/bin/sh\nexec /usr/bin/apk --allow-untrusted "$@"\n' > /usr/local/bin/apk-silex
chmod +x /usr/local/bin/apk-silex

# Keys: private key is stored OUTSIDE /etc/apk/keys/ to avoid apk loading it
# during its directory scan.  If the private key is in /etc/apk/keys/, Wolfi's
# apk parses it as a candidate public key (OpenSSL can extract the public
# component from a private key PEM), which triggers EKEYREJECTED on verification
# failure — an error code not bypassed by --allow-untrusted.
#
# Public key goes into /etc/apk/keys/ so apk index can find and verify package
# signatures normally (ENOKEY → EKEYREJECTED → success path).
mkdir -p /root/.abuild/keys /etc/apk/keys ~/.abuild

printf '%s\n' "$SILEX_PKG_RSA" > /root/.abuild/keys/silex-packages.rsa
if [ -n "${SILEX_PKG_RSA_PUB:-}" ]; then
    printf '%s\n' "$SILEX_PKG_RSA_PUB" > /etc/apk/keys/silex-packages.rsa.pub
elif openssl rsa -in /root/.abuild/keys/silex-packages.rsa -check -noout 2>/dev/null; then
    openssl rsa -in /root/.abuild/keys/silex-packages.rsa -pubout \
        -out /etc/apk/keys/silex-packages.rsa.pub
else
    # Key is missing or malformed; generate an ephemeral pair for this run.
    printf 'WARNING: generating ephemeral signing key\n' >&2
    openssl genrsa -out /root/.abuild/keys/silex-packages.rsa 4096 2>/dev/null
    openssl rsa -in /root/.abuild/keys/silex-packages.rsa -pubout \
        -out /etc/apk/keys/silex-packages.rsa.pub 2>/dev/null
fi
cp /etc/apk/keys/silex-packages.rsa.pub keys/

# Verify key pair consistency with SHA-256 (matching RSA256 abuild-sign patch).
printf 'keypair-test' > /tmp/ktest
openssl dgst -sha256 -sign /root/.abuild/keys/silex-packages.rsa \
    -out /tmp/ktest.sig /tmp/ktest 2>/dev/null
if openssl dgst -sha256 -verify /etc/apk/keys/silex-packages.rsa.pub \
    -signature /tmp/ktest.sig /tmp/ktest 2>/dev/null; then
    printf 'KEYPAIR (RSA256): OK\n'
else
    printf 'KEYPAIR (RSA256): MISMATCH — package signatures will not verify\n' >&2
fi
rm -f /tmp/ktest /tmp/ktest.sig

cat > /etc/abuild.conf << ABUILDCONF
export CC="$CC_BIN"
export CXX="$CXX_BIN"
export CFLAGS="-O3 -march=$MARCH -flto=thin -fomit-frame-pointer"
export CXXFLAGS="\$CFLAGS"
export LDFLAGS="-fuse-ld=mold -flto=thin"
export JOBS=\$(nproc)
export ABUILD_GZIP="pigz -9"
export STRIP="strip --strip-unneeded"
export APK="/usr/local/bin/apk-silex"
export ABUILD_APK_INDEX_OPTS="--allow-untrusted"
export WGET_OPTS="--tries=5 --retry-connrefused --retry-on-http-error=503,429,500"
ABUILDCONF

# PACKAGER_PRIVKEY: path to private key (outside /etc/apk/keys/).
# PACKAGER_PUBKEY: path whose *basename* is embedded in .SIGN entries; apk
#   looks up this basename in /etc/apk/keys/ when verifying.
printf 'PACKAGER="Silex CI <noreply@richarah.github.io>"\nPACKAGER_PRIVKEY="/root/.abuild/keys/silex-packages.rsa"\nPACKAGER_PUBKEY="/etc/apk/keys/silex-packages.rsa.pub"\n' \
    > ~/.abuild/abuild.conf

# abuild-sudo requires the abuild group to exist (even for root)
addgroup -S abuild 2>/dev/null || groupadd -r abuild 2>/dev/null || true

export CC="$CC_BIN"
export CXX="$CXX_BIN"

printf '=== apk version ===\n'; /usr/bin/apk --version 2>&1 || true
printf '=== /etc/apk/keys/ ===\n'; ls /etc/apk/keys/
printf '=== abuild-sign sigtype ===\n'; grep 'sigtype=' /usr/bin/abuild-sign | head -3
printf '=== apk wrapper ===\n'; cat /usr/local/bin/apk-silex
printf '=== privkey location ===\n'; ls -la /root/.abuild/keys/silex-packages.rsa 2>/dev/null || printf 'NOT FOUND\n'
printf '=== pubkey in /etc/apk/keys/ ===\n'; ls -la /etc/apk/keys/silex-packages.rsa.pub 2>/dev/null || printf 'NOT FOUND\n'
printf '=== update_abuildrepo_index die patch ===\n'; grep -c 'die "Failed to create index"' /usr/bin/abuild && printf 'NOT PATCHED\n' || printf 'patched (die removed)\n'

chmod +x scripts/build-all.sh scripts/build-one.sh scripts/index.sh
if [ -n "${1:-}" ]; then
    scripts/build-one.sh "$1"
else
    scripts/build-all.sh
fi
scripts/index.sh
