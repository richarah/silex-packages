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
# apk-tools v3 requirements for the control stream:
#   - POSIX ustar tar format (--format=ustar), not GNU format
#   - No end-of-archive null blocks at the end of the stream
#   - .PKGINFO must contain a 'datahash' field (SHA256 of the data stream)
#
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
DATA_STREAM=$(mktemp)
TMPOUT=$(mktemp)
trap 'rm -f "$CTRL_LIST" "$DATA_LIST" "$DATA_STREAM" "$TMPOUT"' EXIT INT TERM

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

# Stream 2: data section — build first so we can compute datahash for .PKGINFO
(cd "$STAGING" && tar -czf - --no-recursion -T "$DATA_LIST") > "$DATA_STREAM"

# Append datahash to .PKGINFO (SHA256 of the compressed data stream)
printf 'datahash = %s\n' "$(sha256sum "$DATA_STREAM" | awk '{print $1}')" \
    >> "$STAGING/.PKGINFO"

# Stream 1: control section
# apk v3 requires:
#   1. POSIX ustar tar format (not GNU format)
#   2. No end-of-archive null blocks at end of stream
# Compute exact byte count of real tar entries (headers + data, no EOA),
# then use head -c to take only those bytes before the two 512-byte EOA blocks.
ctrl_bytes=0
while IFS= read -r _fname; do
    [ -f "$STAGING/$_fname" ] || continue
    _fsz=$(wc -c < "$STAGING/$_fname")
    ctrl_bytes=$((ctrl_bytes + 512 + (_fsz + 511) / 512 * 512))
done < "$CTRL_LIST"
(cd "$STAGING" && tar --format=ustar -c -b 1 --no-recursion -T "$CTRL_LIST" | \
    head -c "$ctrl_bytes") | gzip -9 >> "$TMPOUT"

# Append data stream
cat "$DATA_STREAM" >> "$TMPOUT"

mv "$TMPOUT" "$OUTPUT"
