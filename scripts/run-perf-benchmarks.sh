#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2024-2025 ArcherDB Contributors
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
AUTO_START_LOCAL="${ARCHERDB_BENCHMARK_AUTO_START:-false}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
RESULTS_DIR="${PROJECT_ROOT}/benchmark-results/perf-${TIMESTAMP}"

case "$AUTO_START_LOCAL" in
    1|true|TRUE|yes|YES|on|ON)
        AUTO_START_LOCAL="true"
        ;;
    *)
        AUTO_START_LOCAL="false"
        ;;
esac

AUTO_STARTED_SERVER_PID=""
AUTO_STARTED_WORK_DIR=""

# Benchmark parameters by mode (Bash 3 compatible scalars)
QUICK_EVENTS="10000"
QUICK_ENTITIES="1000"
QUICK_RUNS="3"
QUICK_CONCURRENCY="1,10"
QUICK_UUID_QUERIES="100"
QUICK_RADIUS_QUERIES="10"
QUICK_POLYGON_QUERIES="10"

FULL_EVENTS="1000000"
FULL_ENTITIES="100000"
FULL_RUNS="10"
FULL_CONCURRENCY="1,10,100"
FULL_UUID_QUERIES="10000"
FULL_RADIUS_QUERIES="1000"
FULL_POLYGON_QUERIES="100"

EXTREME_EVENTS="10000000"
EXTREME_ENTITIES="1000000"
EXTREME_RUNS="30"
EXTREME_CONCURRENCY="1,10,50,100"
EXTREME_UUID_QUERIES="100000"
EXTREME_RADIUS_QUERIES="10000"
EXTREME_POLYGON_QUERIES="1000"

MODE_EVENTS=""
MODE_ENTITIES=""
MODE_RUNS=""
MODE_CONCURRENCY=""
MODE_UUID_QUERIES=""
MODE_RADIUS_QUERIES=""
MODE_POLYGON_QUERIES=""

# Client concurrency limit (default matches current config clients_max).
CLIENTS_MAX="${ARCHERDB_CLIENTS_MAX:-64}"
if [[ ! "$CLIENTS_MAX" =~ ^[0-9]+$ ]] || [[ "$CLIENTS_MAX" -lt 1 ]]; then
    CLIENTS_MAX=64
fi

# Cap concurrency lists to supported client limit and de-duplicate.
cap_concurrency_list() {
    local list="$1"
    local max="$2"
    local -a items=() out=()
    IFS=',' read -ra items <<< "$list"
    for item in "${items[@]-}"; do
        if [[ ! "$item" =~ ^[0-9]+$ ]]; then
            continue
        fi
        local value="$item"
        if (( value > max )); then
            value="$max"
        fi
        local exists=0
        for existing in "${out[@]-}"; do
            if [[ "$existing" == "$value" ]]; then
                exists=1
                break
            fi
        done
        if [[ $exists -eq 0 ]]; then
            out+=("$value")
        fi
    done
    (IFS=','; echo "${out[*]-}")
}

QUICK_CONCURRENCY="$(cap_concurrency_list "$QUICK_CONCURRENCY" "$CLIENTS_MAX")"
FULL_CONCURRENCY="$(cap_concurrency_list "$FULL_CONCURRENCY" "$CLIENTS_MAX")"
EXTREME_CONCURRENCY="$(cap_concurrency_list "$EXTREME_CONCURRENCY" "$CLIENTS_MAX")"

set_mode_parameters() {
    case "$MODE" in
        quick)
            MODE_EVENTS="$QUICK_EVENTS"
            MODE_ENTITIES="$QUICK_ENTITIES"
            MODE_RUNS="$QUICK_RUNS"
            MODE_CONCURRENCY="$QUICK_CONCURRENCY"
            MODE_UUID_QUERIES="$QUICK_UUID_QUERIES"
            MODE_RADIUS_QUERIES="$QUICK_RADIUS_QUERIES"
            MODE_POLYGON_QUERIES="$QUICK_POLYGON_QUERIES"
            ;;
        full)
            MODE_EVENTS="$FULL_EVENTS"
            MODE_ENTITIES="$FULL_ENTITIES"
            MODE_RUNS="$FULL_RUNS"
            MODE_CONCURRENCY="$FULL_CONCURRENCY"
            MODE_UUID_QUERIES="$FULL_UUID_QUERIES"
            MODE_RADIUS_QUERIES="$FULL_RADIUS_QUERIES"
            MODE_POLYGON_QUERIES="$FULL_POLYGON_QUERIES"
            ;;
        extreme)
            MODE_EVENTS="$EXTREME_EVENTS"
            MODE_ENTITIES="$EXTREME_ENTITIES"
            MODE_RUNS="$EXTREME_RUNS"
            MODE_CONCURRENCY="$EXTREME_CONCURRENCY"
            MODE_UUID_QUERIES="$EXTREME_UUID_QUERIES"
            MODE_RADIUS_QUERIES="$EXTREME_RADIUS_QUERIES"
            MODE_POLYGON_QUERIES="$EXTREME_POLYGON_QUERIES"
            ;;
        *)
            echo -e "${RED}Error: Unknown mode: $MODE${NC}" >&2
            exit 1
            ;;
    esac
}

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
    --auto-start-local
                    If target is unreachable and address is local, auto-start
                    a temporary single-node ArcherDB for benchmarking
    --output DIR    Output directory (default: benchmark-results/perf-TIMESTAMP)
    --help          Show this help message

