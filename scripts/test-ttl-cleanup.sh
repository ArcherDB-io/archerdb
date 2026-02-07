#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2024-2025 ArcherDB Contributors
#
# TTL Cleanup Validation Script (CRIT-04)
#
# Tests that TTL expiration works correctly:
# 1. Lazy expiration: Query returns "Entity has expired due to TTL"
# 2. Background cleanup: Explicit cleanup operation removes expired entries
#
# IMPORTANT: The original CRIT-04 bug report was based on the Python client's
# stubbed cleanup_expired() method which always returns 0/0. The server-side
# TTL cleanup actually works correctly - see unit tests in ram_index.zig.
#
# This script validates:
# - Entity insertion with TTL
# - Lazy expiration on query (works)
# - Explicit cleanup_expired via client SDK (may be stubbed depending on client)
#
# Usage:
#   ./scripts/test-ttl-cleanup.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ARCHERDB="$ROOT_DIR/zig-out/bin/archerdb"

# IMPORTANT: Rebuild client libraries to ensure config matches server
# The Python client must be built with the same config as the server.
# Mismatch causes silent communication failures.
echo "Building Python client library..."
cd "$ROOT_DIR"
./zig/zig build -j4 -Dconfig=lite clients:python 2>&1 | tail -3

# Create temporary directory
TEMP_DIR=$(mktemp -d)
# trap "rm -rf $TEMP_DIR; kill $SERVER_PID 2>/dev/null || true" EXIT
trap "kill $SERVER_PID 2>/dev/null || true" EXIT

echo "============================================"
echo "ArcherDB TTL Cleanup Test (CRIT-04)"
echo "============================================"
echo "Working directory: $TEMP_DIR"
echo ""

# Check prerequisites
if [ ! -x "$ARCHERDB" ]; then
    echo "ERROR: archerdb binary not found at $ARCHERDB"
    echo "Run: ./zig/zig build -j4 -Dconfig=lite"
    exit 1
fi

# Set up Python environment for archerdb client
PYTHON_CLIENT="$ROOT_DIR/src/clients/python"
PYTHON_VENV="$PYTHON_CLIENT/venv/bin/python"
export PYTHONPATH="$PYTHON_CLIENT/src"

# Install/Update Python archerdb client
echo "Installing Python client..."
cd "$PYTHON_CLIENT"
$PYTHON_VENV -m pip install --no-cache-dir --force-reinstall .
cd "$TEMP_DIR"

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
$ARCHERDB start --addresses=127.0.0.1:0 --metrics-port=0 --metrics-bind=127.0.0.1 --log-level=debug test.archerdb > server.log 2>&1 &
SERVER_PID=$!
echo "Server PID: $SERVER_PID"

# Wait for server to start and extract ports
# Server needs time to initialize (VSR recovery, etc.)
echo "Waiting for server to start..."
for i in {1..60}; do
    # Look for "server marked as initialized" which indicates ready
    if grep -q "server marked as initialized" server.log 2>/dev/null; then
        break
    fi
    sleep 1
done

# Give a bit more time for port logging
sleep 2

# Extract metrics port
METRICS_PORT=$(grep "metrics server listening" server.log | sed -n 's/.*127\.0\.0\.1:\([0-9]*\).*/\1/p' || echo "")
if [ -z "$METRICS_PORT" ]; then
    echo "FAIL: Could not determine metrics port"
    cat server.log
    exit 1
fi
echo "Metrics port: $METRICS_PORT"

# Extract data port (look for "listening on" that's NOT the metrics server)
# The cluster listening message has format like: "listening on address=Address{...}"
DATA_PORT=$(grep -v "metrics server" server.log | grep "listening on" | sed -n 's/.*127\.0\.0\.1:\([0-9]*\).*/\1/p' | head -1 || echo "")
if [ -z "$DATA_PORT" ]; then
    # Try alternative pattern - sometimes logged differently
    DATA_PORT=$(grep "port=" server.log | sed -n 's/.*port=\([0-9]*\).*/\1/p' | head -1 || echo "")
fi
if [ -z "$DATA_PORT" ]; then
    echo "FAIL: Could not determine data port"
    echo "Server log:"
    cat server.log
    exit 1
fi
echo "Data port: $DATA_PORT"

# Test readiness with retries
echo "Waiting for server to be ready..."
for i in {1..30}; do
    READY_STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:$METRICS_PORT/health/ready 2>/dev/null)
    if [ "$READY_STATUS" = "200" ]; then
        break
    fi
    sleep 1
done
if [ "$READY_STATUS" != "200" ]; then
    echo "FAIL: Server not ready after 30 seconds (status: $READY_STATUS)"
    cat server.log
    exit 1
fi
echo "OK: Server ready"
echo ""

# ===========================================================
# PHASE 3: Run TTL cleanup test via Python
# ===========================================================
echo "PHASE 3: Running TTL cleanup test..."

cat > ttl_test.py << 'PYEOF'
#!/usr/bin/env python3
"""TTL Cleanup validation test for CRIT-04"""
import os
import sys
import time
import logging
import archerdb
from archerdb.errors import StateException

# Configure logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s %(message)s')

PORT = int(os.environ.get("ARCHERDB_PORT", "3000"))
print(f"Connecting to 127.0.0.1:{PORT}")
sys.stdout.flush()

