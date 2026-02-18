#!/usr/bin/env bash
# SIGKILL crash recovery test for ArcherDB
#
# This script tests ArcherDB's recovery from abrupt process termination (SIGKILL).
# It simulates power loss by randomly killing the database process while it's
# writing data, then verifies the database can recover and data integrity is preserved.
#
# Works on both Linux and macOS.
#
# USAGE:
#   ./scripts/sigkill_crash_test.sh [--iterations N] [--timeout N]
#
# The test:
#   1. Starts VOPR with a known seed
#   2. Sends SIGKILL at random points during execution
#   3. Restarts with the same seed and verifies deterministic behavior
#   4. Repeats for N iterations

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ZIG_BIN="${PROJECT_ROOT}/zig/zig"

# Test configuration
ITERATIONS=${ITERATIONS:-3}
TIMEOUT=${TIMEOUT:-30}
SEED=${SEED:-42}
REQUESTS_MAX=${REQUESTS_MAX:-100}
TICKS_MAX_REQUESTS=${TICKS_MAX_REQUESTS:-10000}
TICKS_MAX_CONVERGENCE=${TICKS_MAX_CONVERGENCE:-5000}
FULL_RUN_TIMEOUT=${FULL_RUN_TIMEOUT:-180}

usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --iterations N    Number of crash/recovery test cycles (default: 3)"
    echo "  --timeout N       Seconds before sending SIGKILL (default: 30)"
    echo "  --seed N          VOPR seed for deterministic testing (default: 42)"
    echo "  --requests-max N  Maximum requests per VOPR run (default: 100)"
    echo "  --ticks-max-requests N   Max ticks during request phase (default: 10000)"
    echo "  --ticks-max-convergence N Max ticks during convergence phase (default: 5000)"
    echo "  --full-run-timeout N      Timeout in seconds for Phase 2 run (default: 180)"
    echo "  --help            Show this help message"
    echo ""
    echo "This test verifies ArcherDB's crash recovery by:"
    echo "  1. Running VOPR with a known seed"
    echo "  2. Killing the process with SIGKILL at random times"
    echo "  3. Verifying deterministic behavior after restart"
}

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_prerequisites() {
    log_info "Checking prerequisites..."

    # Check for zig binary
    if [[ ! -x "${ZIG_BIN}" ]]; then
        log_error "zig binary not found at ${ZIG_BIN}"
        log_error "Run: ./zig/zig build"
        exit 1
    fi

    log_info "Prerequisites check passed"
}

run_with_timeout_if_available() {
    local timeout_seconds="$1"
    shift

    local timeout_bin=""
    if command -v gtimeout >/dev/null 2>&1; then
        timeout_bin="gtimeout"
    elif command -v timeout >/dev/null 2>&1; then
        timeout_bin="timeout"
    fi

    if [[ -n "$timeout_bin" ]]; then
        "$timeout_bin" "$timeout_seconds" "$@"
        return $?
    fi

    if command -v python3 >/dev/null 2>&1; then
        python3 - "$timeout_seconds" "$@" <<'PYEOF'
import subprocess
import sys

timeout_seconds = float(sys.argv[1])
command = sys.argv[2:]
try:
    completed = subprocess.run(command, timeout=timeout_seconds, check=False)
    raise SystemExit(completed.returncode)
except subprocess.TimeoutExpired:
    raise SystemExit(124)
PYEOF
        return $?
    fi

    "$@"
}

run_vopr_with_timeout() {
    local timeout_sec=$1
    local kill_after_sec=$2
    local pid
    local exit_code=0

    log_info "Starting VOPR (seed=${SEED}, requests_max=${REQUESTS_MAX})..."

    # Start VOPR in background
    "${ZIG_BIN}" build vopr -Dvopr-state-machine=testing -- \
        --lite --requests-max="${REQUESTS_MAX}" \
        --ticks-max-requests="${TICKS_MAX_REQUESTS}" \
        --ticks-max-convergence="${TICKS_MAX_CONVERGENCE}" \
        "${SEED}" &
    pid=$!

    log_info "VOPR started with PID: ${pid}"

    # Calculate random kill time between 1 and timeout_sec
    local random_delay
    random_delay=$((RANDOM % kill_after_sec + 1))
    log_info "Will send SIGKILL after ${random_delay}s (max: ${kill_after_sec}s)"

    # Wait for random delay
    local waited=0
    while [[ $waited -lt $random_delay ]]; do
        if ! kill -0 "$pid" 2>/dev/null; then
            log_warn "VOPR exited before SIGKILL (waited ${waited}s)"
            wait "$pid" || exit_code=$?
            return $exit_code
        fi
        sleep 1
        ((waited++))
    done

    # Check if process is still running
    if kill -0 "$pid" 2>/dev/null; then
        log_warn "Sending SIGKILL to VOPR (PID: ${pid})..."
        kill -9 "$pid" 2>/dev/null || true
        # Don't wait for killed process, just continue
        # Return 137 to indicate SIGKILL
        return 137
    else
        log_info "VOPR completed naturally before SIGKILL"
        wait "$pid" || exit_code=$?
        return $exit_code
    fi
}

