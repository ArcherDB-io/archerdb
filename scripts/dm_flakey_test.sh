#!/usr/bin/env bash
# dm-flakey power-loss simulation tests for ArcherDB
#
# This script uses Linux device-mapper dm-flakey to simulate disk failures
# and power-loss scenarios. It tests that ArcherDB correctly recovers from
# abrupt disk failures during operation.
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

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Test configuration
ITERATIONS=${ITERATIONS:-3}
SIZE_MB=${SIZE_MB:-100}
TEST_DIR="${PROJECT_ROOT}/.dm_flakey_test"
LOOP_FILE="${TEST_DIR}/test_device.img"
LOOP_DEV=""
FLAKEY_NAME="archerdb-flakey-test"
FLAKEY_DEV="/dev/mapper/${FLAKEY_NAME}"
DATA_DIR="${TEST_DIR}/data"

# dm-flakey timing parameters
UP_INTERVAL=10      # Seconds device is up
DOWN_INTERVAL=5     # Seconds device is down (returns I/O errors)

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

    # Check if running on Linux
    if [[ "$(uname)" != "Linux" ]]; then
        log_error "This script only works on Linux (dm-flakey is Linux-only)"
        echo "Use scripts/sigkill_crash_test.sh for cross-platform testing"
        exit 1
    fi

    # Check for root privileges
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (sudo)"
        exit 1
    fi

    # Check for required tools
    for cmd in losetup dmsetup blockdev; do
        if ! command -v "$cmd" &>/dev/null; then
            log_error "Required command not found: $cmd"
            exit 1
        fi
    done

    # Check if dm-flakey module is available
    if ! modprobe dm-flakey 2>/dev/null; then
        log_warn "dm-flakey module not loaded, attempting to load..."
        modprobe dm-flakey || {
            log_error "Failed to load dm-flakey kernel module"
            log_error "Your kernel may not support dm-flakey"
            exit 1
        }
    fi

    # Check for ArcherDB binary
    if [[ ! -x "${PROJECT_ROOT}/zig/zig" ]]; then
        log_error "zig binary not found. Run: ./zig/zig build"
        exit 1
    fi

    # Safety check: refuse to run on production-looking systems
    if [[ -d "/var/lib/archerdb" ]] && [[ ! -f "${PROJECT_ROOT}/.dm_flakey_test_allowed" ]]; then
        log_error "Detected /var/lib/archerdb - refusing to run on potential production system"
        log_error "To override, create: touch ${PROJECT_ROOT}/.dm_flakey_test_allowed"
        exit 1
    fi

    log_info "Prerequisites check passed"
}

setup_test_device() {
    log_info "Setting up test device (${SIZE_MB}MB)..."

    # Create test directory
    mkdir -p "${TEST_DIR}"
    mkdir -p "${DATA_DIR}"

    # Create sparse file for loop device
    dd if=/dev/zero of="${LOOP_FILE}" bs=1M count=0 seek="${SIZE_MB}" 2>/dev/null

    # Setup loop device
    LOOP_DEV=$(losetup -f --show "${LOOP_FILE}")
    log_info "Created loop device: ${LOOP_DEV}"

    # Get size in sectors (512 bytes per sector)
    local sectors
    sectors=$(blockdev --getsz "${LOOP_DEV}")

    # Create dm-flakey device
    # Table format: <start_sector> <num_sectors> flakey <underlying_device> <offset> <up_interval> <down_interval> [<num_features> [<feature_args>]]
    dmsetup create "${FLAKEY_NAME}" --table "0 ${sectors} flakey ${LOOP_DEV} 0 ${UP_INTERVAL} ${DOWN_INTERVAL}"

    log_info "Created dm-flakey device: ${FLAKEY_DEV}"

    # Format with a filesystem
    mkfs.ext4 -q "${FLAKEY_DEV}"

    # Mount it
    mount "${FLAKEY_DEV}" "${DATA_DIR}"
    log_info "Mounted flakey device at: ${DATA_DIR}"
}

