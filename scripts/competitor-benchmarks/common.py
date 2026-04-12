#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2024-2025 ArcherDB Contributors
"""
Common utilities for competitor benchmark drivers.

Provides shared functionality for consistent benchmarking methodology
across all competitor databases: random event generation, timing,
percentile calculation, and result formatting.

Usage:
    from common import BenchmarkResult, generate_events, percentile, Timer
"""

import random
import time
import uuid
import math
import statistics
from dataclasses import dataclass, field
from typing import List, Optional, Callable, Any
from contextlib import contextmanager


@dataclass
class GeoEvent:
    """A geospatial event matching ArcherDB's GeoEvent schema."""
    entity_id: str
    timestamp_ns: int
    latitude: float
    longitude: float
    altitude_mm: int = 0
    heading_centideg: int = 0
    speed_mm_s: int = 0
    accuracy_mm: int = 1000
    content: Optional[bytes] = None


@dataclass
class BenchmarkResult:
    """Results from a benchmark run."""
    operation: str
    count: int
    duration_sec: float
    latencies_ms: List[float] = field(default_factory=list)
    errors: int = 0

    @property
    def ops_per_sec(self) -> float:
        """Calculate operations per second."""
        if self.duration_sec == 0:
            return 0
        return self.count / self.duration_sec

    @property
    def p50(self) -> float:
        """Calculate 50th percentile latency in ms."""
        return percentile(self.latencies_ms, 50)

    @property
    def p95(self) -> float:
        """Calculate 95th percentile latency in ms."""
        return percentile(self.latencies_ms, 95)

    @property
    def p99(self) -> float:
        """Calculate 99th percentile latency in ms."""
        return percentile(self.latencies_ms, 99)

    @property
    def p999(self) -> float:
        """Calculate 99.9th percentile latency in ms."""
        return percentile(self.latencies_ms, 99.9)

    def to_dict(self) -> dict:
        """Convert to dictionary for JSON serialization."""
        return {
            "operation": self.operation,
            "count": self.count,
            "duration_sec": round(self.duration_sec, 3),
            "ops_per_sec": round(self.ops_per_sec, 2),
            "p50_ms": round(self.p50, 3),
            "p95_ms": round(self.p95, 3),
            "p99_ms": round(self.p99, 3),
            "p99.9_ms": round(self.p999, 3),
            "errors": self.errors,
        }

    def __str__(self) -> str:
        return (
            f"{self.operation}: {self.count:,} ops in {self.duration_sec:.2f}s "
            f"({self.ops_per_sec:,.0f} ops/s) "
            f"p50={self.p50:.3f}ms p95={self.p95:.3f}ms "
            f"p99={self.p99:.3f}ms p99.9={self.p999:.3f}ms"
        )


class Timer:
    """Context manager for timing operations."""

    def __init__(self):
        self.start_time: float = 0
        self.end_time: float = 0
        self.duration_sec: float = 0

    def __enter__(self):
        self.start_time = time.perf_counter()
        return self

    def __exit__(self, *args):
        self.end_time = time.perf_counter()
        self.duration_sec = self.end_time - self.start_time


@contextmanager
def measure_latency(latencies: List[float]):
    """Context manager to measure and record latency in milliseconds."""
    start = time.perf_counter()
    try:
        yield
    finally:
        end = time.perf_counter()
        latencies.append((end - start) * 1000)  # Convert to ms


def percentile(data: List[float], p: float) -> float:
    """
    Calculate the p-th percentile of a list of values.

    Args:
        data: List of numeric values
        p: Percentile to calculate (0-100)

    Returns:
        The p-th percentile value, or 0 if data is empty
    """
    if not data:
        return 0.0

    sorted_data = sorted(data)
    n = len(sorted_data)

    # Use linear interpolation
    k = (p / 100) * (n - 1)
    f = math.floor(k)
    c = math.ceil(k)

    if f == c:
        return sorted_data[int(k)]

    return sorted_data[int(f)] * (c - k) + sorted_data[int(c)] * (k - f)


def generate_entity_ids(count: int, seed: int = 42) -> List[str]:
    """
    Generate a list of unique entity UUIDs.

    Args:
        count: Number of entity IDs to generate
        seed: Random seed for reproducibility

    Returns:
        List of UUID strings
    """
    random.seed(seed)
    return [str(uuid.UUID(int=random.getrandbits(128))) for _ in range(count)]


