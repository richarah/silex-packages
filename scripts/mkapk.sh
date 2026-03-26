#!/bin/sh
# mkapk.sh <staging-dir> <output.apk>
# Assemble an APK package from a staging directory.
#
# The staging directory must contain:
#   .PKGINFO       — package metadata (MUST be first in control stream)
#   usr/, lib/, etc.   — file tree
#
# An APK is two concatenated gzip-compressed tar streams:
#   Stream 1 (control): .PKGINFO + optional hook scripts
#   Stream 2 (data):    file tree
#
# This is the standard v2 APK format, readable by apk-tools v2 and v3.
# Optional pre/post install scripts (.pre-install, .post-install, etc.)
# are included in the control stream if present in the staging dir.

set -e

STAGING="$1"
OUTPUT="$2"

[ -d "$STAGING" ]  || { printf 'mkapk: %s: not a directory\n' "$STAGING" >&2; exit 1; }
[ -n "$OUTPUT" ]   || { printf 'mkapk: output path required\n' >&2; exit 1; }
[ -f "$STAGING/.PKGINFO" ] || { printf 'mkapk: %s/.PKGINFO not found\n' "$STAGING" >&2; exit 1; }

CTRL_LIST=$(mktemp)
DATA_LIST=$(mktemp)
TMPOUT=$(mktemp)
trap 'rm -f "$CTRL_LIST" "$DATA_LIST" "$TMPOUT"' EXIT INT TERM

# Control stream file list: .PKGINFO first, then any hook scripts
printf '.PKGINFO\n' >> "$CTRL_LIST"
for ctrl in .pre-install .post-install .pre-upgrade .post-upgrade .pre-deinstall .post-deinstall; do
    [ -f "$STAGING/$ctrl" ] && printf '%s\n' "$ctrl" >> "$CTRL_LIST"
done

# Data stream file list: everything except control files
(cd "$STAGING" && find . -mindepth 1 \
    ! -name '.PKGINFO' \
    ! -name '.pre-install'   ! -name '.post-install' \
    ! -name '.pre-upgrade'   ! -name '.post-upgrade' \
    ! -name '.pre-deinstall' ! -name '.post-deinstall' \
    | sort) >> "$DATA_LIST"

# Stream 1: control section (gzip-compressed tar)
(cd "$STAGING" && tar -czf - --no-recursion -T "$CTRL_LIST") >> "$TMPOUT"

# Stream 2: data section (gzip-compressed tar)
(cd "$STAGING" && tar -czf - --no-recursion -T "$DATA_LIST") >> "$TMPOUT"

mv "$TMPOUT" "$OUTPUT"