ENVIRONMENT:
    ARCHERDB_ADDRESS  Cluster address
    ARCHERDB_BINARY   Path to archerdb binary
    ARCHERDB_BENCHMARK_AUTO_START=1
                      Same as --auto-start-local

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

BEHAVIOR:
    For local addresses (localhost/127.0.0.1/::1), the script will auto-start
    a temporary benchmark node if the target is unreachable.
    For non-local addresses, it remains strict and prints remediation steps.
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
            --auto-start-local)
                AUTO_START_LOCAL="true"
                shift
                ;;
            --no-auto-start-local)
                AUTO_START_LOCAL="false"
                shift
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

address_host() {
    local address="$1"
    echo "${address%:*}"
}

address_port() {
    local address="$1"
    echo "${address##*:}"
}

address_is_valid() {
    local address="$1"
    local host
    local port
    host="$(address_host "$address")"
    port="$(address_port "$address")"

    if [[ -z "$host" || -z "$port" || "$host" == "$port" ]]; then
        return 1
    fi
    if [[ ! "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
        return 1
    fi
    return 0
}

is_local_host() {
    local host="$1"
    case "$host" in
        localhost|127.0.0.1|::1|\[::1\])
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

check_server_reachable() {
    local address="$1"
    local host
    local port
    host="$(address_host "$address")"
    port="$(address_port "$address")"

    if ! address_is_valid "$address"; then
        return 1
    fi

    if command -v python3 >/dev/null 2>&1; then
        python3 - "$host" "$port" <<'PYEOF'
import socket
import sys

host = sys.argv[1]
port = int(sys.argv[2])
sock = socket.socket()
sock.settimeout(1.0)
try:
    sock.connect((host, port))
    sock.close()
    sys.exit(0)
except Exception:
    sys.exit(1)
PYEOF
        return $?
    fi

    (echo > "/dev/tcp/${host}/${port}") >/dev/null 2>&1
}

cleanup_auto_started_server() {
    if [[ -n "$AUTO_STARTED_SERVER_PID" ]]; then
        kill "$AUTO_STARTED_SERVER_PID" 2>/dev/null || true
        wait "$AUTO_STARTED_SERVER_PID" 2>/dev/null || true
    fi
    if [[ -n "$AUTO_STARTED_WORK_DIR" && -d "$AUTO_STARTED_WORK_DIR" ]]; then
        rm -rf "$AUTO_STARTED_WORK_DIR"
    fi
}

write_unreachable_summary() {
    mkdir -p "$RESULTS_DIR"
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
        echo "Status:   FAILED"
        echo "Reason:   Cluster address is not reachable"
        echo ""
        echo "Remediation:"
        echo "  1) Start ArcherDB and ensure it listens on: $ARCHERDB_ADDRESS"
        echo "  2) Re-run this script"
        echo "  3) Or use --auto-start-local for local addresses"
        if [[ -n "$AUTO_STARTED_WORK_DIR" ]]; then
            echo ""
            echo "Auto-start diagnostics:"
            echo "  $AUTO_STARTED_WORK_DIR"
        fi
    } | tee "$RESULTS_DIR/summary.txt"
}

auto_start_local_server() {
    local address="$1"
    local host
    local port
    host="$(address_host "$address")"
    port="$(address_port "$address")"

    if ! address_is_valid "$address"; then
        echo -e "${RED}Error: Invalid --address format '${address}'. Expected host:port.${NC}" >&2
        return 1
    fi
    if ! is_local_host "$host"; then
        echo -e "${RED}Error: --auto-start-local only supports localhost/127.0.0.1/::1 addresses (got: $host).${NC}" >&2
        return 1
    fi

    AUTO_STARTED_WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/archerdb-bench-auto-XXXXXX")"
    local data_file="${AUTO_STARTED_WORK_DIR}/benchmark.archerdb"
    local format_log="${AUTO_STARTED_WORK_DIR}/format.log"
    local server_log="${AUTO_STARTED_WORK_DIR}/server.log"

    echo -e "${BLUE}Info: Target unreachable; auto-starting temporary ArcherDB at ${address}.${NC}"
    echo -e "${BLUE}Info: Auto-start logs: ${AUTO_STARTED_WORK_DIR}${NC}"

    if ! "$ARCHERDB_BINARY" format --cluster=0 --replica=0 --replica-count=1 "$data_file" >"$format_log" 2>&1; then
        echo -e "${RED}Error: Failed to format temporary benchmark data file.${NC}" >&2
        return 1
    fi

    "$ARCHERDB_BINARY" start --addresses="$address" "$data_file" >"$server_log" 2>&1 &
    AUTO_STARTED_SERVER_PID=$!

    local attempts=60
    while (( attempts > 0 )); do
        if ! kill -0 "$AUTO_STARTED_SERVER_PID" 2>/dev/null; then
            echo -e "${RED}Error: Auto-started ArcherDB exited before becoming reachable.${NC}" >&2
            return 1
        fi
        if check_server_reachable "$address"; then
            echo -e "${GREEN}Info: Auto-started ArcherDB is reachable at ${address}.${NC}"
            return 0
        fi
        sleep 0.5
        attempts=$((attempts - 1))
    done

    echo -e "${RED}Error: Auto-started ArcherDB did not become reachable at ${address}.${NC}" >&2
    return 1
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
    local label=$2
    local line value
    line=$(awk -v label="$label" 'index($0, label) { print; exit }' "$file")
    if [[ -z "$line" ]]; then
        echo "N/A"
        return
    fi
    value=$(echo "$line" | sed -E 's/.*= *([0-9]+).*/\1/')
    if [[ "$value" =~ ^[0-9]+$ ]]; then
        echo "$value"
    else
        echo "N/A"
    fi
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
    set_mode_parameters
    local events="$MODE_EVENTS"
    local entities="$MODE_ENTITIES"
    local runs="$MODE_RUNS"
    local concurrency_levels="$MODE_CONCURRENCY"
    local uuid_queries="$MODE_UUID_QUERIES"
    local radius_queries="$MODE_RADIUS_QUERIES"
    local polygon_queries="$MODE_POLYGON_QUERIES"

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

                throughput=$(extract_metric "$output_file" 'throughput =')
                insert_p50=$(extract_metric "$output_file" 'insert batch latency p50')
                insert_p95=$(extract_metric "$output_file" 'insert batch latency p95')
                insert_p99=$(extract_metric "$output_file" 'insert batch latency p99')
                insert_p99_9=$(extract_metric "$output_file" 'insert batch latency p99.9')
                uuid_p50=$(extract_metric "$output_file" 'UUID query latency p50')
                uuid_p99=$(extract_metric "$output_file" 'UUID query latency p99')
                radius_p50=$(extract_metric "$output_file" 'radius query latency p50')
                radius_p99=$(extract_metric "$output_file" 'radius query latency p99')
                polygon_p50=$(extract_metric "$output_file" 'polygon query latency p50')
                polygon_p99=$(extract_metric "$output_file" 'polygon query latency p99')
                memory_rss=$(extract_metric "$output_file" 'current RSS')

                echo "$concurrency,$run,$throughput,$insert_p50,$insert_p95,$insert_p99,$insert_p99_9,$uuid_p50,$uuid_p99,$radius_p50,$radius_p99,$polygon_p50,$polygon_p99,$memory_rss" >> "$csv_file"
            fi
        done

        # Print aggregated results for this concurrency level
        echo ""
        echo "Aggregated results (concurrency=$concurrency):"
        echo "  Insert throughput: $(aggregate_results 'throughput =' "${run_files[@]}") events/sec"
        echo "  Insert latency p99: $(aggregate_results 'insert batch latency p99' "${run_files[@]}") ms"
        echo "  UUID query p99: $(aggregate_results 'UUID query latency p99' "${run_files[@]}") ms"
        echo "  Radius query p99: $(aggregate_results 'radius query latency p99' "${run_files[@]}") ms"
    done
}

# Generate summary report
generate_summary() {
    local summary_file="$RESULTS_DIR/summary.txt"
    set_mode_parameters

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
        echo "  Events:     $MODE_EVENTS"
        echo "  Entities:   $MODE_ENTITIES"
        echo "  Runs:       $MODE_RUNS"
        echo "  Concurrency: $MODE_CONCURRENCY"
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
    trap cleanup_auto_started_server EXIT

    if ! check_server_reachable "$ARCHERDB_ADDRESS"; then
        local host
        host="$(address_host "$ARCHERDB_ADDRESS")"
        local should_auto_start="false"
        if [[ "$AUTO_START_LOCAL" == "true" ]]; then
            should_auto_start="true"
        elif is_local_host "$host"; then
            should_auto_start="true"
            echo -e "${BLUE}Info: Local benchmark target is unreachable; attempting temporary auto-start.${NC}"
        fi

        if [[ "$should_auto_start" == "true" ]]; then
            if ! auto_start_local_server "$ARCHERDB_ADDRESS"; then
                echo -e "${RED}Error: Benchmark target is unreachable and auto-start failed.${NC}" >&2
                echo -e "${YELLOW}Hint: Start ArcherDB manually and ensure it listens on $ARCHERDB_ADDRESS${NC}" >&2
                write_unreachable_summary
                exit 2
            fi
        else
            echo -e "${RED}Error: Benchmark target is unreachable at $ARCHERDB_ADDRESS.${NC}" >&2
            echo -e "${YELLOW}Fix:${NC}" >&2
            echo "  - Start ArcherDB manually on $ARCHERDB_ADDRESS, or" >&2
            echo "  - Re-run with --auto-start-local for a temporary local node" >&2
            write_unreachable_summary
            exit 2
        fi
    fi
    run_benchmarks
    generate_summary

    echo -e "${GREEN}Benchmark complete!${NC}"
    echo "Results saved to: $RESULTS_DIR"
}

main "$@"
