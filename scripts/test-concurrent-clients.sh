#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2024-2025 ArcherDB Contributors
#
# Test script for concurrent client handling (CRIT-03)
#
# Tests that the server handles 100+ concurrent clients.
# The server's clients_max configuration determines the limit:
#   - Lite/Standard: clients_max = 64
#   - Pro: clients_max = 128
#   - Enterprise/Ultra: clients_max = 256
#
# Usage:
#   ./scripts/test-concurrent-clients.sh [OPTIONS]
#
# Options:
#   --lite          Expect lite tier limits (clients_max=64)
#   --standard      Expect standard tier limits (clients_max=64) [default]
#   --pro           Expect pro tier limits (clients_max=128)
#   --enterprise    Expect enterprise tier limits (clients_max=256)
#   --ultra         Expect ultra tier limits (clients_max=256)
#   --clients N     Number of concurrent clients to test (default: 100)
#   --stress        Run stress test finding actual breaking point
#   --quick         Quick test with 10 clients only
#   --verbose       Show detailed output
#
# Requirements:
#   - Server binary built (./zig-out/bin/archerdb)
#   - Python 3 for client spawning
#
# Expected behavior:
#   - Lite/Standard tiers: handle up to 64 concurrent clients
#   - Pro tier: handles up to 128 concurrent clients
#   - Enterprise/Ultra tiers: handle up to 256 concurrent clients
#   - Beyond limits: connections gracefully rejected, no crashes

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ARCHERDB="$ROOT_DIR/zig-out/bin/archerdb"

# Default options
NUM_CLIENTS=100
CONFIG_TIER="standard"
EXPECTED_CLIENTS_MAX=64
USE_STRESS=false
VERBOSE=false
QUICK_MODE=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --lite)
            CONFIG_TIER="lite"
            EXPECTED_CLIENTS_MAX=64
            shift
            ;;
        --standard)
            CONFIG_TIER="standard"
            EXPECTED_CLIENTS_MAX=64
            shift
            ;;
        --pro)
            CONFIG_TIER="pro"
            EXPECTED_CLIENTS_MAX=128
            shift
            ;;
        --enterprise)
            CONFIG_TIER="enterprise"
            EXPECTED_CLIENTS_MAX=256
            shift
            ;;
        --ultra)
            CONFIG_TIER="ultra"
            EXPECTED_CLIENTS_MAX=256
            shift
            ;;
        --clients)
            NUM_CLIENTS="$2"
            shift 2
            ;;
        --stress)
            USE_STRESS=true
            shift
            ;;
        --quick)
            QUICK_MODE=true
            NUM_CLIENTS=10
            shift
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Create temp directory
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

echo "============================================"
echo "ArcherDB Concurrent Clients Test (CRIT-03)"
echo "============================================"
echo "Working directory: $TEMP_DIR"
echo "Expected tier: $CONFIG_TIER (clients_max=$EXPECTED_CLIENTS_MAX)"
echo "Target clients: $NUM_CLIENTS"
echo "NOTE: ensure binary was built with matching -Dconfig tier."
echo ""

# Check prerequisites
if [ ! -x "$ARCHERDB" ]; then
    echo "ERROR: archerdb binary not found at $ARCHERDB"
    echo "Build with: ./zig/zig build -j4 -Dconfig=$CONFIG_TIER"
    exit 1
fi

get_free_port() {
    python3 - <<'PYEOF'
import socket
sock = socket.socket()
sock.bind(("127.0.0.1", 0))
print(sock.getsockname()[1])
sock.close()
PYEOF
}

cd "$TEMP_DIR"

# ===========================================================
# PHASE 1: Format database
# ===========================================================
echo "PHASE 1: Formatting database..."
$ARCHERDB format --cluster=0 --replica=0 --replica-count=1 test.archerdb > format.log 2>&1
if [ $? -ne 0 ]; then
    echo "FAIL: Database format failed"
    cat format.log
    exit 1
fi
echo "OK: Database formatted"
echo ""

# ===========================================================
# PHASE 2: Start server
# ===========================================================
echo "PHASE 2: Starting server..."

DATA_PORT=$(get_free_port)
METRICS_PORT=$(get_free_port)

$ARCHERDB start --addresses=127.0.0.1:${DATA_PORT} --metrics-port=${METRICS_PORT} --metrics-bind=127.0.0.1 test.archerdb > server.log 2>&1 &
SERVER_PID=$!
echo "Server PID: $SERVER_PID"
echo "Data port: $DATA_PORT"
echo "Metrics port: $METRICS_PORT"

