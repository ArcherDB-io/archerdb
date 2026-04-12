#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2024-2025 ArcherDB Contributors
#
# profile.sh - Hardware counter profiling for ArcherDB workloads
#
# This script wraps Linux perf stat to collect CPU hardware counters and
# derived metrics like IPC, cache miss rate, and branch miss rate.
#
# Usage:
#   ./scripts/profile.sh -- ./zig-out/bin/archerdb benchmark
#   ./scripts/profile.sh --json --repeat 10 -- ./zig-out/bin/archerdb benchmark
#   ./scripts/profile.sh --help
#
# Prerequisites:
#   - Linux kernel with perf support
#   - perf tools installed (apt install linux-perf)
#

set -euo pipefail

# Color codes for output (disabled if not a terminal)
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    NC='\033[0m' # No Color
else
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' NC=''
fi

# Script location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Configuration defaults
COUNTERS="cycles,instructions,cache-misses,cache-references,branch-misses,branches"
REPEAT=5
DETAILED=false
JSON_OUTPUT=false
COMMAND=()

# Temporary file for perf output
PERF_OUTPUT=""

# Usage help
usage() {
    cat <<EOF
Usage: $0 [OPTIONS] -- COMMAND [ARGS...]

Profile hardware counters for ArcherDB workloads using Linux perf stat.

OPTIONS:
    -c, --counters <list>   Hardware counters, comma-separated
                            (default: cycles,instructions,cache-misses,cache-references,branch-misses,branches)
    -r, --repeat <n>        Number of runs for statistics (default: 5)
    -d, --detailed          Show detailed per-core breakdown
    --json                  Output in JSON format for CI
    --help                  Show this help message

COMMON COUNTERS:
    cycles                  CPU cycles
    instructions            Instructions retired
    cache-misses            Last-level cache misses
    cache-references        Last-level cache references
    branch-misses           Branch mispredictions
    branches                Branch instructions
    L1-dcache-loads         L1 data cache loads
    L1-dcache-load-misses   L1 data cache load misses

EXAMPLES:
    # Basic profiling with 5 runs
    $0 -- ./zig-out/bin/archerdb benchmark

    # 10 runs with JSON output for CI
    $0 --json --repeat 10 -- ./zig-out/bin/archerdb benchmark

    # Detailed per-core view
    $0 --detailed -- ./zig-out/bin/archerdb benchmark

    # Custom counters
    $0 -c cycles,instructions,L1-dcache-load-misses -- ./zig-out/bin/archerdb benchmark

DERIVED METRICS:
    IPC                     Instructions per cycle (higher = better, typically 0.5-4)
    Cache miss rate         cache-misses / cache-references (lower = better)
    Branch miss rate        branch-misses / branches (lower = better, typically <2%)

OUTPUT:
    Human-readable summary with statistics across multiple runs.
    JSON output provides structured data for automated analysis.

See docs/profiling.md for interpretation guide and best practices.
EOF
    exit 0
}

# Error message and exit
die() {
    echo -e "${RED}Error: $1${NC}" >&2
    cleanup
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

# Cleanup temporary files
cleanup() {
    if [[ -n "$PERF_OUTPUT" && -f "$PERF_OUTPUT" ]]; then
        rm -f "$PERF_OUTPUT"
    fi
}

trap cleanup EXIT

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
}

