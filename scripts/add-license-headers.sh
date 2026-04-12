#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2024-2025 ArcherDB Contributors
#
# add-license-headers.sh - Add SPDX license headers to first-party source files
#
# Usage:
#   ./scripts/add-license-headers.sh [--check] [--dry-run]
#
# Options:
#   --check     Check files for missing headers (exit 1 if any missing)
#   --dry-run   Show what would be changed without modifying files
#
# The script adds SPDX Apache-2.0 license headers to first-party source files
# and skips vendored/generated directories such as node_modules, dist, target,
# zig-out, .zig-cache, and virtual environments.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CHECK_ONLY=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check)
            CHECK_ONLY=true
            ;;
        --dry-run)
            DRY_RUN=true
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
    shift
done

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

declare -r COPYRIGHT_LINE="Copyright (c) 2024-2025 ArcherDB Contributors"
declare -a SEARCH_ROOTS=(
    "$PROJECT_ROOT/src"
    "$PROJECT_ROOT/scripts"
    "$PROJECT_ROOT/test_infrastructure"
    "$PROJECT_ROOT/tools"
    "$PROJECT_ROOT/.github"
)

header_prefix_for_file() {
    case "$1" in
        *.zig|*.c|*.h|*.cpp|*.go|*.java|*.js|*.ts)
            printf '%s\n' '// SPDX-License-Identifier: Apache-2.0' "// $COPYRIGHT_LINE"
            ;;
        *.py|*.sh|*.yml|*.yaml)
            printf '%s\n' '# SPDX-License-Identifier: Apache-2.0' "# $COPYRIGHT_LINE"
            ;;
        *)
            return 1
            ;;
    esac
}

should_skip_file() {
    case "$1" in
        */node_modules/*|*/dist/*|*/target/*|*/zig-out/*|*/.zig-cache/*|*/__pycache__/*|*/.venv/*|*/venv/*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

insert_header() {
    local file="$1"
    local header="$2"
    local tmpfile
    tmpfile="$(mktemp)"

    if head -n 1 "$file" | grep -q '^#!'; then
        {
            head -n 1 "$file"
            printf '%s\n' "$header"
            tail -n +2 "$file"
        } > "$tmpfile"
    else
        {
            printf '%s\n' "$header"
            cat "$file"
        } > "$tmpfile"
    fi

    mv "$tmpfile" "$file"
}

missing=0
updated=0
skipped=0

while IFS= read -r -d '' file; do
    if should_skip_file "$file"; then
        continue
    fi

    header="$(header_prefix_for_file "$file")" || continue

    if head -5 "$file" | grep -q "SPDX-License-Identifier"; then
        skipped=$((skipped + 1))
        continue
    fi

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

    echo -e "${GREEN}Adding header:${NC} $rel_path"
    insert_header "$file" "$header"
    updated=$((updated + 1))
done < <(find "${SEARCH_ROOTS[@]}" -type f -print0)

echo ""
echo "Summary:"
echo "  Files with header: $skipped"
echo "  Files missing header: $missing"

if [[ "$CHECK_ONLY" == "true" ]]; then
    if [[ $missing -gt 0 ]]; then
        echo -e "${RED}Check failed: $missing files missing license headers${NC}"
        exit 1
    fi
    echo -e "${GREEN}All files have license headers${NC}"
elif [[ "$DRY_RUN" == "true" ]]; then
    echo "  Would update: $missing"
else
    echo "  Files updated: $updated"
fi
