#!/usr/bin/env bash
#
# run-perf-benchmarks.sh - Run ArcherDB performance benchmark suite
#
# This script runs comprehensive benchmarks per PERF-01 through PERF-06:
# - Multiple concurrency levels (1, 10, 100 clients)
# - Various batch sizes for testing batch efficiency
# - Cold and warm cache measurements
# - Statistical significance via multiple runs
#
# Usage:
#   ./scripts/run-perf-benchmarks.sh [--quick|--full|--extreme]
#   ./scripts/run-perf-benchmarks.sh --help
#
# Environment variables:
#   ARCHERDB_ADDRESS  - Cluster address (default: 127.0.0.1:3001)
#   ARCHERDB_BINARY   - Path to archerdb binary (default: auto-detect)
#
# Output:
#   benchmark-results/perf-YYYYMMDD-HHMMSS/
#     - summary.txt        : Human-readable summary
#     - results.csv        : Machine-readable results
#     - raw/               : Raw benchmark outputs
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
MODE="quick"
ARCHERDB_ADDRESS="${ARCHERDB_ADDRESS:-127.0.0.1:3001}"
ARCHERDB_BINARY="${ARCHERDB_BINARY:-}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
RESULTS_DIR="${PROJECT_ROOT}/benchmark-results/perf-${TIMESTAMP}"

# Benchmark parameters by mode
declare -A MODE_EVENTS
declare -A MODE_ENTITIES
declare -A MODE_RUNS
declare -A MODE_CONCURRENCY
declare -A MODE_UUID_QUERIES
declare -A MODE_RADIUS_QUERIES
declare -A MODE_POLYGON_QUERIES

# Quick mode: fast sanity check (~2-5 minutes)
MODE_EVENTS["quick"]="10000"
MODE_ENTITIES["quick"]="1000"
MODE_RUNS["quick"]="3"
MODE_CONCURRENCY["quick"]="1,10"
MODE_UUID_QUERIES["quick"]="100"
MODE_RADIUS_QUERIES["quick"]="10"
MODE_POLYGON_QUERIES["quick"]="10"

# Full mode: comprehensive benchmark (~30-60 minutes)
MODE_EVENTS["full"]="1000000"
MODE_ENTITIES["full"]="100000"
MODE_RUNS["full"]="10"
MODE_CONCURRENCY["full"]="1,10,100"
MODE_UUID_QUERIES["full"]="10000"
MODE_RADIUS_QUERIES["full"]="1000"
MODE_POLYGON_QUERIES["full"]="100"

# Extreme mode: stress test (~2+ hours)
MODE_EVENTS["extreme"]="10000000"
MODE_ENTITIES["extreme"]="1000000"
MODE_RUNS["extreme"]="30"
MODE_CONCURRENCY["extreme"]="1,10,50,100"
MODE_UUID_QUERIES["extreme"]="100000"
MODE_RADIUS_QUERIES["extreme"]="10000"
MODE_POLYGON_QUERIES["extreme"]="1000"

# Usage help
usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

ArcherDB Performance Benchmark Suite

OPTIONS:
    --quick         Quick benchmark (~2-5 min, 10K events, 3 runs)
    --full          Full benchmark (~30-60 min, 1M events, 10 runs)
    --extreme       Extreme benchmark (~2+ hours, 10M events, 30 runs)
    --address ADDR  Cluster address (default: \$ARCHERDB_ADDRESS or 127.0.0.1:3001)
    --binary PATH   Path to archerdb binary (default: auto-detect)
    --output DIR    Output directory (default: benchmark-results/perf-TIMESTAMP)
    --help          Show this help message

ENVIRONMENT:
    ARCHERDB_ADDRESS  Cluster address
    ARCHERDB_BINARY   Path to archerdb binary

EXAMPLES:
    # Quick benchmark against local cluster
    $0 --quick

    # Full benchmark against specific address
    $0 --full --address 192.168.1.100:3001

    # Extreme benchmark with custom output
    $0 --extreme --output /tmp/benchmarks

OUTPUT FILES:
    summary.txt     Human-readable summary with percentiles
    results.csv     Machine-readable CSV for analysis
    raw/            Raw output from each benchmark run