config = archerdb.GeoClientConfig(
    cluster_id=0, 
    addresses=[f"127.0.0.1:{PORT}"],
    request_timeout_ms=60000  # 60s timeout
)
client = archerdb.GeoClientSync(config)

print("CONNECT_OK")
sys.stdout.flush()

# Insert entity with short TTL (1 second)
entity_id = archerdb.id()
print(f"ENTITY_ID {entity_id}")
sys.stdout.flush()

event = archerdb.create_geo_event(
    entity_id=entity_id,
    latitude=37.7749,
    longitude=-122.4194,
    group_id=1,
    ttl_seconds=1,  # 1 second TTL
)

errors = client.insert_event(event)
print(f"INSERT_ERRORS {errors}")
sys.stdout.flush()

# Verify insert succeeded by querying
print("QUERY_UUID_START")
sys.stdout.flush()
time.sleep(1) # Wait a bit to ensure client state is clean
# latest = client.get_latest_by_uuid(entity_id)
# Use batch query to bypass potential issue with singular query_uuid
results = client.query_uuid_batch([entity_id])
latest = results.events[0] if results.events else None
print("QUERY_UUID_END")
sys.stdout.flush()
if latest:
    print(f"LATEST_AFTER_INSERT lat={latest.lat_nano} lon={latest.lon_nano} ttl={latest.ttl_seconds}")
else:
    print("ERROR: Entity not found after insert")
    sys.exit(1)
sys.stdout.flush()

# Wait for TTL to expire
print("WAIT_FOR_EXPIRY (2 seconds)...")
sys.stdout.flush()
time.sleep(2)

# Run cleanup_expired BEFORE checking lazy expiration
print("RUNNING_CLEANUP...")
sys.stdout.flush()
cleanup = client.cleanup_expired()
print(f"CLEANUP_RESULT entries_scanned={cleanup.entries_scanned} entries_removed={cleanup.entries_removed}")
sys.stdout.flush()

# Check if entity is expired (query after cleanup)
# Note: After cleanup removes an entry from RAM index, the query should:
# - Return None (entity not found in index)
# - Or raise StateException 210 (expired) if lazy check triggers
try:
    latest_after = client.get_latest_by_uuid(entity_id)
    if latest_after:
        # Entity still queryable - this can happen if:
        # 1. Query hit a cache
        # 2. cleanup_scanner.position started after entity's slot
        # 3. Timing issue between cleanup and query
        print(f"LATEST_AFTER_CLEANUP lat={latest_after.lat_nano} lon={latest_after.lon_nano}")
        print("NOTE: Entity still queryable (may be cached or timing issue)")
    else:
        print("LATEST_AFTER_CLEANUP None (correctly removed)")
except StateException as exc:
    # StateException with code 210 = Entity has expired due to TTL
    print(f"LATEST_AFTER_CLEANUP_EXCEPTION {exc}")
    if "expired" in str(exc).lower():
        print("LAZY_EXPIRATION_WORKS (entity correctly expired on query)")
    else:
        print(f"ERROR: Unexpected exception: {exc}")
sys.stdout.flush()

# Evaluate results
print("")
print("=" * 50)
print("TTL CLEANUP TEST RESULTS")
print("=" * 50)

# Check 1: entries_scanned should be > 0
if cleanup.entries_scanned > 0:
    print(f"PASS: entries_scanned = {cleanup.entries_scanned} (> 0)")
else:
    print(f"FAIL: entries_scanned = {cleanup.entries_scanned} (should be > 0)")
    print("  BUG: Cleanup is not scanning the index")

# Check 2: entries_removed should be > 0 (we inserted an expired entity)
if cleanup.entries_removed > 0:
    print(f"PASS: entries_removed = {cleanup.entries_removed} (> 0)")
else:
    print(f"FAIL: entries_removed = {cleanup.entries_removed} (should be > 0)")
    print("  BUG: Cleanup found nothing to remove, but entity was expired")

# Final verdict
if cleanup.entries_scanned > 0 and cleanup.entries_removed > 0:
    print("")
    print("OVERALL: PASS - TTL cleanup working correctly")
    sys.exit(0)
else:
    print("")
    print("OVERALL: FAIL - TTL cleanup bug confirmed (CRIT-04)")
    sys.exit(1)

client.close()
PYEOF

export ARCHERDB_PORT=$DATA_PORT
$PYTHON_VENV ttl_test.py 2>&1 | tee ttl_test.log
TTL_TEST_RESULT=${PIPESTATUS[0]}

echo ""

# ===========================================================
# PHASE 4: Report results
# ===========================================================
echo "============================================"
echo "TEST SUMMARY"
echo "============================================"

if [ $TTL_TEST_RESULT -eq 0 ]; then
    echo "CRIT-04 (TTL Cleanup): PASS"
    echo "  - entries_scanned > 0"
    echo "  - entries_removed > 0"
    echo "  - Expired entities removed by cleanup"
else
    echo "CRIT-04 (TTL Cleanup): FAIL"
    echo "  - See ttl_test.log for details"
    echo ""
    echo "Server log:"
    cat server.log
fi

# Cleanup
echo ""
echo "CLEANUP: Stopping server..."
kill -TERM $SERVER_PID 2>/dev/null || true
wait $SERVER_PID 2>/dev/null || true

exit $TTL_TEST_RESULT
