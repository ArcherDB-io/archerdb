#!/bin/bash
# ArcherDB Client Library Tests
# This script tests all client libraries using echo mode which doesn't require a server
# Real-world tests require io_uring support (kernel 5.5+, no seccomp restrictions)

set -e

ARCHERDB_DIR="$(dirname "$(dirname "$(realpath "$0")")")"
cd "$ARCHERDB_DIR"

echo "=============================================="
echo "ArcherDB Client Library Tests"
echo "=============================================="
echo "Directory: $ARCHERDB_DIR"
echo ""

PASS_COUNT=0
FAIL_COUNT=0

# Check if io_uring is available
check_io_uring() {
    local disabled=$(cat /proc/sys/kernel/io_uring_disabled 2>/dev/null || echo "unknown")
    if [ "$disabled" = "0" ]; then
        echo "io_uring: ENABLED"
        return 0
    elif [ "$disabled" = "unknown" ]; then
        echo "io_uring: UNKNOWN (cannot read sysctl)"
        return 1
    else
        echo "io_uring: DISABLED (kernel.io_uring_disabled=$disabled)"
        return 1
    fi
}

echo "=== System Check ==="
check_io_uring
echo ""

# Python Echo Test
test_python_echo() {
    echo "=== Python Client Echo Test ==="

    if ! python3 --version &>/dev/null; then
        echo "SKIP: Python 3 not available"
        return 1
    fi

    python3 << 'PYEOF'
import sys
import threading
sys.path.insert(0, "src/clients/python/src")

import ctypes
from archerdb import bindings
from archerdb.lib import c_uint128

callback_received = threading.Event()
callback_result = [None]

@bindings.OnCompletion
def on_completion(ctx, packet, timestamp, data_ptr, data_size):
    callback_result[0] = data_size
    callback_received.set()

# Initialize client in echo mode
client = bindings.CClient()
cluster_id_u128 = c_uint128.from_param(0)

init_status = bindings.tb_client_init_echo(
    ctypes.byref(client),
    ctypes.cast(ctypes.byref(cluster_id_u128), ctypes.POINTER(ctypes.c_uint8 * 16)),
    b"3000", 4, 42, on_completion
)

if init_status != bindings.InitStatus.SUCCESS:
    print(f"FAIL: Init returned status {init_status}")
    sys.exit(1)

# Create an account packet
packet = bindings.CPacket()
packet.user_data = 1
packet.user_tag = 0
packet.operation = bindings.Operation.CREATE_ACCOUNTS
packet.status = bindings.PacketStatus.OK

account = bindings.CAccount()
account.id = c_uint128.from_param(12345)
account.ledger = 1
account.code = 1

account_array = (bindings.CAccount * 1)(account)
packet.data = ctypes.cast(account_array, ctypes.c_void_p)
packet.data_size = ctypes.sizeof(account_array)

client_status = bindings.tb_client_submit(ctypes.byref(client), ctypes.byref(packet))

if client_status != bindings.ClientStatus.OK:
    print(f"FAIL: Submit returned status {client_status}")
    sys.exit(1)

if not callback_received.wait(timeout=5.0):
    print("FAIL: Timeout waiting for callback")
    sys.exit(1)

if callback_result[0] != ctypes.sizeof(account_array):
    print(f"FAIL: Expected size {ctypes.sizeof(account_array)}, got {callback_result[0]}")
    sys.exit(1)

bindings.tb_client_deinit(ctypes.byref(client))
print("PASS: Python client echo test")
PYEOF

    if [ $? -eq 0 ]; then
        PASS_COUNT=$((PASS_COUNT + 1))
        return 0
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        return 1
    fi
}

# Node.js Echo Test
test_nodejs_echo() {
    echo ""
    echo "=== Node.js Client Echo Test ==="

    if ! node --version &>/dev/null; then
        echo "SKIP: Node.js not available"
        return 1
    fi

    BINDING_PATH="src/clients/node/dist/bin/x86_64-linux-gnu/client.node"
    if [ ! -f "$BINDING_PATH" ]; then
        echo "SKIP: Native binding not found at $BINDING_PATH"
        return 1
    fi

    node << 'JSEOF'
const path = require('path');

const bindingPath = path.join(process.cwd(), 'src/clients/node/dist/bin/x86_64-linux-gnu/client.node');
const binding = require(bindingPath);

let callbackReceived = false;

const client = binding.init_echo({
    cluster_id: BigInt(0),
    replica_addresses: Buffer.from("3000"),
});

const accounts = [{
    id: BigInt(12345),
    debits_pending: BigInt(0),
    debits_posted: BigInt(0),
    credits_pending: BigInt(0),
    credits_posted: BigInt(0),
    user_data_128: BigInt(0),
    user_data_64: BigInt(0),
    user_data_32: 0,
    reserved: 0,
    ledger: 1,
    code: 1,
    flags: 0,
    timestamp: BigInt(0)
}];

binding.submit(client, 138, accounts, (error, results) => {
    if (error) {
        console.log('FAIL: ' + error);
        process.exit(1);
    }
    callbackReceived = true;
});

setTimeout(() => {
    binding.deinit(client);
    if (callbackReceived) {
        console.log('PASS: Node.js client echo test');
        process.exit(0);
    } else {
        console.log('FAIL: No callback received');
        process.exit(1);
    }
}, 2000);
JSEOF

    if [ $? -eq 0 ]; then
        PASS_COUNT=$((PASS_COUNT + 1))
        return 0
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        return 1
    fi
}

# Go Echo Test
test_go_echo() {
    echo ""
    echo "=== Go Client Echo Test ==="

    if ! go version &>/dev/null; then
        echo "SKIP: Go not available"
        return 1
    fi

    cd src/clients/go
    if go test -run TestEchoClient -v -count=1 . 2>&1 | grep -q "PASS"; then
        PASS_COUNT=$((PASS_COUNT + 1))
        echo "PASS: Go client echo test"
        cd "$ARCHERDB_DIR"
        return 0
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        echo "FAIL: Go client echo test"
        cd "$ARCHERDB_DIR"
        return 1
    fi
}

# Run all tests
test_python_echo
test_nodejs_echo
test_go_echo

echo ""
echo "=============================================="
echo "Test Results"
echo "=============================================="
echo "Passed: $PASS_COUNT"
echo "Failed: $FAIL_COUNT"
echo ""

if [ $FAIL_COUNT -eq 0 ]; then
    echo "All echo mode tests PASSED!"
    echo ""
    echo "Note: Real-world tests require:"
    echo "  - Linux kernel 5.5+ with io_uring support"
    echo "  - No seccomp restrictions on io_uring syscalls"
    echo "  - Sufficient locked memory limits (ulimit -l unlimited)"
    exit 0
else
    echo "Some tests FAILED"
    exit 1
fi
