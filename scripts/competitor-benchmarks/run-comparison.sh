#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2024-2025 ArcherDB Contributors
# Competitor Benchmark Comparison Runner (BENCH-07)
#
# Orchestrates full benchmark suite across ArcherDB and all competitors,
# generating a comprehensive comparison report.
#
# Usage:
#   ./run-comparison.sh                    # Run all benchmarks
#   ./run-comparison.sh --quick            # Quick mode (fewer events)
#   ./run-comparison.sh --skip-setup       # Skip container setup
#   ./run-comparison.sh --archerdb-only    # Only run ArcherDB benchmark
#   ./run-comparison.sh --competitor NAME  # Run specific competitor only
#
# Prerequisites:
#   - Docker and docker compose
#   - Python 3.8+ with pip
#   - Running ArcherDB cluster (for ArcherDB benchmarks)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RESULTS_DIR="${PROJECT_ROOT}/benchmark-results/comparison-$(date +%Y%m%d-%H%M%S)"

# Default parameters
ENTITY_COUNT=10000
EVENT_COUNT=100000
QUERY_COUNT=10000
SKIP_SETUP=false
ARCHERDB_ONLY=false
COMPETITOR=""
QUICK_MODE=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --quick)
            QUICK_MODE=true
            ENTITY_COUNT=1000
            EVENT_COUNT=10000
            QUERY_COUNT=1000
            shift
            ;;
        --skip-setup)
            SKIP_SETUP=true
            shift
            ;;
        --archerdb-only)
            ARCHERDB_ONLY=true
            shift
            ;;
        --competitor)
            COMPETITOR="$2"
            shift 2
            ;;
        --entity-count)
            ENTITY_COUNT="$2"
            shift 2
            ;;
        --event-count)
            EVENT_COUNT="$2"
            shift 2
            ;;
        --help)
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  --quick            Quick mode (10K events, 1K entities)"
            echo "  --skip-setup       Skip container setup"
            echo "  --archerdb-only    Only run ArcherDB benchmark"
            echo "  --competitor NAME  Run specific competitor (postgis, tile38, elasticsearch, aerospike)"
            echo "  --entity-count N   Number of entities (default: 10000)"
            echo "  --event-count N    Number of events (default: 100000)"
            echo "  --help             Show this help"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Create results directory
mkdir -p "$RESULTS_DIR"

echo "=============================================="
echo "ArcherDB Competitor Benchmark Suite"
echo "=============================================="
echo ""
echo "Configuration:"
echo "  Entities: $ENTITY_COUNT"
echo "  Events: $EVENT_COUNT"
echo "  Queries: $QUERY_COUNT"
echo "  Results: $RESULTS_DIR"
echo ""

# Install Python dependencies
echo "Checking Python dependencies..."
pip install --quiet psycopg2-binary redis elasticsearch aerospike 2>/dev/null || true

# Function to run a competitor benchmark
run_competitor_benchmark() {
    local name="$1"
    local script="$2"
    local extra_args="${3:-}"

    echo ""
    echo "--- Running $name benchmark ---"

    if python3 "$SCRIPT_DIR/$script" \
        --entity-count "$ENTITY_COUNT" \
        --event-count "$EVENT_COUNT" \
        --query-count "$QUERY_COUNT" \
        --output "$RESULTS_DIR/${name}.csv" \
        $extra_args; then
        echo "$name benchmark complete"
        return 0
    else
        echo "WARNING: $name benchmark failed"
        return 1
    fi
}

