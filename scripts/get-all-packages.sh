#!/bin/sh
# Get ALL Debian/Ubuntu packages except obvious bloat
# This replaces the seeds.list approach entirely

set -e

OUTPUT="${1:-config/all-packages.list}"

echo "Fetching all available packages from apt..." >&2

# Get all packages, filter by section and name patterns
apt-cache dumpavail | awk '
  /^Package: / { pkg = $2 }
  /^Section: / { section = $2 }
  /^$/ {
    # Skip bloat sections
    if (section ~ /^(games|doc|electronics|hamradio|science\/electronics)$/) next

    # Skip bloat package patterns
    if (pkg ~ /^(libreoffice|thunderbird|firefox|chromium|gimp|inkscape|blender|vlc|kdenlive)/) next
    if (pkg ~ /(-games|-game-data|^game-)/) next
    if (pkg ~ /^(gnome-games|kde-games|xscreensaver)/) next

    # Skip documentation packages (except essential ones)
    if (pkg ~ /-doc$/ && pkg !~ /^(man-db|manpages)/) next

    # Skip debug symbols
    if (pkg ~ /-dbg$|-dbgsym$/) next

    # Print everything else
    if (pkg) print pkg

    # Reset for next package
    pkg = ""
    section = ""
  }
' | sort -u > "$OUTPUT"

total=$(wc -l < "$OUTPUT")
echo "Found $total packages to include in repository" >&2
echo "Saved to $OUTPUT" >&2

# Show some stats
echo "" >&2
echo "Sample of included packages:" >&2
grep -E "^(bash|gcc|python3|nodejs|git|curl|vim|nginx|postgresql|redis|docker)$" "$OUTPUT" | head -20 >&2