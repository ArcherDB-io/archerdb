#!/bin/bash
# Quick validation script for readiness probe fix
# Tests that /health/ready returns 200 OK after server initialization

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ARCHERDB="$ROOT_DIR/zig-out/bin/archerdb"
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

echo "=== Validating Readiness Probe Fix ==="
echo "Working directory: $TEMP_DIR"
cd "$TEMP_DIR"

# Format database
echo "Formatting database..."
$ARCHERDB format --cluster=0 --replica=0 --replica-count=1 test.archerdb > /dev/null 2>&1

# Start server
echo "Starting server..."
$ARCHERDB start --addresses=127.0.0.1:0 --metrics-port=0 --metrics-bind=127.0.0.1 --development test.archerdb > server.log 2>&1 &
SERVER_PID=$!
echo "Server PID: $SERVER_PID"

# Give server time to start
sleep 2

# Extract metrics port from log (portable: avoid grep -P).
METRICS_PORT=$(sed -n 's/.*metrics server listening.*127\.0\.0\.1:\([0-9][0-9]*\).*/\1/p' server.log | awk 'NR==1{print; exit}')
echo "Metrics port: $METRICS_PORT"

if [ -z "$METRICS_PORT" ]; then
    echo "✗ FAIL: Could not determine metrics port"
    kill $SERVER_PID 2>/dev/null || true
    cat server.log
    exit 1
fi

# Check if "server marked as initialized" appears in log
if grep -q "server marked as initialized" server.log; then
    echo "✓ Found initialization marker in log"
else
    echo "✗ WARNING: Initialization marker not found in log"
fi

# Test readiness endpoint immediately
echo "Testing readiness endpoint immediately..."
RESPONSE=$(curl -s -w "\n%{http_code}" http://127.0.0.1:$METRICS_PORT/health/ready)
BODY=$(echo "$RESPONSE" | head -n1)
STATUS=$(echo "$RESPONSE" | tail -n1)

echo "Response: $BODY"
echo "HTTP Status: $STATUS"

if [ "$STATUS" = "200" ] && echo "$BODY" | grep -q '"status":"ok"'; then
    echo "✓ PASS: Readiness probe returns 200 OK immediately"
else
    echo "✗ FAIL: Readiness probe did not return 200 OK"
    kill $SERVER_PID 2>/dev/null || true
    exit 1
fi

# Test readiness endpoint after 10 seconds
echo "Waiting 10 seconds and testing again..."
sleep 10

RESPONSE2=$(curl -s -w "\n%{http_code}" http://127.0.0.1:$METRICS_PORT/health/ready)
BODY2=$(echo "$RESPONSE2" | head -n1)
STATUS2=$(echo "$RESPONSE2" | tail -n1)

echo "Response: $BODY2"
echo "HTTP Status: $STATUS2"

if [ "$STATUS2" = "200" ] && echo "$BODY2" | grep -q '"status":"ok"'; then
    echo "✓ PASS: Readiness probe still returns 200 OK after 10s"
else
    echo "✗ FAIL: Readiness probe failed after 10s"
    kill $SERVER_PID 2>/dev/null || true
    exit 1
fi

# Clean up
kill -TERM $SERVER_PID 2>/dev/null || true
wait $SERVER_PID 2>/dev/null || true

echo ""
echo "=== All Readiness Probe Tests Passed ==="
exit 0
