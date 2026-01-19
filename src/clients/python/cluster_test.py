#!/usr/bin/env python3
"""
ArcherDB Cluster Connectivity Test

This script verifies that the ArcherDB cluster is running and accepts GeoEvent operations.
It uses the low-level ArcherDB bindings to test INSERT_EVENTS operations.
"""

import ctypes
import sys
import threading
import os
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'src'))

from archerdb import bindings
from archerdb.lib import c_uint128


# GeoEvent struct matching the Zig extern struct definition (128 bytes)
# Fields ordered largest-to-smallest: u128s, then u64s, then u32s, then u16s
class CGeoEvent(ctypes.Structure):
    _fields_ = [
        ("id", ctypes.c_uint8 * 16),            # u128 composite ID (S2 cell << 64 | timestamp)
        ("entity_id", ctypes.c_uint8 * 16),     # u128 unique identifier
        ("correlation_id", ctypes.c_uint8 * 16),# u128 correlation for batches
        ("user_data", ctypes.c_uint8 * 16),     # u128 application-specific data
        ("lat_nano", ctypes.c_int64),           # i64 latitude in nanodegrees
        ("lon_nano", ctypes.c_int64),           # i64 longitude in nanodegrees
        ("group_id", ctypes.c_uint64),          # u64 fleet/region grouping
        ("timestamp", ctypes.c_uint64),         # u64 server-assigned timestamp
        ("altitude_mm", ctypes.c_int32),        # i32 altitude in mm
        ("velocity_mms", ctypes.c_uint32),      # u32 velocity in mm/s
        ("ttl_seconds", ctypes.c_uint32),       # u32 time-to-live
        ("accuracy_mm", ctypes.c_uint32),       # u32 GPS accuracy in mm
        ("heading_cdeg", ctypes.c_uint16),      # u16 heading in centidegrees
        ("flags", ctypes.c_uint16),             # u16 event flags
        ("reserved", ctypes.c_uint8 * 12),      # u8[12] padding/reserved
    ]

print(f"CGeoEvent size: {ctypes.sizeof(CGeoEvent)} bytes")
assert ctypes.sizeof(CGeoEvent) == 128, f"CGeoEvent size mismatch: {ctypes.sizeof(CGeoEvent)}"


def compute_pseudo_s2_cell(lat_nano: int, lon_nano: int) -> int:
    """Compute a pseudo-S2 cell ID from coordinates (for testing only).

    Real S2 uses a Hilbert curve projection. For testing, we use a simple
    hash-like computation similar to workload.zig.
    """
    # Simple pseudo-cell: multiply lat and lon, take absolute value
    # This gives a non-zero u64 that varies by location
    product = lat_nano * lon_nano
    # Use absolute value and mask to u64
    return abs(product) & 0xFFFFFFFFFFFFFFFF


def pack_composite_id(s2_cell_id: int, timestamp_ns: int) -> int:
    """Pack S2 cell ID and timestamp into composite u128 ID.

    Format: [S2 Cell ID (upper 64 bits) | Timestamp (lower 64 bits)]
    This enables space-major range queries for efficient spatial indexing.
    """
    return (s2_cell_id << 64) | (timestamp_ns & 0xFFFFFFFFFFFFFFFF)


def create_test_geo_event(entity_id: int) -> CGeoEvent:
    """Create a test GeoEvent with valid coordinates (San Francisco area)."""
    event = CGeoEvent()

    # Set entity_id (low bytes first, little endian)
    entity_bytes = entity_id.to_bytes(16, 'little')
    for i in range(16):
        event.entity_id[i] = entity_bytes[i]

    # San Francisco coordinates in nanodegrees
    # 37.7749° N = 37_774_900_000 nanodegrees
    # -122.4194° W = -122_419_400_000 nanodegrees
    event.lat_nano = 37_774_900_000
    event.lon_nano = -122_419_400_000

    # Compute composite ID: [S2 cell (upper 64) | timestamp (lower 64)]
    # The server requires id != 0 for validation
    s2_cell_id = compute_pseudo_s2_cell(event.lat_nano, event.lon_nano)
    timestamp_ns = int(time.time_ns())  # Current time in nanoseconds
    composite_id = pack_composite_id(s2_cell_id, timestamp_ns)

    # Set id field (u128 as 16-byte little-endian)
    id_bytes = composite_id.to_bytes(16, 'little')
    for i in range(16):
        event.id[i] = id_bytes[i]

    # Other fields (using correct field names from Zig struct)
    event.velocity_mms = 5000    # 5 m/s = 5000 mm/s
    event.heading_cdeg = 9000    # 90 degrees (East) = 9000 centidegrees
    event.accuracy_mm = 5000     # 5 meters = 5000 mm
    event.ttl_seconds = 86400    # 24 hours
    event.altitude_mm = 0        # Sea level
    event.flags = 0
    event.group_id = 0
    event.timestamp = 0          # Will be set by server

    # correlation_id, user_data are zeroed (default)

    return event


