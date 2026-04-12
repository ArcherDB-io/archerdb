#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2024-2025 ArcherDB Contributors
#
# flamegraph.sh - Generate CPU flame graphs for ArcherDB workloads
#
# This script wraps Linux perf and Brendan Gregg's FlameGraph tools to produce
# interactive SVG flame graphs for CPU profiling.
#
# Usage:
#   ./scripts/flamegraph.sh --output profile.svg -- ./zig-out/bin/archerdb benchmark
#   ./scripts/flamegraph.sh --output profile.svg --pid 12345
#   ./scripts/flamegraph.sh --help
#
# Prerequisites:
#   - Linux kernel with perf support
#   - FlameGraph scripts (https://github.com/brendangregg/FlameGraph)
#   - perf tools installed (apt install linux-perf)
#
# Environment variables:
#   FLAMEGRAPH_DIR  - Path to FlameGraph scripts directory
#

set -euo pipefail

# Color codes for output (disabled if not a terminal)
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    NC='\033[0m' # No Color
else
    RED='' GREEN='' YELLOW='' BLUE='' NC=''
fi

# Script location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Configuration defaults
DURATION=30
FREQUENCY=99
INCLUDE_KERNEL=false
PID=""
OUTPUT=""
COMMAND=()
CLEANUP_PERF_DATA=true

# Usage help
usage() {
    cat <<EOF
Usage: $0 [OPTIONS] [-- COMMAND [ARGS...]]

Generate CPU flame graphs for ArcherDB workloads using Linux perf.

OPTIONS:
    -d, --duration <sec>    Sampling duration in seconds (default: 30)
    -f, --frequency <hz>    Sampling frequency in Hz (default: 99)
    -a, --all               Include kernel stacks
    -p, --pid <pid>         Attach to existing process instead of running command
    --output <file.svg>     Output SVG file (required)
    --no-cleanup            Keep perf.data file after generation
    --help                  Show this help message

EXAMPLES:
    # Profile a benchmark run for 30 seconds
    $0 --output profile.svg -- ./zig-out/bin/archerdb benchmark

    # Profile an existing server process
    $0 --output server.svg --pid 12345 --duration 60

    # High-frequency sampling with kernel stacks
    $0 --output detailed.svg -f 999 -a -- ./zig-out/bin/archerdb benchmark

PREREQUISITES:
    1. Install perf tools:
       sudo apt install linux-perf

    2. Install FlameGraph scripts:
       git clone https://github.com/brendangregg/FlameGraph.git tools/FlameGraph

    3. Set kernel.perf_event_paranoid if needed:
       sudo sysctl kernel.perf_event_paranoid=1

OUTPUT:
    The generated SVG is interactive - hover over frames to see function names
    and click to zoom into specific call stacks.

See docs/profiling.md for interpretation guide and best practices.
EOF
    exit 0
}

# Error message and exit
die() {
    echo -e "${RED}Error: $1${NC}" >&2
    exit 1
}

# Warning message
warn() {
    echo -e "${YELLOW}Warning: $1${NC}" >&2
}

# Info message
info() {
    echo -e "${BLUE}$1${NC}"
}

# Success message
success() {
    echo -e "${GREEN}$1${NC}"
}

# Find FlameGraph scripts
find_flamegraph() {
    # Check FLAMEGRAPH_DIR env var first
    if [[ -n "${FLAMEGRAPH_DIR:-}" ]]; then
        if [[ -x "$FLAMEGRAPH_DIR/stackcollapse-perf.pl" && -x "$FLAMEGRAPH_DIR/flamegraph.pl" ]]; then
            return 0
        fi
        warn "FLAMEGRAPH_DIR set but scripts not found at: $FLAMEGRAPH_DIR"
    fi

    # Check common locations
    local candidates=(
        "$PROJECT_ROOT/tools/FlameGraph"
        "$HOME/FlameGraph"
        "/usr/share/FlameGraph"
        "/opt/FlameGraph"
    )

    for candidate in "${candidates[@]}"; do
        if [[ -x "$candidate/stackcollapse-perf.pl" && -x "$candidate/flamegraph.pl" ]]; then
            FLAMEGRAPH_DIR="$candidate"
            return 0
        fi
    done

    # Not found - provide installation instructions
    die "FlameGraph scripts not found.

Install FlameGraph scripts:
    git clone https://github.com/brendangregg/FlameGraph.git tools/FlameGraph

Or set FLAMEGRAPH_DIR environment variable:
    export FLAMEGRAPH_DIR=/path/to/FlameGraph"
}

# Check prerequisites
check_prerequisites() {
    # Check for perf
    if ! command -v perf &>/dev/null; then
        die "perf not found.

Install perf tools:
    Ubuntu/Debian: sudo apt install linux-perf
    Fedora/RHEL:   sudo dnf install perf
    Arch:          sudo pacman -S perf"
    fi

    # Check perf_event_paranoid
    local paranoid
    paranoid=$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo "unknown")
    if [[ "$paranoid" == "unknown" ]]; then
        warn "Could not read perf_event_paranoid setting"
    elif [[ "$paranoid" -gt 2 ]]; then
        warn "perf_event_paranoid is $paranoid (may need to run as root or lower the setting)"
        echo "  To allow user profiling: sudo sysctl kernel.perf_event_paranoid=1"
    fi

    # Find FlameGraph
    find_flamegraph
    info "Using FlameGraph scripts from: $FLAMEGRAPH_DIR"
}

