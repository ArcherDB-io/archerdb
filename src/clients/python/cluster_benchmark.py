#!/usr/bin/env python3
"""
ArcherDB Low-Level Performance Benchmark

This benchmark uses the native TigerBeetle bindings directly to measure
actual server performance, bypassing the high-level SDK skeleton.

Target specs from design doc:
- Insert: 1M events/sec (single-node: target 100k+)
- UUID lookup: p99 < 500us
- Radius query: p99 < 50ms
- Polygon query: p99 < 100ms
"""

import argparse
import ctypes
import os
import random
import statistics
import sys
import threading
import time
from dataclasses import dataclass
from typing import List, Optional

sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'src'))

from tigerbeetle import bindings
from tigerbeetle.lib import c_uint128


# ============================================================================
# Data Structures (matching Zig extern structs)
# ============================================================================

class CGeoEvent(ctypes.Structure):
    """128-byte GeoEvent matching Zig extern struct."""
    _fields_ = [
        ("id", ctypes.c_uint8 * 16),
        ("entity_id", ctypes.c_uint8 * 16),
        ("correlation_id", ctypes.c_uint8 * 16),
        ("user_data", ctypes.c_uint8 * 16),
        ("lat_nano", ctypes.c_int64),
        ("lon_nano", ctypes.c_int64),
        ("group_id", ctypes.c_uint64),
        ("timestamp", ctypes.c_uint64),
        ("altitude_mm", ctypes.c_int32),
        ("velocity_mms", ctypes.c_uint32),
        ("ttl_seconds", ctypes.c_uint32),
        ("accuracy_mm", ctypes.c_uint32),
        ("heading_cdeg", ctypes.c_uint16),
        ("flags", ctypes.c_uint16),
        ("reserved", ctypes.c_uint8 * 12),
    ]


class CQueryUuidFilter(ctypes.Structure):
    """128-byte QueryUuidFilter."""
    _fields_ = [
        ("entity_id", ctypes.c_uint8 * 16),
        ("limit", ctypes.c_uint32),
        ("reserved", ctypes.c_uint8 * 108),
    ]


assert ctypes.sizeof(CGeoEvent) == 128
assert ctypes.sizeof(CQueryUuidFilter) == 128


# ============================================================================
# Helpers
# ============================================================================

def compute_pseudo_s2_cell(lat_nano: int, lon_nano: int) -> int:
    """Compute pseudo-S2 cell ID from coordinates."""
    product = lat_nano * lon_nano
    return abs(product) & 0xFFFFFFFFFFFFFFFF


def pack_composite_id(s2_cell_id: int, timestamp_ns: int) -> int:
    """Pack S2 cell ID and timestamp into composite u128 ID."""
    return (s2_cell_id << 64) | (timestamp_ns & 0xFFFFFFFFFFFFFFFF)


def set_u128_field(field: ctypes.Array, value: int) -> None:
    """Set a u128 ctypes field from Python int."""
    value_bytes = value.to_bytes(16, 'little')
    for i in range(16):
        field[i] = value_bytes[i]


def get_u128_field(field: ctypes.Array) -> int:
    """Get Python int from u128 ctypes field."""
    return int.from_bytes(bytes(field), 'little')


def create_random_event(entity_id: int) -> CGeoEvent:
    """Create a random GeoEvent for benchmarking."""
    event = CGeoEvent()

    set_u128_field(event.entity_id, entity_id)

    # Random coordinates in San Francisco area
    # Lat: 37.7 to 37.8, Lon: -122.5 to -122.4
    event.lat_nano = int((37.7 + random.random() * 0.1) * 1e9)
    event.lon_nano = int((-122.5 + random.random() * 0.1) * 1e9)

    # Compute composite ID
    s2_cell = compute_pseudo_s2_cell(event.lat_nano, event.lon_nano)
    timestamp_ns = int(time.time_ns())
    composite_id = pack_composite_id(s2_cell, timestamp_ns)
    set_u128_field(event.id, composite_id)

    # Random other fields
    event.velocity_mms = random.randint(0, 30000)
    event.heading_cdeg = random.randint(0, 35999)
    event.accuracy_mm = random.randint(1000, 10000)
    event.ttl_seconds = 86400
    event.altitude_mm = random.randint(-100, 1000)
    event.flags = 0
    event.group_id = 0
    event.timestamp = 0

    return event


# ============================================================================
# Benchmark Results
# ============================================================================

@dataclass
class BenchmarkResult:
    """Results from a benchmark run."""
    operation: str
    total_ops: int
    duration_ms: float
    ops_per_sec: float
    latency_p50_us: float
    latency_p99_us: float
    latency_avg_us: float
    errors: int


def percentile(data: List[float], p: float) -> float:
    """Calculate percentile."""
    if not data:
        return 0.0
    sorted_data = sorted(data)
    k = (len(sorted_data) - 1) * p / 100
    f = int(k)
    c = f + 1 if f + 1 < len(sorted_data) else f
    return sorted_data[f] + (k - f) * (sorted_data[c] - sorted_data[f])