def test_cluster_connectivity():
    """Test basic cluster connectivity using INSERT_EVENTS operation."""
    print("=" * 60)
    print("  ArcherDB Cluster Connectivity Test")
    print("=" * 60)
    print()

    callback_received = threading.Event()
    callback_result = [None, None, None]  # [status, data_size, data]

    @bindings.OnCompletion
    def on_completion(ctx, packet, timestamp, data_ptr, data_size):
        callback_result[0] = packet.contents.status
        callback_result[1] = data_size
        if data_size > 0 and data_ptr:
            callback_result[2] = bytes(ctypes.cast(data_ptr, ctypes.POINTER(ctypes.c_ubyte * data_size)).contents)
        callback_received.set()

    # Initialize client (real mode, not echo mode)
    client = bindings.CClient()
    cluster_id = c_uint128.from_param(0)  # Cluster ID 0 for development

    # Connect to single-node cluster
    addresses = b"127.0.0.1:3001"

    print(f"  Cluster ID: 0")
    print(f"  Addresses:  {addresses.decode()}")
    print()
    print("  Initializing client...")

    init_status = bindings.arch_client_init(
        ctypes.byref(client),
        ctypes.cast(ctypes.byref(cluster_id), ctypes.POINTER(ctypes.c_uint8 * 16)),
        addresses,
        len(addresses),
        42,  # context
        on_completion
    )

    if init_status != bindings.InitStatus.SUCCESS:
        print(f"  FAIL: Client init returned status {init_status.name}")
        return False

    print("  Client initialized successfully!")
    print()

    # Test: Insert a GeoEvent
    print("  Test: INSERT_EVENTS (single GeoEvent)")
    print("  " + "-" * 40)

    # Generate a unique entity ID using timestamp
    entity_id = int(time.time() * 1000) << 48 | 1  # Timestamp + sequence

    # Create a test event
    event = create_test_geo_event(entity_id)
    event_array = (CGeoEvent * 1)(event)

    packet = bindings.CPacket()
    packet.user_data = 1
    packet.user_tag = 0
    packet.operation = bindings.Operation.INSERT_EVENTS  # Operation code 146
    packet.status = bindings.PacketStatus.OK
    packet.data = ctypes.cast(event_array, ctypes.c_void_p)
    packet.data_size = ctypes.sizeof(event_array)

    # Extract composite ID from event for display
    composite_id = int.from_bytes(bytes(event.id), 'little')
    s2_cell = composite_id >> 64
    ts_part = composite_id & 0xFFFFFFFFFFFFFFFF

    print(f"  Entity ID:  0x{entity_id:032x}")
    print(f"  Composite ID (u128): 0x{composite_id:032x}")
    print(f"    - S2 Cell (upper 64): 0x{s2_cell:016x}")
    print(f"    - Timestamp (lower 64): {ts_part}")
    print(f"  Location:   37.7749°N, 122.4194°W (San Francisco)")
    print(f"  Data size:  {packet.data_size} bytes")
    print()

    callback_received.clear()
    client_status = bindings.arch_client_submit(ctypes.byref(client), ctypes.byref(packet))

    if client_status != bindings.ClientStatus.OK:
        print(f"  FAIL: Submit returned status {client_status.name}")
        bindings.arch_client_deinit(ctypes.byref(client))
        return False

    print("  Waiting for response...")

    if not callback_received.wait(timeout=30.0):
        print("  FAIL: Timeout waiting for INSERT response")
        bindings.arch_client_deinit(ctypes.byref(client))
        return False

    status_name = bindings.PacketStatus(callback_result[0]).name
    print(f"  Response status: {status_name}")
    print(f"  Response size:   {callback_result[1]} bytes")

    if callback_result[0] == bindings.PacketStatus.OK:
        if callback_result[1] == 0:
            print("  PASS: INSERT_EVENTS successful (no errors)")
        else:
            # Response contains error results (8 bytes each: index + result code)
            num_errors = callback_result[1] // 8
            print(f"  INSERT had {num_errors} error(s)")
            if callback_result[2]:
                for i in range(num_errors):
                    idx = int.from_bytes(callback_result[2][i*8:i*8+4], 'little')
                    code = int.from_bytes(callback_result[2][i*8+4:i*8+8], 'little')
                    print(f"    Error {i}: index={idx}, code={code}")
    else:
        print(f"  FAIL: INSERT returned {status_name}")
        bindings.arch_client_deinit(ctypes.byref(client))
        return False

    print()

    # Test: Query UUID - retrieve the event we just inserted
    print("  Test: QUERY_UUID (retrieve inserted event)")
    print("  " + "-" * 40)

    # QueryUuidFilter: entity_id (u128, 16 bytes) + reserved (16 bytes) = 32 bytes
    class CQueryUuidFilter(ctypes.Structure):
        _fields_ = [
            ("entity_id", ctypes.c_uint8 * 16),  # u128 entity to lookup
            ("reserved", ctypes.c_uint8 * 16),   # padding to 32 bytes
        ]

    assert ctypes.sizeof(CQueryUuidFilter) == 32, f"CQueryUuidFilter size mismatch: {ctypes.sizeof(CQueryUuidFilter)}"

    query_filter = CQueryUuidFilter()
    query_filter_bytes = entity_id.to_bytes(16, 'little')
    for i in range(16):
        query_filter.entity_id[i] = query_filter_bytes[i]
    query_packet = bindings.CPacket()
    query_packet.user_data = 2
    query_packet.user_tag = 0
    query_packet.operation = bindings.Operation.QUERY_UUID  # Operation code 149
    query_packet.status = bindings.PacketStatus.OK
    query_packet.data = ctypes.cast(ctypes.byref(query_filter), ctypes.c_void_p)
    query_packet.data_size = ctypes.sizeof(query_filter)

    print(f"  Querying entity: 0x{entity_id:032x}")
    print(f"  Data size:  {query_packet.data_size} bytes")
    print()

    callback_received.clear()
    callback_result[0] = None
    callback_result[1] = None
    callback_result[2] = None

    client_status = bindings.arch_client_submit(ctypes.byref(client), ctypes.byref(query_packet))

    if client_status != bindings.ClientStatus.OK:
        print(f"  FAIL: Submit returned status {client_status.name}")
        bindings.arch_client_deinit(ctypes.byref(client))
        return False

    print("  Waiting for response...")

    if not callback_received.wait(timeout=30.0):
        print("  FAIL: Timeout waiting for QUERY_UUID response")
        bindings.arch_client_deinit(ctypes.byref(client))
        return False

    status_name = bindings.PacketStatus(callback_result[0]).name
    print(f"  Response status: {status_name}")
    print(f"  Response size:   {callback_result[1]} bytes")

    if callback_result[0] == bindings.PacketStatus.OK:
        if callback_result[1] >= 16 and callback_result[2]:
            status = callback_result[2][0]
            if status == 0 and callback_result[1] >= 16 + 128:
                print("  PASS: QUERY_UUID found the event!")
                result_event = CGeoEvent.from_buffer_copy(callback_result[2][16:16 + 128])
                result_entity_id = int.from_bytes(bytes(result_event.entity_id), 'little')
                result_id = int.from_bytes(bytes(result_event.id), 'little')
                print(f"    Returned entity_id: 0x{result_entity_id:032x}")
                print(f"    Returned composite_id: 0x{result_id:032x}")
                print(f"    Returned lat_nano: {result_event.lat_nano}")
                print(f"    Returned lon_nano: {result_event.lon_nano}")
            elif status == 200:
                print("  INFO: QUERY_UUID returned no results (entity not found in RAM index)")
            elif status == 210:
                print("  INFO: QUERY_UUID entity expired (TTL)")
            else:
                print(f"  INFO: QUERY_UUID returned status {status}")
        else:
            print(f"  INFO: Unexpected response size {callback_result[1]} bytes")
    else:
        print(f"  FAIL: QUERY_UUID returned {status_name}")
        bindings.arch_client_deinit(ctypes.byref(client))
        return False

    print()

    # Cleanup
    print("  Closing client...")
    bindings.arch_client_deinit(ctypes.byref(client))
    print("  Client closed successfully!")

    print()
    print("=" * 60)
    print("  TEST COMPLETED!")
    print("=" * 60)

    return True


if __name__ == "__main__":
    success = test_cluster_connectivity()
    sys.exit(0 if success else 1)
