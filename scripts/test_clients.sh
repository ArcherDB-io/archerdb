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

init_status = bindings.arch_client_init_echo(
    ctypes.byref(client),
    ctypes.cast(ctypes.byref(cluster_id_u128), ctypes.POINTER(ctypes.c_uint8 * 16)),
    b"3000", 4, 42, on_completion
)

if init_status != bindings.InitStatus.SUCCESS:
    print(f"FAIL: Init returned status {init_status}")
    sys.exit(1)

# Create a geo event packet
packet = bindings.CPacket()
packet.user_data = 1
packet.user_tag = 0
packet.operation = bindings.Operation.INSERT_EVENTS
packet.status = bindings.PacketStatus.OK

# Create a GeoEvent using the dataclass, then convert to C struct
geo_event_py = bindings.GeoEvent(
    id=1,
    entity_id=12345,
    correlation_id=0,
    user_data=0,
    lat_nano=int(37.7749 * 1_000_000_000),  # San Francisco latitude
    lon_nano=int(-122.4194 * 1_000_000_000),  # San Francisco longitude
    group_id=1,
    timestamp=0,
    altitude_mm=0,
    velocity_mms=0,
    ttl_seconds=86400,
    accuracy_mm=5000,
    heading_cdeg=0,
    flags=bindings.GeoEventFlags.NONE
)

# Convert to C struct
geo_event = bindings.CGeoEvent.from_param(geo_event_py)

event_array = (bindings.CGeoEvent * 1)(geo_event)
packet.data = ctypes.cast(event_array, ctypes.c_void_p)
packet.data_size = ctypes.sizeof(event_array)

client_status = bindings.arch_client_submit(ctypes.byref(client), ctypes.byref(packet))

if client_status != bindings.ClientStatus.OK:
    print(f"FAIL: Submit returned status {client_status}")
    sys.exit(1)

if not callback_received.wait(timeout=5.0):
    print("FAIL: Timeout waiting for callback")
    sys.exit(1)

if callback_result[0] != ctypes.sizeof(event_array):
    print(f"FAIL: Expected size {ctypes.sizeof(event_array)}, got {callback_result[0]}")
    sys.exit(1)

bindings.arch_client_deinit(ctypes.byref(client))
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
const { Operation, GeoEventFlags } = require(path.join(process.cwd(), 'src/clients/node/dist/bindings.js'));

let callbackReceived = false;

const client = binding.init_echo({
    cluster_id: 0n,
    replica_addresses: Buffer.from("3000"),
});

const events = [{
    id: 1n,
    entity_id: 12345n,
    correlation_id: 0n,
    user_data: 0n,
    lat_nano: 37774900000n,
    lon_nano: -122419400000n,
    group_id: 1n,
    timestamp: 0n,
    altitude_mm: 0,
    velocity_mms: 0,
    ttl_seconds: 86400,
    accuracy_mm: 5000,
    heading_cdeg: 0,
    flags: GeoEventFlags.none,
}];

binding.submit(client, Operation.insert_events, events, (error, results) => {
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

# Java Echo Test
test_java_echo() {
    echo ""
    echo "=== Java Client Echo Test ==="

    if ! java -version &>/dev/null; then
        echo "SKIP: Java not available"
        return 1
    fi

    if ! mvn -version &>/dev/null; then
        echo "SKIP: Maven not available"
        return 1
    fi

    if ! javac -version &>/dev/null; then
        echo "SKIP: javac not available"
        return 1
    fi

    cd src/clients/java

    if ! mvn -q -DskipTests compile; then
        echo "FAIL: Java client compile failed"
        cd "$ARCHERDB_DIR"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        return 1
    fi

    tmp_dir="$(mktemp -d)"
    mkdir -p "$tmp_dir/com/archerdb/geo"
    cat > "$tmp_dir/com/archerdb/geo/EchoClientTest.java" << 'JAVAE'
package com.archerdb.geo;

import com.archerdb.core.GeoNativeBridge;
import com.archerdb.core.UInt128;
import java.nio.ByteBuffer;

public final class EchoClientTest {
    private static void fail(String message) {
        System.out.println("FAIL: " + message);
        System.exit(1);
    }

    public static void main(String[] args) {
        byte[] clusterId = new byte[16];
        long latNano = 37_774_900_000L;
        long lonNano = -122_419_400_000L;

        try (GeoNativeBridge bridge = GeoNativeBridge.createEcho(clusterId, "3000")) {
            NativeGeoEventBatch batch = new NativeGeoEventBatch(1);
            batch.add();
            batch.setId(1L, 0L);
            batch.setEntityId(12345L, 0L);
            batch.setCorrelationId(0L, 0L);
            batch.setUserData(0L, 0L);
            batch.setLatNano(latNano);
            batch.setLonNano(lonNano);
            batch.setGroupId(1L);
            batch.setTimestamp(0L);
            batch.setAltitudeMm(0);
            batch.setVelocityMms(0);
            batch.setTtlSeconds(86400);
            batch.setAccuracyMm(5000);
            batch.setHeadingCdeg(0);
            batch.setFlags(0);

            ByteBuffer reply = bridge.submitRequest((byte) 146, batch, 5000);
            if (reply == null || reply.remaining() != 128) {
                fail("Unexpected reply size");
            }

            NativeGeoEventBatch echoed = new NativeGeoEventBatch(reply);
            if (!echoed.next()) {
                fail("No echoed event received");
            }

            if (echoed.getId(UInt128.LeastSignificant) != 1L ||
                    echoed.getId(UInt128.MostSignificant) != 0L) {
                fail("Echoed id mismatch");
            }
            if (echoed.getEntityId(UInt128.LeastSignificant) != 12345L ||
                    echoed.getEntityId(UInt128.MostSignificant) != 0L) {
                fail("Echoed entity_id mismatch");
            }
            if (echoed.getLatNano() != latNano || echoed.getLonNano() != lonNano) {
                fail("Echoed coordinates mismatch");
            }

            System.out.println("PASS: Java client echo test");
        } catch (Throwable err) {
            err.printStackTrace();
            fail("Java echo test failed: " + err.getMessage());
        }
    }
}
JAVAE

    if ! javac -cp "target/classes" -d "$tmp_dir" "$tmp_dir/com/archerdb/geo/EchoClientTest.java"; then
        echo "FAIL: Java client echo test compile failed"
        rm -rf "$tmp_dir"
        cd "$ARCHERDB_DIR"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        return 1
    fi

    if java --enable-native-access=ALL-UNNAMED -cp "$tmp_dir:target/classes:src/main/resources" com.archerdb.geo.EchoClientTest; then
        rm -rf "$tmp_dir"
        PASS_COUNT=$((PASS_COUNT + 1))
        cd "$ARCHERDB_DIR"
        return 0
    else
        rm -rf "$tmp_dir"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        cd "$ARCHERDB_DIR"
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
test_java_echo
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
