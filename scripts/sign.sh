#!/bin/sh
set -e
PRIVKEY="$1"
PUBKEY="$2"
FILE="$(cd "$(dirname "$3")" && pwd)/$(basename "$3")"

[ -f "$PRIVKEY" ] || { printf 'sign: %s: not found\n' "$PRIVKEY" >&2; exit 1; }
[ -f "$FILE"    ] || { printf 'sign: %s: not found\n' "$FILE"    >&2; exit 1; }

PACKAGER_PRIVKEY="$PRIVKEY" abuild-sign -k "$PRIVKEY" "$FILE"