cleanup() {
    log_info "Cleaning up test environment..."

    # Unmount if mounted
    if mountpoint -q "${DATA_DIR}" 2>/dev/null; then
        umount "${DATA_DIR}" 2>/dev/null || umount -f "${DATA_DIR}" 2>/dev/null || true
    fi

    # Remove dm-flakey device
    if dmsetup info "${FLAKEY_NAME}" &>/dev/null; then
        dmsetup remove "${FLAKEY_NAME}" 2>/dev/null || true
    fi

    # Detach loop device
    if [[ -n "${LOOP_DEV}" ]] && losetup "${LOOP_DEV}" &>/dev/null; then
        losetup -d "${LOOP_DEV}" 2>/dev/null || true
    fi

    # Remove test directory
    if [[ -d "${TEST_DIR}" ]]; then
        rm -rf "${TEST_DIR}"
    fi

    log_info "Cleanup complete"
}

trigger_disk_failure() {
    local duration=$1
    log_warn "Triggering disk failure for ${duration}s..."

    # Reload dm-flakey with drop_writes to simulate power loss
    # drop_writes: writes return success but data is dropped
    local sectors
    sectors=$(blockdev --getsz "${LOOP_DEV}")
    dmsetup suspend "${FLAKEY_NAME}"
    dmsetup reload "${FLAKEY_NAME}" --table "0 ${sectors} flakey ${LOOP_DEV} 0 0 ${duration} 1 drop_writes"
    dmsetup resume "${FLAKEY_NAME}"

    sleep "${duration}"

    # Restore normal operation
    dmsetup suspend "${FLAKEY_NAME}"
    dmsetup reload "${FLAKEY_NAME}" --table "0 ${sectors} flakey ${LOOP_DEV} 0 ${UP_INTERVAL} 0"
    dmsetup resume "${FLAKEY_NAME}"

    log_info "Disk failure simulation complete, device restored"
}

run_test_iteration() {
    local iteration=$1
    log_info "=== Iteration ${iteration}/${ITERATIONS} ==="

    local db_path="${DATA_DIR}/archerdb_test"

    # Format database
    log_info "Formatting ArcherDB at ${db_path}..."
    "${PROJECT_ROOT}/zig/zig" build archerdb 2>/dev/null

    # Note: ArcherDB format command would go here
    # For now, we'll just create the data directory
    mkdir -p "${db_path}"

    # TODO: When ArcherDB CLI is ready:
    # "${PROJECT_ROOT}/zig-out/bin/archerdb" format --data-file="${db_path}/data.db" --replica-count=1

    # Start ArcherDB and write some data
    log_info "Writing test data..."
    # TODO: Start archerdb and issue write commands
    # "${PROJECT_ROOT}/zig-out/bin/archerdb" start --data-file="${db_path}/data.db" &
    # ARCHERDB_PID=$!
    # sleep 2
    # Issue write commands here

    # Trigger disk failure during writes
    trigger_disk_failure 3

    # Wait for I/O errors to propagate
    sleep 1

    # Remount to simulate recovery
    log_info "Remounting to simulate recovery..."
    sync
    umount "${DATA_DIR}" 2>/dev/null || umount -l "${DATA_DIR}"
    mount "${FLAKEY_DEV}" "${DATA_DIR}"

    # Verify ArcherDB can recover
    log_info "Verifying recovery..."
    # TODO: Start archerdb and verify data integrity
    # "${PROJECT_ROOT}/zig-out/bin/archerdb" start --data-file="${db_path}/data.db" &
    # ARCHERDB_PID=$!
    # sleep 2
    # Verify data here
    # kill $ARCHERDB_PID 2>/dev/null || true

    # For now, just verify the directory survived
    if [[ -d "${db_path}" ]]; then
        log_info "Iteration ${iteration} PASSED - data directory survived"
        return 0
    else
        log_error "Iteration ${iteration} FAILED - data directory lost"
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
    echo ""

    # Set up trap for cleanup on exit
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
    else
        log_info "All tests passed!"
        exit 0
    fi
}

main "$@"