def print_result(result: BenchmarkResult) -> None:
    """Print formatted benchmark result."""
    print()
    print("=" * 60)
    print(f"  {result.operation} Results")
    print("=" * 60)
    print(f"  Total operations:  {result.total_ops:,}")
    print(f"  Duration:          {result.duration_ms:.2f} ms")
    print(f"  Throughput:        {result.ops_per_sec:,.2f} ops/sec")
    print(f"  Latency p50:       {result.latency_p50_us:.2f} us")
    print(f"  Latency p99:       {result.latency_p99_us:.2f} us")
    print(f"  Latency avg:       {result.latency_avg_us:.2f} us")
    print(f"  Errors:            {result.errors}")
    print("=" * 60)


# ============================================================================
# Benchmark Client
# ============================================================================

class BenchmarkClient:
    """Low-level benchmark client using native bindings."""

    def __init__(self, cluster_id: int, addresses: str):
        self.cluster_id = cluster_id
        self.addresses = addresses
        self.client = None
        self._callback_received = threading.Event()
        self._callback_result = [None, None, None]  # [status, data_size, data]
        self._entity_ids: List[int] = []

    def connect(self) -> bool:
        """Connect to the cluster."""
        @bindings.OnCompletion
        def on_completion(ctx, packet, timestamp, data_ptr, data_size):
            self._callback_result[0] = packet.contents.status
            self._callback_result[1] = data_size
            if data_size > 0 and data_ptr:
                self._callback_result[2] = bytes(
                    ctypes.cast(data_ptr, ctypes.POINTER(ctypes.c_ubyte * data_size)).contents
                )
            else:
                self._callback_result[2] = None
            self._callback_received.set()

        self._on_completion = on_completion  # Keep reference
        self.client = bindings.CClient()
        cluster_id = c_uint128.from_param(self.cluster_id)
        addresses = self.addresses.encode()

        init_status = bindings.tb_client_init(
            ctypes.byref(self.client),
            ctypes.cast(ctypes.byref(cluster_id), ctypes.POINTER(ctypes.c_uint8 * 16)),
            addresses,
            len(addresses),
            42,
            on_completion
        )

        return init_status == bindings.InitStatus.SUCCESS

    def disconnect(self) -> None:
        """Disconnect from cluster."""
        if self.client:
            bindings.tb_client_deinit(ctypes.byref(self.client))
            self.client = None

    def _submit_and_wait(self, operation: int, data: ctypes.Array, timeout: float = 30.0) -> tuple:
        """Submit operation and wait for result."""
        packet = bindings.CPacket()
        packet.user_data = 1
        packet.user_tag = 0
        packet.operation = operation
        packet.status = bindings.PacketStatus.OK
        packet.data = ctypes.cast(data, ctypes.c_void_p)
        packet.data_size = ctypes.sizeof(data)

        self._callback_received.clear()
        self._callback_result[0] = None
        self._callback_result[1] = None
        self._callback_result[2] = None

        client_status = bindings.tb_client_submit(ctypes.byref(self.client), ctypes.byref(packet))
        if client_status != bindings.ClientStatus.OK:
            return (None, 0, None)

        if not self._callback_received.wait(timeout=timeout):
            return (None, 0, None)

        return tuple(self._callback_result)

    def insert_batch(self, events: List[CGeoEvent]) -> int:
        """Insert batch of events. Returns number of errors."""
        if not events:
            return 0

        event_array = (CGeoEvent * len(events))(*events)
        status, data_size, data = self._submit_and_wait(
            bindings.Operation.INSERT_EVENTS.value,
            event_array
        )

        if status is None:
            return len(events)  # All failed

        if status != bindings.PacketStatus.OK.value:
            return len(events)

        # Each error is 8 bytes (index:u32 + result:u32)
        return data_size // 8

    def query_uuid(self, entity_id: int) -> Optional[CGeoEvent]:
        """Query by UUID. Returns event or None."""
        query = CQueryUuidFilter()
        set_u128_field(query.entity_id, entity_id)
        query.limit = 1

        query_array = (CQueryUuidFilter * 1)(query)
        status, data_size, data = self._submit_and_wait(
            bindings.Operation.QUERY_UUID.value,
            query_array
        )

        if status is None or status != bindings.PacketStatus.OK.value:
            return None

        if data_size == 128 and data:  # One GeoEvent
            return CGeoEvent.from_buffer_copy(data)

        return None

    def benchmark_insert(self, num_events: int, batch_size: int, warmup: int) -> BenchmarkResult:
        """Benchmark INSERT_EVENTS operation."""
        print(f"\n[INSERT] Testing with {num_events} events in batches of {batch_size}")

        # Warmup
        print(f"  Warming up with {warmup} events...")
        for i in range(0, warmup, batch_size):
            count = min(batch_size, warmup - i)
            events = [create_random_event(i + j + 1) for j in range(count)]
            self.insert_batch(events)

        # Clear entity_ids for actual test
        self._entity_ids = []

        # Actual benchmark
        latencies_us: List[float] = []
        errors = 0
        start_time = time.perf_counter()

        for i in range(0, num_events, batch_size):
            batch_start = time.perf_counter()

            count = min(batch_size, num_events - i)
            entity_base = warmup + i + 1
            events = []
            for j in range(count):
                entity_id = entity_base + j
                event = create_random_event(entity_id)
                events.append(event)
                self._entity_ids.append(entity_id)

            batch_errors = self.insert_batch(events)
            errors += batch_errors

            batch_end = time.perf_counter()
            latencies_us.append((batch_end - batch_start) * 1_000_000)

            if (i + batch_size) % 10000 == 0:
                print(f"  Progress: {i + batch_size}/{num_events}")

        end_time = time.perf_counter()
        duration_ms = (end_time - start_time) * 1000
        ops_per_sec = num_events / (duration_ms / 1000) if duration_ms > 0 else 0

        return BenchmarkResult(
            operation="INSERT",
            total_ops=num_events,
            duration_ms=duration_ms,
            ops_per_sec=ops_per_sec,
            latency_p50_us=percentile(latencies_us, 50),
            latency_p99_us=percentile(latencies_us, 99),
            latency_avg_us=statistics.mean(latencies_us) if latencies_us else 0,
            errors=errors,
        )

    def benchmark_query_uuid(self, num_queries: int) -> BenchmarkResult:
        """Benchmark QUERY_UUID operation."""
        print(f"\n[QUERY_UUID] Testing with {num_queries} lookups")

        if not self._entity_ids:
            print("  No entity IDs available, skipping...")
            return BenchmarkResult("QUERY_UUID", 0, 0, 0, 0, 0, 0, 0)

        # Warmup
        print("  Warming up...")
        warmup_count = min(100, len(self._entity_ids))
        for i in range(warmup_count):
            entity_id = random.choice(self._entity_ids)
            self.query_uuid(entity_id)

        # Actual benchmark
        latencies_us: List[float] = []
        errors = 0
        start_time = time.perf_counter()

        for i in range(num_queries):
            entity_id = random.choice(self._entity_ids)

            query_start = time.perf_counter()
            result = self.query_uuid(entity_id)
            query_end = time.perf_counter()

            if result is None:
                errors += 1

            latencies_us.append((query_end - query_start) * 1_000_000)

            if (i + 1) % 1000 == 0:
                print(f"  Progress: {i + 1}/{num_queries}")

        end_time = time.perf_counter()
        duration_ms = (end_time - start_time) * 1000
        ops_per_sec = num_queries / (duration_ms / 1000) if duration_ms > 0 else 0

        return BenchmarkResult(
            operation="QUERY_UUID",
            total_ops=num_queries,
            duration_ms=duration_ms,
            ops_per_sec=ops_per_sec,
            latency_p50_us=percentile(latencies_us, 50),
            latency_p99_us=percentile(latencies_us, 99),
            latency_avg_us=statistics.mean(latencies_us) if latencies_us else 0,
            errors=errors,
        )