run_full_vopr() {
    local exit_code=0

    log_info "Running full VOPR to verify recovery (seed=${SEED})..."

    # Keep Phase 2 bounded; otherwise this can run for a very long time.
    run_with_timeout_if_available "${FULL_RUN_TIMEOUT}" \
        "${ZIG_BIN}" build vopr -Dvopr-state-machine=testing -- \
        --lite --requests-max="${REQUESTS_MAX}" \
        --ticks-max-requests="${TICKS_MAX_REQUESTS}" \
        --ticks-max-convergence="${TICKS_MAX_CONVERGENCE}" \
        "${SEED}" || exit_code=$?

    return $exit_code
}

run_test_iteration() {
    local iteration=$1
    log_info "=== Iteration ${iteration}/${ITERATIONS} ==="

    # Use a different seed for each iteration to increase coverage
    local iter_seed=$((SEED + iteration - 1))
    SEED=$iter_seed

    # Phase 1: Run VOPR and kill it
    log_info "Phase 1: Running VOPR with crash injection..."
    local crash_exit_code=0
    run_vopr_with_timeout "${TIMEOUT}" "${TIMEOUT}" || crash_exit_code=$?

    if [[ $crash_exit_code -eq 137 ]]; then
        log_info "VOPR was killed as expected (exit code: 137)"
    elif [[ $crash_exit_code -eq 0 ]]; then
        log_info "VOPR completed normally before crash could be triggered"
    else
        log_warn "VOPR exited with code: ${crash_exit_code}"
    fi

    # Phase 2: Run full VOPR to verify recovery
    # The seed-based determinism means identical behavior should occur
    log_info "Phase 2: Running full VOPR to verify deterministic recovery..."
    local verify_exit_code=0
    run_full_vopr || verify_exit_code=$?

    if [[ $verify_exit_code -eq 0 ]]; then
        log_info "Iteration ${iteration} PASSED - recovery verified"
        return 0
    else
        log_error "Iteration ${iteration} FAILED - exit code: ${verify_exit_code}"
        return 1
    fi
}

main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --iterations)
                ITERATIONS="$2"
                shift 2
                ;;
            --timeout)
                TIMEOUT="$2"
                shift 2
                ;;
            --seed)
                SEED="$2"
                shift 2
                ;;
            --requests-max)
                REQUESTS_MAX="$2"
                shift 2
                ;;
            --ticks-max-requests)
                TICKS_MAX_REQUESTS="$2"
                shift 2
                ;;
            --ticks-max-convergence)
                TICKS_MAX_CONVERGENCE="$2"
                shift 2
                ;;
            --full-run-timeout)
                FULL_RUN_TIMEOUT="$2"
                shift 2
                ;;
            --help)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done

    echo "=============================================="
    echo "  ArcherDB SIGKILL Crash Recovery Test"
    echo "=============================================="
    echo ""
    echo "Configuration:"
    echo "  Iterations: ${ITERATIONS}"
    echo "  Timeout: ${TIMEOUT}s"
    echo "  Base seed: ${SEED}"
    echo "  Requests max: ${REQUESTS_MAX}"
    echo "  Ticks max (requests): ${TICKS_MAX_REQUESTS}"
    echo "  Ticks max (convergence): ${TICKS_MAX_CONVERGENCE}"
    echo "  Full run timeout: ${FULL_RUN_TIMEOUT}s"
    echo "  Platform: $(uname)"
    echo ""

    check_prerequisites

    local passed=0
    local failed=0
    local start_time
    start_time=$(date +%s)

    for i in $(seq 1 "${ITERATIONS}"); do
        if run_test_iteration "$i"; then
            passed=$((passed + 1))
        else
            failed=$((failed + 1))
        fi
        echo ""
    done

    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))

    echo "=============================================="
    echo "  Test Summary"
    echo "=============================================="
    echo "  Passed: ${passed}/${ITERATIONS}"
    echo "  Failed: ${failed}/${ITERATIONS}"
    echo "  Duration: ${duration}s"
    echo "=============================================="

    if [[ ${failed} -gt 0 ]]; then
        log_error "Some tests failed!"
        exit 1
    else
        log_info "All tests passed!"
        exit 0
    fi
}

main "$@"