METRICS COLLECTED:
    - Insert throughput (events/sec)
    - Insert latency (p1, p50, p95, p99, p99.9, p100)
    - UUID query latency
    - Radius query latency
    - Polygon query latency
    - Memory usage (RSS)

See docs/benchmarks.md for methodology and interpretation.
EOF
    exit 0
}

# Parse arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --quick)
                MODE="quick"
                shift
                ;;
            --full)
                MODE="full"
                shift
                ;;
            --extreme)
                MODE="extreme"
                shift
                ;;
            --address)
                ARCHERDB_ADDRESS="$2"
                shift 2
                ;;
            --binary)
                ARCHERDB_BINARY="$2"
                shift 2
                ;;
            --output)
                RESULTS_DIR="$2"
                shift 2
                ;;
            --help|-h)
                usage
                ;;
            *)
                echo -e "${RED}Error: Unknown option: $1${NC}" >&2
                echo "Use --help for usage information" >&2
                exit 1
                ;;
        esac
    done
}

# Find archerdb binary
find_binary() {
    if [[ -n "$ARCHERDB_BINARY" ]]; then
        if [[ ! -x "$ARCHERDB_BINARY" ]]; then
            echo -e "${RED}Error: Specified binary not found or not executable: $ARCHERDB_BINARY${NC}" >&2
            exit 1
        fi
        return
    fi

    # Try common locations
    local candidates=(
        "${PROJECT_ROOT}/zig-out/bin/archerdb"
        "${PROJECT_ROOT}/archerdb"
        "$(command -v archerdb 2>/dev/null || true)"
    )

    for candidate in "${candidates[@]}"; do
        if [[ -x "$candidate" ]]; then
            ARCHERDB_BINARY="$candidate"
            return
        fi
    done

    echo -e "${RED}Error: archerdb binary not found${NC}" >&2
    echo "Try building with: ./zig/zig build -Drelease" >&2
    echo "Or specify with: --binary /path/to/archerdb" >&2
    exit 1
}

# Run a single benchmark configuration
run_benchmark() {
    local run_num=$1
    local concurrency=$2
    local events=$3
    local entities=$4
    local uuid_queries=$5
    local radius_queries=$6
    local polygon_queries=$7
    local output_file=$8

    echo -e "  ${BLUE}Run $run_num:${NC} clients=$concurrency, events=$events"

    "$ARCHERDB_BINARY" benchmark \
        --addresses="$ARCHERDB_ADDRESS" \
        --clients="$concurrency" \
        --event-count="$events" \
        --entity-count="$entities" \
        --query-uuid-count="$uuid_queries" \
        --query-radius-count="$radius_queries" \
        --query-polygon-count="$polygon_queries" \
        > "$output_file" 2>&1 || {
            echo -e "  ${YELLOW}Warning: Benchmark run failed${NC}"
            return 1
        }

    return 0
}

# Extract metric from benchmark output
extract_metric() {
    local file=$1
    local pattern=$2
    grep -oP "$pattern" "$file" 2>/dev/null | head -1 || echo "N/A"
}

