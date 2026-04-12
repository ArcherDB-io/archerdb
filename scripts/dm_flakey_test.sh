#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2024-2025 ArcherDB Contributors
# dm-flakey power-loss simulation tests for ArcherDB
#
# This script uses Linux device-mapper dm-flakey to simulate disk failures
# and power-loss scenarios against a real ArcherDB workload. Each iteration:
#   1. Runs `archerdb benchmark` against a data file on a flakey filesystem
#   2. Switches the block device into `drop_writes` mode mid-run
#   3. Remounts the filesystem after the failure window
#   4. Runs `archerdb verify` on the recovered file
#   5. Restarts ArcherDB and waits for `/health/ready`
#
# REQUIREMENTS:
#   - Linux kernel with device-mapper (dm-flakey target)
#   - Root privileges (uses losetup and dmsetup)
#   - Sufficient disk space for test file
#
# USAGE:
#   sudo ./scripts/dm_flakey_test.sh [--iterations N] [--size-mb N]
#
# SAFETY:
#   This script creates and destroys loop devices and device-mapper targets.
#   It should ONLY be run on development/test systems, NOT production.

set -euo pipefail

RED='[0;31m'
GREEN='[0;32m'
YELLOW='[1;33m'
NC='[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ZIG_BIN="${PROJECT_ROOT}/zig/zig"
ARCHERDB_BIN="${PROJECT_ROOT}/zig-out/bin/archerdb"

ITERATIONS=${ITERATIONS:-3}
SIZE_MB=${SIZE_MB:-100}
TEST_DIR="${PROJECT_ROOT}/.dm_flakey_test"
LOOP_FILE="${TEST_DIR}/test_device.img"
LOOP_DEV=""
FLAKEY_NAME="archerdb-flakey-test"
FLAKEY_DEV="/dev/mapper/${FLAKEY_NAME}"
DATA_DIR="${TEST_DIR}/data"
UP_INTERVAL=10
DOWN_INTERVAL=5
BENCHMARK_TIMEOUT=${BENCHMARK_TIMEOUT:-180}
READY_TIMEOUT=${READY_TIMEOUT:-30}
WORKLOAD_EVENT_COUNT=${WORKLOAD_EVENT_COUNT:-100000}
WORKLOAD_ENTITY_COUNT=${WORKLOAD_ENTITY_COUNT:-20000}
WORKLOAD_BATCH_SIZE=${WORKLOAD_BATCH_SIZE:-1000}

usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --iterations N    Number of crash/recovery cycles (default: 3)"
    echo "  --size-mb N       Size of test device in MB (default: 100)"
    echo "  --help            Show this help message"
    echo ""
    echo "IMPORTANT: This script requires root privileges and should"
    echo "           ONLY be run on development/test systems."
}

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

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

check_prerequisites() {
    log_info "Checking prerequisites..."

    if [[ "$(uname)" != "Linux" ]]; then
        log_error "This script only works on Linux (dm-flakey is Linux-only)"
        echo "Use scripts/sigkill_crash_test.sh for cross-platform testing"
        exit 1
    fi

    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (sudo)"
        exit 1
    fi

    for cmd in losetup dmsetup blockdev mount umount mkfs.ext4 curl setsid modprobe; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log_error "Required command not found: $cmd"
            exit 1
        fi
    done

    if ! modprobe dm-flakey 2>/dev/null; then
        log_warn "dm-flakey module not loaded, attempting to load..."
        modprobe dm-flakey || {
            log_error "Failed to load dm-flakey kernel module"
            log_error "Your kernel may not support dm-flakey"
            exit 1
        }
    fi

    if [[ ! -x "$ARCHERDB_BIN" ]]; then
        if [[ ! -x "$ZIG_BIN" ]]; then
            log_error "zig binary not found. Run: ./zig/zig build"
            exit 1
        fi
        log_info "Building ArcherDB binary..."
        "$ZIG_BIN" build -j2 >/dev/null
    fi

    if [[ ! -x "$ARCHERDB_BIN" ]]; then
        log_error "ArcherDB binary not found at $ARCHERDB_BIN"
        exit 1
    fi

    if [[ -d "/var/lib/archerdb" ]] && [[ ! -f "${PROJECT_ROOT}/.dm_flakey_test_allowed" ]]; then
        log_error "Detected /var/lib/archerdb - refusing to run on potential production system"
        log_error "To override, create: touch ${PROJECT_ROOT}/.dm_flakey_test_allowed"
        exit 1
    fi

    log_info "Prerequisites check passed"
}

