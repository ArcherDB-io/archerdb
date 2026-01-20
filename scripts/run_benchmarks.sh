#!/bin/bash
#
# ArcherDB Multi-Language Benchmark Suite
#
# This script runs benchmarks for all supported client SDKs and produces
# a comparative report.
#
# Prerequisites:
#   - ArcherDB cluster running (at least 1 node)
#   - Python 3.7+
#   - Node.js 18+
#   - Go 1.21+
#   - Maven 3.6+ (for Java)
#
# Usage:
#   ./scripts/run_benchmarks.sh [--events N] [--batch-size B] [--cluster ADDR]
#

set -e

# Default configuration
EVENTS=${EVENTS:-100000}
BATCH_SIZE=${BATCH_SIZE:-1000}
CLUSTER_ADDR=${CLUSTER_ADDR:-"127.0.0.1:3001"}
CLUSTER_ID=${CLUSTER_ID:-0}
OUTPUT_DIR="benchmark-results"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
SUMMARY_FILE=""
BASELINE_FILE=""

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --events)
            EVENTS="$2"
            shift 2
            ;;
        --batch-size)
            BATCH_SIZE="$2"
            shift 2
            ;;
        --cluster)
            CLUSTER_ADDR="$2"
            shift 2
            ;;
        --cluster-id)
            CLUSTER_ID="$2"
            shift 2
            ;;
        --help)
            echo "Usage: $0 [--events N] [--batch-size B] [--cluster ADDR] [--cluster-id ID]"
            echo ""
            echo "Options:"
            echo "  --events N       Number of events to insert (default: 100000)"
            echo "  --batch-size B   Events per batch (default: 1000)"
            echo "  --cluster ADDR   Cluster address (default: 127.0.0.1:3001)"
            echo "  --cluster-id ID  Cluster ID (default: 0)"
            echo "  --baseline PATH  Baseline CSV to compare against (optional)"
            exit 0
            ;;
        --baseline)
            BASELINE_FILE="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
CLIENTS_DIR="$PROJECT_ROOT/src/clients"

# Create output directory
mkdir -p "$OUTPUT_DIR"
SUMMARY_FILE="$OUTPUT_DIR/summary_${TIMESTAMP}.csv"

echo "============================================================"
echo "  ArcherDB Multi-Language Benchmark Suite"
echo "============================================================"
echo ""
echo "Configuration:"
echo "  Events:     $EVENTS"
echo "  Batch Size: $BATCH_SIZE"
echo "  Cluster:    $CLUSTER_ADDR"
echo "  Cluster ID: $CLUSTER_ID"
echo "  Output:     $OUTPUT_DIR"
echo ""
echo "============================================================"

# Results summary
declare -A RESULTS

# Function to run Python benchmark
run_python_benchmark() {
    echo ""
    echo ">>> Running Python Benchmark..."
    echo "------------------------------------------------------------"

    cd "$CLIENTS_DIR/python"

    if ! command -v python3 &> /dev/null; then
        echo "Python 3 not found, skipping Python benchmark"
        RESULTS["python"]="SKIPPED"
        return
    fi

    local output_file="$PROJECT_ROOT/$OUTPUT_DIR/python_${TIMESTAMP}.txt"

    if python3 benchmark.py \
        --events "$EVENTS" \
        --batch-size "$BATCH_SIZE" \
        --addresses "$CLUSTER_ADDR" \
        --cluster-id "$CLUSTER_ID" 2>&1 | tee "$output_file"; then

        # Extract throughput from output
        local throughput=$(grep -oP '\d+(?=,?\d* events/second)' "$output_file" | tail -1)
        RESULTS["python"]="${throughput:-FAILED}"
        echo "Python throughput: ${throughput:-FAILED} events/sec"
    else
        RESULTS["python"]="FAILED"
    fi
}

# Function to run Node.js benchmark
run_node_benchmark() {
    echo ""
    echo ">>> Running Node.js Benchmark..."
    echo "------------------------------------------------------------"

    cd "$CLIENTS_DIR/node"

    if ! command -v node &> /dev/null; then
        echo "Node.js not found, skipping Node benchmark"
        RESULTS["node"]="SKIPPED"
        return
    fi

    local output_file="$PROJECT_ROOT/$OUTPUT_DIR/node_${TIMESTAMP}.txt"

    # Try to run benchmark (requires native bindings)
    if [ -f "dist/benchmark.js" ]; then
        if node dist/benchmark.js \
            --events "$EVENTS" \
            --batch-size "$BATCH_SIZE" \
            --addresses "$CLUSTER_ADDR" \
            --cluster-id "$CLUSTER_ID" 2>&1 | tee "$output_file"; then

            local throughput=$(grep -oP '\d+(?=,?\d* events/second)' "$output_file" | tail -1)
            RESULTS["node"]="${throughput:-FAILED}"
        else
            RESULTS["node"]="FAILED"
        fi
    else
        echo "Node benchmark not built (native bindings required)"
        RESULTS["node"]="NOT_BUILT"
    fi
}

