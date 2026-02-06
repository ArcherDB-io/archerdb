#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 ArcherDB Contributors
#
# Unified SDK Test Runner
# Executes operation tests for all ArcherDB SDKs against a running server.

set -e  # Fail fast on first error (per CONTEXT.md decision)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export PROJECT_ROOT

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Counters
PASSED=0
FAILED=0
SKIPPED=0

# SDK execution order per CONTEXT.md decision
SDKS=("python" "node" "go" "java" "c")

# Parse arguments
FILTER=""
VERBOSE=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --filter=*)
            FILTER="${1#*=}"
            shift
            ;;
        --filter)
            FILTER="$2"
            shift 2
            ;;
        -v|--verbose)
            VERBOSE="-v"
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--filter=sdk1,sdk2] [-v|--verbose]"
            exit 1
            ;;
    esac
done

# Filter SDKs if requested
if [[ -n "$FILTER" ]]; then
    IFS=',' read -ra FILTERED <<< "$FILTER"
    SDKS=("${FILTERED[@]}")
fi

print_header() {
    echo ""
    echo "========================================"
    echo "$1"
    echo "========================================"
}

print_result() {
    local sdk=$1
    local status=$2
    local duration=$3
    local duration_msg=""
    if [[ -z "$duration" && -n "$SDK_START" ]]; then
        duration=$(( $(date +%s) - SDK_START ))
    fi
    if [[ -n "$duration" ]]; then
        duration_msg=" (${duration}s)"
    fi
    if [[ "$status" == "PASSED" ]]; then
        echo -e "${GREEN}$sdk SDK: PASSED${NC}${duration_msg}"
        ((PASSED+=1))
    elif [[ "$status" == "FAILED" ]]; then
        echo -e "${RED}$sdk SDK: FAILED${NC}${duration_msg}"
        ((FAILED+=1))
    else
        echo -e "${YELLOW}$sdk SDK: SKIPPED${NC}${duration_msg}"
        ((SKIPPED+=1))
    fi
}

run_with_cluster() {
    local cmd="$1"
    CMD="$cmd" python3 - <<'PY'
import os
import subprocess
import sys
from pathlib import Path

project_root = Path(os.environ.get("PROJECT_ROOT", ".")).resolve()
sys.path.insert(0, str(project_root))

from test_infrastructure.harness.cluster import ArcherDBCluster, ClusterConfig

cmd = os.environ["CMD"]
cluster = ArcherDBCluster(ClusterConfig(node_count=1, base_port=0))
try:
    cluster.start()
    if not cluster.wait_for_ready(timeout=60):
        print("Cluster failed to become ready")
        cluster.stop()
        sys.exit(1)
    leader_port = cluster.wait_for_leader(timeout=30)
    if not leader_port:
        print("Cluster leader not found")
        cluster.stop()
        sys.exit(1)
    env = os.environ.copy()
    env["ARCHERDB_ADDRESS"] = f"127.0.0.1:{leader_port}"
    sys.exit(subprocess.call(cmd, shell=True, env=env))
finally:
    try:
        cluster.stop()
    except Exception:
        pass
PY
}

# Build ArcherDB first
print_header "Building ArcherDB..."
if ! "$PROJECT_ROOT/zig/zig" build -j4 -Dconfig=lite; then
    echo -e "${RED}Build failed!${NC}"
    exit 1
fi
echo -e "${GREEN}Build successful${NC}"

