#!/bin/bash
# Debug script to investigate why certain packages don't resolve in container
# Run this inside the CI container to understand APT limitations

set -e

echo "=== APT Configuration Debug ==="
echo ""
echo "Ubuntu release:"
lsb_release -a 2>/dev/null || cat /etc/os-release | grep -E "^(NAME|VERSION|ID)"

echo ""
echo "APT sources:"
cat /etc/apt/sources.list

echo ""
echo "=== Testing Major Package Dependencies ==="
echo ""

test_package() {
    local pkg=$1
    echo "Testing: $pkg"

    # Check if package exists
    if ! apt-cache show "$pkg" >/dev/null 2>&1; then
        echo "  ✗ Package NOT FOUND in APT"
        return
    fi

    echo "  ✓ Package exists"

    # Get direct dependencies
    local deps=$(apt-cache depends --no-recommends --no-suggests "$pkg" 2>&1 | grep "Depends:" | awk '{print $2}' | head -5)

    if [ -n "$deps" ]; then
        echo "  Direct dependencies (first 5):"
        apt-cache depends --no-recommends --no-suggests "$pkg" 2>&1 | grep "Depends:" | head -5 | sed 's/^/    /'
    fi

    # Try to expand full closure
    echo "  Full closure expansion:"
    closure_count=$(apt-cache depends --recurse --no-recommends --no-suggests "$pkg" 2>&1 | grep '^[a-z]' | grep -v '^<' | wc -l)
    echo "    Packages in closure: $closure_count"

    # Check for unresolvable dependencies
    echo "  Checking for unresolvable deps..."
    unresolvable=$(apt-cache depends --recurse --no-recommends --no-suggests "$pkg" 2>&1 | grep '^<' | sort -u | head -5)
    if [ -n "$unresolvable" ]; then
        echo "    Virtual/unresolvable packages:"
        echo "$unresolvable" | sed 's/^/      /'
    else
        echo "    ✓ No virtual packages"
    fi

    echo ""
}

# Test critical packages
for pkg in curl git python3 python3-dev python3-minimal nodejs npm ruby perl php-cli nginx build-essential; do
    test_package "$pkg"
done

echo "=== Comparing with Local APT ==="
echo ""
echo "Packages available in APT (sample):"
apt-cache search . 2>/dev/null | cut -d' ' -f1 | head -30 | wc -l
echo "Total packages in APT:"
apt-cache search . 2>/dev/null | cut -d' ' -f1 | wc -l

echo ""
echo "=== Investigating deb-src availability ==="
grep -E "^deb-src" /etc/apt/sources.list && echo "deb-src found" || echo "NO deb-src sources"

echo ""
echo "=== Checking specific missing packages from closure ==="
missing=(
    "libcurl4t64"
    "libcurl3t64-gnutls"
    "python3.13"
    "python3-minimal"
    "libnode115"
    "ruby3.3"
    "libruby"
)

for pkg in "${missing[@]}"; do
    if apt-cache show "$pkg" >/dev/null 2>&1; then
        echo "✓ $pkg available"
    else
        echo "✗ $pkg NOT available"
    fi
done

echo ""
echo "=== APT Cache Stats ==="
apt-cache stats 2>/dev/null || echo "stats unavailable"
