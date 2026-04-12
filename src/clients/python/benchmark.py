#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2024-2025 ArcherDB Contributors
"""
ArcherDB Python SDK Performance Benchmark

This benchmark tests:
- Insert throughput (events/sec)
- Query latency (p50, p99)
- Batch efficiency
- Memory usage

Target specs from design doc:
- Insert: 1M events/sec
- UUID lookup: p99 < 500μs
- Radius query: p99 < 50ms
- Polygon query: p99 < 100ms
"""

import argparse
import os
import random
import statistics
import sys
import time
from dataclasses import dataclass
from typing import List, Optional

# Add the SDK path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'src'))

from archerdb.client import (
    GeoClientConfig,
    GeoClientSync,
    RetryConfig,
    id as generate_id,
)
from archerdb.types import (
    GeoEvent,
    create_geo_event,
    create_radius_query,
    create_polygon_query,
    degrees_to_nano,
)


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
    """Calculate percentile of a sorted list."""
    if not data:
        return 0.0
    sorted_data = sorted(data)
    k = (len(sorted_data) - 1) * p / 100
    f = int(k)
    c = f + 1 if f + 1 < len(sorted_data) else f
    return sorted_data[f] + (k - f) * (sorted_data[c] - sorted_data[f])


class ArcherDBBenchmark:
    """Performance benchmark for ArcherDB Python SDK."""

    def __init__(
        self,
        cluster_id: int = 0,
        addresses: List[str] = None,
        warmup_events: int = 1000,
        test_events: int = 100000,
        batch_size: int = 1000,
    ):
        self.cluster_id = cluster_id
        self.addresses = addresses or ["127.0.0.1:3000"]
        self.warmup_events = warmup_events
        self.test_events = test_events
        self.batch_size = batch_size
        self.client: Optional[GeoClientSync] = None
        self.entity_ids: List[int] = []

    def connect(self) -> bool:
        """Connect to the cluster."""
        try:
            config = GeoClientConfig(
                cluster_id=self.cluster_id,
                addresses=self.addresses,
                retry=RetryConfig(
                    enabled=True,
                    max_retries=3,
                    base_backoff_ms=50,
                ),
            )
            self.client = GeoClientSync(config)
            return True
        except Exception as e:
            print(f"Failed to connect: {e}")
            return False

    def disconnect(self):
        """Disconnect from the cluster."""
        if self.client:
            self.client.close()
            self.client = None

    def generate_random_event(self) -> GeoEvent:
        """Generate a random GeoEvent for testing."""
        entity_id = generate_id()
        self.entity_ids.append(entity_id)

        # Random location in San Francisco area
        lat = 37.7 + random.random() * 0.1
        lon = -122.5 + random.random() * 0.1

        return create_geo_event(
            entity_id=entity_id,
            latitude=lat,
            longitude=lon,
            velocity_mps=random.random() * 30,
            heading=random.random() * 360,
            accuracy_m=random.random() * 10 + 1,
            ttl_seconds=86400,
        )

    def benchmark_insert(self) -> BenchmarkResult:
        """Benchmark insert throughput."""
        print(f"\n[INSERT] Testing with {self.test_events} events in batches of {self.batch_size}")

        # Warmup
        print(f"  Warming up with {self.warmup_events} events...")
        for i in range(0, self.warmup_events, self.batch_size):
            batch = self.client.create_batch()
            for _ in range(min(self.batch_size, self.warmup_events - i)):
                batch.add(self.generate_random_event())
            batch.commit()

        # Actual test
        latencies_us = []
        errors = 0
        start_time = time.perf_counter()

        for i in range(0, self.test_events, self.batch_size):
            batch_start = time.perf_counter()
            try:
                batch = self.client.create_batch()
                for _ in range(min(self.batch_size, self.test_events - i)):
                    batch.add(self.generate_random_event())
                results = batch.commit()
                errors += len(results)
            except Exception as e:
                print(f"  Batch error: {e}")
                errors += self.batch_size
                continue

            batch_end = time.perf_counter()
            batch_latency_us = (batch_end - batch_start) * 1_000_000
            latencies_us.append(batch_latency_us)

            if (i + self.batch_size) % 10000 == 0:
                print(f"  Progress: {i + self.batch_size}/{self.test_events}")

        end_time = time.perf_counter()
        duration_ms = (end_time - start_time) * 1000
        ops_per_sec = self.test_events / (duration_ms / 1000)

        return BenchmarkResult(
            operation="INSERT",
            total_ops=self.test_events,
            duration_ms=duration_ms,
            ops_per_sec=ops_per_sec,
            latency_p50_us=percentile(latencies_us, 50),
            latency_p99_us=percentile(latencies_us, 99),
            latency_avg_us=statistics.mean(latencies_us) if latencies_us else 0,
            errors=errors,
        )

    def benchmark_query_uuid(self, num_queries: int = 10000) -> BenchmarkResult:
        """Benchmark UUID lookup latency."""
        print(f"\n[QUERY_UUID] Testing with {num_queries} lookups")

        if not self.entity_ids:
            print("  No entity IDs available, skipping...")
            return BenchmarkResult("QUERY_UUID", 0, 0, 0, 0, 0, 0, 0)

        # Warmup
        print("  Warming up...")
        for _ in range(min(100, len(self.entity_ids))):
            entity_id = random.choice(self.entity_ids)
            self.client.get_latest_by_uuid(entity_id)

        # Actual test
        latencies_us = []
        errors = 0
        start_time = time.perf_counter()

        for i in range(num_queries):
            entity_id = random.choice(self.entity_ids)
            query_start = time.perf_counter()
            try:
                result = self.client.get_latest_by_uuid(entity_id)
                if result is None:
                    errors += 1
            except Exception as e:
                errors += 1
                continue

            query_end = time.perf_counter()
            latency_us = (query_end - query_start) * 1_000_000
            latencies_us.append(latency_us)

            if (i + 1) % 1000 == 0:
                print(f"  Progress: {i + 1}/{num_queries}")

        end_time = time.perf_counter()
        duration_ms = (end_time - start_time) * 1000
        ops_per_sec = num_queries / (duration_ms / 1000)

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

    def benchmark_query_radius(self, num_queries: int = 1000) -> BenchmarkResult:
        """Benchmark radius query latency."""
        print(f"\n[QUERY_RADIUS] Testing with {num_queries} queries")

        # Warmup
        print("  Warming up...")
        for _ in range(min(10, num_queries)):
            lat = 37.7 + random.random() * 0.1
            lon = -122.5 + random.random() * 0.1
            self.client.query_radius(lat, lon, 1000, limit=100)

        # Actual test
        latencies_us = []
        errors = 0
        start_time = time.perf_counter()

        for i in range(num_queries):
            lat = 37.7 + random.random() * 0.1
            lon = -122.5 + random.random() * 0.1
            radius_m = 100 + random.random() * 2000  # 100m to 2km

            query_start = time.perf_counter()
            try:
                result = self.client.query_radius(lat, lon, radius_m, limit=1000)
            except Exception as e:
                errors += 1
                continue

            query_end = time.perf_counter()
            latency_us = (query_end - query_start) * 1_000_000
            latencies_us.append(latency_us)

            if (i + 1) % 100 == 0:
                print(f"  Progress: {i + 1}/{num_queries}")

        end_time = time.perf_counter()
        duration_ms = (end_time - start_time) * 1000
        ops_per_sec = num_queries / (duration_ms / 1000)

        return BenchmarkResult(
            operation="QUERY_RADIUS",
            total_ops=num_queries,
            duration_ms=duration_ms,
            ops_per_sec=ops_per_sec,
            latency_p50_us=percentile(latencies_us, 50),
            latency_p99_us=percentile(latencies_us, 99),
            latency_avg_us=statistics.mean(latencies_us) if latencies_us else 0,
            errors=errors,
        )

    def benchmark_query_polygon(self, num_queries: int = 500) -> BenchmarkResult:
        """Benchmark polygon query latency."""
        print(f"\n[QUERY_POLYGON] Testing with {num_queries} queries")

        # Warmup
        print("  Warming up...")
        for _ in range(min(5, num_queries)):
            # Random rectangle in San Francisco
            lat = 37.7 + random.random() * 0.05
            lon = -122.5 + random.random() * 0.05
            size = 0.01 + random.random() * 0.02
            vertices = [
                (lat, lon),
                (lat + size, lon),
                (lat + size, lon + size),
                (lat, lon + size),
            ]
            self.client.query_polygon(vertices, limit=100)

        # Actual test
        latencies_us = []
        errors = 0
        start_time = time.perf_counter()

        for i in range(num_queries):
            lat = 37.7 + random.random() * 0.05
            lon = -122.5 + random.random() * 0.05
            size = 0.01 + random.random() * 0.02
            vertices = [
                (lat, lon),
                (lat + size, lon),
                (lat + size, lon + size),
                (lat, lon + size),
            ]

            query_start = time.perf_counter()
            try:
                result = self.client.query_polygon(vertices, limit=1000)
            except Exception as e:
                errors += 1
                continue

            query_end = time.perf_counter()
            latency_us = (query_end - query_start) * 1_000_000
            latencies_us.append(latency_us)

            if (i + 1) % 50 == 0:
                print(f"  Progress: {i + 1}/{num_queries}")

        end_time = time.perf_counter()
        duration_ms = (end_time - start_time) * 1000
        ops_per_sec = num_queries / (duration_ms / 1000)

        return BenchmarkResult(
            operation="QUERY_POLYGON",
            total_ops=num_queries,
            duration_ms=duration_ms,
            ops_per_sec=ops_per_sec,
            latency_p50_us=percentile(latencies_us, 50),
            latency_p99_us=percentile(latencies_us, 99),
            latency_avg_us=statistics.mean(latencies_us) if latencies_us else 0,
            errors=errors,
        )

    def print_result(self, result: BenchmarkResult):
        """Print benchmark result."""
        print(f"\n{'='*60}")
        print(f"  {result.operation} Results")
        print(f"{'='*60}")
        print(f"  Total operations:  {result.total_ops:,}")
        print(f"  Duration:          {result.duration_ms:.2f} ms")
        print(f"  Throughput:        {result.ops_per_sec:,.2f} ops/sec")
        print(f"  Latency p50:       {result.latency_p50_us:.2f} μs")
        print(f"  Latency p99:       {result.latency_p99_us:.2f} μs")
        print(f"  Latency avg:       {result.latency_avg_us:.2f} μs")
        print(f"  Errors:            {result.errors}")
        print(f"{'='*60}")

    def run(self):
        """Run all benchmarks."""
        print("\n" + "="*60)
        print("  ArcherDB Python SDK Performance Benchmark")
        print("="*60)
        print(f"  Cluster ID: {self.cluster_id}")
        print(f"  Addresses:  {', '.join(self.addresses)}")
        print(f"  Test events: {self.test_events:,}")
        print(f"  Batch size: {self.batch_size}")
        print("="*60)

        if not self.connect():
            print("Failed to connect to cluster, exiting.")
            return

        try:
            # Run benchmarks
            results = []

            insert_result = self.benchmark_insert()
            self.print_result(insert_result)
            results.append(insert_result)

            uuid_result = self.benchmark_query_uuid()
            self.print_result(uuid_result)
            results.append(uuid_result)

            radius_result = self.benchmark_query_radius()
            self.print_result(radius_result)
            results.append(radius_result)

            polygon_result = self.benchmark_query_polygon()
            self.print_result(polygon_result)
            results.append(polygon_result)

            # Summary
            print("\n" + "="*60)
            print("  SUMMARY")
            print("="*60)
            for r in results:
                status = "PASS" if r.errors == 0 else f"FAIL ({r.errors} errors)"
                print(f"  {r.operation:15} {r.ops_per_sec:>12,.0f} ops/sec  [{status}]")
            print("="*60)

        finally:
            self.disconnect()


def main():
    parser = argparse.ArgumentParser(description="ArcherDB Python SDK Performance Benchmark")
    parser.add_argument("--cluster-id", type=int, default=0, help="Cluster ID")
    parser.add_argument(
        "--addresses",
        type=str,
        default="127.0.0.1:3000",
        help="Comma-separated replica addresses",
    )
    parser.add_argument(
        "--events",
        type=int,
        default=100000,
        help="Number of test events",
    )
    parser.add_argument(
        "--batch-size",
        type=int,
        default=1000,
        help="Batch size for inserts",
    )
    parser.add_argument(
        "--warmup",
        type=int,
        default=1000,
        help="Number of warmup events",
    )

    args = parser.parse_args()

    benchmark = ArcherDBBenchmark(
        cluster_id=args.cluster_id,
        addresses=args.addresses.split(","),
        warmup_events=args.warmup,
        test_events=args.events,
        batch_size=args.batch_size,
    )

    benchmark.run()


if __name__ == "__main__":
    main()