# Run tests for each SDK
for sdk in "${SDKS[@]}"; do
    print_header "Testing $sdk SDK..."
    SDK_START=$(date +%s)

    case $sdk in
        python)
            if [[ -f "$SCRIPT_DIR/python/test_all_operations.py" ]]; then
                cd "$PROJECT_ROOT"
                echo "Building Python client library..."
                if ! "$PROJECT_ROOT/zig/zig" build -j4 -Dconfig=lite clients:python; then
                    print_result "$sdk" "FAILED"
                    continue
                fi
                export ARCHERDB_INTEGRATION=1
                export PYTHONPATH="$PROJECT_ROOT:$PROJECT_ROOT/src/clients/python/src:$PYTHONPATH"
                if pytest "tests/sdk_tests/python/test_all_operations.py" $VERBOSE --tb=short; then
                    print_result "$sdk" "PASSED"
                else
                    print_result "$sdk" "FAILED"
                fi
            else
                print_result "$sdk" "SKIPPED"
            fi
            ;;
        node)
            if [[ -f "$SCRIPT_DIR/node/package.json" ]]; then
                cd "$SCRIPT_DIR/node"
                echo "Building Node client library..."
                if ! "$PROJECT_ROOT/zig/zig" build -j4 -Dconfig=lite clients:node; then
                    print_result "$sdk" "FAILED"
                    continue
                fi
                if [[ ! -d "node_modules" ]]; then
                    npm install --silent
                fi
                export ARCHERDB_INTEGRATION=1
                if npm test; then
                    print_result "$sdk" "PASSED"
                else
                    print_result "$sdk" "FAILED"
                fi
            else
                print_result "$sdk" "SKIPPED"
            fi
            ;;
        go)
            if [[ -f "$PROJECT_ROOT/tests/sdk_tests/go/all_operations_test.go" ]]; then
                cd "$PROJECT_ROOT/tests/sdk_tests/go"
                export ARCHERDB_INTEGRATION=1
                if run_with_cluster "go test -v ./... -count=1"; then
                    print_result "$sdk" "PASSED"
                else
                    print_result "$sdk" "FAILED"
                fi
            else
                print_result "$sdk" "SKIPPED"
            fi
            ;;
        java)
            if [[ -f "$PROJECT_ROOT/tests/sdk_tests/java/src/test/java/com/archerdb/sdktests/AllOperationsTest.java" ]]; then
                echo "Building Java native client..."
                if ! "$PROJECT_ROOT/zig/zig" build -j4 -Dconfig=lite clients:java; then
                    print_result "$sdk" "FAILED"
                    continue
                fi
                echo "Building Java SDK..."
                if ! (cd "$PROJECT_ROOT/src/clients/java" && mvn -q -DskipTests -Dmaven.javadoc.skip=true install); then
                    print_result "$sdk" "FAILED"
                    continue
                fi
                cd "$PROJECT_ROOT/tests/sdk_tests/java"
                export ARCHERDB_INTEGRATION=1
                if run_with_cluster "mvn test -Dtest=AllOperationsTest -q"; then
                    print_result "$sdk" "PASSED"
                else
                    print_result "$sdk" "FAILED"
                fi
            else
                print_result "$sdk" "SKIPPED"
            fi
            ;;
        c)
            if [[ -f "$SCRIPT_DIR/c/test_all_operations.c" ]]; then
                cd "$SCRIPT_DIR/c"
                echo "Building C SDK tests..."
                export ARCHERDB_INTEGRATION=1
                if "$PROJECT_ROOT/zig/zig" build; then
                    echo "Running C SDK tests..."
                    if run_with_cluster "./zig-out/bin/test_all_operations"; then
                        print_result "$sdk" "PASSED"
                    else
                        print_result "$sdk" "FAILED"
                    fi
                else
                    echo "C SDK build failed"
                    print_result "$sdk" "FAILED"
                fi
            else
                print_result "$sdk" "SKIPPED"
            fi
            ;;
        *)
            echo "Unknown SDK: $sdk"
            print_result "$sdk" "SKIPPED"
            ;;
    esac
done

# Final summary
print_header "Test Summary"
echo -e "Passed:  ${GREEN}$PASSED${NC}"
echo -e "Failed:  ${RED}$FAILED${NC}"
echo -e "Skipped: ${YELLOW}$SKIPPED${NC}"
echo ""

if [[ $FAILED -gt 0 ]]; then
    echo -e "${RED}SOME TESTS FAILED${NC}"
    exit 1
else
    echo -e "${GREEN}ALL TESTS PASSED${NC}"
    exit 0
fi
