#!/usr/bin/env python3
"""
ArcherDB GeoEvent Benchmark

Measures insert throughput (events per second) by sending batches of GeoEvents
to a running ArcherDB cluster.

Usage:
    python benchmark_geo.py [--events N] [--batch-size B] [--addresses ADDR]
"""

import ctypes
import os
import random
import sys
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import List

# Add the client library to the path
sys.path.insert(0, str(Path(__file__).parent / "src" / "clients" / "python" / "src"))

# Import from the tigerbeetle package (which has the working native bindings)
from tigerbeetle import bindings
from tigerbeetle.lib import c_uint128, tbclient, validate_uint

# ============================================================================
# GeoEvent Structure (matches geo_event.zig exactly)
# ============================================================================

class CGeoEvent(ctypes.Structure):
    """
    128-byte GeoEvent structure matching Zig's extern struct layout.
    """
    _fields_ = [
        # u128 fields (16 bytes each)
        ("id", c_uint128),           # Composite key [S2 Cell ID | Timestamp]
        ("entity_id", c_uint128),    # UUID of the moving entity
        ("correlation_id", c_uint128), # Trip/session correlation
        ("user_data", c_uint128),    # Application metadata

        # i64/u64 fields (8 bytes each)
        ("lat_nano", ctypes.c_int64),   # Latitude in nanodegrees
        ("lon_nano", ctypes.c_int64),   # Longitude in nanodegrees
        ("group_id", ctypes.c_uint64),  # Fleet/region grouping
        ("timestamp", ctypes.c_uint64), # Nanoseconds since epoch

        # i32/u32 fields (4 bytes each)
        ("altitude_mm", ctypes.c_int32),  # Millimeters above WGS84
        ("velocity_mms", ctypes.c_uint32), # Millimeters per second
        ("ttl_seconds", ctypes.c_uint32),  # Time-to-live
        ("accuracy_mm", ctypes.c_uint32),  # GPS accuracy radius

        # u16 fields (2 bytes each)
        ("heading_cdeg", ctypes.c_uint16), # Heading in centidegrees
        ("flags", ctypes.c_uint16),        # GeoEventFlags

        # Reserved padding
        ("reserved", ctypes.c_uint8 * 12),
    ]

    @classmethod
    def create(cls, entity_id: int, lat: float, lon: float,
               group_id: int = 0, velocity_mps: float = 0.0,
               heading: float = 0.0) -> "CGeoEvent":
        """Create a GeoEvent from human-friendly parameters."""
        event = cls()
        # Zero out the entire struct first
        ctypes.memset(ctypes.byref(event), 0, ctypes.sizeof(cls))

        event.id = c_uint128.from_param(0)  # Server assigns
        event.entity_id = c_uint128.from_param(entity_id)
        event.correlation_id = c_uint128.from_param(0)
        event.user_data = c_uint128.from_param(0)
        event.lat_nano = int(lat * 1_000_000_000)
        event.lon_nano = int(lon * 1_000_000_000)
        event.group_id = group_id
        event.timestamp = 0  # Server assigns
        event.altitude_mm = 0
        event.velocity_mms = int(velocity_mps * 1000)
        event.ttl_seconds = 0
        event.accuracy_mm = 10000  # 10m accuracy
        event.heading_cdeg = int(heading * 100) % 36000
        event.flags = 0
        return event


# Verify struct size
assert ctypes.sizeof(CGeoEvent) == 128, f"GeoEvent size mismatch: {ctypes.sizeof(CGeoEvent)} != 128"

# GeoEvent operation codes (from archerdb.zig)
# These are different from TigerBeetle's Account/Transfer operations
OP_INSERT_EVENTS = 146  # vsr_operations_reserved (128) + 18

# ============================================================================
# ID Generator (ULID-based)
# ============================================================================

