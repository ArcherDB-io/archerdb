#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2025 Archer Database Contributors
#
# A/B Benchmark Comparison Script using POOP
# Compares performance between baseline and optimized commands with hardware counters

set -e

# ANSI color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Default values
DURATION=5000
WARMUP=3
JSON_OUTPUT=false
BASELINE_CMD=""
OPTIMIZED_CMD=""

# Significance threshold (percentage)
SIGNIFICANCE_THRESHOLD=5

usage() {
    cat << 'EOF'
Usage: benchmark-ab.sh [OPTIONS] <baseline-cmd> <optimized-cmd>

A/B benchmark comparison using POOP (Performance Optimizer Observation Platform).
Compares two commands with hardware counter analysis.

Options:
  -d, --duration <ms>     Per-command duration in milliseconds (default: 5000)
  -w, --warmup <n>        Warmup iterations before measurement (default: 3)
  --json                  Output results in JSON format for CI
  --baseline <cmd>        Baseline command (alternative to positional arg)
  --optimized <cmd>       Optimized command (alternative to positional arg)
  -h, --help              Show this help message

Examples:
  # Compare baseline vs optimized binary
  ./scripts/benchmark-ab.sh \
    './archerdb-baseline benchmark --quick' \
    './archerdb-optimized benchmark --quick'

  # With explicit flags and longer duration
  ./scripts/benchmark-ab.sh -d 10000 \
    --baseline './old benchmark' \
    --optimized './new benchmark'

  # JSON output for CI integration
  ./scripts/benchmark-ab.sh --json \
    './baseline-build benchmark' \
    './optimized-build benchmark'

Hardware Counters Reported:
  - cycles           CPU cycles consumed
  - instructions     Instructions executed (IPC = instructions/cycles)
  - cache-refs       L1/L2/L3 cache accesses
  - cache-misses     Cache misses (lower is better)
  - branches         Branch instructions
  - branch-misses    Mispredicted branches (lower is better)

Interpretation:
  - Green (>5% faster): Significant improvement
  - Red (>5% slower): Significant regression
  - Yellow: Within noise threshold

EOF
}

find_poop() {
    # Check POOP_PATH environment variable first
    if [[ -n "${POOP_PATH:-}" ]] && [[ -x "$POOP_PATH" ]]; then
        echo "$POOP_PATH"
        return 0
    fi

    # Check PATH
    if command -v poop &>/dev/null; then
        command -v poop
        return 0
    fi

    # Check local tools directory
    local local_poop="tools/poop/zig-out/bin/poop"
    if [[ -x "$local_poop" ]]; then
        echo "$local_poop"
        return 0
    fi

    # Check from script directory
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local project_root="$(dirname "$script_dir")"
    local project_poop="$project_root/tools/poop/zig-out/bin/poop"
    if [[ -x "$project_poop" ]]; then
        echo "$project_poop"
        return 0
    fi

    return 1
}

print_install_instructions() {
    cat << 'EOF'
POOP not found. Install with:

  git clone https://github.com/andrewrk/poop tools/poop
  cd tools/poop && zig build -Doptimize=ReleaseFast

Or set POOP_PATH environment variable:

  export POOP_PATH=/path/to/poop

POOP provides hardware counter access for detailed performance analysis,
including CPU cycles, cache misses, and branch mispredictions.

EOF
}

