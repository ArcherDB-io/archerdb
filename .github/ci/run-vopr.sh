#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2024-2025 ArcherDB Contributors
#
# VOPR (Verification-Oriented Property Replication) runner script.
# Runs the VOPR fuzzer for a specified duration with the given state machine.
#
# Usage: ./run-vopr.sh <state_machine> <duration_secs>
#   state_machine: geo | testing
#   duration_secs: Duration in seconds (default: 7200 = 2 hours)
#
# Exit codes:
#   0 - Success (including timeout, which is expected)
#   1 - VOPR found a bug or crashed
#   2 - Build failure
#   3 - Invalid arguments

set -euo pipefail

STATE_MACHINE="${1:-geo}"
DURATION_SECS="${2:-7200}"  # 2 hours default

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

echo "=========================================="
echo "VOPR Fuzzer Run"
echo "=========================================="
echo "State Machine: $STATE_MACHINE"
echo "Duration: $DURATION_SECS seconds ($((DURATION_SECS / 60)) minutes)"
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

# Create log file with timestamp
LOG_FILE="vopr-${STATE_MACHINE}-$(date +%Y%m%d-%H%M%S).log"

# Run VOPR with timeout
# - SIGINT allows graceful shutdown
# - Exit code 124 means timeout reached (expected behavior)
# - Tee output to both console and log file
timeout --signal=SIGINT "$DURATION_SECS" \
    ./zig-out/bin/vopr "${GITHUB_SHA:-$(git rev-parse HEAD)}" \
    --ticks-max-requests=100000000 \
    2>&1 | tee "$LOG_FILE" || {
        EXIT_CODE=$?
        if [ $EXIT_CODE -eq 124 ]; then
            echo ""
            echo "=========================================="
            echo "VOPR completed successfully (timeout reached)"
            echo "Duration: $DURATION_SECS seconds"
            echo "End Time: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
            echo "Log: $LOG_FILE"
            echo "=========================================="
            exit 0
        fi
        echo ""
        echo "=========================================="
        echo "VOPR FAILED with exit code $EXIT_CODE"
        echo "End Time: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
        echo "Log: $LOG_FILE"
        echo "=========================================="
        exit 1
    }

echo ""
echo "=========================================="
echo "VOPR completed successfully"
echo "End Time: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "Log: $LOG_FILE"
echo "=========================================="