class IDGenerator:
    def __init__(self):
        self._last_time_ms = time.time_ns() // 1_000_000
        self._last_random = int.from_bytes(os.urandom(10), 'little')
        self._lock = threading.Lock()

    def generate(self) -> int:
        with self._lock:
            time_ms = time.time_ns() // 1_000_000
            if time_ms <= self._last_time_ms:
                time_ms = self._last_time_ms
            else:
                self._last_time_ms = time_ms
                self._last_random = int.from_bytes(os.urandom(10), 'little')

            self._last_random += 1
            if self._last_random >= 2**80:
                raise RuntimeError("Random bits overflow")

            return (time_ms << 80) | self._last_random


_id_gen = IDGenerator()


def generate_id() -> int:
    return _id_gen.generate()


# ============================================================================
# Completion Callback
# ============================================================================

@dataclass
class RequestContext:
    completed: threading.Event
    status: int = 0
    result_count: int = 0


# Global storage for in-flight requests
_requests: dict = {}
_request_counter = 0
_request_lock = threading.Lock()
_client_instance = None


@bindings.OnCompletion
def on_completion(context, packet_ptr, timestamp: int, result_ptr, result_len: int):
    """Callback invoked when a request completes."""
    packet = packet_ptr.contents
    req_id = packet.user_data

    if req_id in _requests:
        ctx = _requests[req_id]
        ctx.status = packet.status
        ctx.result_count = result_len // 8 if result_len > 0 else 0
        ctx.completed.set()


# ============================================================================
# Client Class
# ============================================================================

class GeoClient:
    def __init__(self, cluster_id: int, addresses: str):
        global _client_instance, _request_counter
        self._client = bindings.CClient()
        self._closed = False
        _client_instance = self

        # Prepare cluster_id as 16 bytes (u128)
        cluster_bytes = (ctypes.c_uint8 * 16)()
        cluster_u128 = c_uint128.from_param(cluster_id)
        ctypes.memmove(cluster_bytes, ctypes.byref(cluster_u128), 16)

        # Prepare addresses
        addr_bytes = addresses.encode('ascii')

        # Keep reference to prevent GC
        self._cluster_bytes = cluster_bytes
        self._addr_bytes = addr_bytes

        # Get a unique context for this client
        with _request_lock:
            _request_counter += 1
            self._context = _request_counter

        status = bindings.tb_client_init(
            ctypes.byref(self._client),
            ctypes.byref(cluster_bytes),
            addr_bytes,
            len(addr_bytes),
            self._context,
            on_completion,
        )

        if status != bindings.InitStatus.SUCCESS:
            raise RuntimeError(f"Failed to initialize client: status={status}")

        print(f"Connected to cluster {cluster_id} at {addresses}")

    def insert_events(self, events: List[CGeoEvent], timeout_ms: int = 30000) -> int:
        """Insert GeoEvents and return number of errors."""
        if not events:
            return 0

        # Create array of events
        EventArray = CGeoEvent * len(events)
        events_array = EventArray(*events)

        # Create packet - use the actual bindings type
        packet = bindings.CPacket()
        # Zero out the packet structure
        ctypes.memset(ctypes.byref(packet), 0, ctypes.sizeof(bindings.CPacket))

        global _request_counter
        with _request_lock:
            _request_counter += 1
            req_id = _request_counter

        packet.user_data = req_id
        packet.data = ctypes.cast(events_array, ctypes.c_void_p)
        packet.data_size = ctypes.sizeof(events_array)
        packet.user_tag = 0
        packet.operation = OP_INSERT_EVENTS
        packet.status = bindings.PacketStatus.OK

        # Create completion context
        ctx = RequestContext(completed=threading.Event())
        _requests[req_id] = ctx

        # Keep references to prevent GC
        self._current_events = events_array
        self._current_packet = packet

        # Submit request
        status = bindings.tb_client_submit(ctypes.byref(self._client), ctypes.byref(packet))
        if status != bindings.ClientStatus.OK:
            del _requests[req_id]
            raise RuntimeError(f"Submit failed with status {status}")

        # Wait for completion
        if not ctx.completed.wait(timeout_ms / 1000.0):
            del _requests[req_id]
            raise TimeoutError("Request timed out")

        del _requests[req_id]

        if ctx.status != bindings.PacketStatus.OK.value:
            raise RuntimeError(f"Request failed with status {ctx.status}")

        return ctx.result_count

    def close(self):
        if not self._closed:
            bindings.tb_client_deinit(ctypes.byref(self._client))
            self._closed = True


