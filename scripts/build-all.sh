#!/bin/sh
set -e

REPO="$(cd "$(dirname "$0")/.." && pwd)"
APORTS="$REPO/aports"
ARCH="${CARCH:-$(apk --print-arch 2>/dev/null || uname -m)}"
# abuild computes repo=${startdir%/*##*/} = parent dir name of each APKBUILD.
# With aports/pkgname/APKBUILD the repo is "aports", so packages land in
# $REPO/aports/$ARCH/.  REPODIR must match this for _reindex_and_install.
REPODIR="$REPO/aports/$ARCH"

# Add our output dir to apk's repo list (first, so it takes priority over
# Alpine/Wolfi for packages we provide).  apk checks repos in listed order.
if ! grep -qxF "$REPODIR" /etc/apk/repositories 2>/dev/null; then
    # Prepend so our packages win over upstream when names collide.
    { echo "$REPODIR"; cat /etc/apk/repositories; } > /tmp/repos.tmp
    mv /tmp/repos.tmp /etc/apk/repositories
fi

# _reindex_and_install: rebuild APKINDEX from every .apk in REPODIR, then
# install all packages from it.  Called after each wave so subsequent abuild -r
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

# _pre_install_deps: collect all makedepends from the listed packages and
# install them in a single serialized apk add before parallel builds start.
# This prevents concurrent apk lock acquisition (which causes EINTR under
# high parallelism) — each parallel build then hits an already-populated DB
# and its own apk add becomes a near-instant no-op.
_pre_install_deps() {
    _all_deps=""
    for pkg in "$@"; do
        dir="$APORTS/$pkg"
        [ -f "$dir/APKBUILD" ] || continue
        # Join APKBUILD lines, extract makedepends="..." value (handles multi-line)
        _deps=$(tr -d '\n\t' < "$dir/APKBUILD" | \
            grep -o 'makedepends="[^"]*"' | \
            sed 's/^makedepends="//; s/"$//')
        _all_deps="$_all_deps $_deps"
    done
    # Deduplicate
    _all_deps=$(printf '%s\n' $_all_deps | sort -u | grep -v '^$' | tr '\n' ' ')
    [ -z "$_all_deps" ] && return 0
    printf '=== pre-installing wave makedeps ===\n'
    /usr/bin/apk add --no-progress $_all_deps 2>/dev/null || true
}

# _build_wave: build all listed packages in parallel, then reindex.
# Packages within a wave have no inter-dependencies; they only depend on
# packages from earlier waves (already installed by _reindex_and_install).
#
# Uses a temp file to propagate failures from background subshells.
_wave_fail=/tmp/_wave_fail_$$
trap 'rm -f "$_wave_fail"' EXIT INT TERM

_build_wave() {
    # Pre-install all makedeps serially before launching parallel builds.
    _pre_install_deps "$@"
    rm -f "$_wave_fail"
    for pkg in "$@"; do
        (
            trap '' EXIT INT TERM  # Don't inherit parent's rm -f on subshell exit
            dir="$APORTS/$pkg"
            [ -f "$dir/APKBUILD" ] || { echo "=== skip $pkg (no APKBUILD) ==="; exit 0; }
            echo "=== building $pkg ==="
            cd "$dir"
            if ! abuild -F -r -P "$REPO"; then
                echo "=== FAILED $pkg ===" >&2
                touch "$_wave_fail"
                exit 1
            fi
            echo "=== done $pkg ==="
        ) &
    done
    wait || true  # wait for all jobs; don't let set -e fire on non-zero exit
    if [ -f "$_wave_fail" ]; then
        echo "=== wave failed ===" >&2
        exit 1
    fi
    _reindex_and_install
}

# Build order: dependencies before dependents, grouped into parallel waves.
#
# Wave 1 — no deps on any custom-built package (all makedeps from Wolfi):
#   zlib bzip2 xz zstd        compression, no inter-deps
#   gmp                        math, needed by gnutls/gcc
#   ncurses                    terminal, needed by readline/libedit/util-linux
#   libffi                     needed by gnutls/python3
#   expat                      needed by git/gettext/python3
#   pcre2                      needed by git
#   libyaml                    no deps from our repo
#   nasm                       build tool; needed by libjpeg-turbo
#   giflib                     no deps from our repo
#   libcap                     no deps from our repo
#   eudev                      no deps from our repo
#   yasm gperf                 build tools, no deps
#   flex                       no deps
#   autoconf automake libtool  autotools chain
#   gettext                    needed by bison
#   file patch unzip jq        utilities
#   c-ares                     DNS library, no inter-deps
_build_wave \
    zlib bzip2 xz zstd \
    gmp libffi expat pcre2 libyaml \
    ncurses \
    nasm giflib libcap eudev \
    yasm gperf flex \
    autoconf automake libtool gettext \
    file patch unzip jq \
    c-ares

# Wave 2 — needs wave-1 packages:
#   readline libedit           need ncurses
#   openssl                    needs zlib
#   libpng                     needs zlib
#   libjpeg-turbo              needs nasm (build tool)
#   libxml2                    needs zlib xz
#   gnutls                     needs gmp libffi zlib
#   bison                      needs gettext
#   gcc                        needs gmp zlib; produces gfortran g++
_build_wave \
    readline libedit \
    openssl \
    libpng \
    libjpeg-turbo \
    libxml2 \
    gnutls \
    bison \
    gcc

# Wave 3 — needs wave-2 packages:
#   libssh2 nghttp2            need openssl zlib
#   libxslt                    needs libxml2
#   libtiff                    needs zlib libjpeg-turbo xz zstd
#   sqlite                     needs zlib readline
#   util-linux                 needs ncurses zlib
#   postgresql                 needs openssl readline zlib
#   mariadb-connector-c        needs openssl zlib
#   openssh-client             needs openssl zlib
#   openblas                   needs gcc (for gfortran)
_build_wave \
    libssh2 nghttp2 \
    libxslt \
    libtiff \
    sqlite \
    util-linux \
    postgresql mariadb-connector-c \
    openssh-client \
    openblas

# Wave 4 — needs wave-3 packages:
#   curl                       needs openssl zlib nghttp2 libssh2 c-ares zstd
#   libwebp                    needs libpng libjpeg-turbo libtiff
#   python3                    needs openssl zlib bzip2 xz readline ncurses sqlite libffi expat
_build_wave \
    curl \
    libwebp \
    python3

# Wave 5 — needs wave-4 packages:
#   git                        needs openssl zlib expat pcre2 curl
#   nodejs                     needs openssl zlib c-ares nghttp2 python3
_build_wave \
    git \
    nodejs

echo "=== all packages built ==="