parse_poop_output() {
    local output="$1"
    local json_mode="$2"

    # Extract timing data from POOP output
    # POOP output format example:
    #   command1         1.234s +-  0.012s
    #   command2         1.456s +-  0.015s  (1.18x slower)

    local baseline_time=""
    local optimized_time=""
    local comparison=""
    local cycles1="" cycles2=""
    local instructions1="" instructions2=""
    local cache_refs1="" cache_refs2=""
    local cache_misses1="" cache_misses2=""
    local branches1="" branches2=""
    local branch_misses1="" branch_misses2=""

    # Parse the output line by line
    local line_num=0
    while IFS= read -r line; do
        line_num=$((line_num + 1))

        # Parse timing lines (wall time)
        if [[ "$line" =~ ^[[:space:]]*[0-9.]+[[:space:]]*(s|ms|us|ns) ]]; then
            local time_val=$(echo "$line" | grep -oP '^[[:space:]]*\K[0-9.]+' | head -1)
            local time_unit=$(echo "$line" | grep -oP '[0-9.]+[[:space:]]*\K(s|ms|us|ns)' | head -1)

            # Convert to nanoseconds
            local time_ns=0
            case "$time_unit" in
                s)  time_ns=$(echo "$time_val * 1000000000" | bc 2>/dev/null || echo "0") ;;
                ms) time_ns=$(echo "$time_val * 1000000" | bc 2>/dev/null || echo "0") ;;
                us) time_ns=$(echo "$time_val * 1000" | bc 2>/dev/null || echo "0") ;;
                ns) time_ns="$time_val" ;;
            esac

            if [[ -z "$baseline_time" ]]; then
                baseline_time="$time_ns"
            else
                optimized_time="$time_ns"
            fi
        fi

        # Parse counter lines (L1 cache, cycles, instructions, etc.)
        if [[ "$line" =~ cycles ]]; then
            local val=$(echo "$line" | grep -oP '[0-9,]+' | head -1 | tr -d ',')
            if [[ -z "$cycles1" ]]; then cycles1="$val"; else cycles2="$val"; fi
        fi
        if [[ "$line" =~ instructions ]]; then
            local val=$(echo "$line" | grep -oP '[0-9,]+' | head -1 | tr -d ',')
            if [[ -z "$instructions1" ]]; then instructions1="$val"; else instructions2="$val"; fi
        fi
        if [[ "$line" =~ cache-ref ]]; then
            local val=$(echo "$line" | grep -oP '[0-9,]+' | head -1 | tr -d ',')
            if [[ -z "$cache_refs1" ]]; then cache_refs1="$val"; else cache_refs2="$val"; fi
        fi
        if [[ "$line" =~ cache-miss ]]; then
            local val=$(echo "$line" | grep -oP '[0-9,]+' | head -1 | tr -d ',')
            if [[ -z "$cache_misses1" ]]; then cache_misses1="$val"; else cache_misses2="$val"; fi
        fi
        if [[ "$line" =~ branch-miss ]]; then
            local val=$(echo "$line" | grep -oP '[0-9,]+' | head -1 | tr -d ',')
            if [[ -z "$branch_misses1" ]]; then branch_misses1="$val"; else branch_misses2="$val"; fi
        elif [[ "$line" =~ branch ]]; then
            local val=$(echo "$line" | grep -oP '[0-9,]+' | head -1 | tr -d ',')
            if [[ -z "$branches1" ]]; then branches1="$val"; else branches2="$val"; fi
        fi

        # Check for comparison result (e.g., "1.18x slower" or "1.05x faster")
        if [[ "$line" =~ ([0-9.]+)x[[:space:]]+(faster|slower) ]]; then
            comparison="$line"
        fi
    done <<< "$output"

    # Calculate delta percentage
    local delta_percent=0
    local verdict="same"
    local significant=false

    if [[ -n "$baseline_time" ]] && [[ -n "$optimized_time" ]] && [[ "$baseline_time" != "0" ]]; then
        # Calculate: ((optimized - baseline) / baseline) * 100
        delta_percent=$(echo "scale=2; (($optimized_time - $baseline_time) / $baseline_time) * 100" | bc 2>/dev/null || echo "0")

        # Determine verdict
        if (( $(echo "$delta_percent < -$SIGNIFICANCE_THRESHOLD" | bc -l) )); then
            verdict="faster"
            significant=true
        elif (( $(echo "$delta_percent > $SIGNIFICANCE_THRESHOLD" | bc -l) )); then
            verdict="slower"
            significant=true
        else
            verdict="same"
            significant=false
        fi
    fi

    # Calculate derived metrics
    local ipc1="" ipc2=""
    local cache_miss_rate1="" cache_miss_rate2=""
    local branch_miss_rate1="" branch_miss_rate2=""

    if [[ -n "$instructions1" ]] && [[ -n "$cycles1" ]] && [[ "$cycles1" != "0" ]]; then
        ipc1=$(echo "scale=3; $instructions1 / $cycles1" | bc 2>/dev/null || echo "")
    fi
    if [[ -n "$instructions2" ]] && [[ -n "$cycles2" ]] && [[ "$cycles2" != "0" ]]; then
        ipc2=$(echo "scale=3; $instructions2 / $cycles2" | bc 2>/dev/null || echo "")
    fi
    if [[ -n "$cache_misses1" ]] && [[ -n "$cache_refs1" ]] && [[ "$cache_refs1" != "0" ]]; then
        cache_miss_rate1=$(echo "scale=4; $cache_misses1 / $cache_refs1 * 100" | bc 2>/dev/null || echo "")
    fi
    if [[ -n "$cache_misses2" ]] && [[ -n "$cache_refs2" ]] && [[ "$cache_refs2" != "0" ]]; then
        cache_miss_rate2=$(echo "scale=4; $cache_misses2 / $cache_refs2 * 100" | bc 2>/dev/null || echo "")
    fi
    if [[ -n "$branch_misses1" ]] && [[ -n "$branches1" ]] && [[ "$branches1" != "0" ]]; then
        branch_miss_rate1=$(echo "scale=4; $branch_misses1 / $branches1 * 100" | bc 2>/dev/null || echo "")
    fi
    if [[ -n "$branch_misses2" ]] && [[ -n "$branches2" ]] && [[ "$branches2" != "0" ]]; then
        branch_miss_rate2=$(echo "scale=4; $branch_misses2 / $branches2 * 100" | bc 2>/dev/null || echo "")
    fi

    if [[ "$json_mode" == "true" ]]; then
        # Output JSON format
        cat << JSONEOF
{
  "baseline": {
    "time_ns": ${baseline_time:-0},
    "counters": {
      "cycles": ${cycles1:-0},
      "instructions": ${instructions1:-0},
      "cache_refs": ${cache_refs1:-0},
      "cache_misses": ${cache_misses1:-0},
      "branches": ${branches1:-0},
      "branch_misses": ${branch_misses1:-0}
    },
    "derived": {
      "ipc": ${ipc1:-0},
      "cache_miss_rate_percent": ${cache_miss_rate1:-0},
      "branch_miss_rate_percent": ${branch_miss_rate1:-0}
    }
  },
  "optimized": {
    "time_ns": ${optimized_time:-0},
    "counters": {
      "cycles": ${cycles2:-0},
      "instructions": ${instructions2:-0},
      "cache_refs": ${cache_refs2:-0},
      "cache_misses": ${cache_misses2:-0},
      "branches": ${branches2:-0},
      "branch_misses": ${branch_misses2:-0}
    },
    "derived": {
      "ipc": ${ipc2:-0},
      "cache_miss_rate_percent": ${cache_miss_rate2:-0},
      "branch_miss_rate_percent": ${branch_miss_rate2:-0}
    }
  },
  "comparison": {
    "time_delta_percent": $delta_percent,
    "verdict": "$verdict",
    "significant": $significant
  }
}
JSONEOF
    else
        # Print enhanced human-readable output
        echo ""
        echo -e "${BOLD}=== A/B Benchmark Results ===${NC}"
        echo ""

        # Print raw POOP output
        echo -e "${BLUE}Raw POOP Output:${NC}"
        echo "$output"
        echo ""

        # Print derived metrics if available
        if [[ -n "$ipc1" ]] || [[ -n "$cache_miss_rate1" ]] || [[ -n "$branch_miss_rate1" ]]; then
            echo -e "${BOLD}Derived Metrics:${NC}"
            printf "%-20s %15s %15s\n" "Metric" "Baseline" "Optimized"
            printf "%-20s %15s %15s\n" "------" "--------" "---------"
            [[ -n "$ipc1" ]] && printf "%-20s %15s %15s\n" "IPC" "${ipc1}" "${ipc2:-N/A}"
            [[ -n "$cache_miss_rate1" ]] && printf "%-20s %14s%% %14s%%\n" "Cache Miss Rate" "${cache_miss_rate1}" "${cache_miss_rate2:-N/A}"
            [[ -n "$branch_miss_rate1" ]] && printf "%-20s %14s%% %14s%%\n" "Branch Miss Rate" "${branch_miss_rate1}" "${branch_miss_rate2:-N/A}"
            echo ""
        fi

        # Print verdict with color
        echo -e "${BOLD}Verdict:${NC}"
        if [[ "$verdict" == "faster" ]]; then
            echo -e "  ${GREEN}IMPROVEMENT: ${delta_percent}% faster (significant)${NC}"
        elif [[ "$verdict" == "slower" ]]; then
            echo -e "  ${RED}REGRESSION: ${delta_percent}% slower (significant)${NC}"
        else
            echo -e "  ${YELLOW}NO SIGNIFICANT CHANGE: ${delta_percent}% (within noise threshold of +/-${SIGNIFICANCE_THRESHOLD}%)${NC}"
        fi
        echo ""
    fi
}

