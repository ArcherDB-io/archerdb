#!/bin/bash
ARCHERDB_DIR="$(dirname "$(dirname "$(realpath "$0")")")"
cd "$ARCHERDB_DIR"
ZIG_BUILD_FLAGS="-Dconfig=lite"

echo "=============================================="
echo "ArcherDB Integration Tests"
echo "=============================================="

# Check if io_uring is available
if [ "$(cat /proc/sys/kernel/io_uring_disabled 2>/dev/null)" != "0" ]; then
    echo "WARNING: io_uring might be disabled. Tests may fail."
fi

# Cleanup any previous instances
echo "Cleaning up..."
pkill -9 archerdb || true
rm -f data.archerdb
rm -f server.log

pick_free_port() {
    if command -v python3 >/dev/null 2>&1; then
        python3 - << 'PYEOF'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PYEOF
        return
    fi
    # Fallback to a default if python3 isn't available
    echo "3001"
}

check_port_open() {
    local port="$1"
    if command -v python3 >/dev/null 2>&1; then
        python3 - << PYEOF
import socket
import sys
sock = socket.socket()
sock.settimeout(0.2)
try:
    sock.connect(("127.0.0.1", int("$port")))
    sock.close()
    sys.exit(0)
except Exception:
    sys.exit(1)
PYEOF
        return $?
    fi
    (echo > "/dev/tcp/127.0.0.1/${port}") >/dev/null 2>&1
}

wait_for_server() {
    local port="$1"
    local attempts=50
    while [ "$attempts" -gt 0 ]; do
        if ! kill -0 "$SERVER_PID" 2>/dev/null; then
            echo "Server failed to start. Log:"
            tail -n 50 server.log
            return 1
        fi
        if [ -f server.log ] && grep -q "AddressInUse" server.log; then
            echo "Server failed to bind (AddressInUse). Log:"
            tail -n 50 server.log
            return 1
        fi
        if check_port_open "$port"; then
            return 0
        fi
        attempts=$((attempts - 1))
        sleep 0.2
    done
    echo "Server did not become ready. Log:"
    tail -n 50 server.log
    return 1
}

# 1. Build ArcherDB
echo "Building ArcherDB..."
./zig/zig build $ZIG_BUILD_FLAGS
if [ $? -ne 0 ]; then
    echo "Build failed"
    exit 1
fi

echo "Building Client Libraries..."
./zig/zig build $ZIG_BUILD_FLAGS clients:python
./zig/zig build $ZIG_BUILD_FLAGS clients:node
./zig/zig build $ZIG_BUILD_FLAGS clients:java
./zig/zig build $ZIG_BUILD_FLAGS clients:go
# C client is tested via test:unit which compiles it internally


# 2. Setup Data Directory
DATA_FILE="data.archerdb"
SERVER_PORT="$(pick_free_port)"

echo "Formatting data file..."
./zig-out/bin/archerdb format --cluster=0 --replica=0 --replica-count=1 $DATA_FILE

# 3. Start ArcherDB in background
echo "Starting ArcherDB..."
./zig-out/bin/archerdb start --addresses="127.0.0.1:${SERVER_PORT}" $DATA_FILE > server.log 2>&1 &
SERVER_PID=$!

# Ensure server is killed on exit
cleanup() {
    echo "Stopping ArcherDB..."
    kill $SERVER_PID 2>/dev/null || true
    wait $SERVER_PID 2>/dev/null || true
    rm -f $DATA_FILE
}
trap cleanup EXIT

# Wait for server to be ready
echo "Waiting for server to start on ${SERVER_PORT}..."
if ! wait_for_server "$SERVER_PORT"; then
    exit 1
fi

export ARCHERDB_INTEGRATION=1
export ARCHERDB_ADDRESS="127.0.0.1:${SERVER_PORT}"

FAIL_COUNT=0

# Disable exit on error for tests
set +e

# 4. Run Tests

# Node.js
echo ""
echo "=== Node.js Integration Tests ==="
if [ -d "src/clients/node" ]; then
    cd src/clients/node
    # Compile TS first
    echo "Building Node.js client..."
    if npm run build; then
        echo "Running Node.js tests..."
        if node dist/test.js; then
            echo "PASS: Node.js integration tests"
        else
            echo "FAIL: Node.js integration tests"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        fi
    else
         echo "FAIL: Node.js build failed"
         FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
    cd "$ARCHERDB_DIR"
else
    echo "SKIP: Node.js client not found"
fi

# Java
echo ""
echo "=== Java Integration Tests ==="
if [ -d "src/clients/java" ]; then
    cd src/clients/java
    # We need to compile first
    echo "Compiling Java client..."
    if mvn -DskipTests compile; then
        # Run specific integration test class
        echo "Running Java tests..."
        if mvn test -Dtest=GeoClientIntegrationTest -Darcherdb.native.enabled=true; then
            echo "PASS: Java integration tests"
        else
            echo "FAIL: Java integration tests"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        fi
    else
        echo "FAIL: Java compile failed"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
    cd "$ARCHERDB_DIR"
else
    echo "SKIP: Java client not found"
fi

# Go
echo ""
echo "=== Go Integration Tests ==="
if [ -d "src/clients/go" ]; then
    cd src/clients/go
    echo "Running Go tests..."
    if go test -v .; then
        echo "PASS: Go integration tests"
    else
        echo "FAIL: Go integration tests"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
    cd "$ARCHERDB_DIR"
else
    echo "SKIP: Go client not found"
fi

# C (Zig)
echo ""
echo "=== C (Zig) Integration Tests ==="
# Run zig build test:unit with filter for arch_client
if ./zig/zig build $ZIG_BUILD_FLAGS test:unit -- --test-filter "arch_client"; then
    echo "PASS: C integration tests"
else
    echo "FAIL: C integration tests"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# Python
echo ""
echo "=== Python Integration Tests ==="
if [ -d "src/clients/python" ]; then
    cd src/clients/python
    echo "Running Python tests..."
    if python3 -m pytest tests/test_integration.py; then
        echo "PASS: Python integration tests"
    else
        echo "FAIL: Python integration tests"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
    cd "$ARCHERDB_DIR"
else
    echo "SKIP: Python client not found"
fi

echo ""
echo "=============================================="
echo "Integration Test Results"
echo "=============================================="
if [ $FAIL_COUNT -eq 0 ]; then
    echo "All integration tests PASSED!"
    exit 0
else
    echo "$FAIL_COUNT test suites FAILED"
    echo "Server Log (last 50 lines):"
    tail -n 50 server.log
    exit 1
fi