# Parse arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -c|--counters)
                COUNTERS="$2"
                shift 2
                ;;
            -r|--repeat)
                REPEAT="$2"
                shift 2
                ;;
            -d|--detailed)
                DETAILED=true
                shift
                ;;
            --json)
                JSON_OUTPUT=true
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

    # Must have command
    if [[ ${#COMMAND[@]} -eq 0 ]]; then
        die "Must specify command after --"
    fi

    # Validate repeat count
    if ! [[ "$REPEAT" =~ ^[1-9][0-9]*$ ]]; then
        die "Invalid repeat count: $REPEAT"
    fi
}

# Run perf stat and collect metrics
run_perf_stat() {
    PERF_OUTPUT=$(mktemp)

    local perf_args=(
        "stat"
        "-e" "$COUNTERS"
        "-r" "$REPEAT"
        "-x" ","  # CSV output
    )

    if [[ "$DETAILED" == true ]]; then
        perf_args+=("-A")  # Per-CPU
    fi

    perf_args+=("--" "${COMMAND[@]}")

    info "Running $REPEAT iterations..."
    info "Command: ${COMMAND[*]}"
    echo ""

    # Run perf stat, capturing stderr (where perf stat outputs)
    if ! perf "${perf_args[@]}" 2>"$PERF_OUTPUT"; then
        die "perf stat failed"
    fi
}

# Parse perf stat CSV output
declare -A COUNTER_VALUES
declare -A COUNTER_STDDEV

parse_perf_output() {
    while IFS=, read -r value unit counter variance _ _ stddev_percent _; do
        # Skip empty lines and non-counter lines
        [[ -z "$value" || -z "$counter" ]] && continue

        # Clean up counter name (remove leading/trailing whitespace)
        counter=$(echo "$counter" | tr -d '[:space:]')

        # Handle <not counted> or <not supported>
        if [[ "$value" == "<not"* ]]; then
            COUNTER_VALUES["$counter"]="N/A"
            COUNTER_STDDEV["$counter"]="N/A"
            continue
        fi

        # Store value (removing commas from numbers)
        value=$(echo "$value" | tr -d ',')
        COUNTER_VALUES["$counter"]=$value

        # Store stddev percentage if available
        if [[ -n "$stddev_percent" && "$stddev_percent" != "" ]]; then
            stddev_percent=$(echo "$stddev_percent" | tr -d '%')
            COUNTER_STDDEV["$counter"]=$stddev_percent
        else
            COUNTER_STDDEV["$counter"]="0"
        fi
    done < "$PERF_OUTPUT"
}

# Calculate derived metrics
calculate_derived() {
    local cycles=${COUNTER_VALUES["cycles"]:-0}
    local instructions=${COUNTER_VALUES["instructions"]:-0}
    local cache_misses=${COUNTER_VALUES["cache-misses"]:-0}
    local cache_refs=${COUNTER_VALUES["cache-references"]:-0}
    local branch_misses=${COUNTER_VALUES["branch-misses"]:-0}
    local branches=${COUNTER_VALUES["branches"]:-0}

    # IPC
    if [[ "$cycles" != "N/A" && "$instructions" != "N/A" && "$cycles" -gt 0 ]]; then
        IPC=$(awk "BEGIN {printf \"%.3f\", $instructions / $cycles}")
    else
        IPC="N/A"
    fi

    # Cache miss rate
    if [[ "$cache_misses" != "N/A" && "$cache_refs" != "N/A" && "$cache_refs" -gt 0 ]]; then
        CACHE_MISS_RATE=$(awk "BEGIN {printf \"%.2f\", ($cache_misses / $cache_refs) * 100}")
    else
        CACHE_MISS_RATE="N/A"
    fi

    # Branch miss rate
    if [[ "$branch_misses" != "N/A" && "$branches" != "N/A" && "$branches" -gt 0 ]]; then
        BRANCH_MISS_RATE=$(awk "BEGIN {printf \"%.2f\", ($branch_misses / $branches) * 100}")
    else
        BRANCH_MISS_RATE="N/A"
    fi
}

# Format large numbers with commas
format_number() {
    local num=$1
    if [[ "$num" == "N/A" ]]; then
        echo "N/A"
    else
        printf "%'d" "$num" 2>/dev/null || echo "$num"
    fi
}

# Print human-readable output
print_human_output() {
    echo ""
    echo -e "${GREEN}============================================================${NC}"
    echo -e "${GREEN}  ArcherDB Hardware Counter Profile${NC}"
    echo -e "${GREEN}============================================================${NC}"
    echo ""
    echo "Command:      ${COMMAND[*]}"
    echo "Iterations:   $REPEAT"
    echo "Counters:     $COUNTERS"
    echo ""
    echo -e "${CYAN}--- Hardware Counters ---${NC}"
    echo ""

    # Print each counter
    for counter in cycles instructions cache-references cache-misses branches branch-misses; do
        local value=${COUNTER_VALUES["$counter"]:-"N/A"}
        local stddev=${COUNTER_STDDEV["$counter"]:-"N/A"}

        if [[ "$value" != "N/A" ]]; then
            local formatted
            formatted=$(format_number "$value")
            printf "  %-20s %20s" "$counter:" "$formatted"
            if [[ "$stddev" != "N/A" && "$stddev" != "0" ]]; then
                printf "  (+/- %5.2f%%)" "$stddev"
            fi
            echo ""
        fi
    done

    echo ""
    echo -e "${CYAN}--- Derived Metrics ---${NC}"
    echo ""
    printf "  %-20s %20s\n" "IPC:" "$IPC"
    if [[ "$CACHE_MISS_RATE" != "N/A" ]]; then
        printf "  %-20s %19s%%\n" "Cache miss rate:" "$CACHE_MISS_RATE"
    fi
    if [[ "$BRANCH_MISS_RATE" != "N/A" ]]; then
        printf "  %-20s %19s%%\n" "Branch miss rate:" "$BRANCH_MISS_RATE"
    fi

    echo ""
    echo -e "${CYAN}--- Interpretation Guide ---${NC}"
    echo ""
    echo "  IPC (Instructions Per Cycle):"
    echo "    < 1.0  : CPU-bound, many stalls (cache misses, branch mispredicts)"
    echo "    1-2    : Typical for complex workloads"
    echo "    2-4    : Very efficient, well-optimized code"
    echo "    > 4    : Possible with SIMD/vectorization"
    echo ""
    echo "  Cache miss rate:"
    echo "    < 5%   : Excellent cache behavior"
    echo "    5-10%  : Good"
    echo "    > 20%  : Potential memory bottleneck"
    echo ""
    echo "  Branch miss rate:"
    echo "    < 2%   : Excellent branch prediction"
    echo "    2-5%   : Typical"
    echo "    > 5%   : May benefit from branchless code"
    echo ""
}

# Print JSON output
print_json_output() {
    local cycles=${COUNTER_VALUES["cycles"]:-0}
    local instructions=${COUNTER_VALUES["instructions"]:-0}
    local cache_misses=${COUNTER_VALUES["cache-misses"]:-0}
    local cache_refs=${COUNTER_VALUES["cache-references"]:-0}
    local branch_misses=${COUNTER_VALUES["branch-misses"]:-0}
    local branches=${COUNTER_VALUES["branches"]:-0}

    local cycles_stddev=${COUNTER_STDDEV["cycles"]:-0}
    local instructions_stddev=${COUNTER_STDDEV["instructions"]:-0}
    local cache_misses_stddev=${COUNTER_STDDEV["cache-misses"]:-0}
    local cache_refs_stddev=${COUNTER_STDDEV["cache-references"]:-0}
    local branch_misses_stddev=${COUNTER_STDDEV["branch-misses"]:-0}
    local branches_stddev=${COUNTER_STDDEV["branches"]:-0}

    cat <<EOF
{
  "command": "${COMMAND[*]}",
  "iterations": $REPEAT,
  "counters": {
    "cycles": { "mean": $cycles, "stddev_percent": $cycles_stddev },
    "instructions": { "mean": $instructions, "stddev_percent": $instructions_stddev },
    "cache-references": { "mean": $cache_refs, "stddev_percent": $cache_refs_stddev },
    "cache-misses": { "mean": $cache_misses, "stddev_percent": $cache_misses_stddev },
    "branches": { "mean": $branches, "stddev_percent": $branches_stddev },
    "branch-misses": { "mean": $branch_misses, "stddev_percent": $branch_misses_stddev }
  },
  "derived": {
    "ipc": ${IPC:-null},
    "cache_miss_rate": ${CACHE_MISS_RATE:-null},
    "branch_miss_rate": ${BRANCH_MISS_RATE:-null}
  }
}
EOF
}

# Main entry point
main() {
    parse_args "$@"
    check_prerequisites

    if [[ "$JSON_OUTPUT" != true ]]; then
        echo ""
        echo -e "${GREEN}============================================================${NC}"
        echo -e "${GREEN}  ArcherDB Hardware Counter Profiler${NC}"
        echo -e "${GREEN}============================================================${NC}"
        echo ""
    fi

    # Run perf stat
    run_perf_stat

    # Parse output
    parse_perf_output

    # Calculate derived metrics
    calculate_derived

    # Output results
    if [[ "$JSON_OUTPUT" == true ]]; then
        print_json_output
    else
        print_human_output
        success "Profiling complete!"
    fi
}

main "$@"