main() {
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                usage
                exit 0
                ;;
            -d|--duration)
                DURATION="$2"
                shift 2
                ;;
            -w|--warmup)
                WARMUP="$2"
                shift 2
                ;;
            --json)
                JSON_OUTPUT=true
                shift
                ;;
            --baseline)
                BASELINE_CMD="$2"
                shift 2
                ;;
            --optimized)
                OPTIMIZED_CMD="$2"
                shift 2
                ;;
            -*)
                echo "Error: Unknown option $1" >&2
                usage
                exit 1
                ;;
            *)
                # Positional arguments
                if [[ -z "$BASELINE_CMD" ]]; then
                    BASELINE_CMD="$1"
                elif [[ -z "$OPTIMIZED_CMD" ]]; then
                    OPTIMIZED_CMD="$1"
                else
                    echo "Error: Too many positional arguments" >&2
                    usage
                    exit 1
                fi
                shift
                ;;
        esac
    done

    # Validate required arguments
    if [[ -z "$BASELINE_CMD" ]] || [[ -z "$OPTIMIZED_CMD" ]]; then
        echo "Error: Both baseline and optimized commands are required" >&2
        echo ""
        usage
        exit 1
    fi

    # Find POOP binary
    POOP_BIN=$(find_poop) || {
        print_install_instructions
        exit 1
    }

    if [[ "$JSON_OUTPUT" != "true" ]]; then
        echo -e "${BOLD}A/B Benchmark Comparison${NC}"
        echo "========================="
        echo ""
        echo "POOP binary: $POOP_BIN"
        echo "Duration: ${DURATION}ms"
        echo "Warmup: ${WARMUP} iterations"
        echo ""
        echo "Baseline command:  $BASELINE_CMD"
        echo "Optimized command: $OPTIMIZED_CMD"
        echo ""
        echo "Running benchmark..."
        echo ""
    fi

    # Build POOP command
    # POOP uses --duration in milliseconds and automatically uses first command as baseline
    local poop_cmd="$POOP_BIN --duration $DURATION --warmup $WARMUP"

    # Run POOP and capture output
    local poop_output
    if poop_output=$($poop_cmd "$BASELINE_CMD" "$OPTIMIZED_CMD" 2>&1); then
        parse_poop_output "$poop_output" "$JSON_OUTPUT"
    else
        if [[ "$JSON_OUTPUT" == "true" ]]; then
            echo '{"error": "POOP execution failed", "details": "'"$(echo "$poop_output" | tr '\n' ' ' | sed 's/"/\\"/g')"'"}'
        else
            echo -e "${RED}Error: POOP execution failed${NC}" >&2
            echo "$poop_output" >&2
        fi
        exit 1
    fi
}

main "$@"