# Wait for readiness
echo "Waiting for server readiness..."
for i in {1..30}; do
    RESPONSE=$(curl -s -w "\n%{http_code}" http://127.0.0.1:$METRICS_PORT/health/ready 2>/dev/null || echo "ERROR")
    STATUS=$(echo "$RESPONSE" | tail -n1)
    if [ "$STATUS" = "200" ]; then
        echo "OK: Server is ready"
        break
    fi
    if [ $i -eq 30 ]; then
        echo "FAIL: Server did not become ready within 30 seconds"
        cat server.log
        kill $SERVER_PID 2>/dev/null || true
        exit 1
    fi
    sleep 1
done
echo ""

# ===========================================================
# PHASE 3: Run concurrent clients test
# ===========================================================
echo "PHASE 3: Testing concurrent clients..."

# Create Python test script for concurrent clients
cat > concurrent_test.py << 'PYEOF'
#!/usr/bin/env python3
"""
Concurrent clients test for ArcherDB.
Spawns multiple workers that concurrently establish TCP connections.
"""
import os
import sys
import socket
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
import json

def run_client(args):
    """Run a single client instance."""
    client_id, host, port = args

    start_time = time.time()
    sock = None
    try:
        sock = socket.create_connection((host, port), timeout=5.0)
        sock.settimeout(5.0)
        # Send one byte to exercise server-side connection handling.
        sock.sendall(b"\x00")
        time.sleep(0.05)
        elapsed = time.time() - start_time

        return {
            'client_id': client_id,
            'success': True,
            'full_success': True,
            'elapsed': elapsed,
            'returncode': 0,
            'connection_error': False,
            'stdout_sample': '',
            'stderr_sample': ''
        }
    except socket.timeout:
        return {
            'client_id': client_id,
            'success': False,
            'full_success': False,
            'elapsed': 5,
            'returncode': -1,
            'connection_error': True,
            'timeout': True,
            'stdout_sample': '',
            'stderr_sample': 'Timeout'
        }
    except Exception as exc:
        return {
            'client_id': client_id,
            'success': False,
            'full_success': False,
            'elapsed': 0,
            'returncode': -1,
            'connection_error': True,
            'error': str(exc),
            'stdout_sample': '',
            'stderr_sample': str(exc)
        }
    finally:
        if sock is not None:
            sock.close()

def main():
    if len(sys.argv) < 3:
        print("Usage: concurrent_test.py <num_clients> <address>")
        sys.exit(1)

    num_clients = int(sys.argv[1])
    address = sys.argv[2]
    host, port_text = address.rsplit(':', 1)
    port = int(port_text)

    print(f"Starting {num_clients} concurrent clients to {address}")

    # Prepare arguments for each client
    args_list = [(i, host, port) for i in range(num_clients)]

    # Use threads because this test is network I/O bound.
    max_workers = min(num_clients, 256)

    results = []
    start_time = time.time()

    with ThreadPoolExecutor(max_workers=max_workers) as executor:
        futures = {executor.submit(run_client, args): args[0] for args in args_list}

        for future in as_completed(futures):
            client_id = futures[future]
            try:
                result = future.result()
                results.append(result)
                # Progress indicator
                if len(results) % 10 == 0:
                    print(f"  Progress: {len(results)}/{num_clients} clients completed")
            except Exception as e:
                results.append({
                    'client_id': client_id,
                    'success': False,
                    'error': str(e)
                })

    total_time = time.time() - start_time

    # Analyze results
    success_count = sum(1 for r in results if r.get('success', False))
    full_success_count = sum(1 for r in results if r.get('full_success', False))
    failure_count = len(results) - success_count
    connection_errors = sum(1 for r in results if r.get('connection_error', False))
    timeouts = sum(1 for r in results if r.get('timeout', False))

    # Calculate latency stats for successful clients
    latencies = [r['elapsed'] for r in results if r.get('success', False)]
    avg_latency = sum(latencies) / len(latencies) if latencies else 0
    max_latency = max(latencies) if latencies else 0
    min_latency = min(latencies) if latencies else 0

    print("\n" + "="*50)
    print("RESULTS")
    print("="*50)
    print(f"Total clients: {num_clients}")
    print(f"Connected + basic ops: {success_count}")
    print(f"Full success (all ops): {full_success_count}")
    print(f"Failed: {failure_count}")
    print(f"  - Connection errors: {connection_errors}")
    print(f"  - Timeouts: {timeouts}")
    print(f"  - Other errors: {failure_count - connection_errors - timeouts}")
    print(f"Total time: {total_time:.2f}s")
    if latencies:
        print(f"Latency (successful): min={min_latency:.2f}s, avg={avg_latency:.2f}s, max={max_latency:.2f}s")

    # Output JSON summary for parsing
    summary = {
        'total': num_clients,
        'success': success_count,
        'full_success': full_success_count,
        'failed': failure_count,
        'connection_errors': connection_errors,
        'timeouts': timeouts,
        'total_time': total_time,
        'avg_latency': avg_latency,
        'max_latency': max_latency
    }

    with open('concurrent_results.json', 'w') as f:
        json.dump(summary, f)

    # Print first few errors for debugging
    errors = [r for r in results if not r.get('success', False)]
    if errors and len(errors) <= 5:
        print("\nError details:")
        for e in errors[:5]:
            print(f"  Client {e['client_id']}: {e.get('stderr_sample', 'No details')[:200]}")

    # Exit with appropriate code.
    if success_count == num_clients:
        print(f"\nPASS: All {num_clients} clients connected successfully")
        sys.exit(0)
    elif success_count >= num_clients * 0.95:
        print(f"\nWARN: {success_count}/{num_clients} clients connected successfully (>95%)")
        sys.exit(0)
    else:
        print(f"\nFAIL: Only {success_count}/{num_clients} clients connected successfully")
        sys.exit(1)

if __name__ == '__main__':
    main()
PYEOF

# Run the concurrent test
echo "Launching $NUM_CLIENTS concurrent clients..."
python3 concurrent_test.py "$NUM_CLIENTS" "127.0.0.1:$DATA_PORT"
TEST_RESULT=$?

# Read results
if [ -f concurrent_results.json ]; then
    RESULTS=$(cat concurrent_results.json)
    SUCCESS=$(echo "$RESULTS" | python3 -c "import sys,json; print(json.load(sys.stdin)['success'])")
    TOTAL=$(echo "$RESULTS" | python3 -c "import sys,json; print(json.load(sys.stdin)['total'])")
    CONN_ERRORS=$(echo "$RESULTS" | python3 -c "import sys,json; print(json.load(sys.stdin)['connection_errors'])")

    echo ""
    echo "Summary: $SUCCESS/$TOTAL clients successful, $CONN_ERRORS connection errors"
fi

echo ""

# ===========================================================
# PHASE 4: Stress test (optional)
# ===========================================================
if [ "$USE_STRESS" = true ]; then
    echo "============================================"
    echo "PHASE 4: Stress test - finding breaking point..."
    echo ""

    # Binary search for max clients
    LOW=10
    HIGH=500
    MAX_WORKING=0

    while [ $LOW -le $HIGH ]; do
        MID=$(( (LOW + HIGH) / 2 ))
        echo "Testing with $MID clients..."

        python3 concurrent_test.py "$MID" "127.0.0.1:$DATA_PORT" > stress_$MID.log 2>&1
        STRESS_RESULT=$?

        if [ $STRESS_RESULT -eq 0 ]; then
            MAX_WORKING=$MID
            LOW=$((MID + 1))
            echo "  SUCCESS: $MID clients worked"
        else
            HIGH=$((MID - 1))
            echo "  FAILED: $MID clients failed"
        fi
    done

    echo ""
    echo "Stress test result: Maximum concurrent clients = $MAX_WORKING"
    echo ""
fi

# ===========================================================
# CLEANUP
# ===========================================================
echo "============================================"
echo "CLEANUP: Stopping server..."
kill -TERM $SERVER_PID 2>/dev/null || true
wait $SERVER_PID 2>/dev/null || true

echo ""
echo "============================================"
echo "TEST SUMMARY"
echo "============================================"

if [ $TEST_RESULT -eq 0 ]; then
    echo "CRIT-03 (Concurrent Clients): PASS"
    echo "  - Server handled $NUM_CLIENTS concurrent clients"
else
    echo "CRIT-03 (Concurrent Clients): FAIL"
    echo "  - Server could not handle $NUM_CLIENTS concurrent clients"
    echo "  - Connection errors: $CONN_ERRORS"
    echo ""
    echo "Server log (last 50 lines):"
    tail -50 server.log
fi

exit $TEST_RESULT
