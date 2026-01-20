#!/usr/bin/env bash
# Run VOPR simulations with multiple seeds and optional integration tests.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ZIG_BIN="$PROJECT_ROOT/zig/zig"

SEEDS=${SEEDS:-"42 97 123"}
REQUESTS_MAX=${REQUESTS_MAX:-200}
STATE_MACHINE=${STATE_MACHINE:-testing}
INTEGRATION=false
LITE_ARGS=("--lite")

usage() {
  echo "Usage: $0 [--seeds \"1 2 3\"] [--requests-max N] [--no-lite] [--integration]"
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

echo "Running VOPR simulations (state_machine=$STATE_MACHINE, requests_max=$REQUESTS_MAX)"
for seed in $SEEDS; do
  echo "--- Seed $seed ---"
  "$ZIG_BIN" build vopr -Dvopr-state-machine="$STATE_MACHINE" -- "${LITE_ARGS[@]}" --requests-max="$REQUESTS_MAX" "$seed"
  echo ""
done

if [[ "$INTEGRATION" == "true" ]]; then
  echo "Running integration tests"
  "$ZIG_BIN" build test:integration
fi
