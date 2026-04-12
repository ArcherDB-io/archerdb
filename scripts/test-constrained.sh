#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2024-2025 ArcherDB Contributors
# Resource-constrained test runner for memory/CPU limited environments
#
# Usage:
#   ./scripts/test-constrained.sh              # Default: -j4, lite config
#   ./scripts/test-constrained.sh --minimal    # Minimal: -j2, lite config
#   ./scripts/test-constrained.sh --full       # Full resources (default Zig behavior)
#   ./scripts/test-constrained.sh --help       # Show this help
#
# Examples:
#   ./scripts/test-constrained.sh unit                    # Run unit tests with constraints
#   ./scripts/test-constrained.sh unit --test-filter foo  # Run filtered unit tests
#   ./scripts/test-constrained.sh integration             # Run integration tests
#   ./scripts/test-constrained.sh --minimal unit          # Minimal resources

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ZIG="$PROJECT_ROOT/zig/zig"

# Defaults
JOBS=4
CONFIG="lite"
PROFILE=""

# Parse resource flags
while [[ $# -gt 0 ]]; do
    case "$1" in
        --minimal)
            JOBS=2
            CONFIG="lite"
            shift
            ;;
        --constrained)
            JOBS=4
            CONFIG="lite"
            shift
            ;;
        --full)
            JOBS=""  # Let Zig use all cores
            CONFIG=""
            shift
            ;;
        --help|-h)
            echo "Resource-constrained test runner"
            echo ""
            echo "Resource profiles:"
            echo "  --minimal      -j2, lite config (~2GB RAM, 2 cores)"
            echo "  --constrained  -j4, lite config (~4GB RAM, 4 cores) [default]"
            echo "  --full         All cores, default config"
            echo ""
            echo "Test targets:"
            echo "  unit           Run unit tests (test:unit)"
            echo "  integration    Run integration tests (test:integration)"
            echo "  all            Run all tests (test)"
            echo "  check          Just compile check (fast)"
            echo "  build          Build only, no tests"
            echo ""
            echo "Examples:"
            echo "  $0 unit                           # Unit tests, constrained"
            echo "  $0 --minimal unit                 # Unit tests, minimal resources"
            echo "  $0 unit --test-filter encryption  # Filtered unit tests"
            echo "  $0 check                          # Quick compile check"
            exit 0
            ;;
        *)
            break
            ;;
    esac
done

# Build the command
BUILD_CMD=("$ZIG" "build")

# Add job limit if specified
if [[ -n "$JOBS" ]]; then
    BUILD_CMD+=("-j$JOBS")
fi

# Add config if specified
if [[ -n "$CONFIG" ]]; then
    BUILD_CMD+=("-Dconfig=$CONFIG")
fi

# Map test target aliases
TARGET="${1:-unit}"
shift || true

case "$TARGET" in
    unit)
        BUILD_CMD+=("test:unit")
        ;;
    integration)
        BUILD_CMD+=("test:integration")
        ;;
    all)
        BUILD_CMD+=("test")
        ;;
    check)
        BUILD_CMD+=("check")
        ;;
    build)
        # Just build, no test target
        ;;
    *)
        # Pass through as-is (e.g., "test:fmt", "fuzz", etc.)
        BUILD_CMD+=("$TARGET")
        ;;
esac

# Pass remaining args (like --test-filter)
if [[ $# -gt 0 ]]; then
    BUILD_CMD+=("--" "$@")
fi

# Show what we're running
echo "Running: ${BUILD_CMD[*]}"
echo "Resources: jobs=${JOBS:-all}, config=${CONFIG:-default}"
echo ""

# Run it
exec "${BUILD_CMD[@]}"