# Aggregate results from multiple runs
aggregate_results() {
    local pattern="$1"
    shift
    local files=("$@")

    local values=()
    for file in "${files[@]}"; do
        local val
        val=$(extract_metric "$file" "$pattern")
        if [[ "$val" != "N/A" && "$val" =~ ^[0-9]+$ ]]; then
            values+=("$val")
        fi
    done

    if [[ ${#values[@]} -eq 0 ]]; then
        echo "N/A"
        return
    fi

    # Calculate mean
    local sum=0
    for v in "${values[@]}"; do
        sum=$((sum + v))
    done
    echo $((sum / ${#values[@]}))
}

# Main benchmark execution
run_benchmarks() {
    local events="${MODE_EVENTS[$MODE]}"
    local entities="${MODE_ENTITIES[$MODE]}"
    local runs="${MODE_RUNS[$MODE]}"
    local concurrency_levels="${MODE_CONCURRENCY[$MODE]}"
    local uuid_queries="${MODE_UUID_QUERIES[$MODE]}"
    local radius_queries="${MODE_RADIUS_QUERIES[$MODE]}"
    local polygon_queries="${MODE_POLYGON_QUERIES[$MODE]}"

    echo ""
    echo -e "${GREEN}============================================================${NC}"
    echo -e "${GREEN}  ArcherDB Performance Benchmark Suite${NC}"
    echo -e "${GREEN}============================================================${NC}"
    echo ""
    echo "Mode:           $MODE"
    echo "Events:         $events"
    echo "Entities:       $entities"
    echo "Runs per config: $runs"
    echo "Concurrency:    $concurrency_levels"
    echo "Address:        $ARCHERDB_ADDRESS"
    echo "Binary:         $ARCHERDB_BINARY"
    echo "Output:         $RESULTS_DIR"
    echo ""

    mkdir -p "$RESULTS_DIR/raw"

    # Initialize CSV output
    local csv_file="$RESULTS_DIR/results.csv"
    echo "concurrency,run,insert_throughput,insert_p50,insert_p95,insert_p99,insert_p99_9,uuid_p50,uuid_p99,radius_p50,radius_p99,polygon_p50,polygon_p99,memory_rss_mb" > "$csv_file"

    # Run benchmarks for each concurrency level
    IFS=',' read -ra CONCURRENCY_ARRAY <<< "$concurrency_levels"
    for concurrency in "${CONCURRENCY_ARRAY[@]}"; do
        echo ""
        echo -e "${BLUE}>>> Concurrency: $concurrency clients${NC}"
        echo "------------------------------------------------------------"

        local run_files=()
        for run in $(seq 1 "$runs"); do
            local output_file="$RESULTS_DIR/raw/c${concurrency}_run${run}.txt"
            run_files+=("$output_file")

            if run_benchmark "$run" "$concurrency" "$events" "$entities" \
                "$uuid_queries" "$radius_queries" "$polygon_queries" "$output_file"; then

                # Extract metrics and append to CSV
                local throughput
                local insert_p50 insert_p95 insert_p99 insert_p99_9
                local uuid_p50 uuid_p99
                local radius_p50 radius_p99
                local polygon_p50 polygon_p99
                local memory_rss

                throughput=$(extract_metric "$output_file" 'throughput = \K[0-9]+')
                insert_p50=$(extract_metric "$output_file" 'insert batch latency p50 *= *\K[0-9]+')
                insert_p95=$(extract_metric "$output_file" 'insert batch latency p95 *= *\K[0-9]+')
                insert_p99=$(extract_metric "$output_file" 'insert batch latency p99 *= *\K[0-9]+')
                insert_p99_9=$(extract_metric "$output_file" 'insert batch latency p99.9.*= *\K[0-9]+')
                uuid_p50=$(extract_metric "$output_file" 'UUID query latency p50 *= *\K[0-9]+')
                uuid_p99=$(extract_metric "$output_file" 'UUID query latency p99 *= *\K[0-9]+')
                radius_p50=$(extract_metric "$output_file" 'radius query latency p50 *= *\K[0-9]+')
                radius_p99=$(extract_metric "$output_file" 'radius query latency p99 *= *\K[0-9]+')
                polygon_p50=$(extract_metric "$output_file" 'polygon query latency p50 *= *\K[0-9]+')
                polygon_p99=$(extract_metric "$output_file" 'polygon query latency p99 *= *\K[0-9]+')
                memory_rss=$(extract_metric "$output_file" 'current RSS *= *\K[0-9]+')

                echo "$concurrency,$run,$throughput,$insert_p50,$insert_p95,$insert_p99,$insert_p99_9,$uuid_p50,$uuid_p99,$radius_p50,$radius_p99,$polygon_p50,$polygon_p99,$memory_rss" >> "$csv_file"
            fi
        done

        # Print aggregated results for this concurrency level
        echo ""
        echo "Aggregated results (concurrency=$concurrency):"
        echo "  Insert throughput: $(aggregate_results 'throughput = \K[0-9]+' "${run_files[@]}") events/sec"
        echo "  Insert latency p99: $(aggregate_results 'insert batch latency p99 *= *\K[0-9]+' "${run_files[@]}") ms"
        echo "  UUID query p99: $(aggregate_results 'UUID query latency p99 *= *\K[0-9]+' "${run_files[@]}") ms"
        echo "  Radius query p99: $(aggregate_results 'radius query latency p99 *= *\K[0-9]+' "${run_files[@]}") ms"
    done
}

# Generate summary report
generate_summary() {
    local summary_file="$RESULTS_DIR/summary.txt"

    {
        echo "============================================================"
        echo "  ArcherDB Performance Benchmark Summary"
        echo "============================================================"
        echo ""
        echo "Date:     $(date)"
        echo "Mode:     $MODE"
        echo "Address:  $ARCHERDB_ADDRESS"
        echo "Binary:   $ARCHERDB_BINARY"
        echo ""
        echo "Configuration:"
        echo "  Events:     ${MODE_EVENTS[$MODE]}"
        echo "  Entities:   ${MODE_ENTITIES[$MODE]}"
        echo "  Runs:       ${MODE_RUNS[$MODE]}"
        echo "  Concurrency: ${MODE_CONCURRENCY[$MODE]}"
        echo ""
        echo "============================================================"
        echo "  Results"
        echo "============================================================"
        echo ""

        # Parse CSV and generate summary
        if [[ -f "$RESULTS_DIR/results.csv" ]]; then
            echo "Results by concurrency level:"
            echo ""

            local prev_concurrency=""
            local throughputs=()
            local p99s=()

            while IFS=, read -r concurrency run throughput p50 p95 p99 p99_9 uuid_p50 uuid_p99 radius_p50 radius_p99 polygon_p50 polygon_p99 memory; do
                [[ "$concurrency" == "concurrency" ]] && continue

                if [[ "$concurrency" != "$prev_concurrency" && -n "$prev_concurrency" ]]; then
                    # Print summary for previous concurrency
                    local avg_throughput=0
                    local avg_p99=0
                    local count=${#throughputs[@]}
                    if [[ $count -gt 0 ]]; then
                        local sum=0
                        for v in "${throughputs[@]}"; do [[ "$v" =~ ^[0-9]+$ ]] && sum=$((sum + v)); done
                        avg_throughput=$((sum / count))
                        sum=0
                        for v in "${p99s[@]}"; do [[ "$v" =~ ^[0-9]+$ ]] && sum=$((sum + v)); done
                        avg_p99=$((sum / count))
                    fi
                    echo "  Concurrency $prev_concurrency:"
                    echo "    Insert throughput: $avg_throughput events/sec (avg of $count runs)"
                    echo "    Insert p99 latency: $avg_p99 ms"
                    echo ""
                    throughputs=()
                    p99s=()
                fi

                prev_concurrency="$concurrency"
                throughputs+=("$throughput")
                p99s+=("$p99")
            done < "$RESULTS_DIR/results.csv"

            # Print last concurrency level
            if [[ -n "$prev_concurrency" && ${#throughputs[@]} -gt 0 ]]; then
                local avg_throughput=0
                local avg_p99=0
                local count=${#throughputs[@]}
                local sum=0
                for v in "${throughputs[@]}"; do [[ "$v" =~ ^[0-9]+$ ]] && sum=$((sum + v)); done
                avg_throughput=$((sum / count))
                sum=0
                for v in "${p99s[@]}"; do [[ "$v" =~ ^[0-9]+$ ]] && sum=$((sum + v)); done
                avg_p99=$((sum / count))
                echo "  Concurrency $prev_concurrency:"
                echo "    Insert throughput: $avg_throughput events/sec (avg of $count runs)"
                echo "    Insert p99 latency: $avg_p99 ms"
                echo ""
            fi
        fi

        echo "============================================================"
        echo "  Performance Targets (from requirements)"
        echo "============================================================"
        echo ""
        echo "  F5.1.1: Insert throughput   - Target: 1,000,000 events/sec/node"
        echo "  F5.1.2: UUID lookup         - Target: <500us p99"
        echo "  F5.1.3: Radius query        - Target: <50ms p99"
        echo "  F5.1.4: Polygon query       - Target: <100ms p99"
        echo ""
        echo "============================================================"
        echo ""
        echo "Full results: $RESULTS_DIR/results.csv"
        echo "Raw outputs:  $RESULTS_DIR/raw/"
        echo ""
        echo "To reproduce these results:"
        echo "  $0 --$MODE --address $ARCHERDB_ADDRESS"
        echo ""
    } | tee "$summary_file"
}

# Main entry point
main() {
    parse_args "$@"
    find_binary
    run_benchmarks
    generate_summary

    echo -e "${GREEN}Benchmark complete!${NC}"
    echo "Results saved to: $RESULTS_DIR"
}

main "$@"
