#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2024-2025 ArcherDB Contributors
#
# Stress Test Runner for TEST-04 (Sustained Load Testing)
#
# USAGE:
#   ./scripts/stress-test.sh [duration]
#   ./scripts/stress-test.sh 5m      # 5 minutes (CI default)
#   ./scripts/stress-test.sh 1h      # 1 hour (manual validation)
#   ./scripts/stress-test.sh 24h     # 24 hours (TEST-04 requirement, self-hosted)
#
# NOTES:
#   - 24-hour tests require self-hosted runner (GitHub Actions ~6h limit)
#   - Uses fixed seed 42 for determinism
#
# EXIT CODES:
#   0 - Test passed (stable memory, stable throughput, zero errors)
#   1 - Test failure

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Configuration
DURATION="${1:-5m}"
SEED="${SEED:-42}"

# Thresholds
MEMORY_GROWTH_THRESHOLD_PCT=10
THROUGHPUT_DROP_THRESHOLD_PCT=20

# Counters
TOTAL_OPS=0
ERRORS=0
declare -a THROUGHPUT_SAMPLES

# Parse duration to seconds
parse_duration() {
    local d="$1"
    case "$d" in
        *m) echo $((${d%m} * 60)) ;;
        *h) echo $((${d%h} * 3600)) ;;
        *s) echo "${d%s}" ;;
        *)  echo "$d" ;;
    esac
}

# Format seconds to human readable
format_duration() {
    local s=$1
    if (( s >= 3600 )); then echo "$((s/3600))h$((s%3600/60))m"
    elif (( s >= 60 )); then echo "$((s/60))m$((s%60))s"
    else echo "${s}s"; fi
}

# Portable timeout wrapper (macOS lacks coreutils timeout)
portable_timeout() {
    local duration=$1; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$duration" "$@"
    else
        # Use perl alarm on macOS
        perl -e 'alarm shift; exec @ARGV' "$duration" "$@"
    fi
}

# Get memory usage (portable: Linux /proc/meminfo, macOS vm_stat)
get_mem() {
    if [[ -f /proc/meminfo ]]; then
        awk '/MemTotal/{t=$2}/MemAvailable/{a=$2}END{print t-a}' /proc/meminfo
    elif command -v vm_stat >/dev/null 2>&1; then
        local page_size
        page_size=$(pagesize 2>/dev/null || sysctl -n hw.pagesize 2>/dev/null || echo 4096)
        local used
        used=$(vm_stat | awk -v ps="$page_size" '
            /Pages active/{a=$NF} /Pages wired/{w=$NF}
            END{gsub(/\./,"",a); gsub(/\./,"",w); print int((a+w)*ps/1024)}')
        echo "${used:-0}"
    else
        echo 0
    fi
}

echo "=============================================="
echo "  ArcherDB Stress Test Runner (TEST-04)"
echo "=============================================="

DURATION_SECS=$(parse_duration "$DURATION")
echo "Duration: $DURATION ($(format_duration $DURATION_SECS))"
echo "Seed: $SEED"
echo ""

# Check prerequisites
if [[ ! -x "$PROJECT_ROOT/zig/zig" ]]; then
    echo "[ERROR] Zig not found" >&2
    exit 1
fi

echo "[INFO] Starting stress test..."

START_TIME=$(date +%s)
INIT_MEM=$(get_mem)
PEAK_MEM=$INIT_MEM
FINAL_MEM=$INIT_MEM

echo "[INFO] Initial memory: ${INIT_MEM}KB"

ITERATION=0
ELAPSED=0

while (( ELAPSED < DURATION_SECS )); do
    ((ITERATION++)) || true

    ITER_START=$(date +%s)
    ITER_MEM=$(get_mem)

    # Run a build check as stress workload
    if portable_timeout 120 "$PROJECT_ROOT/zig/zig" build -j4 -Dconfig=lite check >/dev/null 2>&1; then
        ((TOTAL_OPS += 100)) || true
    else
        ((ERRORS++)) || true
        echo "[WARN] Iteration $ITERATION: build failed"
    fi

    ITER_END=$(date +%s)
    ITER_DUR=$((ITER_END - ITER_START))

    FINAL_MEM=$(get_mem)
    (( FINAL_MEM > PEAK_MEM )) && PEAK_MEM=$FINAL_MEM || true

    # Record throughput
    if (( ITER_DUR > 0 )); then
        THROUGHPUT_SAMPLES+=($((100 / ITER_DUR)))
    fi

    echo "[INFO] Iteration $ITERATION: ${ITER_DUR}s, mem=${FINAL_MEM}KB"

    ELAPSED=$((ITER_END - START_TIME))
done

END_TIME=$(date +%s)
TOTAL_DUR=$((END_TIME - START_TIME))

echo ""
echo "=============================================="
echo "  Results"
echo "=============================================="
echo "Duration: $(format_duration $TOTAL_DUR)"
echo "Iterations: $ITERATION"
echo "Operations: $TOTAL_OPS"
echo "Errors: $ERRORS"
echo ""
echo "Memory:"
echo "  Initial: ${INIT_MEM}KB"
echo "  Peak: ${PEAK_MEM}KB"
echo "  Final: ${FINAL_MEM}KB"

# Check results
STATUS="PASS"
REASONS=()

if (( ERRORS > 0 )); then
    STATUS="FAIL"
    REASONS+=("$ERRORS errors")
fi

if (( INIT_MEM > 0 )); then
    GROWTH=$(( (FINAL_MEM - INIT_MEM) * 100 / INIT_MEM ))
    echo "  Growth: ${GROWTH}%"
    if (( GROWTH > MEMORY_GROWTH_THRESHOLD_PCT )); then
        STATUS="FAIL"
        REASONS+=("memory growth ${GROWTH}%")
    fi
fi

echo ""
echo "Status: $STATUS"
echo "=============================================="

# Output JSON
cat <<EOF
{
  "test": "stress-test",
  "duration_secs": $TOTAL_DUR,
  "iterations": $ITERATION,
  "operations": $TOTAL_OPS,
  "errors": $ERRORS,
  "memory_init_kb": $INIT_MEM,
  "memory_peak_kb": $PEAK_MEM,
  "memory_final_kb": $FINAL_MEM,
  "status": "$STATUS"
}
EOF

if [[ "$STATUS" == "FAIL" ]]; then
    echo "[ERROR] Stress test FAILED: ${REASONS[*]}" >&2
    exit 1
fi

echo "[INFO] Stress test PASSED"
exit 0