# Parse arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -d|--duration)
                DURATION="$2"
                shift 2
                ;;
            -f|--frequency)
                FREQUENCY="$2"
                shift 2
                ;;
            -a|--all)
                INCLUDE_KERNEL=true
                shift
                ;;
            -p|--pid)
                PID="$2"
                shift 2
                ;;
            --output)
                OUTPUT="$2"
                shift 2
                ;;
            --no-cleanup)
                CLEANUP_PERF_DATA=false
                shift
                ;;
            --help|-h)
                usage
                ;;
            --)
                shift
                COMMAND=("$@")
                break
                ;;
            *)
                die "Unknown option: $1
Use --help for usage information"
                ;;
        esac
    done

    # Validate required options
    if [[ -z "$OUTPUT" ]]; then
        die "--output is required"
    fi

    # Must have either PID or command
    if [[ -z "$PID" && ${#COMMAND[@]} -eq 0 ]]; then
        die "Must specify either --pid or -- COMMAND"
    fi

    if [[ -n "$PID" && ${#COMMAND[@]} -gt 0 ]]; then
        die "Cannot specify both --pid and a command"
    fi

    # Validate PID if provided
    if [[ -n "$PID" ]]; then
        if ! [[ "$PID" =~ ^[0-9]+$ ]]; then
            die "Invalid PID: $PID"
        fi
        if ! kill -0 "$PID" 2>/dev/null; then
            die "Process $PID not found or not accessible"
        fi
    fi
}

# Generate workload name for title
get_workload_name() {
    if [[ -n "$PID" ]]; then
        local cmdline
        cmdline=$(cat /proc/"$PID"/cmdline 2>/dev/null | tr '\0' ' ' | head -c 50 || echo "PID $PID")
        echo "${cmdline%% *}"
    else
        echo "${COMMAND[0]##*/}"
    fi
}

# Run perf record
run_perf_record() {
    local perf_args=(
        "record"
        "-F" "$FREQUENCY"
        "--call-graph" "dwarf"
        "-g"
    )

    if [[ "$INCLUDE_KERNEL" != true ]]; then
        perf_args+=("--user-callchains")
    fi

    if [[ -n "$PID" ]]; then
        info "Profiling process $PID for ${DURATION}s at ${FREQUENCY}Hz..."
        perf_args+=("-p" "$PID")
        perf_args+=("--" "sleep" "$DURATION")
    else
        info "Profiling command for up to ${DURATION}s at ${FREQUENCY}Hz..."
        info "Command: ${COMMAND[*]}"
        perf_args+=("--" "${COMMAND[@]}")
    fi

    # Run perf record
    if ! perf "${perf_args[@]}"; then
        die "perf record failed"
    fi
}

# Generate flame graph from perf data
generate_flamegraph() {
    local workload
    workload=$(get_workload_name)
    local title="ArcherDB CPU Profile - $workload"

    info "Generating flame graph..."

    # perf script | stackcollapse-perf.pl | flamegraph.pl > output.svg
    if ! perf script | \
         "$FLAMEGRAPH_DIR/stackcollapse-perf.pl" | \
         "$FLAMEGRAPH_DIR/flamegraph.pl" --title "$title" --colors java > "$OUTPUT"; then
        die "Failed to generate flame graph"
    fi

    success "Flame graph generated: $OUTPUT"
}

# Cleanup perf.data
cleanup() {
    if [[ "$CLEANUP_PERF_DATA" == true && -f "perf.data" ]]; then
        rm -f perf.data perf.data.old 2>/dev/null || true
    fi
}

# Main entry point
main() {
    parse_args "$@"
    check_prerequisites

    echo ""
    echo -e "${GREEN}============================================================${NC}"
    echo -e "${GREEN}  ArcherDB Flame Graph Generator${NC}"
    echo -e "${GREEN}============================================================${NC}"
    echo ""
    echo "Output:         $OUTPUT"
    echo "Duration:       ${DURATION}s"
    echo "Frequency:      ${FREQUENCY}Hz"
    echo "Kernel stacks:  $INCLUDE_KERNEL"
    if [[ -n "$PID" ]]; then
        echo "Target PID:     $PID"
    else
        echo "Command:        ${COMMAND[*]}"
    fi
    echo ""

    # Run profiling
    run_perf_record

    # Generate flame graph
    generate_flamegraph

    # Cleanup
    cleanup

    echo ""
    success "Done! View the flame graph with:"
    echo "  xdg-open $OUTPUT"
    echo "  # or open in browser: file://$(realpath "$OUTPUT")"
    echo ""
}

main "$@"