# Start competitor containers
if [[ "$SKIP_SETUP" != "true" && "$ARCHERDB_ONLY" != "true" ]]; then
    echo "Starting competitor containers..."
    cd "$SCRIPT_DIR"

    # Determine which services to start
    if [[ -n "$COMPETITOR" ]]; then
        case "$COMPETITOR" in
            postgis)
                docker compose up -d postgis postgis-default
                ;;
            tile38)
                docker compose up -d tile38
                ;;
            elasticsearch)
                docker compose up -d elasticsearch elasticsearch-default
                ;;
            aerospike)
                docker compose up -d aerospike
                ;;
            *)
                echo "Unknown competitor: $COMPETITOR"
                exit 1
                ;;
        esac
    else
        docker compose up -d
    fi

    echo "Waiting for services to be healthy..."
    sleep 30

    # Run setup scripts
    echo "Running setup scripts..."
    if [[ -z "$COMPETITOR" || "$COMPETITOR" == "postgis" ]]; then
        "$SCRIPT_DIR/setup-postgis.sh" 2>/dev/null || true
        "$SCRIPT_DIR/setup-postgis.sh" --default 2>/dev/null || true
    fi
    if [[ -z "$COMPETITOR" || "$COMPETITOR" == "tile38" ]]; then
        "$SCRIPT_DIR/setup-tile38.sh" 2>/dev/null || true
    fi
    if [[ -z "$COMPETITOR" || "$COMPETITOR" == "elasticsearch" ]]; then
        "$SCRIPT_DIR/setup-elasticsearch.sh" 2>/dev/null || true
        "$SCRIPT_DIR/setup-elasticsearch.sh" --default 2>/dev/null || true
    fi
    if [[ -z "$COMPETITOR" || "$COMPETITOR" == "aerospike" ]]; then
        "$SCRIPT_DIR/setup-aerospike.sh" 2>/dev/null || true
    fi
fi

# Run ArcherDB benchmark
if [[ "$ARCHERDB_ONLY" == "true" || -z "$COMPETITOR" ]]; then
    echo ""
    echo "--- Running ArcherDB benchmark ---"
    if [[ -x "$PROJECT_ROOT/scripts/run-perf-benchmarks.sh" ]]; then
        if "$PROJECT_ROOT/scripts/run-perf-benchmarks.sh" \
            --output "$RESULTS_DIR/archerdb.csv" \
            --entity-count "$ENTITY_COUNT" \
            --event-count "$EVENT_COUNT" 2>/dev/null; then
            echo "ArcherDB benchmark complete"
        else
            echo "WARNING: ArcherDB benchmark failed (cluster may not be running)"
        fi
    else
        echo "WARNING: ArcherDB benchmark script not found"
    fi
fi

# Run competitor benchmarks
if [[ "$ARCHERDB_ONLY" != "true" ]]; then
    # PostGIS
    if [[ -z "$COMPETITOR" || "$COMPETITOR" == "postgis" ]]; then
        run_competitor_benchmark "postgis-tuned" "benchmark-postgis.py" "" || true
        run_competitor_benchmark "postgis-default" "benchmark-postgis.py" "--default" || true
    fi

    # Tile38
    if [[ -z "$COMPETITOR" || "$COMPETITOR" == "tile38" ]]; then
        run_competitor_benchmark "tile38" "benchmark-tile38.py" "" || true
    fi

    # Elasticsearch
    if [[ -z "$COMPETITOR" || "$COMPETITOR" == "elasticsearch" ]]; then
        run_competitor_benchmark "elasticsearch-tuned" "benchmark-elasticsearch.py" "" || true
        run_competitor_benchmark "elasticsearch-default" "benchmark-elasticsearch.py" "--default" || true
    fi

    # Aerospike
    if [[ -z "$COMPETITOR" || "$COMPETITOR" == "aerospike" ]]; then
        run_competitor_benchmark "aerospike" "benchmark-aerospike.py" "" || true
    fi
fi

# Generate comparison report
echo ""
echo "--- Generating comparison report ---"
python3 "$SCRIPT_DIR/generate-comparison.py" \
    --results-dir "$RESULTS_DIR" \
    --output "$RESULTS_DIR/comparison-report.md"

echo ""
echo "=============================================="
echo "Benchmark suite complete!"
echo "=============================================="
echo ""
echo "Results:"
echo "  CSV files: $RESULTS_DIR/*.csv"
echo "  Report: $RESULTS_DIR/comparison-report.md"
echo ""

# Show summary
if [[ -f "$RESULTS_DIR/comparison-report.md" ]]; then
    echo "Summary:"
    head -50 "$RESULTS_DIR/comparison-report.md"
fi