setup_test_device() {
    log_info "Setting up test device (${SIZE_MB}MB)..."

    mkdir -p "${TEST_DIR}"
    mkdir -p "${DATA_DIR}"

    dd if=/dev/zero of="${LOOP_FILE}" bs=1M count=0 seek="${SIZE_MB}" 2>/dev/null

    LOOP_DEV=$(losetup -f --show "${LOOP_FILE}")
    log_info "Created loop device: ${LOOP_DEV}"

    local sectors
    sectors=$(blockdev --getsz "${LOOP_DEV}")
    dmsetup create "${FLAKEY_NAME}" --table "0 ${sectors} flakey ${LOOP_DEV} 0 ${UP_INTERVAL} ${DOWN_INTERVAL}"

    log_info "Created dm-flakey device: ${FLAKEY_DEV}"

    mkfs.ext4 -q "${FLAKEY_DEV}"
    mount "${FLAKEY_DEV}" "${DATA_DIR}"
    log_info "Mounted flakey device at: ${DATA_DIR}"
}

cleanup() {
    log_info "Cleaning up test environment..."

    if mountpoint -q "${DATA_DIR}" 2>/dev/null; then
        umount "${DATA_DIR}" 2>/dev/null || umount -f "${DATA_DIR}" 2>/dev/null || umount -l "${DATA_DIR}" 2>/dev/null || true
    fi

    if dmsetup info "${FLAKEY_NAME}" >/dev/null 2>&1; then
        dmsetup remove "${FLAKEY_NAME}" 2>/dev/null || true
    fi

    if [[ -n "${LOOP_DEV}" ]] && losetup "${LOOP_DEV}" >/dev/null 2>&1; then
        losetup -d "${LOOP_DEV}" 2>/dev/null || true
    fi

    if [[ -d "${TEST_DIR}" ]]; then
        rm -rf "${TEST_DIR}"
    fi

    log_info "Cleanup complete"
}

trigger_disk_failure() {
    local duration=$1
    log_warn "Triggering disk failure for ${duration}s..."

    local sectors
    sectors=$(blockdev --getsz "${LOOP_DEV}")
    dmsetup suspend "${FLAKEY_NAME}"
    dmsetup reload "${FLAKEY_NAME}" --table "0 ${sectors} flakey ${LOOP_DEV} 0 0 ${duration} 1 drop_writes"
    dmsetup resume "${FLAKEY_NAME}"

    sleep "${duration}"

    dmsetup suspend "${FLAKEY_NAME}"
    dmsetup reload "${FLAKEY_NAME}" --table "0 ${sectors} flakey ${LOOP_DEV} 0 ${UP_INTERVAL} 0"
    dmsetup resume "${FLAKEY_NAME}"

    log_info "Disk failure simulation complete, device restored"
}

stop_process_group() {
    local pid="$1"
    local label="$2"

    if ! kill -0 "$pid" >/dev/null 2>&1; then
        wait "$pid" >/dev/null 2>&1 || true
        return
    fi

    log_info "Stopping ${label} (pid=${pid})..."
    kill -TERM -- "-${pid}" >/dev/null 2>&1 || kill -TERM "$pid" >/dev/null 2>&1 || true
    sleep 2

    if kill -0 "$pid" >/dev/null 2>&1; then
        kill -KILL -- "-${pid}" >/dev/null 2>&1 || kill -KILL "$pid" >/dev/null 2>&1 || true
    fi

    wait "$pid" >/dev/null 2>&1 || true
}

wait_for_ready() {
    local metrics_port="$1"
    local timeout_seconds="$2"
    local deadline=$((SECONDS + timeout_seconds))

    while (( SECONDS < deadline )); do
        local status
        status=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${metrics_port}/health/ready" 2>/dev/null || echo "000")
        if [[ "$status" == "200" ]]; then
            return 0
        fi
        sleep 1
    done

    return 1
}

start_benchmark_workload() {
    local db_path="$1"
    local log_file="$2"

    rm -f "$db_path"
    mkdir -p "$(dirname "$db_path")"

    if command -v timeout >/dev/null 2>&1; then
        setsid timeout "${BENCHMARK_TIMEOUT}"             "$ARCHERDB_BIN" benchmark             --file="$db_path"             --event-count="${WORKLOAD_EVENT_COUNT}"             --entity-count="${WORKLOAD_ENTITY_COUNT}"             --event-batch-size="${WORKLOAD_BATCH_SIZE}"             --query-uuid-count=0             --query-radius-count=0             --query-polygon-count=0 >"$log_file" 2>&1 &
    else
        setsid "$ARCHERDB_BIN" benchmark             --file="$db_path"             --event-count="${WORKLOAD_EVENT_COUNT}"             --entity-count="${WORKLOAD_ENTITY_COUNT}"             --event-batch-size="${WORKLOAD_BATCH_SIZE}"             --query-uuid-count=0             --query-radius-count=0             --query-polygon-count=0 >"$log_file" 2>&1 &
    fi

    echo $!
}

