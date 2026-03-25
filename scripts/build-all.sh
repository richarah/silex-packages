#!/bin/sh
set -e

REPO="$(cd "$(dirname "$0")/.." && pwd)"
APORTS="$REPO/aports"
ARCH="${CARCH:-$(apk --print-arch 2>/dev/null || uname -m)}"
REPODIR="$REPO/$ARCH"

# Add our output dir to apk's repo list (first, so it takes priority over
# Alpine/Wolfi for packages we provide).  apk checks repos in listed order.
if ! grep -qxF "$REPODIR" /etc/apk/repositories 2>/dev/null; then
    # Prepend so our packages win over upstream when names collide.
    { echo "$REPODIR"; cat /etc/apk/repositories; } > /tmp/repos.tmp
    mv /tmp/repos.tmp /etc/apk/repositories
fi

# _reindex: rebuild APKINDEX from every .apk in REPODIR, then install all
# packages from it.  Called after each package build so subsequent abuild -r
# invocations can resolve our packages (including subpackages like libcurl,
# gfortran, g++) by name when satisfying makedepends.
#
# No signing here — this is the intermediate build index.  CI signs the
# final release index via scripts/index.sh before publishing to Pages.
_reindex_and_install() {
    ls "$REPODIR"/*.apk >/dev/null 2>&1 || return 0
    apk index -q -o "$REPODIR/APKINDEX.tar.gz" "$REPODIR"/*.apk 2>/dev/null || return 0
    # Install every .apk file directly (bypasses signature verification).
    # apk silently skips already-installed packages at the same version.
    for f in "$REPODIR"/*.apk; do
        apk add --allow-untrusted --no-progress "$f" 2>/dev/null || true
    done
}

# Build order: dependencies before dependents.
# Rationale for each group:
#
#   zlib bzip2 xz zstd   — compression, no inter-deps
#   gmp                  — math, needed by gnutls
#   ncurses              — terminal, needed by readline libedit util-linux
#   readline             — needs ncurses; needed by sqlite postgresql python3
#   libffi               — needed by gnutls python3
#   expat                — needed by git gettext python3
#   pcre2                — needed by git
#   libyaml              — no deps from our repo
#   openssl              — needs zlib; needed by curl gnutls postgresql git openssh-client python3 nodejs
#   nghttp2 c-ares       — need openssl/zlib; needed by curl nodejs
#   libssh2              — needs openssl zlib; needed by curl
#   curl                 — needs openssl zlib nghttp2 libssh2 c-ares zstd; needed by git
#   gnutls               — needs gmp libffi zlib (nettle/libtasn1/p11-kit from Alpine)
#   libxml2              — needs zlib xz; needed by libxslt
#   libxslt              — needs libxml2
#   nasm                 — build tool; needed by libjpeg-turbo
#   libjpeg-turbo        — needs nasm (build tool)
#   libpng               — needs zlib; needed by libtiff libwebp
#   libtiff              — needs zlib libjpeg-turbo xz zstd; needed by libwebp
#   libwebp              — needs libpng libjpeg-turbo libtiff
#   giflib               — no deps from our repo
#   libedit              — needs ncurses
#   libcap               — no deps from our repo
#   eudev                — no deps from our repo (gperf is a build tool, from Alpine)
#   util-linux           — needs ncurses zlib
#   sqlite               — needs zlib readline
#   postgresql           — needs openssl readline zlib
#   mariadb-connector-c  — needs openssl zlib
#   yasm gperf           — build tools, no deps from our repo
#   flex                 — no deps from our repo
#   autoconf automake libtool gettext — autotools chain
#   bison                — needs gettext-dev; placed after our gettext for cleanliness
#   openblas             — after gcc so it links our libgfortran
#   gcc                  — needs gmp zlib (mpfr/mpc1/isl from Alpine); produces gfortran g++
#   file patch unzip jq  — utilities
#   git                  — needs openssl zlib expat pcre2 curl-dev
#   openssh-client       — needs openssl zlib
#   python3              — needs openssl zlib bzip2 xz readline ncurses sqlite libffi expat
#   nodejs               — needs openssl zlib c-ares nghttp2 python3
PKGS="
zlib
bzip2
xz
zstd
gmp
ncurses
readline
libffi
expat
pcre2
libyaml
openssl
nghttp2
c-ares
libssh2
curl
gnutls
libxml2
libxslt
nasm
libjpeg-turbo
libpng
libtiff
libwebp
giflib
libedit
libcap
eudev
util-linux
sqlite
postgresql
mariadb-connector-c
yasm
gperf
flex
autoconf
automake
libtool
gettext
bison
gcc
openblas
file
patch
unzip
jq
git
openssh-client
python3
nodejs
"

for pkg in $PKGS; do
    dir="$APORTS/$pkg"
    [ -f "$dir/APKBUILD" ] || { echo "=== skip $pkg (no APKBUILD) ==="; continue; }
    echo "=== building $pkg ==="
    cd "$dir"
    abuild -F -r -P "$REPO"
    # Rebuild the local index and install all packages (including subpackages)
    # so the next abuild -r can resolve them by name from makedepends.
    _reindex_and_install
    cd "$REPO"
done

echo "=== all packages built ==="