# ============================================================================
# Main
# ============================================================================

def main():
    parser = argparse.ArgumentParser(description="ArcherDB Low-Level Benchmark")
    parser.add_argument("--cluster-id", type=int, default=0, help="Cluster ID")
    parser.add_argument("--addresses", default="127.0.0.1:3001", help="Replica addresses")
    parser.add_argument("--events", type=int, default=10000, help="Number of test events")
    parser.add_argument("--batch-size", type=int, default=1000, help="Batch size")
    parser.add_argument("--warmup", type=int, default=1000, help="Warmup events")
    parser.add_argument("--queries", type=int, default=5000, help="Number of queries")
    args = parser.parse_args()

    print("=" * 60)
    print("  ArcherDB Low-Level Performance Benchmark")
    print("=" * 60)
    print(f"  Cluster ID: {args.cluster_id}")
    print(f"  Addresses:  {args.addresses}")
    print(f"  Test events: {args.events}")
    print(f"  Batch size: {args.batch_size}")
    print(f"  Warmup events: {args.warmup}")
    print(f"  Queries: {args.queries}")
    print("=" * 60)

    client = BenchmarkClient(args.cluster_id, args.addresses)

    if not client.connect():
        print("FAIL: Could not connect to cluster")
        sys.exit(1)

    print("\nConnected to cluster!")

    try:
        # INSERT benchmark
        insert_result = client.benchmark_insert(args.events, args.batch_size, args.warmup)
        print_result(insert_result)

        # QUERY_UUID benchmark
        query_result = client.benchmark_query_uuid(args.queries)
        print_result(query_result)

        # Summary
        print("\n" + "=" * 60)
        print("  BENCHMARK SUMMARY")
        print("=" * 60)
        print(f"  INSERT:     {insert_result.ops_per_sec:,.0f} events/sec (target: 1M)")
        print(f"  QUERY_UUID: {query_result.latency_p99_us:.0f} us p99 (target: <500us)")
        print("=" * 60)

    finally:
        client.disconnect()
        print("\nDisconnected.")


if __name__ == "__main__":
    main()
