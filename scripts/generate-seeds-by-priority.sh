#!/bin/sh
# Generate seeds.list from Debian package priorities
# Includes: required + standard + important + useful optional/extra packages
# Philosophy: Required + standard + important by default.
#   If they have dependencies in optional/extra, grab those too.
#   Also grab useful optional/extra packages for Silex.
#   Rather have too much than too little.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SEEDS="$REPO_ROOT/config/seeds.list"

printf 'Generating seeds.list from Debian priorities...\n' >&2

# Helper: extract package names from apt-cache dumpavail by priority
# APT format: records separated by blank lines, fields on separate lines
get_packages_by_priority() {
  local priority="$1"
  apt-cache dumpavail 2>/dev/null | awk -v p="$priority" '
    /^Package: / { pkg = $2 }
    /^Priority: / && $2 == p { print pkg; next }
  ' | sort -u
}

# Get packages by priority
{
  # All required packages (essential)
  printf '# Priority: required (essential system packages)\n'
  get_packages_by_priority "required"

  # All standard packages
  printf '\n# Priority: standard (standard utilities and tools)\n'
  get_packages_by_priority "standard"

  # All important packages
  printf '\n# Priority: important (important for typical systems)\n'
  get_packages_by_priority "important"

  # Useful optional/extra packages for development
  printf '\n# Priority: optional/extra (development and useful tools)\n'
  printf 'build-essential\n'
  printf 'clang\n'
  printf 'cmake\n'
  printf 'git\n'
  printf 'curl\n'
  printf 'wget\n'
  printf 'jq\n'
  printf 'vim\n'
  printf 'nano\n'
  printf 'python3\n'
  printf 'python3-dev\n'
  printf 'nodejs\n'
  printf 'ruby\n'
  printf 'perl\n'
  printf 'php-cli\n'

} > "$SEEDS"

PACKAGE_COUNT=$(grep -c "^[a-z]" "$SEEDS")
printf 'Generated %d packages in %s\n' "$PACKAGE_COUNT" "$SEEDS" >&2