verify_recovered_file() {
    local iteration="$1"
    local db_path="$2"
    local verify_log="$3"
    local server_log="$4"
    local data_port=$((33000 + iteration))
    local metrics_port=$((34000 + iteration))

    log_info "Running offline verify on recovered file..."
    if ! run_with_timeout_if_available 120 "$ARCHERDB_BIN" verify "$db_path" >"$verify_log" 2>&1; then
        log_error "Offline verify failed for recovered file"
        cat "$verify_log"
        return 1
    fi

    log_info "Restarting ArcherDB on recovered file..."
    "$ARCHERDB_BIN" start         --addresses="127.0.0.1:${data_port}"         --metrics-port="${metrics_port}"         --metrics-bind=127.0.0.1         --development         "$db_path" >"$server_log" 2>&1 &
    local server_pid=$!

    if ! wait_for_ready "$metrics_port" "$READY_TIMEOUT"; then
        log_error "Recovered ArcherDB instance did not become ready"
        cat "$server_log"
        kill "$server_pid" >/dev/null 2>&1 || true
        wait "$server_pid" >/dev/null 2>&1 || true
        return 1
    fi

    log_info "Recovered ArcherDB instance reached /health/ready"
    kill "$server_pid" >/dev/null 2>&1 || true
    wait "$server_pid" >/dev/null 2>&1 || true
    return 0
}

run_test_iteration() {
    local iteration="$1"
    log_info "=== Iteration ${iteration}/${ITERATIONS} ==="

    local db_dir="${DATA_DIR}/archerdb_test_${iteration}"
    local db_path="${db_dir}/data.archerdb"
    local benchmark_log="${TEST_DIR}/benchmark_${iteration}.log"
    local verify_log="${TEST_DIR}/verify_${iteration}.log"
    local server_log="${TEST_DIR}/server_${iteration}.log"
    mkdir -p "$db_dir"

    log_info "Starting real ArcherDB workload at ${db_path}..."
    local benchmark_pid
    benchmark_pid=$(start_benchmark_workload "$db_path" "$benchmark_log")

    local found_file=false
    for _ in $(seq 1 15); do
        if [[ -f "$db_path" ]]; then
            found_file=true
            break
        fi
        if ! kill -0 "$benchmark_pid" >/dev/null 2>&1; then
            break
        fi
        sleep 1
    done

    if [[ "$found_file" != "true" ]]; then
        log_error "Benchmark workload never created ${db_path}"
        cat "$benchmark_log"
        stop_process_group "$benchmark_pid" "benchmark workload"
        return 1
    fi

    if ! kill -0 "$benchmark_pid" >/dev/null 2>&1; then
        log_error "Benchmark workload exited before the fault window"
        cat "$benchmark_log"
        return 1
    fi

    trigger_disk_failure 3
    sleep 1
    stop_process_group "$benchmark_pid" "benchmark workload"

    log_info "Remounting flakey filesystem..."
    sync || true
    if mountpoint -q "${DATA_DIR}" 2>/dev/null; then
        umount "${DATA_DIR}" 2>/dev/null || umount -l "${DATA_DIR}" || true
    fi
    mount "${FLAKEY_DEV}" "${DATA_DIR}"

    if [[ ! -f "$db_path" ]]; then
        log_error "Recovered data file missing: ${db_path}"
        return 1
    fi

    if verify_recovered_file "$iteration" "$db_path" "$verify_log" "$server_log"; then
        log_info "Iteration ${iteration} PASSED - recovery verified"
        return 0
    fi

    log_error "Iteration ${iteration} FAILED"
    return 1
}

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --iterations)
                ITERATIONS="$2"
                shift 2
                ;;
            --size-mb)
                SIZE_MB="$2"
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
    echo "  ArcherDB dm-flakey Power-Loss Test"
    echo "=============================================="
    echo ""
    echo "Configuration:"
    echo "  Iterations: ${ITERATIONS}"
    echo "  Device size: ${SIZE_MB}MB"
    echo "  Up interval: ${UP_INTERVAL}s"
    echo "  Down interval: ${DOWN_INTERVAL}s"
    echo "  Workload events: ${WORKLOAD_EVENT_COUNT}"
    echo ""

    trap cleanup EXIT

    check_prerequisites
    setup_test_device

    local passed=0
    local failed=0

    for i in $(seq 1 "${ITERATIONS}"); do
        if run_test_iteration "$i"; then
            ((passed++))
        else
            ((failed++))
        fi
        echo ""
    done

    echo "=============================================="
    echo "  Test Summary"
    echo "=============================================="
    echo "  Passed: ${passed}/${ITERATIONS}"
    echo "  Failed: ${failed}/${ITERATIONS}"
    echo "=============================================="

    if [[ ${failed} -gt 0 ]]; then
        log_error "Some tests failed!"
        exit 1
    fi

    log_info "All tests passed!"
    exit 0
}

main "$@"
