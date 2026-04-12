#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2024-2025 ArcherDB Contributors
#
# Legacy local benchmark wrapper for ArcherDB.
#
# This script used to emit simulated throughput and latency values. It now
# fails closed for unsupported legacy modes and forwards the supported quick
# smoke cases to the real `archerdb benchmark` command.
#
# Supported here:
#   - single-node local smoke runs for `write_only`, `read_only`, and `mixed`
#
# Use the maintained benchmark harness instead when you need:
#   - time-bounded runs
#   - multi-node topologies
#   - JSON artifacts
#   - release-evidence outputs

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ZIG_BIN="$PROJECT_ROOT/zig/zig"
ARCHERDB_BIN="$PROJECT_ROOT/zig-out/bin/archerdb"

WRITES=100000
READS=10000
DURATION=60
WARMUP=10
CONFIG="current"
SCENARIO="mixed"
OUTPUT_FORMAT="text"
BATCH_SIZE=1000
VALUE_SIZE=128

usage() {
    cat <<EOF
Legacy ArcherDB benchmark wrapper

Supported quick smoke scenarios:
  write_only
  read_only
  mixed

Usage:
  $0 [options]

Options:
  --writes N           Number of write operations to offer to the real benchmark
                       driver (default: $WRITES)
  --reads N            Number of UUID lookups for read/mixed smoke runs
                       (default: $READS)
  --scenario NAME      write_only | read_only | mixed (default: $SCENARIO)
  --batch-size N       Insert batch size (default: $BATCH_SIZE)
  --help               Show this help message

Unsupported legacy flags in this wrapper:
  --duration
  --warmup
  --config
  --output=json
  --value-size
  --scenario=range_scan
  --scenario=compaction_stress

For maintained benchmark workflows use:
  zig-out/bin/archerdb benchmark --event-count=100000 --query-uuid-count=10000
  python3 test_infrastructure/benchmarks/cli.py run --topology 3 --time-limit 60
EOF
}

log_note() {
    echo "[benchmark_lsm] $*" >&2
}

fatal() {
    echo "error: $*" >&2
    exit 1
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --writes=*) WRITES="${1#*=}"; shift ;;
            --writes) WRITES="$2"; shift 2 ;;
            --reads=*) READS="${1#*=}"; shift ;;
            --reads) READS="$2"; shift 2 ;;
            --duration=*) DURATION="${1#*=}"; shift ;;
            --duration) DURATION="$2"; shift 2 ;;
            --warmup=*) WARMUP="${1#*=}"; shift ;;
            --warmup) WARMUP="$2"; shift 2 ;;
            --config=*) CONFIG="${1#*=}"; shift ;;
            --config) CONFIG="$2"; shift 2 ;;
            --scenario=*) SCENARIO="${1#*=}"; shift ;;
            --scenario) SCENARIO="$2"; shift 2 ;;
            --output=*) OUTPUT_FORMAT="${1#*=}"; shift ;;
            --output) OUTPUT_FORMAT="$2"; shift 2 ;;
            --batch-size=*) BATCH_SIZE="${1#*=}"; shift ;;
            --batch-size) BATCH_SIZE="$2"; shift 2 ;;
            --value-size=*) VALUE_SIZE="${1#*=}"; shift ;;
            --value-size) VALUE_SIZE="$2"; shift 2 ;;
            --verbose) shift ;;
            --help|-h) usage; exit 0 ;;
            *) fatal "unknown option: $1" ;;
        esac
    done
}

validate_args() {
    [[ "$WRITES" =~ ^[0-9]+$ ]] || fatal "--writes must be a non-negative integer"
    [[ "$READS" =~ ^[0-9]+$ ]] || fatal "--reads must be a non-negative integer"
    [[ "$BATCH_SIZE" =~ ^[0-9]+$ ]] || fatal "--batch-size must be a positive integer"
    [[ "$BATCH_SIZE" -gt 0 ]] || fatal "--batch-size must be greater than 0"

    case "$SCENARIO" in
        write_only|read_only|mixed) ;;
        range_scan|compaction_stress)
            fatal "--scenario=$SCENARIO is no longer implemented here; use python3 test_infrastructure/benchmarks/cli.py run"
            ;;
        *) fatal "--scenario must be one of: write_only, read_only, mixed" ;;
    esac

    [[ "$CONFIG" == "current" ]] || fatal "--config is no longer interpreted here; use python3 test_infrastructure/benchmarks/cli.py run"
    [[ "$OUTPUT_FORMAT" == "text" ]] || fatal "--output=$OUTPUT_FORMAT is unsupported in this wrapper; use python3 test_infrastructure/benchmarks/cli.py run"
    [[ "$DURATION" == "60" && "$WARMUP" == "10" ]] || fatal "--duration/--warmup are no longer interpreted here; use python3 test_infrastructure/benchmarks/cli.py run"
    [[ "$VALUE_SIZE" == "128" ]] || fatal "--value-size is no longer interpreted here; use zig-out/bin/archerdb benchmark directly if you need custom synthetic payloads"
}

ensure_archerdb() {
    if [[ -x "$ARCHERDB_BIN" ]]; then
        return
    fi

    [[ -x "$ZIG_BIN" ]] || fatal "zig binary not found at $ZIG_BIN"
    log_note "building ArcherDB binary..."
    "$ZIG_BIN" build -j2 >/dev/null
    [[ -x "$ARCHERDB_BIN" ]] || fatal "archerdb binary not found at $ARCHERDB_BIN after build"
}

run_local_smoke() {
    local event_count="$WRITES"
    local query_uuid_count=0

    case "$SCENARIO" in
        write_only)
            [[ "$event_count" -gt 0 ]] || fatal "--writes must be greater than 0 for write_only"
            ;;
        read_only)
            [[ "$READS" -gt 0 ]] || fatal "--reads must be greater than 0 for read_only"
            query_uuid_count="$READS"
            if [[ "$event_count" -lt "$query_uuid_count" ]]; then
                event_count="$query_uuid_count"
            fi
            ;;
        mixed)
            [[ "$event_count" -gt 0 ]] || fatal "--writes must be greater than 0 for mixed"
            query_uuid_count="$READS"
            ;;
    esac

    if [[ "$event_count" -lt "$BATCH_SIZE" ]]; then
        event_count="$BATCH_SIZE"
    fi

    local entity_count="$event_count"
    if [[ "$entity_count" -gt 100000 ]]; then
        entity_count=100000
    fi
    if [[ "$entity_count" -lt 1 ]]; then
        entity_count=1
    fi

    log_note "forwarding to the real single-node benchmark driver"
    log_note "for time-limited, multi-node, or JSON evidence runs use: python3 test_infrastructure/benchmarks/cli.py run --topology 3 --time-limit 60"

    exec "$ARCHERDB_BIN" benchmark         --event-count="$event_count"         --entity-count="$entity_count"         --event-batch-size="$BATCH_SIZE"         --query-uuid-count="$query_uuid_count"         --query-radius-count=0         --query-polygon-count=0
}

main() {
    parse_args "$@"
    validate_args
    ensure_archerdb
    run_local_smoke
}

main "$@"
