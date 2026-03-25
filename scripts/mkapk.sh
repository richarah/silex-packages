#!/bin/sh
# mkapk.sh <staging-dir> <output.apk>
# Assemble an APK package from a staging directory.
#
# The staging directory must contain:
#   .PKGINFO       — package metadata (MUST be first in archive)
#   usr/, lib/, etc.   — file tree
#
# An APK is a gzip'd tar archive with .PKGINFO as the first member.
# Optional pre/post install scripts (.pre-install, .post-install, etc.)
# must also precede the file tree; they are included before the tree
# if present in the staging dir.

set -e

STAGING="$1"
OUTPUT="$2"

[ -d "$STAGING" ]  || { printf 'mkapk: %s: not a directory\n' "$STAGING" >&2; exit 1; }
[ -n "$OUTPUT" ]   || { printf 'mkapk: output path required\n' >&2; exit 1; }
[ -f "$STAGING/.PKGINFO" ] || { printf 'mkapk: %s/.PKGINFO not found\n' "$STAGING" >&2; exit 1; }

FILELIST=$(mktemp)
trap 'rm -f "$FILELIST"' EXIT INT TERM

# .PKGINFO must be first
printf '.PKGINFO\n' >> "$FILELIST"

# Optional control scripts (before file tree)
for ctrl in .pre-install .post-install .pre-upgrade .post-upgrade .pre-deinstall .post-deinstall; do
    [ -f "$STAGING/$ctrl" ] && printf '%s\n' "$ctrl" >> "$FILELIST"
done

# File tree: everything except .PKGINFO and control scripts
(cd "$STAGING" && find . -mindepth 1 \
    ! -name '.PKGINFO' \
    ! -name '.pre-install'   ! -name '.post-install' \
    ! -name '.pre-upgrade'   ! -name '.post-upgrade' \
    ! -name '.pre-deinstall' ! -name '.post-deinstall' \
    | sort) >> "$FILELIST"

# Build the archive. --no-recursion: file list already includes all paths.
(cd "$STAGING" && tar -czf "$OUTPUT" --no-recursion -T "$FILELIST")
