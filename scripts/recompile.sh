#!/bin/sh
# recompile.sh <debian-package-name>
# Fetch Debian source package, apply patches, build with Silex compiler
# flags, pack result as .apk.
#
# Environment:
#   REPO_DIR    -- directory where .apk files are written (required)
#   ARCH        -- target architecture (default: $(uname -m))
#   SCRIPTS_DIR -- directory containing helper scripts
#   PRIVKEY     -- path to RSA private key for signing (optional)
#   PUBKEY      -- path to RSA public key (required if PRIVKEY is set)
#   CC, CXX, CFLAGS, CXXFLAGS, LDFLAGS -- set by sourcing config/cflags.conf
#
# Requires: apt-get, dpkg-source, dpkg-deb, make/ninja/meson, openssl

set -e

PKG="$1"
[ -n "$PKG" ]      || { printf 'recompile: package name required\n' >&2; exit 1; }
[ -n "$REPO_DIR" ] || { printf 'recompile: REPO_DIR not set\n' >&2; exit 1; }

ARCH="${ARCH:-$(uname -m)}"
SCRIPTS_DIR="${SCRIPTS_DIR:-$(cd "$(dirname "$0")" && pwd)}"
REPO_ROOT="$(cd "$SCRIPTS_DIR/.." && pwd)"

# Load Silex compiler flags if not already in environment
[ -z "$CC" ] && [ -f "$REPO_ROOT/config/cflags.conf" ] && . "$REPO_ROOT/config/cflags.conf"

mkdir -p "$REPO_DIR"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM

STAGING="$WORK/staging"
mkdir -p "$STAGING"

cd "$WORK"

# Fetch Debian source (downloads .dsc, .orig.tar.*, .debian.tar.*)
apt-get source --download-only "$PKG" 2>&1
DSC=$(ls "$WORK"/*.dsc 2>/dev/null | head -1)
[ -f "$DSC" ] || { printf 'recompile: %s: no .dsc found\n' "$PKG" >&2; exit 1; }

# Unpack source tree; Debian patches applied automatically by dpkg-source
dpkg-source --no-check -x "$DSC" "$WORK/source"
cd "$WORK/source"

# --- Build system detection ---
# Some upstreams ship configure.ac without a pre-generated configure;
# run autoreconf to generate it before falling through to the autoconf path.
if [ ! -f configure ] && [ -f configure.ac -o -f configure.in ]; then
    autoreconf -fiv 2>&1 || true
fi
# autogen.sh is another common variant
if [ ! -f configure ] && [ -f autogen.sh ]; then
    sh autogen.sh 2>&1 || true
fi

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
    # Fallback: use Debian's own build system.
    # Export CC/CXX/CFLAGS so well-behaved packages pick them up.
    # DEB_BUILD_OPTIONS=nocheck skips test suites.
    # dpkg-buildpackage puts output in the parent directory ($WORK).
    export DEB_CC="$CC" DEB_CXX="${CXX:-$CC}"
    DEB_BUILD_OPTIONS="nocheck nostrip" \
        dpkg-buildpackage -b -uc -us -j"$(nproc)"

    # Extract each resulting .deb (skip dbg/dbgsym/doc)
    for deb in "$WORK"/*.deb; do
        [ -f "$deb" ] || continue
        case "$(basename "$deb")" in
            *-dbg_*|*-dbgsym_*|*-doc_*) continue ;;
        esac
        dpkg-deb -x "$deb" "$STAGING"
    done
fi

# Strip binaries and shared libraries
_strip="${STRIP:-strip}"
find "$STAGING" -type f | while IFS= read -r f; do
    if file "$f" 2>/dev/null | grep -q 'ELF'; then
        "$_strip" --strip-unneeded "$f" 2>/dev/null || true
    fi
done

# --- Control file for .PKGINFO generation ---
# Prefer debian/control from the source tree; fall back to extracting from
# one of the produced .deb files (dpkg-buildpackage path).
CTRL=""
if [ -f "$WORK/source/debian/control" ]; then
    # debian/control may have a Source: stanza followed by Package: stanzas.
    # Extract the stanza matching $PKG; if not found, use the first Package: stanza.
    awk -v pkg="$PKG" '
        /^Package:[[:space:]]/ {
            cur = $0; sub(/^Package:[[:space:]]*/, "", cur)
            in_match = (cur == pkg)
        }
        in_match { print }
        /^[[:space:]]*$/ && in_match { exit }
    ' "$WORK/source/debian/control" > "$WORK/binary.control"

    if [ ! -s "$WORK/binary.control" ]; then
        awk '/^Package:/{found=1} found{print} /^[[:space:]]*$/ && found{exit}' \
            "$WORK/source/debian/control" > "$WORK/binary.control"
    fi
    CTRL="$WORK/binary.control"
fi

if [ -z "$CTRL" ] || [ ! -s "$CTRL" ]; then
    # Fall back to extracting control from the first non-dbg .deb
    for deb in "$WORK"/*.deb; do
        [ -f "$deb" ] || continue
        case "$(basename "$deb")" in *-dbg_*|*-dbgsym_*) continue ;; esac
        _ctmp=$(mktemp -d)
        dpkg-deb -e "$deb" "$_ctmp"
        cp "$_ctmp/control" "$WORK/binary.control" 2>/dev/null && CTRL="$WORK/binary.control"
        rm -rf "$_ctmp"
        break
    done
fi

[ -n "$CTRL" ] && [ -s "$CTRL" ] || \
    { printf 'recompile: %s: cannot extract binary control\n' "$PKG" >&2; exit 1; }

SIZE=$(du -sb "$STAGING" | cut -f1)
"$SCRIPTS_DIR/mkpkginfo.sh" "$CTRL" "$SIZE" "$ARCH" > "$STAGING/.PKGINFO"

PKGNAME=$(awk '/^pkgname/{print $3}' "$STAGING/.PKGINFO")
PKGVER=$(awk  '/^pkgver/{print $3}'  "$STAGING/.PKGINFO")
OUTPUT="$REPO_DIR/${PKGNAME}-${PKGVER}.${ARCH}.apk"

"$SCRIPTS_DIR/mkapk.sh" "$STAGING" "$OUTPUT"

[ -n "$PRIVKEY" ] && [ -n "$PUBKEY" ] && \
    "$SCRIPTS_DIR/sign.sh" "$PRIVKEY" "$PUBKEY" "$OUTPUT"

printf 'recompiled: %s -> %s\n' "$PKG" "$(basename "$OUTPUT")"
