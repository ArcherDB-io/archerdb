#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2024-2025 ArcherDB Contributors
#
# Unified chaos test runner for TEST-05
#
# This script runs fault tolerance tests that validate ArcherDB's behavior under
# adverse conditions including node kills, network partitions, disk faults, and
# process crashes.
#
# USAGE:
#   ./scripts/chaos-test.sh [--quick|--full|--help]
#
# MODES:
#   --quick   Run only deterministic FAULT tests (~5 min, default)
#   --full    Run all chaos tests including shell scripts (~30 min)
#
# REQUIREMENTS:
#   - Zig compiler (downloaded via ./zig/download.sh)
#   - Linux for dm-flakey tests (optional, skipped on macOS)
#   - Root for dm-flakey tests (optional, skipped without sudo)
#
# EXIT CODES:
#   0 - All tests passed
#   1 - One or more tests failed

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Configuration
MODE="${1:---quick}"
SEED="${SEED:-42}"  # Fixed seed for determinism (per project decision 02-01)

# Test counters
PASSED=0
FAILED=0
SKIPPED=0

usage() {
    echo "Unified Chaos Test Runner for ArcherDB (TEST-05)"
    echo ""
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --quick    Run only deterministic FAULT tests (~5 min, default)"
    echo "  --full     Run all chaos tests including shell scripts (~30 min)"
    echo "  --help     Show this help message"
    echo ""
    echo "Environment Variables:"
    echo "  SEED       Random seed for VOPR-based tests (default: 42)"
    echo ""
    echo "The script validates fault tolerance requirements:"
    echo "  - FAULT-01: Process crash (SIGKILL) recovery"
    echo "  - FAULT-02: Power loss (torn writes) recovery"
    echo "  - FAULT-03: Disk read error handling"
    echo "  - FAULT-04: Full disk graceful degradation"
    echo "  - FAULT-05: Network partition handling"
    echo "  - FAULT-06: Packet loss/latency handling"
    echo "  - FAULT-07: Corrupted log entry detection"
    echo "  - FAULT-08: Recovery time < 60 seconds"
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

log_section() {
    echo ""
    echo -e "${BLUE}=== $1 ===${NC}"
}

check_prerequisites() {
    log_info "Checking prerequisites..."

    # Check for zig binary
    if [[ ! -x "${PROJECT_ROOT}/zig/zig" ]]; then
        log_warn "Zig not found, attempting download..."
        "${PROJECT_ROOT}/zig/download.sh" || {
            log_error "Failed to download zig"
            exit 1
        }
    fi

    log_info "Prerequisites check passed"
}

# Run deterministic FAULT tests from fault_tolerance_test.zig
run_deterministic_chaos() {
    log_section "Deterministic FAULT Tests"
    log_info "Running deterministic FAULT tests (seed=$SEED)..."
    log_info "This includes 28 FAULT-labeled tests validating fault tolerance"

    local start_time
    start_time=$(date +%s)

    # Run the Zig-based FAULT tests
    # Using -j4 -Dconfig=lite per CLAUDE.md resource constraints
    if "${PROJECT_ROOT}/zig/zig" build -j4 -Dconfig=lite test:unit -- --test-filter "FAULT"; then
        local end_time
        end_time=$(date +%s)
        local duration=$((end_time - start_time))
        log_info "Deterministic FAULT tests PASSED (${duration}s)"
        ((PASSED++))
        return 0
    else
        local end_time
        end_time=$(date +%s)
        local duration=$((end_time - start_time))
        log_error "Deterministic FAULT tests FAILED (${duration}s)"
        ((FAILED++))
        return 1
    fi
}

# Run SIGKILL crash recovery tests
run_sigkill_tests() {
    log_section "SIGKILL Crash Recovery Tests"

    local sigkill_script="${PROJECT_ROOT}/scripts/sigkill_crash_test.sh"

    if [[ ! -x "$sigkill_script" ]]; then
        log_warn "SIGKILL test script not found or not executable, skipping"
        ((SKIPPED++))
        return 0
    fi

    log_info "Running SIGKILL crash recovery tests (seed=$SEED, iterations=3)..."

    local start_time
    start_time=$(date +%s)

    # Run with fixed seed for determinism
    if SEED="$SEED" "$sigkill_script" --iterations 3 --seed "$SEED"; then
        local end_time
        end_time=$(date +%s)
        local duration=$((end_time - start_time))
        log_info "SIGKILL tests PASSED (${duration}s)"
        ((PASSED++))
        return 0
    else
        local end_time
        end_time=$(date +%s)
        local duration=$((end_time - start_time))
        log_error "SIGKILL tests FAILED (${duration}s)"
        ((FAILED++))
        return 1
    fi
}

# Run dm-flakey disk fault injection tests (Linux + root only)
run_dm_flakey_tests() {
    log_section "dm-flakey Disk Fault Tests"

    local flakey_script="${PROJECT_ROOT}/scripts/dm_flakey_test.sh"

    if [[ ! -x "$flakey_script" ]]; then
        log_warn "dm-flakey test script not found or not executable, skipping"
        ((SKIPPED++))
        return 0
    fi

    # Check if running on Linux
    if [[ "$(uname)" != "Linux" ]]; then
        log_warn "dm-flakey tests require Linux kernel, skipping on $(uname)"
        ((SKIPPED++))
        return 0
    fi

    # Check for root privileges
    if [[ $EUID -ne 0 ]]; then
        log_warn "dm-flakey tests require root privileges, skipping"
        log_info "To run: sudo ./scripts/chaos-test.sh --full"
        ((SKIPPED++))
        return 0
    fi

    log_info "Running dm-flakey disk fault injection tests..."

    local start_time
    start_time=$(date +%s)

    if "$flakey_script" --iterations 3; then
        local end_time
        end_time=$(date +%s)
        local duration=$((end_time - start_time))
        log_info "dm-flakey tests PASSED (${duration}s)"
        ((PASSED++))
        return 0
    else
        local end_time
        end_time=$(date +%s)
        local duration=$((end_time - start_time))
        log_error "dm-flakey tests FAILED (${duration}s)"
        ((FAILED++))
        return 1
    fi
}

main() {
    # Parse arguments
    case "${MODE}" in
        --quick)
            MODE="quick"
            ;;
        --full)
            MODE="full"
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            # Check if it's a bare option without --
            if [[ "${MODE}" == "quick" || "${MODE}" == "full" ]]; then
                : # Keep as-is
            else
                log_error "Unknown option: ${MODE}"
                usage
                exit 1
            fi
            ;;
    esac

    echo "=============================================="
    echo "  ArcherDB Chaos Test Runner (TEST-05)"
    echo "=============================================="
    echo ""
    echo "Configuration:"
    echo "  Mode: ${MODE}"
    echo "  Seed: ${SEED}"
    echo "  Platform: $(uname)"
    echo ""

    local start_time
    start_time=$(date +%s)

    check_prerequisites

    # Always run deterministic FAULT tests (both quick and full modes)
    run_deterministic_chaos || true

    # Full mode: also run shell-based chaos tests
    if [[ "${MODE}" == "full" ]]; then
        run_sigkill_tests || true
        run_dm_flakey_tests || true
    fi

    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))

    echo ""
    echo "=============================================="
    echo "  Chaos Test Summary"
    echo "=============================================="
    echo "  Passed:  ${PASSED}"
    echo "  Failed:  ${FAILED}"
    echo "  Skipped: ${SKIPPED}"
    echo "  Duration: ${duration}s"
    echo "=============================================="

    if [[ ${FAILED} -gt 0 ]]; then
        log_error "Some chaos tests failed!"
        exit 1
    else
        log_info "All chaos tests passed!"
        exit 0
    fi
}

main "$@"
