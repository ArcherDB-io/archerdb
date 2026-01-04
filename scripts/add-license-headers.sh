#!/usr/bin/env bash
#
# add-license-headers.sh - Add SPDX license headers to source files
#
# Usage:
#   ./scripts/add-license-headers.sh [--check] [--dry-run]
#
# Options:
#   --check     Check files for missing headers (exit 1 if any missing)
#   --dry-run   Show what would be changed without modifying files
#
# The script adds SPDX Apache-2.0 license headers to all Zig source files
# that don't already have one.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Header to add
HEADER="// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
"

# Parse arguments
CHECK_ONLY=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --check)
            CHECK_ONLY=true
            ;;
        --dry-run)
            DRY_RUN=true
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
    shift
done

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# Counters
missing=0
updated=0
skipped=0

# Find all Zig files
while IFS= read -r -d '' file; do
    # Check if file already has SPDX header
    if head -5 "$file" | grep -q "SPDX-License-Identifier"; then
        skipped=$((skipped + 1))
        continue
    fi

    # File is missing header
    missing=$((missing + 1))
    rel_path="${file#"$PROJECT_ROOT"/}"

    if [[ "$CHECK_ONLY" == "true" ]]; then
        echo -e "${RED}Missing header:${NC} $rel_path"
        continue
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "${YELLOW}Would add header:${NC} $rel_path"
        continue
    fi

    # Add header to file
    echo -e "${GREEN}Adding header:${NC} $rel_path"

    # Create temp file with header + original content
    tmpfile=$(mktemp)
    echo -n "$HEADER" > "$tmpfile"
    cat "$file" >> "$tmpfile"
    mv "$tmpfile" "$file"

    updated=$((updated + 1))

done < <(find "$PROJECT_ROOT/src" -name "*.zig" -type f -print0)

# Summary
echo ""
echo "Summary:"
echo "  Files with header: $skipped"
echo "  Files missing header: $missing"

if [[ "$CHECK_ONLY" == "true" ]]; then
    if [[ $missing -gt 0 ]]; then
        echo -e "${RED}Check failed: $missing files missing license headers${NC}"
        exit 1
    else
        echo -e "${GREEN}All files have license headers${NC}"
    fi
elif [[ "$DRY_RUN" == "true" ]]; then
    echo "  Would update: $missing"
else
    echo "  Files updated: $updated"
fi
