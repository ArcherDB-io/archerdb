#!/usr/bin/env bash
# Run VOPR simulations with multiple seeds and optional integration tests.
#
# Usage:
#   ./scripts/run_vopr.sh                     # Run with default seeds
#   ./scripts/run_vopr.sh --replay 42         # Replay seed 42 in Debug mode
#   ./scripts/run_vopr.sh --dump-on-fail      # Dump decision history on failure
#   ./scripts/run_vopr.sh --crash-rate 1      # Set crash rate to 1%
#   ./scripts/run_vopr.sh --replicas 5        # Use 5-replica cluster

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ZIG_BIN="$PROJECT_ROOT/zig/zig"

SEEDS=${SEEDS:-"42 97 123"}
REQUESTS_MAX=${REQUESTS_MAX:-200}
STATE_MACHINE=${STATE_MACHINE:-testing}
INTEGRATION=false
LITE_ARGS=("--lite")
REPLAY_SEED=""
DUMP_ON_FAIL=false
CRASH_RATE=""
REPLICAS=""
REPLAY_FROM_TICK=""

usage() {
  echo "Usage: $0 [options]"
  echo ""
  echo "Options:"
  echo "  --seeds \"1 2 3\"       Seeds to test (default: 42 97 123)"
  echo "  --requests-max N       Max requests per run (default: 200)"
  echo "  --no-lite              Run full swarm mode instead of lite"
  echo "  --integration          Run integration tests after VOPR"
  echo "  --replay SEED          Replay specific seed in Debug mode for debugging"
  echo "  --replay-from-tick N   Skip to tick N when replaying"
  echo "  --dump-on-fail         Dump decision history on failure"
  echo "  --crash-rate N         Set crash rate percentage (0-100)"
  echo "  --replicas N           Number of replicas (1-6)"
  echo ""
  echo "Environment overrides:"
  echo "  SEEDS=\"42 97 123\""
  echo "  REQUESTS_MAX=200"
  echo "  STATE_MACHINE=testing"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --seeds)
      SEEDS="$2"
      shift 2
      ;;
    --requests-max)
      REQUESTS_MAX="$2"
      shift 2
      ;;
    --no-lite)
      LITE_ARGS=()
      shift
      ;;
    --integration)
      INTEGRATION=true
      shift
      ;;
    --replay)
      REPLAY_SEED="$2"
      shift 2
      ;;
    --replay-from-tick)
      REPLAY_FROM_TICK="$2"
      shift 2
      ;;
    --dump-on-fail)
      DUMP_ON_FAIL=true
      shift
      ;;
    --crash-rate)
      CRASH_RATE="$2"
      shift 2
      ;;
    --replicas)
      REPLICAS="$2"
      shift 2
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

if [[ ! -x "$ZIG_BIN" ]]; then
  echo "Error: zig binary not found at $ZIG_BIN"
  echo "Run: ./zig/zig build"
  exit 1
fi

# Build extra args based on options
EXTRA_ARGS=()
if [[ "$DUMP_ON_FAIL" == "true" ]]; then
  EXTRA_ARGS+=("--dump-on-fail")
fi
if [[ -n "$CRASH_RATE" ]]; then
  EXTRA_ARGS+=("--crash-rate=$CRASH_RATE")
fi
if [[ -n "$REPLICAS" ]]; then
  EXTRA_ARGS+=("--replicas=$REPLICAS")
fi

# Replay mode: run single seed with verbose logging for debugging
if [[ -n "$REPLAY_SEED" ]]; then
  echo "REPLAY MODE: Replaying seed $REPLAY_SEED with full logging"
  REPLAY_ARGS=("--replay")
  if [[ -n "$REPLAY_FROM_TICK" ]]; then
    REPLAY_ARGS+=("--replay-from-tick=$REPLAY_FROM_TICK")
  fi
  # Note: Use -Dvopr-log=full for maximum debug output
  "$ZIG_BIN" build vopr -Dvopr-state-machine="$STATE_MACHINE" -Dvopr-log=full -- \
    ${LITE_ARGS[@]+"${LITE_ARGS[@]}"} --requests-max="$REQUESTS_MAX" "${REPLAY_ARGS[@]}" ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} "$REPLAY_SEED"
  exit $?
fi

echo "Running VOPR simulations (state_machine=$STATE_MACHINE, requests_max=$REQUESTS_MAX)"
for seed in $SEEDS; do
  echo "--- Seed $seed ---"
  "$ZIG_BIN" build vopr -Dvopr-state-machine="$STATE_MACHINE" -- ${LITE_ARGS[@]+"${LITE_ARGS[@]}"} --requests-max="$REQUESTS_MAX" ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} "$seed"
  echo ""
done

if [[ "$INTEGRATION" == "true" ]]; then
  echo "Running integration tests"
  "$ZIG_BIN" build test:integration
fi
