#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2024-2025 ArcherDB Contributors
#
# VOPR (Verification-Oriented Property Replication) runner script.
# Runs the VOPR fuzzer for a specified duration with the given state machine.
# Supports multiple seeds for increased coverage (TEST-03 requirement).
#
# Usage: ./run-vopr.sh <state_machine> <duration_secs> [num_seeds]
#   state_machine: geo | testing
#   duration_secs: Total duration in seconds (default: 7200 = 2 hours)
#   num_seeds:     Number of seeds to run (default: 1 for backward compatibility)
#
# Multi-seed mode:
#   Seeds are deterministic: 42, 43, 44, ..., 42+(num_seeds-1)
#   Duration is split evenly across seeds: duration / num_seeds per seed
#   Fails if ANY seed fails (aggregated results)
#
# Exit codes:
#   0 - Success (including timeout, which is expected)
#   1 - VOPR found a bug or crashed
#   2 - Build failure
#   3 - Invalid arguments

set -euo pipefail

STATE_MACHINE="${1:-geo}"
DURATION_SECS="${2:-7200}"  # 2 hours default
NUM_SEEDS="${3:-1}"         # Default 1 seed for backward compatibility

# Validate state machine argument
if [[ "$STATE_MACHINE" != "geo" && "$STATE_MACHINE" != "testing" ]]; then
    echo "Error: Invalid state machine '$STATE_MACHINE'. Must be 'geo' or 'testing'."
    exit 3
fi

# Validate duration is a positive integer
if ! [[ "$DURATION_SECS" =~ ^[0-9]+$ ]] || [[ "$DURATION_SECS" -eq 0 ]]; then
    echo "Error: Duration must be a positive integer (got '$DURATION_SECS')."
    exit 3
fi

# Validate num_seeds is a positive integer
if ! [[ "$NUM_SEEDS" =~ ^[0-9]+$ ]] || [[ "$NUM_SEEDS" -eq 0 ]]; then
    echo "Error: Number of seeds must be a positive integer (got '$NUM_SEEDS')."
    exit 3
fi

# Calculate duration per seed
DURATION_PER_SEED=$((DURATION_SECS / NUM_SEEDS))
if [[ "$DURATION_PER_SEED" -eq 0 ]]; then
    echo "Error: Duration too short for $NUM_SEEDS seeds (need at least $NUM_SEEDS seconds)."
    exit 3
fi

# Base seed for deterministic reproducibility
BASE_SEED=42

echo "=========================================="
echo "VOPR Fuzzer Run"
echo "=========================================="
echo "State Machine: $STATE_MACHINE"
echo "Total Duration: $DURATION_SECS seconds ($((DURATION_SECS / 60)) minutes)"
echo "Number of Seeds: $NUM_SEEDS"
echo "Duration per Seed: $DURATION_PER_SEED seconds ($((DURATION_PER_SEED / 60)) minutes)"
echo "Seed Range: $BASE_SEED to $((BASE_SEED + NUM_SEEDS - 1))"
echo "Commit: ${GITHUB_SHA:-$(git rev-parse HEAD)}"
echo "Start Time: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "=========================================="

# Build VOPR with release optimizations
echo "Building VOPR..."
if ! ./zig/zig build vopr \
    -Dvopr-state-machine="$STATE_MACHINE" \
    -Drelease; then
    echo "Error: VOPR build failed"
    exit 2
fi

echo "VOPR build complete. Starting fuzzer..."

# Track overall result
FAILED_SEEDS=()
PASSED_SEEDS=()

# Function to run a single seed
run_single_seed() {
    local SEED="$1"
    local DURATION="$2"
    local SEED_INDEX="$3"

    echo ""
    echo "=========================================="
    echo "Starting seed $SEED (${SEED_INDEX}/${NUM_SEEDS})"
    echo "Duration: $DURATION seconds"
    echo "Start: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    echo "=========================================="

    # Create log file for this seed
    local LOG_FILE="vopr-${STATE_MACHINE}-seed${SEED}-$(date +%Y%m%d-%H%M%S).log"

    # Run VOPR with timeout
    # - SIGINT allows graceful shutdown
    # - Exit code 124 means timeout reached (expected behavior)
    # - Tee output to both console and log file
    timeout --signal=SIGINT "$DURATION" \
        ./zig-out/bin/vopr "$SEED" \
        --ticks-max-requests=100000000 \
        2>&1 | tee "$LOG_FILE" || {
            local EXIT_CODE=$?
            if [ $EXIT_CODE -eq 124 ]; then
                echo ""
                echo "Seed $SEED: PASSED (timeout reached)"
                echo "Log: $LOG_FILE"
                PASSED_SEEDS+=("$SEED")
                return 0
            fi
            echo ""
            echo "=========================================="
            echo "Seed $SEED: FAILED with exit code $EXIT_CODE"
            echo "Log: $LOG_FILE"
            echo "To reproduce: ./zig-out/bin/vopr $SEED"
            echo "=========================================="
            FAILED_SEEDS+=("$SEED")
            return 1
        }

    echo ""
    echo "Seed $SEED: PASSED"
    echo "Log: $LOG_FILE"
    PASSED_SEEDS+=("$SEED")
    return 0
}

# Run all seeds
for i in $(seq 0 $((NUM_SEEDS - 1))); do
    SEED=$((BASE_SEED + i))
    # Continue running even if a seed fails - collect all results
    run_single_seed "$SEED" "$DURATION_PER_SEED" "$((i + 1))" || true
done

# Final summary
echo ""
echo "=========================================="
echo "VOPR Run Complete"
echo "=========================================="
echo "State Machine: $STATE_MACHINE"
echo "Total Duration: $DURATION_SECS seconds"
echo "Seeds Run: $NUM_SEEDS (${BASE_SEED} to $((BASE_SEED + NUM_SEEDS - 1)))"
echo "Passed: ${#PASSED_SEEDS[@]} (${PASSED_SEEDS[*]:-none})"
echo "Failed: ${#FAILED_SEEDS[@]} (${FAILED_SEEDS[*]:-none})"
echo "End Time: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "=========================================="

# Exit with failure if any seed failed
if [[ ${#FAILED_SEEDS[@]} -gt 0 ]]; then
    echo ""
    echo "VOPR FAILED: ${#FAILED_SEEDS[@]} seed(s) found issues"
    echo "To reproduce failures, run:"
    for SEED in "${FAILED_SEEDS[@]}"; do
        echo "  ./zig-out/bin/vopr $SEED"
    done
    exit 1
fi

echo ""
echo "VOPR PASSED: All $NUM_SEEDS seeds completed successfully"
exit 0
