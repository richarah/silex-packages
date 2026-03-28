#!/bin/bash
# Generate seeds.list automatically from Debian Bookworm packages
# Usage: ./scripts/generate-seeds.sh [--dry-run] [--verbose]

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load configuration
if [ ! -f "$REPO_ROOT/config/pkg-selection.conf" ]; then
    printf "Error: config/pkg-selection.conf not found\n" >&2
    exit 1
fi
source "$REPO_ROOT/config/pkg-selection.conf"

# Parse arguments
DRY_RUN=0
VERBOSE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --verbose) VERBOSE=1 ;;
        *) printf "Unknown option: %s\n" "$1" >&2; exit 1 ;;
    esac
    shift
done

log() {
    if [ "$VERBOSE" = 1 ]; then
        printf "[generate-seeds] %s\n" "$1" >&2
    fi
}

# Backup existing files
if [ -f "$REPO_ROOT/lists/seeds.list" ]; then
    cp "$REPO_ROOT/lists/seeds.list" "$REPO_ROOT/lists/seeds.list.bak"
    log "Backed up seeds.list"
fi

# Create temporary work file
WORK_FILE=$(mktemp)
trap "rm -f $WORK_FILE" EXIT

# Function to check if package matches exclude patterns
is_excluded() {
    local pkg="$1"
    while IFS= read -r pattern; do
        # Skip empty lines and comments
        [ -z "$pattern" ] || [ "$pattern" = "${pattern#\#}" ] || continue
        pattern="${pattern#"${pattern%%[![:space:]]*}"}"  # trim leading
        pattern="${pattern%"${pattern##*[![:space:]]}"}"  # trim trailing
        [ -n "$pattern" ] || continue

        if printf '%s' "$pkg" | grep -qE "$pattern"; then
            return 0  # excluded
        fi
    done <<< "$EXCLUDE_PATTERNS"
    return 1  # not excluded
}

# Function to check if optional package should be included
is_optional_match() {
    local pkg="$1"
    for category in $INCLUDE_OPTIONAL_CATEGORIES; do
        if printf '%s' "$pkg" | grep -qE "^$category"; then
            return 0  # matches
        fi
    done
    return 1  # doesn't match
}

# Query packages from apt cache
log "Querying packages from Debian Bookworm..."

# Get all packages with priority and size
apt-cache dumpavail 2>/dev/null | awk '
/^Package:/ { pkg = $2 }
/^Priority:/ { priority = $2 }
/^Size:/ { size = $2 }
/^$/ {
    if (pkg && priority) {
        printf "%s\t%s\t%s\n", pkg, priority, size
    }
    pkg = ""; priority = ""; size = 0
}
' > "$WORK_FILE"

log "Found $(wc -l < "$WORK_FILE") total packages"

# Separate packages by priority
REQUIRED=$(awk -F'\t' '$2=="required" {print $1}' "$WORK_FILE")
IMPORTANT=$(awk -F'\t' '$2=="important" {print $1}' "$WORK_FILE")
STANDARD=$(awk -F'\t' '$2=="standard" {print $1}' "$WORK_FILE")
OPTIONAL=$(awk -F'\t' '$2=="optional" {print $1}' "$WORK_FILE")

log "By priority: required=$(printf '%s\n' "$REQUIRED" | wc -l) important=$(printf '%s\n' "$IMPORTANT" | wc -l) standard=$(printf '%s\n' "$STANDARD" | wc -l) optional=$(printf '%s\n' "$OPTIONAL" | wc -l)"

# Build seeds list
SEEDS=""

# Helper function to add packages from a set
add_packages() {
    local source_var="$1"
    local description="$2"
    local optional_filter="$3"

    local pkglist
    eval "pkglist=\$$source_var"

    local added=0
    while IFS= read -r pkg; do
        [ -z "$pkg" ] && continue

        # Apply exclusion filter
        if is_excluded "$pkg"; then
            log "Excluding: $pkg (matches exclude pattern)"
            continue
        fi

        # For optional packages, apply category filter
        if [ "$optional_filter" = "yes" ]; then
            if ! is_optional_match "$pkg"; then
                continue
            fi
        fi

        SEEDS="$SEEDS$pkg
"
        added=$((added + 1))

        if [ $((added % 500)) -eq 0 ]; then
            log "Added $added packages from $description"
        fi
    done <<< "$pkglist"

    log "Added $added packages from $description"
}

# Add packages in priority order
add_packages "REQUIRED" "required" "no"
add_packages "IMPORTANT" "important" "no"
add_packages "STANDARD" "standard" "no"
add_packages "OPTIONAL" "optional" "yes"

# Sort and deduplicate
SEEDS=$(printf '%s' "$SEEDS" | sort -u | grep -v '^$')
PACKAGE_COUNT=$(printf '%s' "$SEEDS" | wc -l)

# Calculate total size
log "Calculating total package size..."
TOTAL_SIZE=0
while IFS= read -r pkg; do
    [ -z "$pkg" ] && continue
    local size=$(apt-cache show "$pkg" 2>/dev/null | grep "^Size:" | head -1 | awk '{print $2}')
    TOTAL_SIZE=$((TOTAL_SIZE + ${size:-0}))
done <<< "$SEEDS"

SIZE_GB=$((TOTAL_SIZE / 1024 / 1024 / 1024))
SIZE_MB=$((TOTAL_SIZE / 1024 / 1024))

log "Final selection: $PACKAGE_COUNT packages, ~${SIZE_GB}GB"

# Show summary
printf "\n=== Package Selection Summary ===\n"
printf "Total packages: %d\n" "$PACKAGE_COUNT"
printf "Total size: ~%dGB (limit: %dGB)\n" "$SIZE_GB" "$MAX_SIZE_GB"
printf "\n"

if [ "$DRY_RUN" = 1 ]; then
    printf "DRY RUN MODE - Not writing files\n"
    printf "\nFirst 20 packages that would be added:\n"
    printf '%s' "$SEEDS" | head -20
    printf "\nLast 20 packages that would be added:\n"
    printf '%s' "$SEEDS" | tail -20
    exit 0
fi

# Write seeds.list
printf "# AUTO-GENERATED by generate-seeds.sh - DO NOT EDIT MANUALLY\n"      > "$REPO_ROOT/lists/seeds.list"
printf "# Generated: $(date -u +%%Y-%%m-%%dT%%H:%%M:%%SZ)\n"                >> "$REPO_ROOT/lists/seeds.list"
printf "# Config: %s\n" "$(md5sum "$REPO_ROOT/config/pkg-selection.conf" | cut -d' ' -f1)" >> "$REPO_ROOT/lists/seeds.list"
printf "# Packages: %d, Size: ~%dGB\n" "$PACKAGE_COUNT" "$SIZE_GB"           >> "$REPO_ROOT/lists/seeds.list"
printf "# To regenerate: make update-seeds\n\n"                            >> "$REPO_ROOT/lists/seeds.list"
printf '%s' "$SEEDS"                                                         >> "$REPO_ROOT/lists/seeds.list"

printf "\n✓ Wrote %d packages to lists/seeds.list\n" "$PACKAGE_COUNT"

# Update skip.list to exclude everything else
printf "# AUTO-UPDATED by generate-seeds.sh\n" > "$REPO_ROOT/lists/skip.list.new"
printf "# Packages in Debian but NOT in silex-packages (because they exceed size limit)\n" >> "$REPO_ROOT/lists/skip.list.new"
printf "# Total packages skipped: $(apt-cache dumpavail 2>/dev/null | grep "^Package:" | wc -l) - $PACKAGE_COUNT\n\n" >> "$REPO_ROOT/lists/skip.list.new"

# Get all available packages and exclude the ones we selected
apt-cache dumpavail 2>/dev/null | grep "^Package:" | awk '{print $2}' | sort -u > "$WORK_FILE.all"
printf '%s' "$SEEDS" | sort -u > "$WORK_FILE.selected"
comm -23 "$WORK_FILE.all" "$WORK_FILE.selected" >> "$REPO_ROOT/lists/skip.list.new"

if [ -f "$REPO_ROOT/lists/skip.list" ]; then
    mv "$REPO_ROOT/lists/skip.list.new" "$REPO_ROOT/lists/skip.list"
    printf "✓ Updated lists/skip.list\n"
else
    mv "$REPO_ROOT/lists/skip.list.new" "$REPO_ROOT/lists/skip.list"
    printf "✓ Created lists/skip.list\n"
fi

printf "\nDone! Run 'make test-seeds' to validate.\n"