# ============================================================================
# Benchmark
# ============================================================================

def generate_random_location():
    """Generate a random location within reasonable bounds."""
    lat = random.uniform(-60, 70)  # Avoid polar regions
    lon = random.uniform(-180, 180)
    return lat, lon


def run_benchmark(
    addresses: str = "127.0.0.1:3001,127.0.0.1:3002,127.0.0.1:3003",
    cluster_id: int = 0,
    total_events: int = 100_000,
    batch_size: int = 1000,
):
    """Run the benchmark and report results."""
    print(f"\n{'='*60}")
    print("ArcherDB GeoEvent Benchmark")
    print(f"{'='*60}")
    print(f"Cluster ID: {cluster_id}")
    print(f"Addresses: {addresses}")
    print(f"Total events: {total_events:,}")
    print(f"Batch size: {batch_size}")
    print(f"{'='*60}\n")

    # Connect to cluster
    try:
        client = GeoClient(cluster_id, addresses)
    except Exception as e:
        print(f"ERROR: Failed to connect: {e}")
        import traceback
        traceback.print_exc()
        return

    # Pre-generate all events
    print("Generating events...")
    all_events = []
    for i in range(total_events):
        entity_id = generate_id()
        lat, lon = generate_random_location()
        velocity = random.uniform(0, 30)  # 0-30 m/s
        heading = random.uniform(0, 360)

        event = CGeoEvent.create(
            entity_id=entity_id,
            lat=lat,
            lon=lon,
            velocity_mps=velocity,
            heading=heading,
        )
        all_events.append(event)
    print(f"Generated {len(all_events):,} events\n")

    # Run benchmark
    print("Starting benchmark...")
    start_time = time.perf_counter()

    events_sent = 0
    batches_sent = 0
    errors = 0

    try:
        for i in range(0, total_events, batch_size):
            batch = all_events[i:i+batch_size]
            batch_errors = client.insert_events(batch)

            events_sent += len(batch)
            batches_sent += 1
            errors += batch_errors

            # Progress update every 10 batches
            if batches_sent % 10 == 0:
                elapsed = time.perf_counter() - start_time
                rps = events_sent / elapsed if elapsed > 0 else 0
                print(f"  Progress: {events_sent:,}/{total_events:,} events, {rps:,.0f} events/sec")

    except Exception as e:
        print(f"ERROR during benchmark: {e}")
        import traceback
        traceback.print_exc()

    finally:
        end_time = time.perf_counter()
        client.close()

    # Report results
    elapsed = end_time - start_time
    rps = events_sent / elapsed if elapsed > 0 else 0

    print(f"\n{'='*60}")
    print("RESULTS")
    print(f"{'='*60}")
    print(f"Events sent: {events_sent:,}")
    print(f"Batches sent: {batches_sent:,}")
    print(f"Errors: {errors:,}")
    print(f"Time elapsed: {elapsed:.2f} seconds")
    print(f"Throughput: {rps:,.0f} events/second")
    print(f"Latency per batch: {(elapsed/batches_sent)*1000:.2f} ms" if batches_sent > 0 else "N/A")
    print(f"{'='*60}\n")


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="ArcherDB GeoEvent Benchmark")
    parser.add_argument("--events", type=int, default=100_000, help="Total events to insert")
    parser.add_argument("--batch-size", type=int, default=1000, help="Events per batch")
    parser.add_argument("--addresses", default="127.0.0.1:3001,127.0.0.1:3002,127.0.0.1:3003", help="Cluster addresses")
    parser.add_argument("--cluster-id", type=int, default=0, help="Cluster ID (default: 0 for dev cluster)")

    args = parser.parse_args()

    run_benchmark(
        addresses=args.addresses,
        cluster_id=args.cluster_id,
        total_events=args.events,
        batch_size=args.batch_size,
    )
