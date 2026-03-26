#!/bin/sh
# verify.sh [dir]
# Verify all .apk files in dir (default: x86_64/ and aarch64/).
# Checks:
#   - Archive is a valid zstd-compressed tar
#   - Contains a .PKGINFO member
#   - .PKGINFO has required fields: pkgname, pkgver, arch
#   - APKINDEX.tar.gz is present and non-empty (if packages exist)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

FAILURES=0

check_apk() {
    APK="$1"
    NAME=$(basename "$APK")

    # Readable zstd?
    if ! zstd -t "$APK" 2>/dev/null; then
        printf 'FAIL %s: not a valid zstd file\n' "$NAME"
        FAILURES=$((FAILURES + 1))
        return
    fi

    # Contains .PKGINFO?
    PKGINFO=$(zstd -dc "$APK" 2>/dev/null | tar -t 2>/dev/null \
                  | grep -x '\.PKGINFO' | head -1)
    if [ -z "$PKGINFO" ]; then
        printf 'FAIL %s: no .PKGINFO member\n' "$NAME"
        FAILURES=$((FAILURES + 1))
        return
    fi

    # Extract .PKGINFO and check required fields
    INFO=$(zstd -dc "$APK" 2>/dev/null | tar -x .PKGINFO -O 2>/dev/null)

    for field in pkgname pkgver arch; do
        if ! printf '%s' "$INFO" | grep -q "^$field = "; then
            printf 'FAIL %s: .PKGINFO missing %s field\n' "$NAME" "$field"
            FAILURES=$((FAILURES + 1))
        fi
    done

    printf 'ok   %s\n' "$NAME"
}

check_dir() {
    DIR="$1"
    [ -d "$DIR" ] || return 0

    count=$(ls "$DIR"/*.apk 2>/dev/null | wc -l)
    [ "$count" -eq 0 ] && { printf 'verify: %s: no .apk files\n' "$DIR"; return 0; }

    printf 'verify: checking %d packages in %s\n' "$count" "$DIR"

    for apk in "$DIR"/*.apk; do
        check_apk "$apk"
    done

    if [ -f "$DIR/APKINDEX.tar.gz" ]; then
        if [ -s "$DIR/APKINDEX.tar.gz" ]; then
            printf 'ok   APKINDEX.tar.gz (%s bytes)\n' \
                "$(wc -c < "$DIR/APKINDEX.tar.gz")"
        else
            printf 'FAIL APKINDEX.tar.gz: empty\n'
            FAILURES=$((FAILURES + 1))
        fi
    else
        printf 'WARN %s: no APKINDEX.tar.gz\n' "$DIR"
    fi
}

if [ -n "$1" ]; then
    check_dir "$1"
else
    check_dir "$REPO_ROOT/x86_64"
    check_dir "$REPO_ROOT/aarch64"
fi

printf '\nverify: %d failure(s)\n' "$FAILURES"
exit "$FAILURES"
