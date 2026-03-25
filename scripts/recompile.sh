#!/bin/sh
# recompile.sh <debian-package-name>
# Fetch Debian source package, apply patches, build with Silex compiler
# flags, pack result as .apk.
#
# Environment:
#   REPO_DIR    — directory where .apk files are written (required)
#   ARCH        — target architecture (default: $(uname -m))
#   SCRIPTS_DIR — directory containing helper scripts
#   PRIVKEY     — path to RSA private key for signing (optional)
#   PUBKEY      — path to RSA public key (required if PRIVKEY is set)
#   CC, CXX, CFLAGS, CXXFLAGS, LDFLAGS — set by sourcing config/cflags.conf
#
# Requires: apt-get source, dpkg-source, dpkg-deb, tar, openssl

set -e

PKG="$1"
[ -n "$PKG" ]      || { printf 'recompile: package name required\n' >&2; exit 1; }
[ -n "$REPO_DIR" ] || { printf 'recompile: REPO_DIR not set\n' >&2; exit 1; }

ARCH="${ARCH:-$(uname -m)}"
SCRIPTS_DIR="${SCRIPTS_DIR:-$(cd "$(dirname "$0")" && pwd)}"
REPO_ROOT="$(cd "$SCRIPTS_DIR/.." && pwd)"

# Load Silex compiler flags if not already in environment
if [ -z "$CC" ] && [ -f "$REPO_ROOT/config/cflags.conf" ]; then
    # shellcheck source=config/cflags.conf
    . "$REPO_ROOT/config/cflags.conf"
fi

mkdir -p "$REPO_DIR"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM

STAGING="$WORK/staging"
mkdir -p "$STAGING"

cd "$WORK"

# Fetch Debian source (downloads .dsc, .orig.tar.*, .debian.tar.*)
apt-get source --download-only "$PKG" 2>&1
DSC=$(ls "$WORK"/*.dsc 2>/dev/null | head -1)
[ -f "$DSC" ] || { printf 'recompile: apt-get source %s: no .dsc found\n' "$PKG" >&2; exit 1; }

# Unpack source tree; Debian patches applied by dpkg-source
dpkg-source --no-check -x "$DSC" "$WORK/source"
cd "$WORK/source"

# Determine build system and build
if [ -f configure ]; then
    ./configure \
        --prefix=/usr \
        --libdir=/usr/lib \
        --sysconfdir=/etc \
        --localstatedir=/var \
        CC="$CC" CXX="${CXX:-$CC}" \
        CFLAGS="$CFLAGS" CXXFLAGS="${CXXFLAGS:-$CFLAGS}" \
        LDFLAGS="$LDFLAGS"
    make -j"$(nproc)"
    make install DESTDIR="$STAGING"

elif [ -f CMakeLists.txt ]; then
    cmake -B _build -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr \
        -DCMAKE_INSTALL_LIBDIR=lib \
        -DCMAKE_C_COMPILER="$CC" \
        -DCMAKE_CXX_COMPILER="${CXX:-$CC}" \
        -DCMAKE_C_FLAGS="$CFLAGS" \
        -DCMAKE_CXX_FLAGS="${CXXFLAGS:-$CFLAGS}" \
        -DCMAKE_EXE_LINKER_FLAGS="$LDFLAGS" \
        -DCMAKE_SHARED_LINKER_FLAGS="$LDFLAGS" \
        -DCMAKE_MODULE_LINKER_FLAGS="$LDFLAGS"
    ninja -C _build -j"$(nproc)"
    DESTDIR="$STAGING" ninja -C _build install

elif [ -f meson.build ]; then
    meson setup _build \
        --prefix=/usr \
        --libdir=lib \
        --buildtype=release \
        -Db_lto=true
    ninja -C _build -j"$(nproc)"
    DESTDIR="$STAGING" ninja -C _build install

else
    # Fallback: use Debian's build system with our flags exported.
    # DEB_BUILD_OPTIONS=nocheck skips test suites.
    # The resulting .deb files are extracted into staging/.
    DEB_BUILD_OPTIONS="nocheck nostrip" \
        dpkg-buildpackage -b -uc -us -j"$(nproc)"

    for deb in "$WORK"/*.deb; do
        [ -f "$deb" ] || continue
        # Skip debug/doc packages
        case "$(basename "$deb")" in
            *-dbg_*|*-dbgsym_*|*-doc_*) continue ;;
        esac
        dpkg-deb -x "$deb" "$STAGING"
    done
fi

# Strip binaries and shared libraries
STRIP="${STRIP:-strip}"
find "$STAGING" -type f \( -name '*.so*' -o -perm /0111 \) -exec sh -c \
    'file "$1" 2>/dev/null | grep -q ELF && '"$STRIP"' --strip-unneeded "$1" 2>/dev/null || true' \
    _ {} \;

# Generate .PKGINFO from Debian source control
# debian/control may have multiple stanzas; we want the stanza matching $PKG
# or the first binary package stanza.
if [ -f "$WORK/source/debian/control" ]; then
    # Extract the binary stanza matching $PKG using awk
    awk -v pkg="$PKG" '
        /^Package:/ { in_pkg = ($2 == pkg) }
        in_pkg { print }
        /^$/ && in_pkg { exit }
    ' "$WORK/source/debian/control" > "$WORK/binary.control"

    # If no exact match, use first binary stanza (skip Source: stanza)
    if [ ! -s "$WORK/binary.control" ]; then
        awk '
            /^Package:/ { found=1 }
            found { print }
            /^$/ && found { exit }
        ' "$WORK/source/debian/control" > "$WORK/binary.control"
    fi
else
    # dpkg-buildpackage path: extract control from one of the .deb files
    FIRST_DEB=$(ls "$WORK"/*.deb 2>/dev/null | head -1)
    if [ -f "$FIRST_DEB" ]; then
        CTRL_TMP=$(mktemp -d)
        dpkg-deb -e "$FIRST_DEB" "$CTRL_TMP"
        cp "$CTRL_TMP/control" "$WORK/binary.control"
        rm -rf "$CTRL_TMP"
    fi
fi

[ -s "$WORK/binary.control" ] || \
    { printf 'recompile: %s: cannot find binary control stanza\n' "$PKG" >&2; exit 1; }

SIZE=$(du -sb "$STAGING" | cut -f1)
"$SCRIPTS_DIR/mkpkginfo.sh" "$WORK/binary.control" "$SIZE" "$ARCH" > "$STAGING/.PKGINFO"

# Derive output filename
PKGNAME=$(grep '^pkgname' "$STAGING/.PKGINFO" | cut -d' ' -f3)
PKGVER=$(grep  '^pkgver'  "$STAGING/.PKGINFO" | cut -d' ' -f3)
OUTPUT="$REPO_DIR/${PKGNAME}-${PKGVER}.${ARCH}.apk"

"$SCRIPTS_DIR/mkapk.sh" "$STAGING" "$OUTPUT"

if [ -n "$PRIVKEY" ] && [ -n "$PUBKEY" ]; then
    "$SCRIPTS_DIR/sign.sh" "$PRIVKEY" "$PUBKEY" "$OUTPUT"
fi

printf 'recompiled: %s → %s\n' "$PKG" "$(basename "$OUTPUT")"
