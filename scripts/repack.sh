#!/bin/sh
# repack.sh <debian-package-name>
# Download a Debian binary package (.deb), extract its file tree,
# generate APK metadata, and pack as a .apk file.
#
# Environment:
#   REPO_DIR    — directory where .apk files are written (required)
#   ARCH        — target architecture (default: $(uname -m))
#   SCRIPTS_DIR — directory containing mkpkginfo.sh, mkapk.sh, sign.sh
#                 (default: directory of this script)
#
# Requires: apt-get, dpkg-deb, tar, gzip

set -e

PKG="$1"
[ -n "$PKG" ] || { printf 'repack: package name required\n' >&2; exit 1; }
[ -n "$REPO_DIR" ] || { printf 'repack: REPO_DIR not set\n' >&2; exit 1; }

ARCH="${ARCH:-$(uname -m)}"
SCRIPTS_DIR="${SCRIPTS_DIR:-$(cd "$(dirname "$0")" && pwd)}"

mkdir -p "$REPO_DIR"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM

STAGING="$WORK/staging"
CONTROL_DIR="$WORK/control"
mkdir -p "$STAGING" "$CONTROL_DIR"

cd "$WORK"

# Download the binary .deb
apt-get download "$PKG" 2>&1 | grep -v '^WARNING: apt does not' || true
DEB=$(ls "$WORK"/*.deb 2>/dev/null | head -1)
[ -f "$DEB" ] || { printf 'repack: apt-get download %s produced no .deb\n' "$PKG" >&2; exit 1; }

# Extract file tree into staging/
dpkg-deb -x "$DEB" "$STAGING"

# Extract control metadata
dpkg-deb -e "$DEB" "$CONTROL_DIR"
CONTROL="$CONTROL_DIR/control"
[ -f "$CONTROL" ] || { printf 'repack: no control file in %s\n' "$DEB" >&2; exit 1; }

# Compute installed size in bytes
SIZE=$(du -sb "$STAGING" | cut -f1)

# Generate .PKGINFO
"$SCRIPTS_DIR/mkpkginfo.sh" "$CONTROL" "$SIZE" "$ARCH" > "$STAGING/.PKGINFO"

# Derive output filename from .PKGINFO
PKGNAME=$(grep '^pkgname' "$STAGING/.PKGINFO" | cut -d' ' -f3)
PKGVER=$(grep '^pkgver'  "$STAGING/.PKGINFO" | cut -d' ' -f3)
OUTPUT="$REPO_DIR/${PKGNAME}-${PKGVER}.${ARCH}.apk"

# Assemble .apk
"$SCRIPTS_DIR/mkapk.sh" "$STAGING" "$OUTPUT"


printf 'repacked: %s -> %s\n' "$PKG" "$(basename "$OUTPUT")"