# Function to run Go benchmark
run_go_benchmark() {
    echo ""
    echo ">>> Running Go Benchmark..."
    echo "------------------------------------------------------------"

    cd "$CLIENTS_DIR/go"

    if ! command -v go &> /dev/null; then
        echo "Go not found, skipping Go benchmark"
        RESULTS["go"]="SKIPPED"
        return
    fi

    local output_file="$PROJECT_ROOT/$OUTPUT_DIR/go_${TIMESTAMP}.txt"

    if go test -run=^$ -bench=BenchmarkInsert -benchtime=10s -count=1 2>&1 | tee "$output_file"; then
        # Extract ops/sec from Go benchmark output
        local ops=$(grep -oP '\d+(?= ns/op)' "$output_file" | head -1)
        if [ -n "$ops" ] && [ "$ops" -gt 0 ]; then
            local throughput=$((1000000000 / ops))
            RESULTS["go"]="$throughput"
        else
            RESULTS["go"]="COMPLETED"
        fi
    else
        RESULTS["go"]="FAILED"
    fi
}

# Function to run Java benchmark
run_java_benchmark() {
    echo ""
    echo ">>> Running Java Benchmark..."
    echo "------------------------------------------------------------"

    cd "$CLIENTS_DIR/java"

    if ! command -v mvn &> /dev/null; then
        echo "Maven not found, skipping Java benchmark"
        RESULTS["java"]="SKIPPED"
        return
    fi

    local output_file="$PROJECT_ROOT/$OUTPUT_DIR/java_${TIMESTAMP}.txt"

    # Java benchmark would need native JNI bindings
    echo "Java benchmark requires native bindings (build via CI)"
    RESULTS["java"]="NOT_BUILT"
}

# Run standalone Python benchmark script (uses low-level bindings)
run_python_standalone() {
    echo ""
    echo ">>> Running Python Standalone Benchmark..."
    echo "------------------------------------------------------------"

    cd "$PROJECT_ROOT"

    local output_file="$OUTPUT_DIR/python_standalone_${TIMESTAMP}.txt"

    if python3 benchmark_geo.py \
        --events "$EVENTS" \
        --batch-size "$BATCH_SIZE" \
        --addresses "$CLUSTER_ADDR" \
        --cluster-id "$CLUSTER_ID" 2>&1 | tee "$output_file"; then

        local throughput=$(grep -oP '\d+(?=,?\d* events/second)' "$output_file" | tail -1)
        RESULTS["python_standalone"]="${throughput:-COMPLETED}"
        echo "Python standalone throughput: ${throughput:-N/A} events/sec"
    else
        RESULTS["python_standalone"]="FAILED"
    fi
}

# Print summary
print_summary() {
    echo ""
    echo "============================================================"
    echo "  Benchmark Summary"
    echo "============================================================"
    echo ""
    printf "%-20s %s\n" "Language" "Throughput (events/sec)"
    printf "%-20s %s\n" "--------" "-----------------------"

    for lang in "${!RESULTS[@]}"; do
        printf "%-20s %s\n" "$lang" "${RESULTS[$lang]}"
    done

    echo ""
    echo "Results saved to: $OUTPUT_DIR/"
    echo "Summary CSV: $SUMMARY_FILE"
    echo "============================================================"
}

write_summary_file() {
    {
        echo "language,throughput"
        for lang in "${!RESULTS[@]}"; do
            echo "${lang},${RESULTS[$lang]}"
        done
    } > "$SUMMARY_FILE"
}

compare_baseline() {
    local baseline_path="$BASELINE_FILE"
    if [[ -z "$baseline_path" && -f "$OUTPUT_DIR/baseline.csv" ]]; then
        baseline_path="$OUTPUT_DIR/baseline.csv"
    fi

    if [[ -z "$baseline_path" || ! -f "$baseline_path" ]]; then
        echo "No baseline file found. To compare, save a summary as $OUTPUT_DIR/baseline.csv."
        return
    fi

    declare -A BASELINE
    while IFS=, read -r lang value; do
        if [[ "$lang" == "language" ]]; then
            continue
        fi
        BASELINE["$lang"]="$value"
    done < "$baseline_path"

    echo ""
    echo "Baseline comparison: $baseline_path"
    for lang in "${!RESULTS[@]}"; do
        local current="${RESULTS[$lang]}"
        local base="${BASELINE[$lang]}"
        if [[ "$current" =~ ^[0-9]+$ && "$base" =~ ^[0-9]+$ && "$base" -gt 0 ]]; then
            local delta
            delta=$(awk -v cur="$current" -v base="$base" \
                'BEGIN { printf "%.1f", (cur - base) / base * 100 }')
            echo "  $lang: $current (baseline $base, delta ${delta}%)"
        else
            echo "  $lang: $current (baseline ${base:-N/A})"
        fi
    done
}

# Main execution
main() {
    # Check if cluster is reachable
    echo "Checking cluster connectivity..."
    if ! nc -z "${CLUSTER_ADDR%:*}" "${CLUSTER_ADDR#*:}" 2>/dev/null; then
        echo ""
        echo "WARNING: Cannot connect to cluster at $CLUSTER_ADDR"
        echo "Make sure ArcherDB is running:"
        echo "  ./scripts/dev-cluster.sh start"
        echo ""
        read -p "Continue anyway? [y/N] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi

    # Run benchmarks
    run_python_standalone
    run_go_benchmark
    # run_python_benchmark  # Requires high-level SDK (optional)
    # run_node_benchmark    # Requires native bindings
    # run_java_benchmark    # Requires native bindings

    # Print summary
    write_summary_file
    print_summary
    compare_baseline
}

main "$@"
