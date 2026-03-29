#!/bin/bash
# Test what closure we get with Debian bookworm packages
# This simulates what the CI container will actually have

echo "=== Debian Bookworm Package Availability ==="
echo ""
echo "Testing if critical packages are in bookworm..."
echo ""

# These are the packages we want
critical_packages=(
    "curl"
    "git"
    "python3"
    "python3-minimal"
    "python3.13"
    "libcurl4t64"
    "libcurl3t64-gnutls"
    "nodejs"
    "libnode115"
    "ruby"
    "ruby3.3"
    "libruby"
    "nginx"
    "php-cli"
)

available=0
missing=0

for pkg in "${critical_packages[@]}"; do
    # Try to find the package in Debian bookworm sources
    result=$(apt-cache search --names-only "^${pkg}$" 2>/dev/null | wc -l)

    if [ "$result" -gt 0 ]; then
        echo "✓ $pkg"
        ((available++))
    else
        echo "✗ $pkg"
        ((missing++))
    fi
done

echo ""
echo "Summary: $available available, $missing missing"
echo ""
echo "=== Why packages are missing from closure ==="
echo ""
echo "Debian bookworm released June 2023 with specific package versions."
echo "The CI container is locked to bookworm and won't get newer packages."
echo ""
echo "Solution options:"
echo "1. Use ubuntu:24.04 container instead of debian:bookworm"
echo "2. Build custom container with additional PPAs"
echo "3. Accept 246-package limitation from bookworm"
echo "4. Add missing packages to required-repo.list with special handling"