def generate_events(
    entity_count: int,
    event_count: int,
    seed: int = 42
) -> List[GeoEvent]:
    """
    Generate a list of GeoEvents with random but reproducible data.

    Generates events distributed uniformly across the globe, matching
    the workload characteristics used in ArcherDB benchmarks.

    Args:
        entity_count: Number of unique entities
        event_count: Total number of events to generate
        seed: Random seed for reproducibility

    Returns:
        List of GeoEvent objects
    """
    random.seed(seed)

    # Generate entity IDs
    entity_ids = generate_entity_ids(entity_count, seed)

    events = []
    base_timestamp = 1700000000000000000  # 2023-11-14 in nanoseconds

    for i in range(event_count):
        entity_id = entity_ids[i % entity_count]

        # Uniform global distribution
        lat = random.uniform(-90, 90)
        lon = random.uniform(-180, 180)

        event = GeoEvent(
            entity_id=entity_id,
            timestamp_ns=base_timestamp + i * 1000000,  # 1ms apart
            latitude=lat,
            longitude=lon,
            altitude_mm=random.randint(0, 10000000),  # 0-10km
            heading_centideg=random.randint(0, 36000),  # 0-360 degrees
            speed_mm_s=random.randint(0, 50000),  # 0-50 m/s (~180 km/h)
            accuracy_mm=random.randint(100, 10000),  # 10cm-10m
            content=None,
        )
        events.append(event)

    return events


def generate_query_points(
    count: int,
    seed: int = 12345
) -> List[tuple]:
    """
    Generate random query center points.

    Args:
        count: Number of query points to generate
        seed: Random seed for reproducibility

    Returns:
        List of (latitude, longitude) tuples
    """
    random.seed(seed)
    return [(random.uniform(-90, 90), random.uniform(-180, 180)) for _ in range(count)]


def run_benchmark(
    name: str,
    operation: Callable[[], Any],
    count: int,
    warmup: int = 100
) -> BenchmarkResult:
    """
    Run a benchmark with warmup and timing.

    Args:
        name: Name of the benchmark operation
        operation: Function to benchmark (called count times)
        count: Number of operations to perform
        warmup: Number of warmup operations

    Returns:
        BenchmarkResult with timing data
    """
    # Warmup phase
    for _ in range(warmup):
        try:
            operation()
        except Exception:
            pass

    # Benchmark phase
    latencies = []
    errors = 0

    with Timer() as timer:
        for _ in range(count):
            try:
                with measure_latency(latencies):
                    operation()
            except Exception:
                errors += 1

    return BenchmarkResult(
        operation=name,
        count=count,
        duration_sec=timer.duration_sec,
        latencies_ms=latencies,
        errors=errors,
    )


def format_results(results: List[BenchmarkResult], database: str) -> str:
    """
    Format benchmark results as a human-readable report.

    Args:
        results: List of BenchmarkResult objects
        database: Name of the database being benchmarked

    Returns:
        Formatted report string
    """
    lines = [
        f"=== {database} Benchmark Results ===",
        "",
        f"{'Operation':<20} {'Count':>10} {'Ops/s':>12} {'p50':>10} {'p95':>10} {'p99':>10} {'p99.9':>10}",
        "-" * 92,
    ]

    for result in results:
        lines.append(
            f"{result.operation:<20} {result.count:>10,} {result.ops_per_sec:>12,.0f} "
            f"{result.p50:>10.3f} {result.p95:>10.3f} {result.p99:>10.3f} {result.p999:>10.3f}"
        )

    lines.append("-" * 92)
    return "\n".join(lines)


def save_results_csv(
    results: List[BenchmarkResult],
    database: str,
    filepath: str
) -> None:
    """
    Save benchmark results to CSV file.

    Args:
        results: List of BenchmarkResult objects
        database: Name of the database being benchmarked
        filepath: Path to output CSV file
    """
    import csv

    with open(filepath, 'w', newline='') as f:
        writer = csv.writer(f)
        writer.writerow([
            'database', 'operation', 'count', 'duration_sec', 'ops_per_sec',
            'p50_ms', 'p95_ms', 'p99_ms', 'p999_ms', 'errors'
        ])

        for result in results:
            writer.writerow([
                database,
                result.operation,
                result.count,
                round(result.duration_sec, 3),
                round(result.ops_per_sec, 2),
                round(result.p50, 3),
                round(result.p95, 3),
                round(result.p99, 3),
                round(result.p999, 3),
                result.errors,
            ])


if __name__ == "__main__":
    # Self-test
    print("Testing common.py utilities...")

    # Test percentile calculation
    data = list(range(1, 101))
    assert percentile(data, 50) == 50.5, "p50 failed"
    assert percentile(data, 99) == 99.01, f"p99 failed: {percentile(data, 99)}"
    print("  Percentile calculation: OK")

    # Test event generation
    events = generate_events(100, 1000)
    assert len(events) == 1000, "Event count mismatch"
    assert len(set(e.entity_id for e in events)) == 100, "Entity count mismatch"
    print("  Event generation: OK")

    # Test timer
    with Timer() as t:
        time.sleep(0.1)
    assert 0.09 < t.duration_sec < 0.15, f"Timer failed: {t.duration_sec}"
    print("  Timer: OK")

    # Test benchmark result
    result = BenchmarkResult(
        operation="test",
        count=1000,
        duration_sec=1.0,
        latencies_ms=[1.0] * 1000,
    )
    assert result.ops_per_sec == 1000, "ops/sec failed"
    assert result.p50 == 1.0, "p50 failed"
    print("  BenchmarkResult: OK")

    print("\nAll tests passed!")
